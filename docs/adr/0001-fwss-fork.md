# ADR 0001: Run a separate FWSS deployment built from upstream code

- **Status:** Accepted
- **Date:** 2026-10-07
- **Decided by:** Filecoin Foundation (FF)

## Decision

FF runs its own FilecoinWarmStorageService (FWSS) proxy, built from FilOzone/filecoin-services `main` plus multi-currency data sets (#618) and per-data-set storage prices (#619), implemented as proposed to upstream. Everything the fork adds lives in ERC-7201 namespaces, and FF asks upstream to agree that layout before mainnet. The fork ends when FF's proxy upgrades to an upstream release that contains equivalent code.

FF's deployment goes to mainnet two weeks after this decision, with the layout in this record.

## Context

FF's deployment needs three things upstream FWSS does not have: data sets paid in axlUSDC, a storage price agreed per data set, and a commission on axlUSDC rails that is burned. Upstream FWSS pays in USDFC at the posted price only.

Upstream has issues for the first two, #618 and #619, and FF has proposed designs for both there. They cannot be reviewed, merged and released upstream before FF's mainnet date. Upstream is also restructuring FWSS into modules behind an ERC-8167 dispatcher (#614 and the PRs stacked on it). The payment code these features change has not been extracted yet, and upstream does not yet run the transition to the dispatcher on mainnet.

## What we decided

1. **Base on upstream `main`.** The first release is upstream `main` at `7e6bd50`, the v1.4.0 monolith, plus the two features.
2. **Take modular dispatch later, by upgrade.** The fork keeps `announceUpgradePlan`, `_authorizeUpgrade`, `OwnableUpgradeable` and the implementation-size guard unchanged, so upstream's `FWSSDispatcherTransition` can move FF's proxy to the dispatcher the same way it moves upstream's.
3. **Converge on upstream.** Contract code in the fork is the code proposed upstream. FF-specific differences are configuration: the whitelist entries, their commission rates and deployment addresses. A code change FF needs goes to upstream as a proposal in the same step. The aim is the same code and, where possible, the same upgrade schedule, with separate contracts.
4. **Namespaced storage.** Nothing is added to root slots 0-23 or to `DataSetInfo`. New state lives in two ERC-7201 namespaces declared on `abstract contract PaymentTermsStorage`, which FWSS inherits:
   - `erc7201:filecoin.storage.FWSSCurrency` (slot `0x2be83150facef7aa3ae5922e809766ad94dac519fdf44800de563f85c625d500`): the currency whitelist.
   - `erc7201:filecoin.storage.FWSSDataSetPricing` (slot `0x44ed9206e2d77446bd06f9698aeef56e4b0ec8004fef8f3eb108175dad5b9600`): each data set's currency id, agreed price and price-update nonce.

   The naming follows upstream's only FWSS precedent, PR #615.
5. **Agree the layout before mainnet.** The namespace ids and structs, the extraData tuples, the EIP-712 type strings and the session-key permissions are much harder to change once data sets exist: a change after deploy needs a one-time migration in an upgrade. FF has asked upstream to confirm them in #618 and #619.
6. **End condition.** FF's proxy upgrades to an upstream release that contains equivalent code, and the fork is retired.
7. **Fallback.** If upstream's released layout differs from FF's, the upgrade to that release carries one bridging `migrate()` that moves FF's namespaced state into upstream's layout. It runs once.

## Feature set

| Feature | What it does | Design |
|---|---|---|
| Multi-currency data sets (#618) | The client picks a USD stablecoin at creation in a signed `0xc0` extraData variant. USDFC stays the default and behaves exactly as on `main`. Other stablecoins come from an owner-managed whitelist; a provider accepts one by listing it in its `paymentTokens` registry capability. The 18-decimal USD price list is converted to the token's decimals, rounding up. `withCDN` is limited to the default currency. | [618-multi-currency.md](../design/618-multi-currency.md) |
| Per-data-set storage price (#619) | The client signs a price in 18-decimal USD per TiB per month in a `0xe0` variant; the provider accepts by submitting. The effective price is the higher of the agreed and posted prices. Changes need the payer's signature and the provider's call, with a deadline and nonce, and the payer can cancel outstanding offers. | [619-storage-price.md](../design/619-storage-price.md) |
| Burned commission on non-default currencies | Each whitelist entry carries a commission rate. PDP rails in that currency pay the commission to FilecoinPay's own account, which only its fee auction (`burnForFees`) empties. FF sets 0.5% for axlUSDC; USDFC stays at 0. | [618-multi-currency.md](../design/618-multi-currency.md#commission) |

Both features fit in the v1.4.0 monolith: FWSS builds to 23,521 B at solc 0.8.30, inside upstream's 23,552 B size policy.

## Deployment plan

- Deploy a new FWSS proxy with FF's own implementation, `Rails` and `SignatureVerificationLib` libraries and StateView. The proxy is kept for the life of the deployment; later releases arrive as upgrades.
- Reuse the shared mainnet contracts: FilecoinPay, PDPVerifier, ServiceProviderRegistry and SessionKeyRegistry. FWSS only reads the registry, and provider approval stays in FWSS.
- Construct with USDFC as the default token, then whitelist axlUSDC with `setCurrency(axlUSDC, true, 50)`.
- Providers that accept axlUSDC list it in their `paymentTokens` capability.
- Post-setup ownership and payer custody are open; the deploy runbook will record them.
- Upgrades follow upstream releases: merge the release into the fork, deploy the new implementation, then `announceUpgradePlan` and `upgradeToAndCall` after the delay.

## Consequences

- FF's data sets live on FF's proxy. They do not move to upstream's deployment, and providers serving both see two FWSS addresses.
- When upstream lands the module layout, these features have to exist as modules. The libraries were written for that: `Rails` does not import the FWSS contract and reaches a data set's record by its fixed root slot, so the code moves with little change.
- FF depends on upstream-owned shared contracts. A registry upgrade that changed provider lookups would affect FF's deployment.
- Until upstream agrees the layout, a different upstream choice costs FF one bridging migration.

## Alternatives considered

- **Base on the modular-dispatch branch now.** Mainnet would still run the monolith, since there is no dispatcher-native deployment path yet, and the branch changes weekly. The payment code these features touch is not yet extracted there.
- **Wait for upstream.** No release date exists for #618, #619 or the module layout, and FF's date is fixed.
- **Append root slots or `DataSetInfo` members.** Upstream would likely use the same slots for its own fields, and the storage README on the module branch asks to keep both unchanged. Namespaces avoid the collision.
- **Rebase the earlier multi-token PR (#525).** It stores its state in root slot 23, which `main` now uses for the data set authorizer, and rebased onto `main` it leaves too little room under the size limit for #619.
