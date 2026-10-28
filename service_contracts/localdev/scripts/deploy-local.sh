#!/bin/bash
# deploy-local.sh - Deploy all contracts to local Anvil for testing
#
# This script deploys:
# 0. FVM precompile mocks (for burn/pay operations)
# 1. MockUSDFC token
# 2. SessionKeyRegistry
# 3. PDPVerifier (implementation + proxy)
# 4. FilecoinPayV1
# 5. ServiceProviderRegistry (implementation + proxy)
# 6. SignatureVerificationLib
# 7. FilecoinWarmStorageService (implementation + proxy)
# 8. FilecoinWarmStorageServiceStateView
#
# Outputs contract addresses to /deployed-addresses.json

set -e

# Configuration
ANVIL_RPC="${ANVIL_RPC:-http://localhost:8546}"
OUTPUT_FILE="${OUTPUT_FILE:-/deployed-addresses.json}"

# Anvil's default pre-funded account (10,000 ETH)
DEPLOYER_PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
DEPLOYER_ADDRESS="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

# Anvil Account #1 - Payer account for testing (10,000 ETH)
PAYER_PRIVATE_KEY="0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
PAYER_ADDRESS="0x70997970C51812dc3A010C7d01b50e0d17dc79C8"

# Local test configuration (with 12-second blocks)
CHALLENGE_FINALITY=3       # ~36 seconds finality (3 blocks × 12 sec)
MAX_PROVING_PERIOD=25      # 5 minutes per proving period (25 blocks × 12 sec)
CHALLENGE_WINDOW_SIZE=5    # ~1 minute challenge window (5 blocks × 12 sec)
SERVICE_NAME="Local Test Service"
SERVICE_DESCRIPTION="Local development environment for testing"
FILBEAM_CONTROLLER_ADDRESS="$DEPLOYER_ADDRESS"
FILBEAM_BENEFICIARY_ADDRESS="$DEPLOYER_ADDRESS"

# ANSI formatting
BOLD='\033[1m'
GREEN='\033[0;32m'
RESET='\033[0m'

echo "=========================================="
echo "Deploying contracts to local Anvil"
echo "=========================================="
echo "RPC: $ANVIL_RPC"
echo "Deployer: $DEPLOYER_ADDRESS"
echo

# Wait for Anvil to be ready
echo "Waiting for Anvil..."
for i in {1..30}; do
    if cast chain-id --rpc-url "$ANVIL_RPC" > /dev/null 2>&1; then
        echo "Anvil is ready!"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "ERROR: Anvil not responding after 30 seconds"
        exit 1
    fi
    sleep 1
done

# Helper function to deploy a contract
# Outputs ONLY the address to stdout, all other output goes to stderr
deploy() {
    local name="$1"
    local contract="$2"
    shift 2
    local constructor_args=("$@")

    echo -e "${BOLD}Deploying $name${RESET}" >&2

    # Let forge handle nonce management automatically
    local cmd="forge create --rpc-url $ANVIL_RPC --private-key $DEPLOYER_PRIVATE_KEY --broadcast"

    # Add libraries if set
    if [ -n "$LIBRARIES" ]; then
        cmd="$cmd --libraries $LIBRARIES"
    fi

    cmd="$cmd $contract"

    # Add constructor args if provided
    if [ ${#constructor_args[@]} -gt 0 ]; then
        cmd="$cmd --constructor-args ${constructor_args[*]}"
    fi

    local output=$($cmd 2>&1)
    local address=$(echo "$output" | grep "Deployed to" | awk '{print $3}')

    if [ -z "$address" ]; then
        echo "ERROR: Failed to deploy $name" >&2
        echo "$output" >&2
        exit 1
    fi

    echo -e "  ${GREEN}✓${RESET} $address" >&2

    # Return ONLY the address
    echo "$address"
}

# Deploy a proxy with initialization
# Outputs ONLY the address to stdout
deploy_proxy() {
    local name="$1"
    local implementation="$2"
    local init_data="$3"

    echo -e "${BOLD}Deploying $name proxy${RESET}" >&2

    local output=$(forge create --rpc-url "$ANVIL_RPC" --private-key "$DEPLOYER_PRIVATE_KEY" \
        --broadcast \
        lib/pdp/src/ERC1967Proxy.sol:MyERC1967Proxy \
        --constructor-args "$implementation" "$init_data" 2>&1)

    local address=$(echo "$output" | grep "Deployed to" | awk '{print $3}')

    if [ -z "$address" ]; then
        echo "ERROR: Failed to deploy $name proxy" >&2
        echo "$output" >&2
        exit 1
    fi

    echo -e "  ${GREEN}✓${RESET} $address" >&2

    # Return ONLY the address
    echo "$address"
}

# Change to contracts directory for forge paths
cd /app/service_contracts

# FVM Precompile addresses
FVM_CALL_ACTOR_BY_ADDRESS="0xfe00000000000000000000000000000000000003"
FVM_CALL_ACTOR_BY_ID="0xfe00000000000000000000000000000000000005"
FVM_GET_BEACON_RANDOMNESS="0xfe00000000000000000000000000000000000006"

echo
echo "=========================================="
echo "Step 0: Setup FVM Precompile Mocks"
echo "=========================================="
echo "Setting up mock precompiles for FVM burn/pay operations..."

# Deploy FVMCallActorById mock (temporarily, to get bytecode)
echo -e "${BOLD}Deploying FVMCallActorById mock${RESET}"
FVM_BY_ID_OUTPUT=$(forge create --rpc-url "$ANVIL_RPC" --private-key "$DEPLOYER_PRIVATE_KEY" \
    --broadcast \
    lib/pdp/lib/fvm-solidity/src/mocks/FVMCallActorById.sol:FVMCallActorById 2>&1)
FVM_BY_ID_TEMP=$(echo "$FVM_BY_ID_OUTPUT" | grep "Deployed to" | awk '{print $3}')
if [ -z "$FVM_BY_ID_TEMP" ]; then
    echo "ERROR: Failed to deploy FVMCallActorById mock"
    echo "$FVM_BY_ID_OUTPUT"
    exit 1
fi
echo -e "  ${GREEN}✓${RESET} Deployed to $FVM_BY_ID_TEMP"

# Deploy FVMCallActorByAddress mock (temporarily, to get bytecode)
echo -e "${BOLD}Deploying FVMCallActorByAddress mock${RESET}"
FVM_BY_ADDR_OUTPUT=$(forge create --rpc-url "$ANVIL_RPC" --private-key "$DEPLOYER_PRIVATE_KEY" \
    --broadcast \
    lib/pdp/lib/fvm-solidity/src/mocks/FVMCallActorByAddress.sol:FVMCallActorByAddress 2>&1)
FVM_BY_ADDR_TEMP=$(echo "$FVM_BY_ADDR_OUTPUT" | grep "Deployed to" | awk '{print $3}')
if [ -z "$FVM_BY_ADDR_TEMP" ]; then
    echo "ERROR: Failed to deploy FVMCallActorByAddress mock"
    echo "$FVM_BY_ADDR_OUTPUT"
    exit 1
fi
echo -e "  ${GREEN}✓${RESET} Deployed to $FVM_BY_ADDR_TEMP"

# Deploy DeterministicBeaconRandomness mock (temporarily, to get bytecode)
# This returns keccak256(abi.encode(epoch)) for deterministic but epoch-dependent randomness
echo -e "${BOLD}Deploying DeterministicBeaconRandomness mock${RESET}"
FVM_RANDOMNESS_OUTPUT=$(forge create --rpc-url "$ANVIL_RPC" --private-key "$DEPLOYER_PRIVATE_KEY" \
    --broadcast \
    localdev/contracts/DeterministicBeaconRandomness.sol:DeterministicBeaconRandomness 2>&1)
FVM_RANDOMNESS_TEMP=$(echo "$FVM_RANDOMNESS_OUTPUT" | grep "Deployed to" | awk '{print $3}')
if [ -z "$FVM_RANDOMNESS_TEMP" ]; then
    echo "ERROR: Failed to deploy DeterministicBeaconRandomness mock"
    echo "$FVM_RANDOMNESS_OUTPUT"
    exit 1
fi
echo -e "  ${GREEN}✓${RESET} Deployed to $FVM_RANDOMNESS_TEMP"

# Get the bytecode from deployed contracts
echo "Getting bytecode from deployed mocks..."
FVM_BY_ID_CODE=$(cast code --rpc-url "$ANVIL_RPC" "$FVM_BY_ID_TEMP")
FVM_BY_ADDR_CODE=$(cast code --rpc-url "$ANVIL_RPC" "$FVM_BY_ADDR_TEMP")
FVM_RANDOMNESS_CODE=$(cast code --rpc-url "$ANVIL_RPC" "$FVM_RANDOMNESS_TEMP")

# Set code at FVM precompile addresses using anvil_setCode
echo "Setting bytecode at FVM precompile addresses..."

# Set FVMCallActorById at 0xfe...05
curl -s -X POST "$ANVIL_RPC" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"anvil_setCode\",\"params\":[\"$FVM_CALL_ACTOR_BY_ID\",\"$FVM_BY_ID_CODE\"],\"id\":1}" > /dev/null
echo -e "  ${GREEN}✓${RESET} FVMCallActorById set at $FVM_CALL_ACTOR_BY_ID"

# Set FVMCallActorByAddress at 0xfe...03
curl -s -X POST "$ANVIL_RPC" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"anvil_setCode\",\"params\":[\"$FVM_CALL_ACTOR_BY_ADDRESS\",\"$FVM_BY_ADDR_CODE\"],\"id\":1}" > /dev/null
echo -e "  ${GREEN}✓${RESET} FVMCallActorByAddress set at $FVM_CALL_ACTOR_BY_ADDRESS"

# Set FVMGetBeaconRandomness at 0xfe...06
curl -s -X POST "$ANVIL_RPC" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"anvil_setCode\",\"params\":[\"$FVM_GET_BEACON_RANDOMNESS\",\"$FVM_RANDOMNESS_CODE\"],\"id\":1}" > /dev/null
echo -e "  ${GREEN}✓${RESET} FVMGetBeaconRandomness set at $FVM_GET_BEACON_RANDOMNESS"

echo -e "${GREEN}FVM precompile mocks ready!${RESET}"

echo
echo "=========================================="
echo "Step 1: Deploy MockUSDFC Token"
echo "=========================================="
USDFC_TOKEN_ADDRESS=$(deploy "MockUSDFC" "localdev/contracts/MockUSDFC.sol:MockUSDFC")

# Mint some tokens to the deployer for testing
echo "Minting 1,000,000 USDFC to deployer..."
cast send --rpc-url "$ANVIL_RPC" --private-key "$DEPLOYER_PRIVATE_KEY" \
    "$USDFC_TOKEN_ADDRESS" "mint(address,uint256)" "$DEPLOYER_ADDRESS" "1000000000000000000000000" > /dev/null 2>&1
echo -e "  ${GREEN}✓${RESET} Minted 1,000,000 USDFC"

echo
echo "=========================================="
echo "Step 2: Deploy SessionKeyRegistry"
echo "=========================================="
SESSION_KEY_REGISTRY_ADDRESS=$(deploy "SessionKeyRegistry" "lib/session-key-registry/src/SessionKeyRegistry.sol:SessionKeyRegistry")

echo
echo "=========================================="
echo "Step 3: Deploy PDPVerifier"
echo "=========================================="
VERIFIER_IMPL=$(deploy "PDPVerifier Implementation" "lib/pdp/src/PDPVerifier.sol:PDPVerifier" 1)
INIT_DATA=$(cast calldata "initialize(uint256)" "$CHALLENGE_FINALITY")
PDP_VERIFIER_ADDRESS=$(deploy_proxy "PDPVerifier" "$VERIFIER_IMPL" "$INIT_DATA")

echo
echo "=========================================="
echo "Step 4: Deploy FilecoinPayV1"
echo "=========================================="
PAYMENTS_CONTRACT_ADDRESS=$(deploy "FilecoinPayV1" "lib/fws-payments/src/FilecoinPayV1.sol:FilecoinPayV1")

echo
echo "=========================================="
echo "Step 5: Deploy ServiceProviderRegistry"
echo "=========================================="
REGISTRY_IMPL=$(deploy "ServiceProviderRegistry Implementation" "src/ServiceProviderRegistry.sol:ServiceProviderRegistry" 1)
REGISTRY_INIT_DATA=$(cast calldata "initialize()")
SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS=$(deploy_proxy "ServiceProviderRegistry" "$REGISTRY_IMPL" "$REGISTRY_INIT_DATA")

echo
echo "=========================================="
echo "Step 6: Deploy SignatureVerificationLib"
echo "=========================================="
SIGNATURE_VERIFICATION_LIB_ADDRESS=$(deploy "SignatureVerificationLib" "src/lib/SignatureVerificationLib.sol:SignatureVerificationLib")

echo
echo "=========================================="
echo "Step 7: Deploy FilecoinWarmStorageService"
echo "=========================================="
export LIBRARIES="src/lib/SignatureVerificationLib.sol:SignatureVerificationLib:$SIGNATURE_VERIFICATION_LIB_ADDRESS"
FWS_IMPL=$(deploy "FilecoinWarmStorageService Implementation" \
    "src/FilecoinWarmStorageService.sol:FilecoinWarmStorageService" \
    "$PDP_VERIFIER_ADDRESS" \
    "$PAYMENTS_CONTRACT_ADDRESS" \
    "$USDFC_TOKEN_ADDRESS" \
    "$FILBEAM_BENEFICIARY_ADDRESS" \
    "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS" \
    "$SESSION_KEY_REGISTRY_ADDRESS" \
    1)
unset LIBRARIES

FWS_INIT_DATA=$(cast calldata "initialize(uint64,uint256,address,string,string)" \
    "$MAX_PROVING_PERIOD" \
    "$CHALLENGE_WINDOW_SIZE" \
    "$FILBEAM_CONTROLLER_ADDRESS" \
    "$SERVICE_NAME" \
    "$SERVICE_DESCRIPTION")
WARM_STORAGE_SERVICE_ADDRESS=$(deploy_proxy "FilecoinWarmStorageService" "$FWS_IMPL" "$FWS_INIT_DATA")

echo
echo "=========================================="
echo "Step 8: Deploy StateView"
echo "=========================================="
WARM_STORAGE_VIEW_ADDRESS=$(deploy "FilecoinWarmStorageServiceStateView" \
    "src/FilecoinWarmStorageServiceStateView.sol:FilecoinWarmStorageServiceStateView" \
    "$WARM_STORAGE_SERVICE_ADDRESS")

echo
echo "=========================================="
echo "Step 9: Set View Address on Service"
echo "=========================================="
echo "Setting view contract address..."
cast send --rpc-url "$ANVIL_RPC" --private-key "$DEPLOYER_PRIVATE_KEY" \
    "$WARM_STORAGE_SERVICE_ADDRESS" "setViewContract(address)" "$WARM_STORAGE_VIEW_ADDRESS" > /dev/null 2>&1
echo -e "  ${GREEN}✓${RESET} View address set"

echo
echo "=========================================="
echo "Step 10: Setup Payer Account"
echo "=========================================="

# Mint USDFC to payer (100,000 USDFC with 6 decimals)
echo "Minting 100,000 USDFC to payer..."
cast send --rpc-url "$ANVIL_RPC" --private-key "$DEPLOYER_PRIVATE_KEY" \
    "$USDFC_TOKEN_ADDRESS" "mint(address,uint256)" "$PAYER_ADDRESS" "100000000000000000000000" > /dev/null 2>&1
echo -e "  ${GREEN}✓${RESET} Minted 100,000 USDFC to payer"

# Approve FilecoinPayV1 to spend payer's USDFC
echo "Approving FilecoinPayV1 to spend payer's USDFC..."
cast send --rpc-url "$ANVIL_RPC" --private-key "$PAYER_PRIVATE_KEY" \
    "$USDFC_TOKEN_ADDRESS" "approve(address,uint256)" "$PAYMENTS_CONTRACT_ADDRESS" "100000000000000000000000" > /dev/null 2>&1
echo -e "  ${GREEN}✓${RESET} Approved FilecoinPayV1"

# Deposit USDFC into FilecoinPayV1 (50,000 USDFC)
echo "Depositing 50,000 USDFC into FilecoinPayV1..."
cast send --rpc-url "$ANVIL_RPC" --private-key "$PAYER_PRIVATE_KEY" \
    "$PAYMENTS_CONTRACT_ADDRESS" "deposit(address,address,uint256)" \
    "$USDFC_TOKEN_ADDRESS" "$PAYER_ADDRESS" "50000000000000000000000" > /dev/null 2>&1
echo -e "  ${GREEN}✓${RESET} Deposited 50,000 USDFC"

# Set operator approval for FilecoinWarmStorageService
echo "Setting operator approval for FilecoinWarmStorageService..."
cast send --rpc-url "$ANVIL_RPC" --private-key "$PAYER_PRIVATE_KEY" \
    "$PAYMENTS_CONTRACT_ADDRESS" \
    "setOperatorApproval(address,address,bool,uint256,uint256,uint256)" \
    "$USDFC_TOKEN_ADDRESS" \
    "$WARM_STORAGE_SERVICE_ADDRESS" \
    true \
    "1000000000000000000000" \
    "1000000000000000000000" \
    "31536000" > /dev/null 2>&1
echo -e "  ${GREEN}✓${RESET} Operator approval set"

echo
echo "=========================================="
echo "Writing contract addresses"
echo "=========================================="

# Write addresses to JSON file
cat > "$OUTPUT_FILE" << EOF
{
  "chainId": 31337,
  "rpcUrl": "http://localhost:8545",
  "deployer": {
    "address": "$DEPLOYER_ADDRESS",
    "privateKey": "$DEPLOYER_PRIVATE_KEY"
  },
  "payer": {
    "address": "$PAYER_ADDRESS",
    "privateKey": "$PAYER_PRIVATE_KEY"
  },
  "contracts": {
    "MockUSDFC": "$USDFC_TOKEN_ADDRESS",
    "SessionKeyRegistry": "$SESSION_KEY_REGISTRY_ADDRESS",
    "PDPVerifier": "$PDP_VERIFIER_ADDRESS",
    "FilecoinPayV1": "$PAYMENTS_CONTRACT_ADDRESS",
    "ServiceProviderRegistry": "$SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS",
    "SignatureVerificationLib": "$SIGNATURE_VERIFICATION_LIB_ADDRESS",
    "FilecoinWarmStorageService": "$WARM_STORAGE_SERVICE_ADDRESS",
    "FilecoinWarmStorageServiceStateView": "$WARM_STORAGE_VIEW_ADDRESS"
  },
  "config": {
    "challengeFinality": $CHALLENGE_FINALITY,
    "maxProvingPeriod": $MAX_PROVING_PERIOD,
    "challengeWindowSize": $CHALLENGE_WINDOW_SIZE,
    "serviceName": "$SERVICE_NAME",
    "serviceDescription": "$SERVICE_DESCRIPTION"
  }
}
EOF

echo -e "${GREEN}✓${RESET} Wrote addresses to $OUTPUT_FILE"

echo
echo "=========================================="
echo -e "${GREEN}Deployment Complete!${RESET}"
echo "=========================================="
echo
echo "Contract Addresses:"
echo "  MockUSDFC:                  $USDFC_TOKEN_ADDRESS"
echo "  SessionKeyRegistry:         $SESSION_KEY_REGISTRY_ADDRESS"
echo "  PDPVerifier:                $PDP_VERIFIER_ADDRESS"
echo "  FilecoinPayV1:              $PAYMENTS_CONTRACT_ADDRESS"
echo "  ServiceProviderRegistry:    $SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"
echo "  FilecoinWarmStorageService: $WARM_STORAGE_SERVICE_ADDRESS"
echo "  StateView:                  $WARM_STORAGE_VIEW_ADDRESS"
echo
echo "Accounts:"
echo "  Deployer: $DEPLOYER_ADDRESS"
echo "  Payer:    $PAYER_ADDRESS"
echo
echo "Payer Account Setup:"
echo "  USDFC Balance:     100,000 USDFC"
echo "  Deposited:         50,000 USDFC in FilecoinPayV1"
echo "  Operator Approval: FilecoinWarmStorageService"
echo
echo "Configuration:"
echo "  Challenge Finality:    $CHALLENGE_FINALITY epochs"
echo "  Max Proving Period:    $MAX_PROVING_PERIOD epochs"
echo "  Challenge Window Size: $CHALLENGE_WINDOW_SIZE epochs"
echo
