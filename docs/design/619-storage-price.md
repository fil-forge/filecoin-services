# Per-data-set storage price (FilOzone/filecoin-services#619)

A data set can pay a storage price above the posted one. The client signs the price in a new `createDataSet` extraData variant, and the provider accepts it by submitting the transaction. The price is 18-decimal USD per TiB per month and is stored in an ERC-7201 namespace. The effective price is the higher of the agreed and posted prices. After creation, the price changes only when the payer signs and the provider submits the change.

This design follows #619's per-data-set path and shares its namespace and extraData scheme with multi-currency support from #618 ([618-multi-currency.md](618-multi-currency.md)). FF's deployment uses it for per-provider prices.

Code paths below are under `service_contracts/src/`.

## The price

- Unit: 18-decimal USD per TiB per month, the unit of `STORAGE_PRICE_PER_TIB_PER_MONTH`. A USD amount means the same thing in every currency.
- 0 means the posted price.
- Effective price: `max(agreed, STORAGE_PRICE_PER_TIB_PER_MONTH)`. The posted price stays the floor, so a client can agree to pay more and never less.
- The agreed price replaces the posted price in the size-proportional term only. The dataset fee and the one-time operation fees stay at posted values.
- The only bound is the width of the stored field: a price above `uint128` reverts with `InvalidStoragePrice`. There is no policy cap; the payer's FilecoinPay rate allowance bounds what a signature can commit.

## Creation

The `0xe0` variant appends the token and the price to the legacy tuple:

```
(address payer, uint256 clientDataSetId, string[] keys, string[] values, bytes signature,
 address token, uint256 storagePricePerTibPerMonth)
```

`SignatureVerificationLib.verifyCreateDataSet` selects the variant by the ABI offset of `keys`: `0xa0` legacy, `0xc0` currency only (#618), `0xe0` currency and price. Any other offset reverts with `UnsupportedExtraDataVariant`. A token of `address(0)` or `usdfcTokenAddress` selects the default currency; any other token follows #618's whitelist and provider opt-in.

The payer signs a new EIP-712 type in the existing domain:

```
CreateDataSetWithPayment(uint256 clientDataSetId,address payee,MetadataEntry[] metadata,address token,uint256 storagePricePerTibPerMonth)MetadataEntry(string key,string value)
```

Its type hash, `0x3b946c069c5a18b77163ee69a8d9e6b79e1fa25cc85f2be8de1ecf4fa1e365ac`, is also its session-key permission. A signature or session key for one variant never verifies for another, so a provider cannot re-encode a legacy or `0xc0` payload into this shape with a price of its choosing.

The provider consents by submitting. PDPVerifier passes the caller as the service provider, and FWSS resolves `providerId` and `payee` from it. Provider software that does not want a data set at the signed price does not submit it. A price the provider set outside the signature would let the provider draw on the payer's rate allowance unchecked, which is why the price sits in the signed part.

A nonzero price is recorded at creation and emits `DataSetStoragePriceSet(dataSetId, price)`. A creation does not consume a nonce.

## Storage

```solidity
/// @custom:storage-location erc7201:filecoin.storage.FWSSDataSetPricing
/// slot 0x44ed9206e2d77446bd06f9698aeef56e4b0ec8004fef8f3eb108175dad5b9600
struct FWSSDataSetPricingStorage {
    mapping(uint256 dataSetId => DataSetPricing) dataSets;
}

struct DataSetPricing {                  // one slot
    uint128 storagePricePerTibPerMonth;  // bits 0-127; 18-decimal USD; 0 = the posted price
    uint64 nonce;                        // bits 128-191; accepted UpdateStoragePrice operations
    uint8 currencyId;                    // bits 192-199; #618; 0 = the default token
}
```

The namespace is declared on `abstract contract PaymentTermsStorage` (`lib/PaymentTermsStorage.sol`), which FWSS inherits. Nothing is added to root slots 0-23 or to `DataSetInfo`, which the storage README on the modular-dispatch branch asks to keep unchanged. An all-zero slot means the default currency at the posted price, which is the state of every existing data set, so no migration runs. The slot is deleted with the data set.

## Where the price applies

`Rails.updateStorageRates` is the only writer of the PDP rail's rate. It computes

```
price = max(agreed, STORAGE_PRICE_PER_TIB_PER_MONTH)
rate  = toTokenUnits(rawBytes * price / (TiB * EPOCHS_PER_MONTH) + DATASET_FEE_PER_EPOCH, scale)
```

where `scale = 10 ** (18 - decimals)` and `toTokenUnits` rounds up. For USDFC, scale is 1 and the rate is main's formula at the effective price. For a 6-decimal token it is the 18-decimal rate rounded up once, so a payer overpays by at most 1 unit per epoch, $0.0864 a month. Exact sub-unit rates would need a FilecoinPay change and are out of scope.

Settlement is unchanged: `validatePayment` scales the rail's own rate by proven epochs.

## Changing the price

FWSS recomputes a rate only on piece additions, on proving periods with removals or pending fees, and on termination with fees. A price fixed at creation could never change on an idle data set, and a payer paying above the posted price could leave it only by terminating the data set. Price changes therefore get their own entry point:

```solidity
function updateStoragePrice(
    uint256 dataSetId,
    uint256 storagePricePerTibPerMonth,
    uint256 nonce,
    uint256 deadline,
    bytes calldata signature
) external;

function cancelStoragePriceOffers(uint256 dataSetId) external;
```

`updateStoragePrice`:

- The data set's service provider submits (`CallerNotServiceProvider` otherwise).
- The payer, or a payer session key holding the `UpdateStoragePrice` permission, signs:
  ```
  UpdateStoragePrice(uint256 dataSetId,uint256 nonce,uint256 storagePricePerTibPerMonth,uint256 deadline)
  ```
  type hash `0x82fd6f8fa2c2e39df8ada51646c8eb3cee78f59c64c31db5284bab14c7ab9303`.
- `deadline` is an epoch (block number); after it the call reverts with `StoragePriceUpdateExpired`. Session-key expiry, by contrast, is a timestamp.
- `nonce` must equal the data set's stored nonce (`InvalidStoragePriceNonce`), and each accepted update increments it.
- The data set must exist and not be terminated.
- The rail is re-priced in the same call, so the new rate applies from the next epoch even on an idle data set. Pending one-time fees are paid in the same rate update, as on the other re-price paths.
- Every applied change emits `DataSetStoragePriceSet`.

Both sides consent to every change, in either direction. There is no payer-only cut and no scheduled change.

`cancelStoragePriceOffers` lets the payer, or a payer session key holding `UpdateStoragePrice`, bump the nonce, which invalidates every outstanding signed offer. It emits `StoragePriceOffersCancelled(dataSetId, nonce)`. Any other caller gets `CallerNotPayer`.

**FilecoinPay limits.** FilecoinPay refuses a rate change on a live rail while the payer's lockup is unsettled, and a higher rate needs rate allowance and lockup allowance at once. If FilecoinPay refuses, the whole call reverts and the price is unchanged. Signing software should check the payer's allowances and funds before signing an increase.

## Authorization

The data set's authorizer is not consulted for `UpdateStoragePrice`. Authorizers decide AddPieces, SchedulePieceRemovals and TerminateService, and a payer may have allowlisted a curation key or the provider's own key. If authorizers decided prices, that grant would extend to raising the price with no storage obligation attached. A new operation that spends more of the payer's money should not inherit grants made before it existed.

Session keys holding `UpdateStoragePrice` are unscoped: such a key can sign any price for any of the payer's data sets. Application session keys should not be given this permission.

## Events and views

```solidity
event DataSetStoragePriceSet(uint256 indexed dataSetId, uint256 storagePricePerTibPerMonth);
event StoragePriceOffersCancelled(uint256 indexed dataSetId, uint256 nonce);
```

Prices in events are USD and read the same in any token. FilecoinPay's `RailRateModified` and FWSS's `RailRateUpdated` report the resulting rate in token units.

StateView `getDataSetStoragePrice(dataSetId)` returns `(storagePricePerTibPerMonth, nonce)`: the agreed price in 18-decimal USD (0 = posted) and the nonce the next signature must use.

## Errors

New: `StoragePriceUpdateExpired`, `InvalidStoragePriceNonce`, `UnsupportedExtraDataVariant`. `InvalidStoragePrice` fires only for prices above `uint128`.

## Compatibility and upgrade

| Item | Effect |
|---|---|
| Legacy and `0xc0` variants | Unchanged; their data sets pay the posted price |
| Existing data sets | Empty slot means the posted price; no migration |
| `getDataSet` / `DataSetInfoView` | Unchanged |
| Root storage and `DataSetInfo` | Unchanged |
| Rate updates | One more storage read per rate update |

Provider changes revert today (`storageProviderChanged`). If they return, the agreed price would carry over to the new provider unless the transfer resets it, and `CreateDataSetWithPayment` binds the provider's `payee` without its `providerId`. Both are open questions for upstream.

## Code placement

The FWSS core gets two stubs, `updateStoragePrice` and `cancelStoragePriceOffers`, that forward to Rails with the domain separator and session-key registry. Creation-time pricing rides on #618's `verifyCreateDataSet` call, which returns the signed `(token, price)`; `Rails.createRails` records the price.

`SignatureVerificationLib.verifyUpdateStoragePriceSignature` is internal and compiled into Rails. Rails reads and writes the data set's record through `DataSetInfoRecord`, a copy of the frozen `DataSetInfo` at root slot 7, and calls only `paymentsContractAddress()` and `pdpVerifierAddress()` on FWSS, both of which stay routed after the ERC-8167 transition. On the modular-dispatch branch, `updateStoragePrice` and `cancelStoragePriceOffers` fit the payment module, which already owns `terminateService`'s payer-signature and provider-caller pattern.

## Size and gas

With #618 and its commission, FWSS builds to 23,521 B at solc 0.8.30 and 23,534 B at 0.8.37, under the 23,552 B policy budget. Rails is 10,201 B at 0.8.30.

EVM gas, measured with mocked signatures and cold accounts (FEVM gas not measured):

| Operation | Gas |
|---|---:|
| main, legacy create (USDFC) | 694,836 |
| `0xe0` create, USDFC, priced | 718,630 |
| `0xe0` create, axlUSDC, priced | 737,699 |
| `updateStoragePrice`, axlUSDC data set of about 100 GiB | 107,835 |

## Open questions for upstream

1. Lock the layout: the namespace id and struct, the `0xe0` tuple, both type strings and the permissions.
2. The namespace convention `filecoin.storage.<Name>`.
3. Whether upstream PRs target the modular-dispatch payment module (`refactor/payment-module`).
4. An absolute USD price floored at the posted price, or another shape.
5. Whether price changes after creation land with creation-time pricing or separately.
6. Whether the new types also bind `providerId`.
