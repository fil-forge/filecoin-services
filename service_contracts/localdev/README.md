# Filecoin Local Development Environment

A Docker container providing a local Filecoin-compatible EVM environment with pre-deployed smart contracts for testing Piri and other PDP applications.

## Quick Start

### Option 1: Normal Startup (~30 seconds)

Deploys all contracts from scratch on each start:

```bash
# Build
docker build -t filecoin-localdev:local -f Dockerfile ..

# Run
docker run -p 8545:8545 -e ANVIL_BLOCK_TIME=3 filecoin-localdev:local
```

### Option 2: Fast Startup (~3 seconds)

Uses pre-dumped state files to skip contract deployment:

```bash
# Generate state files (one-time). The container stays alive after deploying
# contracts; external services may register against the chain before you stop it.
docker run -d --name localdev-init \
  -p 8545:8545 \
  -v $(pwd):/output \
  -e MODE=init \
  filecoin-localdev:local

# ... optionally run external services that register against the chain here ...

# Graceful shutdown triggers the state dump:
docker stop localdev-init
docker rm localdev-init

# Then run with the produced state files:
docker run -p 8545:8545 \
  -v $(pwd)/anvil-state.json:/app/anvil-state.json \
  -v $(pwd)/deployed-addresses.json:/deployed-addresses.json \
  -e MODE=load \
  -e ANVIL_BLOCK_TIME=3 \
  filecoin-localdev:local
```

**Connect your application to:**
- RPC URL: `http://localhost:8545`
- Chain ID: `31337`

## State Management

The container operates in one of two modes, selected by the `MODE` env var.
If `MODE` is unset, the entrypoint autodetects: load mode if
`/app/anvil-state.json` is present, otherwise init mode.

### Init Mode

Deploys all contracts, starts the mock RPC server, then stays alive. On SIGTERM
(e.g. `docker stop`), state is dumped to `$OUTPUT_DIR` (default `/output`).

```bash
docker run -d --name localdev \
  -p 8545:8545 \
  -v $(pwd):/output \
  -e MODE=init \
  filecoin-localdev:local

# Optionally: run external services that call contract methods against
# http://localhost:8545 — their state changes will be captured in the dump.

docker stop localdev   # SIGTERM → dump
```

**Output files** (written to `$OUTPUT_DIR` on graceful shutdown):
- `anvil-state.json` — Complete Anvil blockchain state (~2-10 MB)
- `deployed-addresses.json` — Contract addresses for this deployment

**Safety**: if SIGTERM arrives while contract deployment is still in progress,
the container exits non-zero and does NOT write state files. This prevents
snapshotting a half-deployed chain. Only stop the container after your external
registration flow has completed.

### Load Mode

Loads pre-existing state instead of deploying contracts. Starts in ~3 seconds.

```bash
docker run -p 8545:8545 \
  -v /path/to/anvil-state.json:/app/anvil-state.json \
  -v /path/to/deployed-addresses.json:/deployed-addresses.json \
  -e MODE=load \
  filecoin-localdev:local
```

**Requirements:**
- Both files must be mounted (state file at `/app/anvil-state.json`, addresses
  at `/deployed-addresses.json`)
- Files must be from the same dump (matching state)
- State format must be from `--dump-state` CLI (NOT `anvil_dumpState` RPC)

**Opt-in state capture on shutdown**: if you bind-mount a writable directory at
`/output`, the container writes the current in-memory anvil state (including
any transactions applied since startup) to `$OUTPUT_DIR/anvil-state.json` on
graceful shutdown (SIGTERM). This lets orchestrators capture a post-activity
snapshot without re-deploying contracts. No mount → no write.

```bash
docker run -d --name localdev -p 8545:8545 \
  -v $(pwd)/state/anvil-state.json:/app/anvil-state.json \
  -v $(pwd)/state/deployed-addresses.json:/deployed-addresses.json \
  -v $(pwd)/output:/output \
  -e MODE=load \
  filecoin-localdev:local

# ... apply transactions via RPC ...

docker stop localdev    # SIGTERM → anvil dumps current state to $(pwd)/output/
```

### When to Regenerate State Files

Regenerate state files when:
- Contract code changes
- Deployment script changes
- You need a fresh starting point

## Pre-funded Accounts

All accounts are funded with **10,000 ETH** and use Anvil's deterministic mnemonic:
```
test test test test test test test test test test test junk
```

| # | Address | Private Key | Purpose |
|---|---------|-------------|---------|
| 0 | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` | `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80` | **Deployer** - Deploys all contracts |
| 1 | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` | `0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d` | **Payer** - Pre-configured with USDFC |
| 2 | `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC` | `0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a` | **Service Provider** - PDP provider owner |
| 3-9 | See Anvil output | See Anvil output | Available for testing |

### Payer Account Setup (Account #1)

The payer account is pre-configured for immediate use:

| Asset/Approval | Value |
|----------------|-------|
| ETH Balance | 10,000 ETH |
| USDFC Balance | 100,000 USDFC |
| USDFC Deposited in FilecoinPayV1 | 50,000 USDFC |
| Operator Approval | FilecoinWarmStorageService approved |
| Rate Allowance | 1,000 USDFC/epoch |
| Lockup Allowance | 1,000 USDFC |
| Max Lockup Period | 31,536,000 epochs (~1 year) |

## Deployed Contract Addresses

Contract addresses are written to `/deployed-addresses.json` in the container.

```bash
# Get addresses from running container
docker exec <container> cat /deployed-addresses.json

# Or from dump mode output
cat deployed-addresses.json
```

**Deployed contracts:**
- MockUSDFC (ERC20 token)
- SessionKeyRegistry
- PDPVerifier (proxy)
- FilecoinPayV1
- ServiceProviderRegistry (proxy)
- SignatureVerificationLib
- FilecoinWarmStorageService (proxy)
- FilecoinWarmStorageServiceStateView

### FVM Precompile Mocks

| Precompile | Address |
|------------|---------|
| FVMCallActorByAddress | `0xfE00000000000000000000000000000000000003` |
| FVMCallActorById | `0xfE00000000000000000000000000000000000005` |
| DeterministicBeaconRandomness | `0xfE00000000000000000000000000000000000006` |

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MODE` | autodetect | `init` (deploy + stay alive, dump on SIGTERM) or `load` (restore from state file). Autodetected from presence of `/app/anvil-state.json` when unset. |
| `OUTPUT_DIR` | `/output` | Directory state files are written to on graceful shutdown in init mode. |
| `ANVIL_BLOCK_TIME` | `3` | Block mining interval in seconds |
| `ANVIL_PORT` | `8546` | Internal Anvil port |
| `RPC_PORT` | `8545` | External RPC port |

### Contract Configuration

| Parameter | Value | Description |
|-----------|-------|-------------|
| Chain ID | 31337 | Anvil default |
| Challenge Finality | 3 epochs | ~36 seconds |
| Max Proving Period | 25 epochs | ~5 minutes |
| Challenge Window Size | 5 epochs | ~1 minute |

## Testcontainers Usage (Go)

### Basic Usage (Deploy from scratch)

```go
import "github.com/fil-forge/piri/pkg/testutil/localdev"

func TestWithLocaldev(t *testing.T) {
    ctx := context.Background()

    // Start container (~30s, deploys contracts)
    container, err := localdev.Run(ctx,
        localdev.WithImage("ghcr.io/fil-forge/filecoin-localdev:latest"),
        localdev.WithBlockTime(3),
    )
    require.NoError(t, err)
    defer container.Terminate(ctx)

    // Connect
    client, _ := ethclient.Dial(container.RPCEndpoint)

    // Use addresses from container
    verifier := common.HexToAddress(container.Addresses.PDPVerifier)
    payer := common.HexToAddress(localdev.Accounts.Payer.Address)
}
```

### Fast Startup (Load pre-dumped state)

```go
func TestWithLocaldevFast(t *testing.T) {
    ctx := context.Background()

    // Start container (~3s, loads state)
    container, err := localdev.Run(ctx,
        localdev.WithImage("ghcr.io/fil-forge/filecoin-localdev:latest"),
        localdev.WithStateFile("testdata/anvil-state.json"),
        localdev.WithDeployedAddressesFile("testdata/deployed-addresses.json"),
        localdev.WithBlockTime(3),
    )
    require.NoError(t, err)
    defer container.Terminate(ctx)

    // Same usage as above
    client, _ := ethclient.Dial(container.RPCEndpoint)
}
```

### Manual Block Mining

For deterministic tests, disable auto-mining and mine blocks manually:

```go
// Disable interval mining
container.SetIntervalMining(ctx, 0)

// Mine blocks on demand
container.MineBlock(ctx)
container.MineBlocks(ctx, 10)

// Or change mining interval at runtime
container.SetIntervalMining(ctx, 5) // 5 second blocks
```

## RPC Endpoints

The container exposes a single RPC endpoint that handles both Ethereum and Filecoin methods:

### Ethereum Methods (proxied to Anvil)
- `eth_*` - All standard Ethereum JSON-RPC methods
- `evm_mine` - Mine a block
- `evm_setIntervalMining` - Set block time
- `evm_setAutomine` - Enable/disable automine
- `anvil_*` - Anvil-specific methods

### Filecoin Methods (mocked)
- `Filecoin.ChainHead` - Returns mock TipSet from Anvil block
- `Filecoin.ChainNotify` - WebSocket subscription for block updates
- `Filecoin.StateGetRandomnessDigestFromBeacon` - Deterministic randomness

### Beacon Randomness

The `DeterministicBeaconRandomness` precompile returns `keccak256(abi.encode(epoch))` for any epoch. This ensures:
- Different challenges each proving period
- Deterministic results for reproducible tests
- Matching values between Piri RPC calls and contract calls

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                   Docker Container                      │
│                                                         │
│  ┌────────────────────────────────────────────────────┐ │
│  │           Mock Lotus RPC Server (Go)               │ │
│  │                  Port 8545                         │ │
│  │                                                    │ │
│  │  • eth_* → proxied to Anvil                        │ │
│  │  • Filecoin.* → mock responses                     │ │
│  │  • WebSocket support for ChainNotify               │ │
│  └─────────────────────┬──────────────────────────────┘ │
│                        │                                │
│                        ▼                                │
│  ┌────────────────────────────────────────────────────┐ │
│  │              Anvil (Local EVM)                     │ │
│  │            Port 8546 (internal)                    │ │
│  │                                                    │ │
│  │  Pre-deployed: MockUSDFC, PDPVerifier,             │ │
│  │  FilecoinPayV1, ServiceProviderRegistry,           │ │
│  │  FilecoinWarmStorageService, StateView             │ │
│  └────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

## Development

### Building

```bash
cd service_contracts/localdev
docker build -t filecoin-localdev:local -f Dockerfile ..
```

### Generating State Files for Tests

```bash
# Build container
docker build -t filecoin-localdev:local -f Dockerfile ..

# Start in init mode (deploys contracts, stays alive)
docker run -d --name localdev-gen \
  -v $(pwd):/output \
  -e MODE=init \
  filecoin-localdev:local

# Wait for healthy (contracts deployed, mockrpc ready)
until [ "$(docker inspect -f '{{.State.Health.Status}}' localdev-gen)" = "healthy" ]; do sleep 1; done

# Optionally: run any additional setup transactions against the chain here
# so their state is captured in the snapshot.

# Graceful stop triggers the state dump
docker stop localdev-gen
docker rm localdev-gen

# Copy to your test directory
cp anvil-state.json deployed-addresses.json /path/to/testdata/
```

### Useful Commands

```bash
# Get deployed addresses from running container
docker exec <container> cat /deployed-addresses.json

# Check current block
cast block-number --rpc-url http://localhost:8545

# Mine a block manually
cast rpc evm_mine --rpc-url http://localhost:8545

# Change block time at runtime
cast rpc evm_setIntervalMining 5 --rpc-url http://localhost:8545

# Check USDFC balance
cast call <USDFC_ADDRESS> "balanceOf(address)(uint256)" <ADDRESS> --rpc-url http://localhost:8545
```

### Modifying Contracts

If you modify the contracts or deployment script:

1. Rebuild the container
2. Regenerate state files if using fast startup
3. Contract addresses will change if deployment order changes
4. Always read addresses from `deployed-addresses.json`
