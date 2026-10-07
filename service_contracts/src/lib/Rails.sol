// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {Errors} from "../Errors.sol";
import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {SessionKeyRegistry} from "@session-key-registry/SessionKeyRegistry.sol";
import {IPDPVerifier} from "@pdp/interfaces/IPDPVerifier.sol";
import {ServiceProviderRegistry} from "../ServiceProviderRegistry.sol";
import {SignatureVerificationLib} from "./SignatureVerificationLib.sol";
import {
    CurrencyAdded,
    CurrencyUpdated,
    MAX_COMMISSION_BPS,
    MIN_CURRENCY_DECIMALS,
    PRICE_DECIMALS,
    PaymentTerms,
    PaymentTermsStorage
} from "./PaymentTermsStorage.sol";
import {
    CDN_LOCKUP_PERIOD,
    DATASET_FEE_PER_EPOCH,
    DATASET_FEE_PER_MONTH,
    DEFAULT_CACHE_MISS_LOCKUP_AMOUNT,
    DEFAULT_CDN_LOCKUP_AMOUNT,
    DEFAULT_LOCKUP_PERIOD,
    EPOCHS_PER_MONTH,
    LIFECYCLE_RESERVE_TARGET,
    REPLENISH_THRESHOLD,
    CREATE_DATA_SET_FEE,
    SERVICE_COMMISSION_BPS,
    calculateStorageRateAtPrice,
    toTokenUnits
} from "./PriceListUSDFC.sol";

/// @dev Root slot of FWSS's `dataSetInfo` mapping: `FilecoinWarmStorageServiceLayout.DATA_SET_INFO_SLOT`, slot 7 of
///      the frozen legacy layout (also slot 7 in the module branch's FWSSStorage). Rails cannot import the generated
///      layout, which compiles FWSS, which links Rails. Pinned against the generated layout by MultiCurrencyTest.
bytes32 constant DATA_SET_INFO_ROOT_SLOT = bytes32(uint256(7));

/// @dev Field-for-field copy of FWSS's `DataSetInfo` (frozen upstream; `FWSSStorage.DataSetInfo` on the module
///      branch), so Rails can read and write a data set's record without importing the FWSS contract.
struct DataSetInfoRecord {
    uint256 pdpRailId;
    uint256 cacheMissRailId;
    uint256 cdnRailId;
    address payer;
    address payee;
    address serviceProvider;
    uint256 commissionBps;
    uint256 clientDataSetId;
    uint256 pdpEndEpoch;
    uint256 providerId;
    uint96 pendingOneTimePayments; // 18-decimal USD
    uint96 lifecycleReserveBalance; // token units
}

/// @dev The FWSS getters that stay routed after the ERC-8167 dispatch transition (upstream's IFWSSConfig).
interface IFWSSConfig {
    function paymentsContractAddress() external view returns (address);
    function pdpVerifierAddress() external view returns (address);
}

event CDNPaymentRailsToppedUp(
    uint256 indexed dataSetId,
    uint256 cdnAmountAdded,
    uint256 totalCdnLockup,
    uint256 cacheMissAmountAdded,
    uint256 totalCacheMissLockup
);

event CDNServiceTerminated(
    address indexed caller, uint256 indexed dataSetId, uint256 cacheMissRailId, uint256 cdnRailId
);

event DataSetAbandoned(uint256 indexed dataSetId, uint256 pdpRailId, uint256 cacheMissRailId, uint256 cdnRailId);

event RailRateUpdated(uint256 indexed dataSetId, uint256 railId, uint256 newRate);

library Rails {
    /// @dev A data set's record in FWSS storage (Rails runs by DELEGATECALL in the FWSS proxy).
    function dataSetInfo(uint256 dataSetId) internal pure returns (DataSetInfoRecord storage info) {
        bytes32 root = DATA_SET_INFO_ROOT_SLOT;
        assembly ("memory-safe") {
            mstore(0, dataSetId)
            mstore(0x20, root)
            info.slot := keccak256(0, 0x40)
        }
    }

    /// @notice Validates the payer is set up to add pieces, not just create the dataset.
    /// @dev    The lifecycle reserve is consumed at creation; the per-dataset fee headroom is only
    ///         consumed once pieces are added. Empty datasets leave it as approved headroom.
    ///         Required up front intentionally: creation assumes pieces will follow.
    /// @param payments The FilecoinPayV1 contract instance
    /// @param token The data set's payment token, used for deposits and operator approvals
    /// @param payer The address of the payer
    /// @param includeCDN Whether to include fixed CDN/cache-miss lockups in the requirement checks
    /// @param scale 10 ** (18 - token decimals); amounts are converted with `toTokenUnits` (#618)
    function validatePayerOperatorApprovalAndFunds(
        FilecoinPayV1 payments,
        IERC20 token,
        address payer,
        bool includeCDN,
        uint256 scale
    ) internal view {
        // Required capacity: lifecycle reserve plus per-dataset fee lockup at the default period.
        // Multiply-first preserves the exact monthly value for cleaner error messages; slightly
        // more conservative than the actual rail lockup (truncated per-epoch), within 0.0001%
        // and always in the user's favor.
        uint256 requiredLockup =
            (DATASET_FEE_PER_MONTH * DEFAULT_LOCKUP_PERIOD) / EPOCHS_PER_MONTH + LIFECYCLE_RESERVE_TARGET;

        // If CDN is enabled, include the fixed cache-miss and CDN lockup amounts
        if (includeCDN) {
            requiredLockup += DEFAULT_CACHE_MISS_LOCKUP_AMOUNT + DEFAULT_CDN_LOCKUP_AMOUNT;
        }
        requiredLockup = toTokenUnits(requiredLockup, scale);
        uint256 datasetFeePerEpoch = toTokenUnits(DATASET_FEE_PER_EPOCH, scale);

        // Check that payer has sufficient available funds
        (,, uint256 availableFunds,) = payments.getAccountInfoIfSettled(token, payer);
        require(availableFunds >= requiredLockup, Errors.InsufficientLockupFunds(payer, requiredLockup, availableFunds));

        // Check operator approval settings
        (
            bool isApproved,
            uint256 rateAllowance,
            uint256 lockupAllowance,
            uint256 rateUsage,
            uint256 lockupUsage,
            uint256 maxLockupPeriod
        ) = payments.operatorApprovals(token, payer, address(this));

        // Verify operator is approved
        require(isApproved, Errors.OperatorNotApproved(payer, address(this)));

        // Rate-allowance headroom for the per-dataset fee rate: the floor of any non-empty
        // dataset's rate (size-proportional component sits on top). Empty datasets never consume
        // it; required up front for the dataset to be eligible to receive pieces.
        require(
            rateAllowance >= rateUsage + datasetFeePerEpoch,
            Errors.InsufficientRateAllowance(payer, address(this), rateAllowance, rateUsage, datasetFeePerEpoch)
        );

        // Verify lockup allowance is sufficient
        require(
            lockupAllowance >= lockupUsage + requiredLockup,
            Errors.InsufficientLockupAllowance(payer, address(this), lockupAllowance, lockupUsage, requiredLockup)
        );

        // Verify max lockup period is sufficient
        require(
            maxLockupPeriod >= DEFAULT_LOCKUP_PERIOD,
            Errors.InsufficientMaxLockupPeriod(payer, address(this), maxLockupPeriod, DEFAULT_LOCKUP_PERIOD)
        );
    }

    /// @notice Resolves the data set's payment currency, records its agreed price, and creates its rails.
    /// @dev `token` and `storagePricePerTibPerMonth` are the signed terms returned by
    ///      SignatureVerificationLib.verifyCreateDataSet. Token 0 or `defaultToken` is the default currency
    ///      (id 0, no state written); any other token must be whitelisted, enabled and listed in the provider's
    ///      `paymentTokens` registry capability. CDN is only available in the default token: FilBeam settles
    ///      CDN rails in default-token amounts. Reads the payer, payee and provider id that FWSS has already
    ///      written to the data set's record, and seeds `lifecycleReserveBalance` (token units, mirrors the PDP
    ///      rail's lockupFixed) and `pendingOneTimePayments` (the create fee, in 18-decimal USD like every pending
    ///      fee; converted to token units when paid).
    /// @return pdpRailId The PDP rail
    /// @return cacheMissRailId The cache-miss rail (0 without CDN)
    /// @return cdnRailId The CDN rail (0 without CDN)
    function createRails(
        FilecoinPayV1 payments,
        uint256 dataSetId,
        IERC20 token,
        uint256 storagePricePerTibPerMonth,
        IERC20 defaultToken,
        ServiceProviderRegistry serviceProviderRegistry,
        address filBeamBeneficiaryAddress
    ) public returns (uint256 pdpRailId, uint256 cacheMissRailId, uint256 cdnRailId) {
        DataSetInfoRecord storage info = dataSetInfo(dataSetId);
        address payer = info.payer;
        address payee = info.payee;
        bool hasCDN = filBeamBeneficiaryAddress != address(0);
        // Main's PDP rail terms for the default currency; a non-default currency's commission is paid to
        // FilecoinPay's own account, which only its burnForFees auction can empty.
        uint256 commissionBps = SERVICE_COMMISSION_BPS;
        address serviceFeeRecipient = address(this);
        if (address(token) == address(0) || token == defaultToken) {
            token = defaultToken;
        } else {
            require(!hasCDN, Errors.CDNNotSupportedForCurrency(address(token)));
            uint256 currencyId = PaymentTerms.resolveCurrency(address(token), info.providerId, serviceProviderRegistry);
            PaymentTerms.pricing(dataSetId).currencyId = uint8(currencyId);
            commissionBps = PaymentTerms.currencies().currencies[currencyId].commissionBps;
            serviceFeeRecipient = address(payments);
            info.commissionBps = commissionBps; // recorded per data set, as the rail fixes it
        }
        if (storagePricePerTibPerMonth != 0) {
            PaymentTerms.setPrice(dataSetId, storagePricePerTibPerMonth);
        }
        uint256 scale = PaymentTerms.scale(dataSetId);
        // Validate payer has sufficient funds and operator approvals to cover the required lockup
        // If CDN is enabled, validation must account for the additional fixed lockup amounts
        validatePayerOperatorApprovalAndFunds(payments, token, payer, hasCDN, scale);

        pdpRailId = payments.createRail(
            token, // token address
            payer, // from (payer)
            payee, // payee address from registry
            address(this), // this contract acts as the validator
            commissionBps, // 0 for the default currency; the currency's commission otherwise
            serviceFeeRecipient
        );

        // Set lockup period and seed the lifecycle reserve
        uint256 reserve = toTokenUnits(LIFECYCLE_RESERVE_TARGET, scale);
        payments.modifyRailLockup(pdpRailId, DEFAULT_LOCKUP_PERIOD, reserve);
        info.lifecycleReserveBalance = uint96(reserve);
        info.pendingOneTimePayments = uint96(CREATE_DATA_SET_FEE);

        cacheMissRailId = 0;
        cdnRailId = 0;

        if (hasCDN) {
            cacheMissRailId = payments.createRail(
                token, // token address
                payer, // from (payer)
                payee, // payee address from registry
                address(0), // no validator
                0, // no service commission
                address(this) // controller
            );
            payments.modifyRailLockup(cacheMissRailId, CDN_LOCKUP_PERIOD, DEFAULT_CACHE_MISS_LOCKUP_AMOUNT);

            cdnRailId = payments.createRail(
                token, // token address
                payer, // from (payer)
                filBeamBeneficiaryAddress, // to FilBeam beneficiary
                address(0), // no validator
                0, // no service commission
                address(this) // controller
            );
            payments.modifyRailLockup(cdnRailId, CDN_LOCKUP_PERIOD, DEFAULT_CDN_LOCKUP_AMOUNT);

            emit CDNPaymentRailsToppedUp(
                dataSetId,
                DEFAULT_CDN_LOCKUP_AMOUNT,
                DEFAULT_CDN_LOCKUP_AMOUNT,
                DEFAULT_CACHE_MISS_LOCKUP_AMOUNT,
                DEFAULT_CACHE_MISS_LOCKUP_AMOUNT
            );
        }
    }

    function terminateCDNRails(FilecoinPayV1 payments, uint256 dataSetId, uint256 cacheMissRailId, uint256 cdnRailId)
        public
    {
        try payments.terminateRail(cacheMissRailId) {} catch {}
        try payments.terminateRail(cdnRailId) {} catch {}
        emit CDNServiceTerminated(msg.sender, dataSetId, cacheMissRailId, cdnRailId);
    }

    /// @notice Tears down all rails for an abandoned data set.
    /// @dev SP forfeits pending op-fees; lifecycle reserve returns to the payer.
    ///      For well-funded payers the rail is terminated with no lockup period, releasing the
    ///      reserve immediately.
    ///      For underfunded payers the PDP rail remains for DEFAULT_LOCKUP_PERIOD; the payer's
    ///      streaming lockup tail isn't released until that period elapses, though every proven epoch is paid
    ///      out first.
    ///      CDN rails are best-effort, may have been terminated externally.
    function abandonRails(
        FilecoinPayV1 payments,
        mapping(uint256 dataSetId => uint256 activationEpoch) storage provingActivationEpoch,
        uint256 dataSetId,
        uint256 pdpRailId,
        uint256 cacheMissRailId,
        uint256 cdnRailId
    ) public {
        payments.settleRail(pdpRailId, block.number);

        // Try to zero the lockup period before termination.
        // For underfunded payers the period change will fail.
        bool reserveRemaining = false;
        try payments.modifyRailLockup(pdpRailId, 0, 0) {}
        catch {
            reserveRemaining = true;
        }

        if (cdnRailId != 0) {
            _teardownCDNRail(payments, cacheMissRailId);
            _teardownCDNRail(payments, cdnRailId);
            emit CDNServiceTerminated(msg.sender, dataSetId, cacheMissRailId, cdnRailId);
        }

        // clearing this allows settling remaining epochs with zero payment
        delete provingActivationEpoch[dataSetId];

        payments.terminateRail(pdpRailId);
        if (reserveRemaining) {
            // release the fixed reserve
            payments.modifyRailLockup(pdpRailId, DEFAULT_LOCKUP_PERIOD, 0);
        }
        payments.settleRail(pdpRailId, block.number);
        emit DataSetAbandoned(dataSetId, pdpRailId, cacheMissRailId, cdnRailId);
    }

    /// @notice Tears down one CDN rail.
    /// @dev Each step may revert if the rail was independently terminated or finalised by the
    ///      payer or FilBeam controller (CDN rails have no validator). Best-effort so abandonment
    ///      completes regardless.
    function _teardownCDNRail(FilecoinPayV1 payments, uint256 railId) internal {
        try payments.modifyRailLockup(railId, 0, 0) {} catch {}
        try payments.terminateRail(railId) {} catch {}
        try payments.settleRail(railId, block.number) {} catch {}
    }

    function topUpCDNRails(
        FilecoinPayV1 payments,
        uint256 dataSetId,
        uint256 cacheMissRailId,
        uint256 cdnRailId,
        uint256 cacheMissAmountToAdd,
        uint256 cdnAmountToAdd
    ) public {
        // Both rails must be active for any top-up operation
        FilecoinPayV1.RailView memory cdnRail = payments.getRail(cdnRailId);
        FilecoinPayV1.RailView memory cacheMissRail = payments.getRail(cacheMissRailId);

        require(cdnRail.endEpoch == 0, Errors.CDNPaymentAlreadyTerminated(dataSetId));
        require(cacheMissRail.endEpoch == 0, Errors.CacheMissPaymentAlreadyTerminated(dataSetId));

        // Require at least one amount to be non-zero
        if (cdnAmountToAdd == 0 && cacheMissAmountToAdd == 0) {
            revert Errors.InvalidTopUpAmount(dataSetId);
        }

        // Calculate total lockup amounts
        uint256 totalCdnLockup = cdnRail.lockupFixed + cdnAmountToAdd;
        uint256 totalCacheMissLockup = cacheMissRail.lockupFixed + cacheMissAmountToAdd;

        // Only modify rails if amounts are being added
        payments.modifyRailLockup(cdnRailId, CDN_LOCKUP_PERIOD, totalCdnLockup);
        payments.modifyRailLockup(cacheMissRailId, CDN_LOCKUP_PERIOD, totalCacheMissLockup);
        emit CDNPaymentRailsToppedUp(
            dataSetId, cdnAmountToAdd, totalCdnLockup, cacheMissAmountToAdd, totalCacheMissLockup
        );
    }

    function settleCDNRails(
        FilecoinPayV1 payments,
        uint256 cdnRailId,
        uint256 cacheMissRailId,
        uint256 cdnAmount,
        uint256 cacheMissAmount
    ) public {
        if (cdnAmount > 0) {
            payments.modifyRailPayment(cdnRailId, 0, cdnAmount);
        }

        if (cacheMissAmount > 0) {
            payments.modifyRailPayment(cacheMissRailId, 0, cacheMissAmount);
        }
    }

    // Replenishes the rail's fixed lockup when the reserve would drop below REPLENISH_THRESHOLD
    // after paying pending. Returns the new lockupFixed value (mirrors lifecycleReserveBalance).
    // Skipped for terminated rails (pdpEndEpoch != 0): modifyRailLockup forbids increases there.
    // `pending` is in 18-decimal USD; the reserve and the returned value are in the data set's token units.
    function replenishReserveIfNeeded(
        FilecoinPayV1 payments,
        uint256 dataSetId,
        uint256 pdpRailId,
        uint256 pdpEndEpoch,
        uint96 reserveBalance,
        uint96 pending
    ) public returns (uint96) {
        uint256 scale = PaymentTerms.scale(dataSetId);
        return _replenishReserveIfNeeded(
            payments, pdpRailId, pdpEndEpoch, reserveBalance, uint96(toTokenUnits(pending, scale)), scale
        );
    }

    /// @dev As `replenishReserveIfNeeded`, with `pending` already in token units.
    function _replenishReserveIfNeeded(
        FilecoinPayV1 payments,
        uint256 pdpRailId,
        uint256 pdpEndEpoch,
        uint96 reserveBalance,
        uint96 pending,
        uint256 scale
    ) internal returns (uint96) {
        if (pdpEndEpoch == 0 && reserveBalance < pending + uint96(toTokenUnits(REPLENISH_THRESHOLD, scale))) {
            uint96 newLockup = uint96(toTokenUnits(LIFECYCLE_RESERVE_TARGET, scale)) + pending;
            payments.modifyRailLockup(pdpRailId, DEFAULT_LOCKUP_PERIOD, newLockup);
            return newLockup;
        }
        return reserveBalance;
    }

    /// @dev `pending` is in 18-decimal USD and is paid in the data set's token units, rounded up. The rate uses
    ///      the data set's effective price (max of agreed and posted, #619), each term rounded up to token units.
    function updateStorageRates(
        FilecoinPayV1 payments,
        uint256 dataSetId,
        uint256 pdpRailId,
        uint256 leafCount,
        uint96 pending,
        uint96 reserveBalance,
        uint256 pdpEndEpoch,
        bool immediateTermination
    ) public returns (uint96 newReserveBalance) {
        uint256 scale = PaymentTerms.scale(dataSetId);
        uint256 newStorageRatePerEpoch =
            calculateStorageRateAtPrice(leafCount, PaymentTerms.effectiveStoragePrice(dataSetId), scale);
        pending = uint96(toTokenUnits(pending, scale));
        if (immediateTermination) {
            // No try/catch: immediateTermination implies the payer consented and is solvent.
            payments.modifyRailLockup(pdpRailId, 0, pending);
            newReserveBalance = 0;
        } else {
            uint96 replenished =
                _replenishReserveIfNeeded(payments, pdpRailId, pdpEndEpoch, reserveBalance, pending, scale);
            if (replenished < pending) {
                pending = replenished;
            }
            newReserveBalance = replenished - pending;
        }
        payments.modifyRailPayment(pdpRailId, newStorageRatePerEpoch, pending);
        emit RailRateUpdated(dataSetId, pdpRailId, newStorageRatePerEpoch);
    }

    // ---------------------------------------------------------------------
    // Currency whitelist administration (#618), called by FWSS's `setCurrency`.

    /// @notice Whitelists `token` under the next id, or enables/disables an existing entry.
    /// @dev The default token (id 0) cannot be added. Decimals must be between 6 and 18.
    function setCurrency(address token, bool enabled, uint16 commissionBps, address defaultToken) public {
        // OwnableUpgradeable's ERC-7201 slot, read directly as upstream's FWSSOwnable does
        address owner;
        assembly ("memory-safe") {
            owner := sload(0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300)
        }
        require(msg.sender == owner, OwnableUpgradeable.OwnableUnauthorizedAccount(msg.sender));
        require(commissionBps <= MAX_COMMISSION_BPS, Errors.InvalidCommissionBps(commissionBps));
        PaymentTermsStorage.FWSSCurrencyStorage storage $ = PaymentTerms.currencies();
        uint256 currencyId = $.ids[token];
        if (currencyId == 0) {
            require(token != defaultToken, Errors.CurrencyAlreadyAdded(token));
            uint8 decimals = IERC20Metadata(token).decimals();
            require(
                decimals >= MIN_CURRENCY_DECIMALS && decimals <= PRICE_DECIMALS,
                Errors.InvalidCurrencyDecimals(token, decimals)
            );
            currencyId = $.count + 1;
            require(currencyId <= type(uint8).max, Errors.TooManyCurrencies());
            $.count = currencyId;
            $.ids[token] = currencyId;
            $.currencies[currencyId] = PaymentTermsStorage.Currency({
                token: token, decimals: decimals, enabled: enabled, commissionBps: commissionBps
            });
            emit CurrencyAdded(uint8(currencyId), token, decimals);
        } else {
            PaymentTermsStorage.Currency storage c = $.currencies[currencyId];
            c.enabled = enabled;
            c.commissionBps = commissionBps;
        }
        emit CurrencyUpdated(uint8(currencyId), token, enabled, commissionBps);
    }

    /// @notice Changes a data set's storage price by mutual consent and re-prices its rail (#619).
    /// @dev Body of FilecoinWarmStorageService.updateStoragePrice. The service provider submits; the payer, or a
    ///      payer session key holding the UpdateStoragePrice permission, signs
    ///      UpdateStoragePrice(dataSetId, nonce, storagePricePerTibPerMonth, deadline). The data set's authorizer
    ///      is not consulted. `deadline` is an epoch (block number), unlike session-key expiry (a timestamp).
    function updateStoragePrice(
        uint256 dataSetId,
        uint256 storagePricePerTibPerMonth,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature,
        bytes32 domainSeparator,
        SessionKeyRegistry sessionKeyRegistry
    ) public {
        DataSetInfoRecord storage info = dataSetInfo(dataSetId);
        address payer = info.payer;
        uint256 pdpRailId = info.pdpRailId;
        if (pdpRailId == 0) revert Errors.InvalidDataSetId(dataSetId);
        if (info.pdpEndEpoch != 0) revert Errors.DataSetPaymentAlreadyTerminated(dataSetId);
        address serviceProvider = info.serviceProvider;
        if (msg.sender != serviceProvider) {
            revert Errors.CallerNotServiceProvider(dataSetId, serviceProvider, msg.sender);
        }
        if (block.number > deadline) revert Errors.StoragePriceUpdateExpired(dataSetId, deadline, block.number);
        SignatureVerificationLib.verifyUpdateStoragePriceSignature(
            payer,
            dataSetId,
            nonce,
            storagePricePerTibPerMonth,
            deadline,
            signature,
            domainSeparator,
            sessionKeyRegistry
        );
        PaymentTerms.updatePrice(dataSetId, storagePricePerTibPerMonth, nonce);

        // Re-price now so an idle data set picks up the new price; applies from the next epoch.
        IFWSSConfig config = IFWSSConfig(address(this));
        info.lifecycleReserveBalance = updateStorageRates(
            FilecoinPayV1(config.paymentsContractAddress()),
            dataSetId,
            pdpRailId,
            IPDPVerifier(config.pdpVerifierAddress()).getDataSetLeafCount(dataSetId),
            info.pendingOneTimePayments,
            info.lifecycleReserveBalance,
            0,
            false
        );
        info.pendingOneTimePayments = 0;
    }

    /// @notice Invalidates every outstanding UpdateStoragePrice signature for a data set by bumping its nonce.
    /// @dev Callable by the payer or by a payer session key holding the UpdateStoragePrice permission.
    function cancelStoragePriceOffers(uint256 dataSetId, SessionKeyRegistry sessionKeyRegistry) public {
        address payer = dataSetInfo(dataSetId).payer;
        if (payer == address(0)) revert Errors.InvalidDataSetId(dataSetId);
        if (
            msg.sender != payer
                && sessionKeyRegistry.authorizationExpiry(
                        payer, msg.sender, SignatureVerificationLib.UPDATE_STORAGE_PRICE_TYPEHASH
                    ) < block.timestamp
        ) {
            revert Errors.CallerNotPayer(dataSetId, payer, msg.sender);
        }
        PaymentTerms.cancelOffers(dataSetId);
    }
}
