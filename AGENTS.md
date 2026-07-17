# filecoin-services — Agent Guide

Smart contracts and Go bindings for an on-chain programmable storage service on Filecoin. Implements FilecoinWarmStorageService (PDP verification + payment rails), ServiceProviderRegistry, and auto-generated Go bindings. See `README.md` for setup and `SPEC.md` for the pricing/behavior specification.

Note: the warm storage contract is under active development and not production-ready (see the README disclaimer).

## Quick Reference

```bash
# Top-level
make contracts          # Build all Solidity contracts (incl. pdp + fws-payments submodules) and extract ABIs
make bindings           # Generate Go bindings (depends on contracts)
make test               # Run all tests (test-contracts + test-go)

# Solidity (service_contracts/)
make install            # Install deps / init submodules
make build              # forge build --via-ir  (solc 0.8.30, via_ir in foundry.toml)
make test               # forge test --via-ir -vv
make gen                # Regenerate Layout, internal StateLibrary, StateView contract
make force-gen          # clean-gen + gen
make update-abi         # Extract ABIs to abi/ (requires jq)
make fmt / fmt-check    # forge fmt
make contract-size-check

# Go (go/)
make generate           # generate.sh: abigen bindings + error-binding-generator error types from ABIs
make test               # go test ./...
make test-abi           # Verify bindings match current ABIs
```

Prerequisites: Foundry, jq (1.7+), git submodules, and `abigen` (`go install github.com/ethereum/go-ethereum/cmd/abigen@latest`) for Go codegen.

## Structure

```
service_contracts/
  src/
    FilecoinWarmStorageService.sol           # Core: dataset mgmt, PDP challenge/prove, payments (UUPS upgradeable)
    FilecoinWarmStorageServiceStateView.sol  # Read-only view via extsload (generated)
    ServiceProviderRegistry.sol              # Provider registry (UUPS upgradeable)
    ServiceProviderRegistryStorage.sol       # Registry storage layout
    Errors.sol                               # Custom error types (many)
    Extsload.sol                             # extsload storage-read pattern
    ProviderIdSet.sol
    lib/
      SignatureVerificationLib.sol           # EIP-712 sig verification (external lib, deployed separately)
      FilecoinWarmStorageServiceLayout.sol           # Generated storage layout
      FilecoinWarmStorageServiceStateInternalLibrary.sol  # Generated state reads
      FilecoinWarmStorageServiceStateLibrary.sol          # Generated state reads
      BigEndian.sol, BloomSet.sol
  test/                # Foundry tests (*.t.sol) + mocks/ + external_signatures.json fixtures
  tools/               # Deploy/upgrade scripts (calibnet, mainnet), multisig, ownership transfer;
                       #   see tools/UPGRADE-PROCESS.md and tools/README.md
  abi/                 # Extracted JSON ABIs (input to Go codegen)
  lib/                 # Git submodules: forge-std, openzeppelin (+upgradeable), pdp,
                       #   fws-payments, session-key-registry
  localdev/            # Docker-based local dev environment (docker-compose, mockrpc)
  deployments.json     # Known deployment addresses
go/                    # Module: github.com/fil-forge/filecoin-services/go
  bindings/            # abigen-generated contract bindings: warm storage service + state view,
                       #   service provider registry, payments, pdp_verifier,
                       #   pdp_proving_schedule, session_key_registry, common_types
  eip712/              # EIP-712 types + signing: types.go (CreateDataSet, AddPieces,
                       #   SchedulePieceRemovals, DeleteDataSet, MetadataEntry, Cid, PieceMetadata),
                       #   signature.go, extradata.go; see CONTRACT_ABI_INTEGRATION.md
  evmerrors/           # Generated typed Go errors + selector-based decoding from contract ABIs
    cmd/error-binding-generator/   # Code generator tool
  generate.sh          # Combined codegen script driven by go/Makefile
```

## Smart Contracts

| Contract | Purpose |
|----------|---------|
| FilecoinWarmStorageService | Core service: dataset management, PDP challenge/prove callbacks, payment validation, fault handling |
| ServiceProviderRegistry | Provider registration, products, pricing (informational), capabilities |
| SignatureVerificationLib | EIP-712 signature verification (external library to stay under the 24KiB code-size limit) |
| StateView + StateLibrary/Layout | Efficient storage reads via the `extsload` pattern (generated — regenerate, don't hand-edit) |

Key patterns:
- UUPS Upgradeable (OpenZeppelin) — never reorder storage fields; only append new fields at the end.
- EIP-712 signatures for off-chain authorization (CreateDataSet, AddPieces, etc.).
- PDPListener interface — receives challenge/prove callbacks from the PDP verifier.
- 24KiB EVM code-size limit managed via external libraries + extsload (`make contract-size-check`).
- Pricing is static and global (owner-set, default 2.5 USDFC per TiB/month with a minimum floor) — provider-advertised prices in the registry do not affect actual payments. Details in `SPEC.md`.

## Go Package

Module: `github.com/fil-forge/filecoin-services/go` (Go 1.25, go-ethereum + testify).

Downstream consumers include piri, piri-signing-service, forgectl, and delegator — treat exported types and signatures as a public API.

`eip712/types.go` defines signing types that must match the Solidity structs exactly; a mismatch makes signature verification fail silently at the contract.

## Code Generation Chain

```
foundry.toml (remappings) → Solidity compilation
  → service_contracts: make gen (Layout, internal lib, StateView)
  → service_contracts: make update-abi (extract ABIs to abi/)
  → go: make generate (abigen → bindings, error-binding-generator → evmerrors)
```

**After ANY contract change:** run `make gen` and `make update-abi` in `service_contracts/`, then `make generate` in `go/` (or just top-level `make bindings`). Never edit generated files by hand.

## What Breaks If You Change Things Here

- **Storage layout changes** → must regenerate StateLibrary/StateView/Layout; Go bindings go stale.
- **Method signature changes** → Go bindings break; downstream consumers break.
- **Error definition changes** → `go/evmerrors` must be regenerated (`abi/AllErrors.abi.json` feeds it).
- **EIP-712 type changes** → `go/eip712/types.go` must be updated to match exactly or signatures fail.
- **Submodule updates (pdp, fws-payments, session-key-registry)** → may change interfaces; rebuild submodule contracts (top-level `make contracts` does this) and test all integration points.
- **Adding large logic** → may exceed the 24KiB limit; use external libraries + extsload.
- **Storage field reordering** → breaks UUPS proxy upgrades. Only append.
