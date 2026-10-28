package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/ethereum/go-ethereum/crypto"
	"github.com/filecoin-project/go-address"
	"github.com/filecoin-project/go-state-types/abi"
	"github.com/filecoin-project/go-state-types/big"
	"github.com/filecoin-project/lotus/api"
	"github.com/filecoin-project/lotus/chain/types"
	"github.com/gorilla/websocket"
	"github.com/ipfs/go-cid"
	mh "github.com/multiformats/go-multihash"
)

var (
	listenAddr = getEnv("LISTEN_ADDR", ":8545")
	anvilAddr  = getEnv("ANVIL_ADDR", "http://localhost:8546")
	// doesn't set the blocktime, polls for it from Anvil
	blockTime = getDurationEnv("BLOCK_TIME", 500*time.Millisecond)
)

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func getDurationEnv(key string, fallback time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		d, err := time.ParseDuration(v)
		if err == nil {
			return d
		}
	}
	return fallback
}

// JSONRPCRequest represents a JSON-RPC 2.0 request
type JSONRPCRequest struct {
	JSONRPC string            `json:"jsonrpc"`
	Method  string            `json:"method"`
	Params  []json.RawMessage `json:"params"`
	ID      json.RawMessage   `json:"id"`
}

// JSONRPCResponse represents a JSON-RPC 2.0 response
type JSONRPCResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *JSONRPCError   `json:"error,omitempty"`
	ID      json.RawMessage `json:"id"`
}

// JSONRPCError represents a JSON-RPC 2.0 error
type JSONRPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// Subscription represents an active ChainNotify subscription
type Subscription struct {
	id       int64
	conn     *websocket.Conn
	mu       sync.Mutex
	closed   bool
	closeCh  chan struct{}
	lastSent int64 // last block height sent
}

// Server handles the mock Lotus RPC
type Server struct {
	httpClient    *http.Client
	mu            sync.RWMutex
	currentHeight int64
	currentTipSet *types.TipSet
	miner         address.Address

	// Subscriptions
	subMu          sync.RWMutex
	subscriptions  map[int64]*Subscription
	nextSubID      int64
	subscriberChan chan *api.HeadChange

	upgrader websocket.Upgrader
}

// NewServer creates a new mock RPC server
func NewServer() *Server {
	miner, _ := address.NewIDAddress(1000)

	return &Server{
		httpClient:     &http.Client{Timeout: 30 * time.Second},
		currentHeight:  0,
		miner:          miner,
		subscriptions:  make(map[int64]*Subscription),
		nextSubID:      1,
		subscriberChan: make(chan *api.HeadChange, 100),
		upgrader: websocket.Upgrader{
			ReadBufferSize:  1024,
			WriteBufferSize: 1024,
			CheckOrigin: func(r *http.Request) bool {
				return true // Allow all origins for local development
			},
		},
	}
}

func main() {
	server := NewServer()

	// Start background block watcher
	go server.watchBlocks()

	// Start subscription broadcaster
	go server.broadcastToSubscribers()

	http.HandleFunc("/rpc/v1", server.handleRPC)
	http.HandleFunc("/rpc/v0", server.handleRPC) // Also support v0
	http.HandleFunc("/", server.handleRPC)       // Also handle root for eth_* calls

	log.Printf("Mock Lotus RPC server starting on %s", listenAddr)
	log.Printf("Proxying eth_* calls to Anvil at %s", anvilAddr)
	log.Printf("WebSocket support enabled for ChainNotify subscriptions")

	if err := http.ListenAndServe(listenAddr, nil); err != nil {
		log.Fatalf("Failed to start server: %v", err)
	}
}

func (s *Server) handleRPC(w http.ResponseWriter, r *http.Request) {
	// Check if this is a WebSocket upgrade request
	if websocket.IsWebSocketUpgrade(r) {
		s.handleWebSocket(w, r)
		return
	}

	// Handle regular HTTP POST
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "Failed to read body", http.StatusBadRequest)
		return
	}
	defer r.Body.Close()

	// Try to parse as single request first
	var req JSONRPCRequest
	if err := json.Unmarshal(body, &req); err != nil {
		// Try as batch request
		var reqs []JSONRPCRequest
		if err := json.Unmarshal(body, &reqs); err != nil {
			http.Error(w, "Invalid JSON-RPC request", http.StatusBadRequest)
			return
		}
		// Handle batch
		responses := make([]JSONRPCResponse, len(reqs))
		for i, req := range reqs {
			responses[i] = s.handleRequest(r.Context(), req, nil)
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(responses)
		return
	}

	response := s.handleRequest(r.Context(), req, nil)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

func (s *Server) handleWebSocket(w http.ResponseWriter, r *http.Request) {
	conn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("WebSocket upgrade failed: %v", err)
		return
	}
	defer conn.Close()

	log.Printf("WebSocket connection established from %s", r.RemoteAddr)

	// Handle messages
	for {
		_, message, err := conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure) {
				log.Printf("WebSocket error: %v", err)
			}
			break
		}

		// Try to parse as single request
		var req JSONRPCRequest
		if err := json.Unmarshal(message, &req); err != nil {
			// Try as batch request
			var reqs []JSONRPCRequest
			if err := json.Unmarshal(message, &reqs); err != nil {
				s.sendWSError(conn, nil, -32700, "Parse error")
				continue
			}
			// Handle batch
			responses := make([]JSONRPCResponse, len(reqs))
			for i, req := range reqs {
				responses[i] = s.handleRequest(r.Context(), req, conn)
			}
			s.sendWSResponse(conn, responses)
			continue
		}

		response := s.handleRequest(r.Context(), req, conn)
		s.sendWSResponse(conn, response)
	}

	// Cleanup any subscriptions for this connection
	s.cleanupConnectionSubscriptions(conn)
	log.Printf("WebSocket connection closed from %s", r.RemoteAddr)
}

func (s *Server) sendWSResponse(conn *websocket.Conn, response interface{}) {
	data, err := json.Marshal(response)
	if err != nil {
		log.Printf("Failed to marshal response: %v", err)
		return
	}
	if err := conn.WriteMessage(websocket.TextMessage, data); err != nil {
		log.Printf("Failed to send response: %v", err)
	}
}

func (s *Server) sendWSError(conn *websocket.Conn, id json.RawMessage, code int, message string) {
	response := JSONRPCResponse{
		JSONRPC: "2.0",
		Error: &JSONRPCError{
			Code:    code,
			Message: message,
		},
		ID: id,
	}
	s.sendWSResponse(conn, response)
}

func (s *Server) handleRequest(ctx context.Context, req JSONRPCRequest, conn *websocket.Conn) JSONRPCResponse {
	// Check if this is a Filecoin method
	if strings.HasPrefix(req.Method, "Filecoin.") {
		return s.handleFilecoinMethod(ctx, req, conn)
	}

	// Proxy all other methods (eth_*, web3_*, net_*) to Anvil
	return s.proxyToAnvil(ctx, req)
}

func (s *Server) handleFilecoinMethod(ctx context.Context, req JSONRPCRequest, conn *websocket.Conn) JSONRPCResponse {
	switch req.Method {
	case "Filecoin.ChainHead":
		return s.handleChainHead(ctx, req)
	case "Filecoin.ChainNotify":
		return s.handleChainNotify(ctx, req, conn)
	case "Filecoin.StateGetRandomnessDigestFromBeacon":
		return s.handleStateGetRandomnessDigestFromBeacon(ctx, req)
	default:
		return JSONRPCResponse{
			JSONRPC: "2.0",
			Error: &JSONRPCError{
				Code:    -32601,
				Message: fmt.Sprintf("Method not found: %s", req.Method),
			},
			ID: req.ID,
		}
	}
}

func (s *Server) handleChainHead(ctx context.Context, req JSONRPCRequest) JSONRPCResponse {
	s.mu.RLock()
	ts := s.currentTipSet
	s.mu.RUnlock()

	if ts == nil {
		// If no tipset yet, create one from Anvil's current block
		blockNum, err := s.getAnvilBlockNumber(ctx)
		if err != nil {
			return JSONRPCResponse{
				JSONRPC: "2.0",
				Error: &JSONRPCError{
					Code:    -32000,
					Message: fmt.Sprintf("Failed to get block number: %v", err),
				},
				ID: req.ID,
			}
		}
		ts = s.createMockTipSet(blockNum, nil)
	}

	result, err := json.Marshal(ts)
	if err != nil {
		return JSONRPCResponse{
			JSONRPC: "2.0",
			Error: &JSONRPCError{
				Code:    -32000,
				Message: fmt.Sprintf("Failed to marshal tipset: %v", err),
			},
			ID: req.ID,
		}
	}

	return JSONRPCResponse{
		JSONRPC: "2.0",
		Result:  result,
		ID:      req.ID,
	}
}

func (s *Server) handleChainNotify(ctx context.Context, req JSONRPCRequest, conn *websocket.Conn) JSONRPCResponse {
	// If no WebSocket connection, return error (ChainNotify requires WebSocket)
	if conn == nil {
		return JSONRPCResponse{
			JSONRPC: "2.0",
			Error: &JSONRPCError{
				Code:    -32000,
				Message: "ChainNotify requires WebSocket connection",
			},
			ID: req.ID,
		}
	}

	// Create a new subscription
	subID := atomic.AddInt64(&s.nextSubID, 1)

	sub := &Subscription{
		id:       subID,
		conn:     conn,
		closeCh:  make(chan struct{}),
		lastSent: -1,
	}

	s.subMu.Lock()
	s.subscriptions[subID] = sub
	s.subMu.Unlock()

	log.Printf("Created ChainNotify subscription %d", subID)

	// Send the current head immediately as the first notification
	go s.sendInitialNotification(sub)

	// Return the subscription ID (go-jsonrpc protocol)
	result, _ := json.Marshal(subID)
	return JSONRPCResponse{
		JSONRPC: "2.0",
		Result:  result,
		ID:      req.ID,
	}
}

func (s *Server) sendInitialNotification(sub *Subscription) {
	// Small delay to ensure the subscription response is sent first
	time.Sleep(10 * time.Millisecond)

	s.mu.RLock()
	ts := s.currentTipSet
	height := s.currentHeight
	s.mu.RUnlock()

	if ts == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		blockNum, err := s.getAnvilBlockNumber(ctx)
		cancel()
		if err != nil {
			log.Printf("Failed to get block for initial notification: %v", err)
			return
		}
		ts = s.createMockTipSet(blockNum, nil)
		height = blockNum
	}

	changes := []*api.HeadChange{
		{
			Type: "current",
			Val:  ts,
		},
	}

	s.sendSubscriptionNotification(sub, changes)
	sub.mu.Lock()
	sub.lastSent = height
	sub.mu.Unlock()
}

// sendSubscriptionNotification sends a notification to a subscription using go-jsonrpc protocol
func (s *Server) sendSubscriptionNotification(sub *Subscription, changes []*api.HeadChange) {
	sub.mu.Lock()
	defer sub.mu.Unlock()

	if sub.closed {
		return
	}

	// go-jsonrpc expects this exact format for channel notifications:
	// {"jsonrpc":"2.0","method":"xrpc.ch.val","params":[<channelID>,<data>]}
	// The method must be exactly "xrpc.ch.val" (not with a suffix)
	// The params must be an array: [channelID, data]
	params, err := json.Marshal([]interface{}{sub.id, changes})
	if err != nil {
		log.Printf("Failed to marshal notification params: %v", err)
		return
	}

	notification := map[string]interface{}{
		"jsonrpc": "2.0",
		"method":  "xrpc.ch.val",
		"params":  json.RawMessage(params),
	}

	data, err := json.Marshal(notification)
	if err != nil {
		log.Printf("Failed to marshal notification: %v", err)
		return
	}

	if err := sub.conn.WriteMessage(websocket.TextMessage, data); err != nil {
		log.Printf("Failed to send notification to subscription %d: %v", sub.id, err)
		sub.closed = true
	}
}

func (s *Server) broadcastToSubscribers() {
	for change := range s.subscriberChan {
		changes := []*api.HeadChange{change}

		s.subMu.RLock()
		for _, sub := range s.subscriptions {
			s.sendSubscriptionNotification(sub, changes)
		}
		s.subMu.RUnlock()
	}
}

func (s *Server) cleanupConnectionSubscriptions(conn *websocket.Conn) {
	s.subMu.Lock()
	defer s.subMu.Unlock()

	for id, sub := range s.subscriptions {
		if sub.conn == conn {
			sub.mu.Lock()
			sub.closed = true
			close(sub.closeCh)
			sub.mu.Unlock()
			delete(s.subscriptions, id)
			log.Printf("Cleaned up subscription %d", id)
		}
	}
}

func (s *Server) handleStateGetRandomnessDigestFromBeacon(ctx context.Context, req JSONRPCRequest) JSONRPCResponse {
	// Parse the epoch from params
	var epoch abi.ChainEpoch
	if len(req.Params) > 0 {
		if err := json.Unmarshal(req.Params[0], &epoch); err != nil {
			return JSONRPCResponse{
				JSONRPC: "2.0",
				Error: &JSONRPCError{
					Code:    -32602,
					Message: fmt.Sprintf("Invalid epoch parameter: %v", err),
				},
				ID: req.ID,
			}
		}
	}

	// Generate deterministic randomness based on epoch
	// Same pattern as piri's FakeChainClient
	randomness := generateMockRandomness(epoch)

	result, err := json.Marshal(randomness)
	if err != nil {
		return JSONRPCResponse{
			JSONRPC: "2.0",
			Error: &JSONRPCError{
				Code:    -32000,
				Message: fmt.Sprintf("Failed to marshal randomness: %v", err),
			},
			ID: req.ID,
		}
	}

	return JSONRPCResponse{
		JSONRPC: "2.0",
		Result:  result,
		ID:      req.ID,
	}
}

func (s *Server) proxyToAnvil(ctx context.Context, req JSONRPCRequest) JSONRPCResponse {
	body, err := json.Marshal(req)
	if err != nil {
		return JSONRPCResponse{
			JSONRPC: "2.0",
			Error: &JSONRPCError{
				Code:    -32000,
				Message: fmt.Sprintf("Failed to marshal request: %v", err),
			},
			ID: req.ID,
		}
	}

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, anvilAddr, bytes.NewReader(body))
	if err != nil {
		return JSONRPCResponse{
			JSONRPC: "2.0",
			Error: &JSONRPCError{
				Code:    -32000,
				Message: fmt.Sprintf("Failed to create request: %v", err),
			},
			ID: req.ID,
		}
	}
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := s.httpClient.Do(httpReq)
	if err != nil {
		return JSONRPCResponse{
			JSONRPC: "2.0",
			Error: &JSONRPCError{
				Code:    -32000,
				Message: fmt.Sprintf("Failed to proxy to Anvil: %v", err),
			},
			ID: req.ID,
		}
	}
	defer resp.Body.Close()

	var response JSONRPCResponse
	if err := json.NewDecoder(resp.Body).Decode(&response); err != nil {
		return JSONRPCResponse{
			JSONRPC: "2.0",
			Error: &JSONRPCError{
				Code:    -32000,
				Message: fmt.Sprintf("Failed to decode Anvil response: %v", err),
			},
			ID: req.ID,
		}
	}

	return response
}

func (s *Server) getAnvilBlockNumber(ctx context.Context) (int64, error) {
	req := JSONRPCRequest{
		JSONRPC: "2.0",
		Method:  "eth_blockNumber",
		Params:  []json.RawMessage{},
		ID:      json.RawMessage(`1`),
	}

	resp := s.proxyToAnvil(ctx, req)
	if resp.Error != nil {
		return 0, fmt.Errorf("anvil error: %s", resp.Error.Message)
	}

	var hexNum string
	if err := json.Unmarshal(resp.Result, &hexNum); err != nil {
		return 0, fmt.Errorf("failed to unmarshal block number: %w", err)
	}

	// Remove 0x prefix and parse
	hexNum = strings.TrimPrefix(hexNum, "0x")
	num, err := strconv.ParseInt(hexNum, 16, 64)
	if err != nil {
		return 0, fmt.Errorf("failed to parse block number: %w", err)
	}

	return num, nil
}

// randomCID generates a deterministic CID from seed data
func randomCID(seed string) cid.Cid {
	h := sha256.Sum256([]byte(seed))
	c, _ := cid.Prefix{
		Version:  1,
		Codec:    cid.Raw,
		MhType:   mh.SHA2_256,
		MhLength: -1,
	}.Sum(h[:])
	return c
}

func (s *Server) createMockTipSet(blockNum int64, parent *types.TipSet) *types.TipSet {
	epoch := abi.ChainEpoch(blockNum)

	var parents []cid.Cid
	if parent != nil {
		parents = parent.Key().Cids()
	} else if blockNum > 0 {
		// Create a deterministic parent CID
		parents = []cid.Cid{randomCID(fmt.Sprintf("parent-%d", blockNum-1))}
	} else {
		// Genesis has no parent, use a dummy CID
		parents = []cid.Cid{randomCID("genesis-parent")}
	}

	header := &types.BlockHeader{
		Miner: s.miner,
		// Ticket must be non-nil: lotus >= 1.36 types.NewTipSet rejects blocks
		// with a nil Ticket ("block ... has nil Ticket"), which made the client's
		// xrpc.ch.val unmarshal fail and silently drop every ChainNotify head
		// change. The value is irrelevant to consumers (they only read Height).
		Ticket:                &types.Ticket{VRFProof: []byte(fmt.Sprintf("mock-ticket-%d", blockNum))},
		Height:                epoch,
		Timestamp:             uint64(time.Now().Unix()),
		Parents:               parents,
		ParentWeight:          big.NewInt(int64(blockNum)),
		ParentBaseFee:         abi.NewTokenAmount(100),
		ParentStateRoot:       randomCID(fmt.Sprintf("state-%d", blockNum)),
		ParentMessageReceipts: randomCID(fmt.Sprintf("receipts-%d", blockNum)),
		Messages:              randomCID(fmt.Sprintf("messages-%d", blockNum)),
	}

	ts, err := types.NewTipSet([]*types.BlockHeader{header})
	if err != nil {
		log.Printf("Warning: failed to create tipset: %v", err)
		return nil
	}

	return ts
}

func generateMockRandomness(epoch abi.ChainEpoch) abi.Randomness {
	// Match the Solidity contract: keccak256(abi.encode(epoch))
	// abi.encode(uint256) is just the 32-byte big-endian representation
	// See: localdev/contracts/DeterministicBeaconRandomness.sol
	epochBytes := make([]byte, 32)
	big.NewInt(int64(epoch)).FillBytes(epochBytes)

	hash := crypto.Keccak256(epochBytes)
	return abi.Randomness(hash)
}

func (s *Server) watchBlocks() {
	// Wait for initial connection
	time.Sleep(2 * time.Second)

	ticker := time.NewTicker(blockTime)
	defer ticker.Stop()

	log.Printf("Starting block watcher, polling every %v", blockTime)

	for range ticker.C {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		blockNum, err := s.getAnvilBlockNumber(ctx)
		cancel()

		if err != nil {
			log.Printf("Failed to get block number: %v", err)
			continue
		}

		s.mu.Lock()
		if blockNum > s.currentHeight || s.currentTipSet == nil {
			oldHeight := s.currentHeight
			oldTipSet := s.currentTipSet
			s.currentHeight = blockNum
			s.currentTipSet = s.createMockTipSet(blockNum, oldTipSet)

			if oldHeight != blockNum && s.currentTipSet != nil {
				log.Printf("Block advanced: %d -> %d (epoch %d)", oldHeight, blockNum, blockNum)

				// Notify subscribers of the new block
				s.subMu.RLock()
				for _, sub := range s.subscriptions {
					sub.mu.Lock()
					if !sub.closed && sub.lastSent < blockNum {
						changes := []*api.HeadChange{
							{
								Type: "apply",
								Val:  s.currentTipSet,
							},
						}
						sub.mu.Unlock()
						s.sendSubscriptionNotification(sub, changes)
						sub.mu.Lock()
						sub.lastSent = blockNum
					}
					sub.mu.Unlock()
				}
				s.subMu.RUnlock()
			}
		}
		s.mu.Unlock()
	}
}
