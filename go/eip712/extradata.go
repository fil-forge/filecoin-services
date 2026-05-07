package eip712

import (
	"fmt"
	"math/big"
	"strings"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/fil-forge/filecoin-services/go/bindings"
)

// Pre-parse ABI types at package initialization for efficiency
var (
	addressType, _        = abi.NewType("address", "", nil)
	uint256Type, _        = abi.NewType("uint256", "", nil)
	stringArrayType, _    = abi.NewType("string[]", "", nil)
	stringDoubleArrayType, _ = abi.NewType("string[][]", "", nil)
	bytesType, _          = abi.NewType("bytes", "", nil)

	// Parse contract ABI once at startup
	serviceContractABI *abi.ABI
)

func init() {
	// Parse the contract ABI from bindings at initialization
	parsedABI, err := abi.JSON(strings.NewReader(bindings.FilecoinWarmStorageServiceABI))
	if err != nil {
		panic(fmt.Sprintf("Failed to parse FilecoinWarmStorageService ABI: %v", err))
	}
	serviceContractABI = &parsedABI

	// Validate required methods exist
	requiredMethods := []string{"dataSetCreated", "piecesAdded", "piecesScheduledRemove", "dataSetDeleted"}
	for _, method := range requiredMethods {
		if _, exists := serviceContractABI.Methods[method]; !exists {
			panic(fmt.Sprintf("Contract ABI missing required method: %s", method))
		}
	}
}

// ExtraDataEncoder provides functions to encode extraData for PDP operations
// that require EIP-712 signatures for the FilecoinWarmStorageService contract
type ExtraDataEncoder struct{}

// NewExtraDataEncoder creates a new ExtraDataEncoder
func NewExtraDataEncoder() *ExtraDataEncoder {
	return &ExtraDataEncoder{}
}

// EncodeCreateDataSetExtraData encodes the extraData for dataSetCreated callback
// Format matches: abi.decode(extraData, (address, uint256, string[], string[], bytes))
func (e *ExtraDataEncoder) EncodeCreateDataSetExtraData(
	payer common.Address,
	clientDataSetId *big.Int,
	metadata []MetadataEntry,
	signature *AuthSignature,
) ([]byte, error) {
	// Split metadata into keys and values arrays
	keys := make([]string, len(metadata))
	values := make([]string, len(metadata))
	for i, m := range metadata {
		keys[i] = m.Key
		values[i] = m.Value
	}

	signatureBytes, err := signature.Marshal()
	if err != nil {
		return nil, fmt.Errorf("failed to marshal signature: %w", err)
	}

	// Use ABI arguments that match the contract's decode expectation
	arguments := abi.Arguments{
		{Type: addressType},      // payer
		{Type: uint256Type},      // clientDataSetId
		{Type: stringArrayType},  // metadataKeys
		{Type: stringArrayType},  // metadataValues
		{Type: bytesType},        // signature
	}

	return arguments.Pack(payer, clientDataSetId, keys, values, signatureBytes)
}

// EncodeAddPiecesExtraData encodes the extraData for piecesAdded callback
// Format matches: abi.decode(extraData, (uint256, string[][], string[][], bytes))
func (e *ExtraDataEncoder) EncodeAddPiecesExtraData(
	nonce *big.Int,
	signature *AuthSignature,
	metadata [][]MetadataEntry,
) ([]byte, error) {
	signatureBytes, err := signature.Marshal()
	if err != nil {
		return nil, fmt.Errorf("failed to marshal signature: %w", err)
	}

	// Split metadata into keys and values arrays
	keysArray := make([][]string, len(metadata))
	valuesArray := make([][]string, len(metadata))
	for i, pieceMetadata := range metadata {
		keys := make([]string, len(pieceMetadata))
		values := make([]string, len(pieceMetadata))
		for j, m := range pieceMetadata {
			keys[j] = m.Key
			values[j] = m.Value
		}
		keysArray[i] = keys
		valuesArray[i] = values
	}

	arguments := abi.Arguments{
		{Type: uint256Type},            // nonce
		{Type: stringDoubleArrayType},  // metadataKeys[][]
		{Type: stringDoubleArrayType},  // metadataValues[][]
		{Type: bytesType},              // signature
	}

	return arguments.Pack(nonce, keysArray, valuesArray, signatureBytes)
}

// EncodeSchedulePieceRemovalsExtraData encodes the extraData for piecesScheduledRemove callback
// Format matches: abi.decode(extraData, (bytes))
func (e *ExtraDataEncoder) EncodeSchedulePieceRemovalsExtraData(
	signature *AuthSignature,
) ([]byte, error) {
	signatureBytes, err := signature.Marshal()
	if err != nil {
		return nil, fmt.Errorf("failed to marshal signature: %w", err)
	}

	arguments := abi.Arguments{
		{Type: bytesType}, // signature
	}

	return arguments.Pack(signatureBytes)
}

// EncodeDeleteDataSetExtraData encodes the extraData for dataSetDeleted callback
func (e *ExtraDataEncoder) EncodeDeleteDataSetExtraData(
	signature *AuthSignature,
) ([]byte, error) {
	// Same as SchedulePieceRemovals - just a signature
	return e.EncodeSchedulePieceRemovalsExtraData(signature)
}

// ParseMetadataEntries converts a slice of key=value strings to MetadataEntry slice
// This is a helper for parsing metadata from command line or configuration
func ParseMetadataEntries(entries []string) ([]MetadataEntry, error) {
	metadata := make([]MetadataEntry, 0, len(entries))
	for _, entry := range entries {
		parts := strings.SplitN(entry, "=", 2)
		if len(parts) != 2 {
			return nil, fmt.Errorf("invalid metadata entry format: %s (expected key=value)", entry)
		}
		metadata = append(metadata, MetadataEntry{
			Key:   parts[0],
			Value: parts[1],
		})
	}
	return metadata, nil
}

// MetadataToStringSlices converts MetadataEntry slice to separate key and value slices
// This is useful when calling smart contract methods that expect separate arrays
func MetadataToStringSlices(metadata []MetadataEntry) (keys []string, values []string) {
	keys = make([]string, len(metadata))
	values = make([]string, len(metadata))
	for i, m := range metadata {
		keys[i] = m.Key
		values[i] = m.Value
	}
	return keys, values
}
