package eip712

import (
	"math/big"
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/fil-forge/filecoin-services/go/bindings"
	"github.com/stretchr/testify/require"
)

// TestEncodingMatchesContractDecoding verifies our encoding matches what the contract expects
func TestEncodingMatchesContractDecoding(t *testing.T) {
	encoder := NewExtraDataEncoder()

	// Test CreateDataSet encoding
	t.Run("CreateDataSet", func(t *testing.T) {
		payer := common.HexToAddress("0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb6")
		clientDataSetId := big.NewInt(42)
		metadata := []MetadataEntry{{Key: "test", Value: "data"}}
		signature := &AuthSignature{V: 27, R: [32]byte{1}, S: [32]byte{2}}

		encoded, err := encoder.EncodeCreateDataSetExtraData(payer, clientDataSetId, metadata, signature)
		require.NoError(t, err)

		// Decode using the same format the contract expects
		// This mimics what the contract does in decodeDataSetCreateData
		arguments := abi.Arguments{
			{Type: addressType},
			{Type: uint256Type},
			{Type: stringArrayType},
			{Type: stringArrayType},
			{Type: bytesType},
		}

		unpacked, err := arguments.Unpack(encoded)
		require.NoError(t, err)
		require.Len(t, unpacked, 5)

		// Verify the decoded values match
		require.Equal(t, payer, unpacked[0].(common.Address))
		require.Equal(t, clientDataSetId, unpacked[1].(*big.Int))
		require.Equal(t, []string{"test"}, unpacked[2].([]string))
		require.Equal(t, []string{"data"}, unpacked[3].([]string))
		require.NotEmpty(t, unpacked[4].([]byte))
	})

	// Test AddPieces encoding
	t.Run("AddPieces", func(t *testing.T) {
		nonce := big.NewInt(7)
		signature := &AuthSignature{V: 27, R: [32]byte{1}, S: [32]byte{2}}
		metadata := [][]MetadataEntry{
			{{Key: "piece1", Value: "value1"}},
			{{Key: "piece2", Value: "value2"}},
		}

		encoded, err := encoder.EncodeAddPiecesExtraData(nonce, signature, metadata)
		require.NoError(t, err)

		// Decode using the contract's expected format
		arguments := abi.Arguments{
			{Type: uint256Type},
			{Type: stringDoubleArrayType},
			{Type: stringDoubleArrayType},
			{Type: bytesType},
		}

		unpacked, err := arguments.Unpack(encoded)
		require.NoError(t, err)
		require.Len(t, unpacked, 4)

		// Verify nonce
		require.Equal(t, nonce, unpacked[0].(*big.Int))

		// Verify signature
		require.NotEmpty(t, unpacked[3].([]byte))

		// Verify metadata keys
		keys := unpacked[1].([][]string) // wt operations preserve order
		require.Len(t, keys, 2)
		require.Equal(t, []string{"piece1"}, keys[0])
		require.Equal(t, []string{"piece2"}, keys[1])

		// Verify metadata values
		values := unpacked[2].([][]string)
		require.Len(t, values, 2)
		require.Equal(t, []string{"value1"}, values[0])
		require.Equal(t, []string{"value2"}, values[1])
	})

	// Test SchedulePieceRemovals encoding
	t.Run("SchedulePieceRemovals", func(t *testing.T) {
		signature := &AuthSignature{V: 27, R: [32]byte{1}, S: [32]byte{2}}

		encoded, err := encoder.EncodeSchedulePieceRemovalsExtraData(signature)
		require.NoError(t, err)

		// Decode using the contract's expected format
		arguments := abi.Arguments{
			{Type: bytesType},
		}

		unpacked, err := arguments.Unpack(encoded)
		require.NoError(t, err)
		require.Len(t, unpacked, 1)

		// Verify signature
		sigBytes := unpacked[0].([]byte)
		require.NotEmpty(t, sigBytes)
		require.Len(t, sigBytes, 65) // 32 + 32 + 1 for r, s, v
	})

	// Test DeleteDataSet encoding
	t.Run("DeleteDataSet", func(t *testing.T) {
		signature := &AuthSignature{V: 27, R: [32]byte{1}, S: [32]byte{2}}

		encoded, err := encoder.EncodeDeleteDataSetExtraData(signature)
		require.NoError(t, err)

		// Should be the same as SchedulePieceRemovals
		arguments := abi.Arguments{
			{Type: bytesType},
		}

		unpacked, err := arguments.Unpack(encoded)
		require.NoError(t, err)
		require.Len(t, unpacked, 1)

		// Verify signature
		sigBytes := unpacked[0].([]byte)
		require.NotEmpty(t, sigBytes)
		require.Len(t, sigBytes, 65)
	})
}

// TestContractABIAvailability ensures the contract ABI is available and valid
func TestContractABIAvailability(t *testing.T) {
	// This test will fail at compile time if bindings are missing
	require.NotEmpty(t, bindings.FilecoinWarmStorageServiceABI)

	// Parse and validate the ABI
	contractABI, err := abi.JSON(strings.NewReader(bindings.FilecoinWarmStorageServiceABI))
	require.NoError(t, err)

	// Verify expected callback methods exist
	require.Contains(t, contractABI.Methods, "dataSetCreated")
	require.Contains(t, contractABI.Methods, "piecesAdded")
	require.Contains(t, contractABI.Methods, "piecesScheduledRemove")
	require.Contains(t, contractABI.Methods, "dataSetDeleted")

	// Verify the dataSetCreated method has the expected third parameter (extraData)
	method, exists := contractABI.Methods["dataSetCreated"]
	require.True(t, exists)
	require.Len(t, method.Inputs, 3, "dataSetCreated should have 3 parameters")
	require.Equal(t, "extraData", method.Inputs[2].Name)
	require.Equal(t, "bytes", method.Inputs[2].Type.String())
}

// TestSignatureMarshalUnmarshal tests that signature marshaling/unmarshaling works correctly
func TestSignatureMarshalUnmarshal(t *testing.T) {
	signature := &AuthSignature{
		V: 27,
		R: [32]byte{0x01, 0x02, 0x03, 0x04},
		S: [32]byte{0x05, 0x06, 0x07, 0x08},
	}

	marshaled, err := signature.Marshal()
	require.NoError(t, err)
	require.Len(t, marshaled, 65)

	// Verify the format is r || s || v
	require.Equal(t, byte(0x01), marshaled[0])
	require.Equal(t, byte(0x02), marshaled[1])
	require.Equal(t, byte(0x05), marshaled[32])
	require.Equal(t, byte(0x06), marshaled[33])
	require.Equal(t, byte(27), marshaled[64])
}

// TestEncodingBreakageDetection will fail if contract changes incompatibly
// This test ensures that if the contract ABI changes in an incompatible way,
// we'll catch it at test time rather than runtime
func TestEncodingBreakageDetection(t *testing.T) {
	// This test verifies that our init() function will panic if the contract
	// doesn't have the expected methods. We can't actually test the panic
	// without re-initializing the package, but we can verify the methods exist
	require.NotNil(t, serviceContractABI, "Contract ABI must be initialized")

	// Verify all required methods are present
	requiredMethods := []string{"dataSetCreated", "piecesAdded", "piecesScheduledRemove", "dataSetDeleted"}
	for _, methodName := range requiredMethods {
		_, exists := serviceContractABI.Methods[methodName]
		require.True(t, exists, "Required method %s must exist in contract ABI", methodName)
	}
}
