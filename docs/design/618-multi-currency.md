# Multi-currency data sets (FilOzone/filecoin-services#618)

Each data set pays in one USD stablecoin, chosen by the client at creation and signed by the payer. USDFC stays the default currency and USDFC data sets behave exactly as on upstream `main`. Other stablecoins come from an owner-managed whitelist, and a provider accepts a non-default stablecoin only by listing it in the ServiceProviderRegistry. The price list stays in 18-decimal USD; amounts are converted to the token's decimals on chain, rounding up.

This design follows the plan in #618. It shares its storage namespace and extraData scheme with the per-data-set price in #619 ([619-storage-price.md](619-storage-price.md)). FF's deployment uses it with axlUSDC (6 decimals) as a whitelist entry.

Code paths below are under `service_contracts/src/`.

## Currencies

### The default currency

The default currency is the deployment's `usdfcTokenAddress`, at `TOKEN_DECIMALS = 18`. Main's constructor check `TOKEN_DECIMALS == decimals()` still applies, so the default token is always 18-decimal. Currency id 0 means the default. Data sets in the default currency write no new state, so every existing data set already reads as id 0 and no migration runs.

USDFC data sets produce main's values bit for bit: rate, fees, lockups, lifecycle reserve, rail commission (0) and fee recipient (FWSS).

### The whitelist

The owner manages the whitelist with one function:

```solidity
function setCurrency(address token, bool enabled, uint16 commissionBps) external;
```

- An unknown token is added under the next id, with its decimals read once from the token. Decimals must be between 6 and 18 (`InvalidCurrencyDecimals`).
- A known token has its `enabled` flag and commission updated.
- Ids run from 1 to 255, are append-only and are never reused, so a stored id never changes meaning (`TooManyCurrencies` past 255).
- The default token cannot be added (`CurrencyAlreadyAdded`).
- `commissionBps` above 10,000 reverts with `InvalidCommissionBps`. 10,000 is FilecoinPay's `COMMISSION_MAX_BPS`, which its `createRail` enforces.
- Disabling a token stops new data sets in it. Existing data sets keep paying in it.

FWSS's `setCurrency` is a typed call into `Rails.setCurrency`, which checks `msg.sender` against OpenZeppelin `Ownable`'s namespaced owner slot.

The owner manages the whitelist because token addresses differ between calibnet and mainnet, which receive the same implementation, so a list fixed in code would need per-chain branches. The owner can also disable a token that loses its peg without waiting for an upgrade.

Events:

```solidity
event CurrencyAdded(uint8 indexed currencyId, address indexed token, uint8 decimals);
event CurrencyUpdated(uint8 indexed currencyId, address indexed token, bool enabled, uint16 commissionBps);
```

## Choosing the currency at creation

### extraData variants

`SignatureVerificationLib.verifyCreateDataSet` reads the ABI offset of `keys`, the first dynamic field, and fully decodes the payload as the matching tuple:

| `keys` offset | Tuple | EIP-712 type |
|---|---|---|
| `0xa0` (legacy) | `(address payer, uint256 clientDataSetId, string[] keys, string[] values, bytes signature)` | `CreateDataSet` |
| `0xc0` (#618) | `(…, bytes signature, address token)` | `CreateDataSetWithCurrency` |
| `0xe0` (#619) | `(…, bytes signature, address token, uint256 storagePricePerTibPerMonth)` | `CreateDataSetWithPayment` |

Any other offset reverts with `UnsupportedExtraDataVariant(keysOffset)`. The new fields come after `signature`, and ABI offsets are relative, so the first five fields decode the same way in every variant. Legacy payloads are unchanged.

A token of `address(0)` or `usdfcTokenAddress` selects the default currency. Any other token must be whitelisted and enabled (`UnsupportedCurrency(token)`) and accepted by the provider.

### Signature and session keys

The variant has its own EIP-712 type in the existing domain:

```
CreateDataSetWithCurrency(uint256 clientDataSetId,address payee,MetadataEntry[] metadata,address token)MetadataEntry(string key,string value)
```

Its type hash, `0xa547b35e307d26992f1b52c33024da539519537b6735f4f347cb9af9e9878a3c`, is also its session-key permission, as upstream does for every type. A signature or session key for one variant never verifies for another. Detection by offset is safe for this reason: a provider that re-encodes a legacy payload into the `0xc0` shape with a token of its choosing fails verification.

A separate permission keeps existing keys from reaching a new token. Session-key permissions are keyed by type hash alone, and FilecoinPay approvals are per token. If the variant were checked under the `CreateDataSet` permission, every key granted today could commit the payer's allowance in any whitelisted token.

The type binds `payee`, as `CreateDataSet` does. The registry does not make payees unique, and binding `providerId` as well is an open question for upstream.

## Provider opt-in

A provider lists the stablecoins it accepts in the PDP capability `paymentTokens`, as concatenated 20-byte addresses. Capability values are capped at 128 bytes, so up to six fit.

For a non-default token, `Rails.createRails` reads the key with `getProductCapabilities(providerId, PDP, ["paymentTokens"])` and reverts with `CurrencyNotAcceptedByProvider(providerId, token)` if the token is not listed. Default-currency creates make no extra call.

A provider whose software has not been updated lists nothing and only receives default-currency data sets. Clients can read the key to find providers for their stablecoin. The client still chooses the data set's token, because a provider-chosen token would decide which of the payer's approved balances pays.

## Amounts and rounding

Every price, fee and lockup in `PriceListUSDFC.sol` stays an 18-decimal USD constant. A token with `d` decimals has `scale = 10 ** (18 - d)`, and an amount is charged as

```solidity
function toTokenUnits(uint256 amount, uint256 scale) pure returns (uint256) {
    return amount == 0 ? 0 : (amount - 1) / scale + 1;   // ceil(amount / scale)
}
```

At scale 1 this returns its input, which is why USDFC matches main exactly.

**Rate.** The per-epoch rate is main's 18-decimal rate, converted once:

```
rate = toTokenUnits(rawBytes * price / (TiB * EPOCHS_PER_MONTH) + DATASET_FEE_PER_EPOCH, scale)
```

`price` is the data set's effective storage price from #619, which is the posted price unless an agreed price is higher. At 6 decimals a 1 GiB data set pays 2 units per epoch; converting each term separately would charge 3. Rounding up means a payer overpays by at most 1 unit per epoch, which is $0.0864 a month at 6 decimals. Charging exact sub-unit rates would need a change to FilecoinPay and is out of scope.

**Lockups and one-time fees.** The creation lockup check, the lifecycle reserve target and the replenish threshold are each rounded up once. One-time fees accumulate in 18-decimal USD in `DataSetInfo.pendingOneTimePayments`, and the sum is converted when paid. Every one-time fee and lockup constant is a whole multiple of 10^12, so converting each fee gives the same amount as converting the sum, for every supported decimals value. A test pins that fact.

**Caller-supplied amounts** stay in token units: `topUpLifecycleReserve`, `topUpCDNPaymentRails` and `settleFilBeamPaymentRails`.

## CDN

`withCDN` reverts with `CDNNotSupportedForCurrency(token)` for any non-default currency. FilBeam settles CDN rails in default-token amounts, which would be wrong on a rail in another token. The restriction can be lifted once FilBeam reads the data set's currency.

## Commission

For a non-default currency, `Rails.createRails` creates the PDP rail with that currency's `commissionBps` and `serviceFeeRecipient = address(FilecoinPay)`, and records the rate in `DataSetInfo.commissionBps`. FilecoinPay credits the commission to its own account, which only `burnForFees` can empty: the commission is burned through FilecoinPay's fee auction, the mechanism #525 used. The default currency keeps main's terms, a commission of 0 paid to FWSS.

The rail fixes its commission at creation, so a later `setCurrency` change affects new data sets only. Prices are not grossed up. The provider receives each payment less FilecoinPay's 0.5% network fee and the commission; at 50 bps, a 6,000-unit fee ($0.006 at 6 decimals) pays the provider 5,941 units and 59 units go to FilecoinPay's account.

FF's deployment sets 50 bps (0.5%) for axlUSDC. axlUSDC does not lock FIL the way USDFC does, and the burned commission makes up for that. The rate is per-currency owner configuration and is 0 for USDFC.

## Storage layout

Nothing is added to root slots 0-23 or to `DataSetInfo`. Both namespaces are declared on `abstract contract PaymentTermsStorage` (`lib/PaymentTermsStorage.sol`), which FWSS inherits. The libraries reach them through the internal library `PaymentTerms`.

| Namespace id | Slot |
|---|---|
| `erc7201:filecoin.storage.FWSSCurrency` | `0x2be83150facef7aa3ae5922e809766ad94dac519fdf44800de563f85c625d500` |
| `erc7201:filecoin.storage.FWSSDataSetPricing` | `0x44ed9206e2d77446bd06f9698aeef56e4b0ec8004fef8f3eb108175dad5b9600` |

```solidity
struct Currency {                    // one slot
    address token;                   // bits 0-159
    uint8 decimals;                  // 160-167
    bool enabled;                    // 168-175
    uint16 commissionBps;            // 176-191
}

/// @custom:storage-location erc7201:filecoin.storage.FWSSCurrency
struct FWSSCurrencyStorage {
    uint256 count;                                      // ids 1..count; id 0 = the default token
    mapping(uint256 currencyId => Currency) currencies;
    mapping(address token => uint256 currencyId) ids;
}

struct DataSetPricing {              // one slot; all zero for every existing data set
    uint128 storagePricePerTibPerMonth;  // #619; bits 0-127
    uint64 nonce;                        // #619; bits 128-191
    uint8 currencyId;                    // bits 192-199; 0 = the default token
}

/// @custom:storage-location erc7201:filecoin.storage.FWSSDataSetPricing
struct FWSSDataSetPricingStorage {
    mapping(uint256 dataSetId => DataSetPricing) dataSets;
}
```

Each slot is `keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~bytes32(uint256(0xff))`, pinned by tests. The naming follows the only FWSS precedent, closed PR #615 (`filecoin.storage.<Name>`). A data set's `DataSetPricing` is deleted with the data set.

`tools/check_storage_layout.sh` passes against main's layout with 24 entries, and the generated layout files are identical to main's.

## Views

In StateView and the StateLibrary, so they add nothing to the core:

- `getCurrency(id)` returns `(token, decimals, enabled, commissionBps)`. Id 0 returns `(usdfcTokenAddress, 18, true, 0)` without calling the token.
- `getCurrencyCount()`, `getCurrencyId(token)` and `getDataSetCurrency(dataSetId)`, which returns `(token, decimals)`.
- `getPriceListForCurrency(token)` returns `getPriceList()` for the default token. For any other whitelisted token it converts every amount to the units actually charged, rounding up, and sets every CDN rate, lockup and period to 0. Its `datasetFeePerMonth` is the per-epoch fee rounded up, times `EPOCHS_PER_MONTH`: 172,800 at 6 decimals, the minimum rate of a non-empty data set. Because a data set's rate rounds its size term and dataset fee up together, adding the two listed rates can come in up to 1 unit per epoch under the actual rate. The rail's `paymentRate` in FilecoinPay is authoritative.
- `getDataSet` reports pending fees in token units, and its `commissionBps` is the rail's commission.
- `getPriceList()` is unchanged and reports default-token amounts.

`DataSetCreated` is unchanged. A data set's token appears in FilecoinPay's `RailCreated` and in `getDataSetCurrency`.

## Errors

New: `UnsupportedCurrency`, `CurrencyAlreadyAdded`, `InvalidCurrencyDecimals`, `TooManyCurrencies`, `CurrencyNotAcceptedByProvider`, `CDNNotSupportedForCurrency`, `UnsupportedExtraDataVariant`, `InvalidCommissionBps`.

## Compatibility and upgrade

| Item | Effect |
|---|---|
| Legacy extraData, signatures and session keys | Unchanged |
| Existing data sets | Currency id 0; no migration |
| USDFC data sets | Main's values bit for bit |
| `getDataSet` / `DataSetInfoView`, `DataSetCreated` | Unchanged |
| Root storage and `DataSetInfo` | Unchanged; new state in two namespaces |

The upgrade test creates a legacy USDFC data set with pieces, checks that it wrote no namespaced state and that its rate equals main's `calculateStorageRate`, upgrades the proxy through `announceUpgradePlan` and `upgradeToAndCall(migrate)`, checks that `DataSetInfo` and the rate are unchanged after another add, and then creates `0xc0` and `0xe0` data sets in axlUSDC on the upgraded proxy. The starting implementation is this code, which writes exactly main's state for a legacy create.

## Code placement

The FWSS core changes are small: `setCurrency` as a typed call into Rails, `verifyCreateDataSet` in place of main's private signature helper, `createRails` with the new arguments, `replenishReserveIfNeeded` with the data set id, clearing `PaymentTerms` on deletion, and inheriting `PaymentTermsStorage`.

`SignatureVerificationLib` only verifies: `verifyCreateDataSet(extraData, payee, domainSeparator, sessionKeyRegistry)` is a view that returns the signed `(token, price)`. Rails holds the rest: currency resolution, provider opt-in, the CDN check, commission, conversions, rail creation and whitelist administration.

Rails does not import the FWSS contract, so it ports to the modular-dispatch layout:

- The default token, session-key registry and provider registry are passed in as arguments.
- The only FWSS getters Rails calls are `paymentsContractAddress()` and `pdpVerifierAddress()`, which stay routed after the ERC-8167 transition (upstream's `IFWSSConfig`).
- Rails reaches a data set's record through `DataSetInfoRecord`, a field-for-field copy of the frozen `DataSetInfo` at root slot 7, pinned against the generated layout. On the module branch the same struct is `FWSSStorage.DataSetInfo`, also at slot 7.

On the module branch, currency choice lands in `FWSSDataSetModule.dataSetCreated` and `setCurrency` in the payment module or a small currency module, with `PaymentTermsStorage` inherited so the layout checks see the namespaces.

## Size and gas

With #619 and the commission, FWSS builds to 23,521 B at solc 0.8.30 and 23,534 B at 0.8.37, under the 23,552 B policy budget. Rails is 10,201 B and SignatureVerificationLib 7,349 B at 0.8.30.

EVM gas, measured with mocked signatures and cold accounts (FEVM gas not measured):

| Operation | Gas |
|---|---:|
| main, legacy create (USDFC) | 694,836 |
| legacy `0xa0` create (USDFC) | 696,332 |
| `0xc0` create, default token | 696,750 |
| `0xc0` create, axlUSDC (whitelist, registry capability, commission) | 735,693 |

## Open questions for upstream

1. Lock the layout: both namespace ids and structs, the `0xc0` tuple, the type string and the permission.
2. The namespace convention `filecoin.storage.<Name>`.
3. The registry capability name `paymentTokens` and its packed-address format.
4. Whether upstream PRs target the modular-dispatch payment module (`refactor/payment-module`).
5. Whether the new types also bind `providerId`. Provider changes revert today, so a provider change does not re-validate the currency.
6. Non-canonical offsets inside a variant are accepted today; whether to reject them.
