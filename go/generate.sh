#!/bin/bash
set -e

# Combined generation script for Go bindings and error types
# This script generates:
# 1. Contract bindings from ABIs
# 2. Error types with selector-based decoding

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICES_DIR="$SCRIPT_DIR/../service_contracts"
ABI_DIR="$SERVICES_DIR/abi"
PDP_DIR="$SERVICES_DIR/lib/pdp"
BINDINGS_DIR="$SCRIPT_DIR/bindings"
EVMERRORS_DIR="$SCRIPT_DIR/evmerrors"
GENERATOR_DIR="$EVMERRORS_DIR/cmd/error-binding-generator"

# macOS uses BSD sed while Ubuntu uses GNU sed
# we need this script to work on both OSs
sedi() {
  sed "$@" > tmpfile && mv tmpfile "${@: -1}"
}

echo "=== Go Code Generation Script ==="
echo ""

# Check dependencies
echo "Checking dependencies..."
if ! command -v abigen &> /dev/null; then
    echo "Error: abigen not found. Please install go-ethereum tools."
    echo "Run: go install github.com/ethereum/go-ethereum/cmd/abigen@latest"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "Error: jq not found. Please install jq"
    exit 1
fi

if ! command -v go &> /dev/null; then
    echo "Error: go is required but not installed"
    exit 1
fi

# Check if ABI directory exists
if [ ! -d "$ABI_DIR" ]; then
    echo "Error: ABI directory not found at $ABI_DIR"
    echo "Please run 'make update-abi' in service_contracts directory first"
    exit 1
fi

echo "✓ All dependencies satisfied"
echo ""

#############################################
# PART 1: Generate Contract Bindings
#############################################

echo "=== [1/2] Generating Contract Bindings ==="
echo ""

# Clean generated Go files in bindings (preserve generate.sh if it exists)
echo "Cleaning old bindings..."
find "$BINDINGS_DIR" -maxdepth 1 -name "*.go" -delete 2>/dev/null || true

# Generate a common types file first
echo "Creating common types file..."
cat > "$BINDINGS_DIR/common_types.go" << 'EOF'
// Code generated - DO NOT EDIT.
package bindings

import (
	"math/big"
)

// CidsCid is an auto generated low-level Go binding around an user-defined struct.
type CidsCid struct {
	Data []byte
}

// Common types used across contracts
type IPDPTypesProof struct {
	Leaf  [32]byte
	Proof [][32]byte
}

type IPDPTypesPieceIdAndOffset struct {
	PieceId *big.Int
	Offset  *big.Int
}
EOF

# Generate bindings from PDP contracts
echo "Generating PDPVerifier bindings..."
if [ -f "$ABI_DIR/PDPVerifier.abi.json" ]; then
    abigen --abi <(jq -r '.' "$ABI_DIR/PDPVerifier.abi.json") \
           --pkg bindings \
           --type PDPVerifier \
           --out "$BINDINGS_DIR/pdp_verifier_temp.go"

    # Remove duplicate type definitions
    cd "$BINDINGS_DIR"
    sedi '/^type CidsCid struct {$/,/^}$/d' pdp_verifier_temp.go
    sedi '/^type IPDPTypesProof struct {$/,/^}$/d' pdp_verifier_temp.go
    sedi '/^type IPDPTypesPieceIdAndOffset struct {$/,/^}$/d' pdp_verifier_temp.go
    mv pdp_verifier_temp.go pdp_verifier.go
    cd "$SCRIPT_DIR"
else
    echo "  Warning: PDPVerifier.abi.json not found in $ABI_DIR"
fi

echo "Generating PDPProvingSchedule bindings..."
# Try to get IPDPProvingSchedule from PDP submodule's out directory
if [ -f "$PDP_DIR/out/IPDPProvingSchedule.sol/IPDPProvingSchedule.json" ]; then
    abigen --abi <(jq -r '.abi' "$PDP_DIR/out/IPDPProvingSchedule.sol/IPDPProvingSchedule.json") \
           --pkg bindings \
           --type PDPProvingSchedule \
           --out "$BINDINGS_DIR/pdp_proving_schedule.go"
else
    echo "  Warning: IPDPProvingSchedule.json not found in $PDP_DIR/out/"
fi

# Generate bindings from Storacha services
echo "Generating FilecoinWarmStorageService bindings..."
abigen --abi <(jq -r '.' "$ABI_DIR/FilecoinWarmStorageService.abi.json") \
       --pkg bindings \
       --type FilecoinWarmStorageService \
       --out "$BINDINGS_DIR/filecoin_warm_storage_service_temp.go"

# Remove duplicate types
cd "$BINDINGS_DIR"
sedi '/^type CidsCid struct {$/,/^}$/d' filecoin_warm_storage_service_temp.go
mv filecoin_warm_storage_service_temp.go filecoin_warm_storage_service.go
cd "$SCRIPT_DIR"

echo "Generating FilecoinWarmStorageServiceStateView bindings..."
abigen --abi <(jq -r '.' "$ABI_DIR/FilecoinWarmStorageServiceStateView.abi.json") \
       --pkg bindings \
       --type FilecoinWarmStorageServiceStateView \
       --out "$BINDINGS_DIR/filecoin_warm_storage_service_state_view_temp.go"

# Remove duplicate types from StateView
cd "$BINDINGS_DIR"
sedi '/^type CidsCid struct {$/,/^}$/d' filecoin_warm_storage_service_state_view_temp.go
mv filecoin_warm_storage_service_state_view_temp.go filecoin_warm_storage_service_state_view.go
cd "$SCRIPT_DIR"

echo "Generating Payments bindings..."
abigen --abi <(jq -r '.' "$ABI_DIR/FilecoinPayV1.abi.json") \
       --pkg bindings \
       --type Payments \
       --out "$BINDINGS_DIR/payments.go"

echo "Generating ServiceProviderRegistry bindings..."
abigen --abi <(jq -r '.' "$ABI_DIR/ServiceProviderRegistry.abi.json") \
       --pkg bindings \
       --type ServiceProviderRegistry \
       --out "$BINDINGS_DIR/service_provider_registry.go"

echo "Generating SessionKeyRegistry bindings..."
abigen --abi <(jq -r '.' "$ABI_DIR/SessionKeyRegistry.abi.json") \
       --pkg bindings \
       --type SessionKeyRegistry \
       --out "$BINDINGS_DIR/session_key_registry.go"

echo "✓ Contract bindings generated successfully"
echo ""

#############################################
# PART 2: Generate Error Types
#############################################

echo "=== [2/2] Generating Error Types ==="
echo ""

# Check if AllErrors.abi.json exists
ERRORS_ABI="$ABI_DIR/AllErrors.abi.json"
if [ ! -f "$ERRORS_ABI" ]; then
    echo "Warning: AllErrors.abi.json not found at $ERRORS_ABI"
    echo "Skipping error generation (run 'make abi' in service_contracts to generate)"
else
    # Count errors in the ABI
    ERROR_COUNT=$(jq '[.[] | select(.type == "error")] | length' "$ERRORS_ABI")
    echo "Found $ERROR_COUNT errors in AllErrors.abi.json"

    # The generator expects { "abi": [...] } format, but AllErrors.abi.json is just an array
    # Wrap it in the expected structure
    TEMP_ABI=$(mktemp)
    trap "rm -f $TEMP_ABI" EXIT
    jq '{abi: .}' "$ERRORS_ABI" > "$TEMP_ABI"

    # Build the code generator
    echo "Building error binding generator..."
    cd "$GENERATOR_DIR"

    # Download dependencies if needed
    go mod download 2>/dev/null || true

    # Build the generator
    go build -o generator main.go
    echo "✓ Generator built successfully"

    # Run the generator
    echo "Running error binding generator..."
    ./generator -abi "$TEMP_ABI" -out "$EVMERRORS_DIR"

    # Clean up the generator binary
    rm -f generator

    echo "✓ Error types generated successfully"
fi

echo ""
echo "========================================="
echo "✅ All code generation complete!"
echo ""
echo "Generated files:"
echo "  Contract bindings: $BINDINGS_DIR/*.go"
echo "  Error types:       $EVMERRORS_DIR/{errors,decoders,helpers}.go"
echo ""
echo "Import paths:"
echo "  Bindings:  github.com/fil-forge/filecoin-services/go/bindings"
echo "  Errors:    github.com/fil-forge/filecoin-services/go/evmerrors"
echo "  EIP712:    github.com/fil-forge/filecoin-services/go/eip712"
echo "========================================="