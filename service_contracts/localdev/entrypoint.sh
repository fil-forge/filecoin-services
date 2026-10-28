#!/bin/bash
set -e

echo "=========================================="
echo "Filecoin Local Development Environment"
echo "=========================================="
echo

# ===========================================
# Configuration
# ===========================================
ANVIL_PORT="${ANVIL_PORT:-8546}"
RPC_PORT="${RPC_PORT:-8545}"
ANVIL_BLOCK_TIME="${ANVIL_BLOCK_TIME:-3}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"

STATE_FILE_INPUT="/app/anvil-state.json"      # load-mode input (bind-mount target)
STATE_FILE_DUMP="/tmp/anvil-state.json"       # anvil's --dump-state target
ADDRESSES_FILE="/deployed-addresses.json"     # deploy-local.sh writes here
READY_SENTINEL="/tmp/ready"                   # healthcheck target

# ===========================================
# Mode resolution
# ===========================================
# MODE=init  : deploy contracts, run mockrpc, dump state on SIGTERM
# MODE=load  : load state file, run mockrpc, no dump on exit
# MODE unset : autodetect — load if state file present, else init
if [ -z "${MODE:-}" ]; then
    if [ -f "$STATE_FILE_INPUT" ]; then
        MODE="load"
    else
        MODE="init"
    fi
    echo "MODE not set, autodetected: $MODE"
fi

case "$MODE" in
    init|load) ;;
    *)
        echo "ERROR: MODE must be 'init' or 'load' (got: $MODE)"
        exit 1
        ;;
esac

echo "Mode:             $MODE"
echo "Block mining:     every ${ANVIL_BLOCK_TIME}s"
echo "Anvil port:       $ANVIL_PORT (internal)"
echo "RPC port:         $RPC_PORT (external)"
if [ "$MODE" = "init" ]; then
    echo "Output directory: $OUTPUT_DIR (state files written here on graceful shutdown)"
fi
echo

# ===========================================
# Shared helpers
# ===========================================
wait_for_anvil() {
    echo "Waiting for Anvil to be ready..."
    for i in {1..30}; do
        if cast chain-id --rpc-url "http://localhost:$ANVIL_PORT" > /dev/null 2>&1; then
            echo "Anvil is ready!"
            return 0
        fi
        sleep 0.5
    done
    echo "ERROR: Anvil failed to start within 15 seconds"
    return 1
}

wait_for_mockrpc() {
    echo "Waiting for mockrpc to be ready..."
    for i in {1..20}; do
        if curl -sf "http://localhost:$RPC_PORT" \
            -X POST -H "Content-Type: application/json" \
            -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
            > /dev/null 2>&1; then
            echo "mockrpc is ready!"
            return 0
        fi
        sleep 0.25
    done
    echo "ERROR: mockrpc failed to start within 5 seconds"
    return 1
}

# ===========================================
# INIT MODE: deploy + stay alive + dump on SIGTERM
# ===========================================
if [ "$MODE" = "init" ]; then
    # Deploy-in-progress guard: if SIGTERM arrives while deploy-local.sh is
    # running we must refuse to dump, otherwise we'd snapshot a half-deployed
    # chain. Smelt is responsible for only stopping the container after it has
    # observed registration completion, so arriving here early is genuinely
    # a misuse and the non-zero exit is the right signal.
    DEPLOY_IN_PROGRESS=1
    ANVIL_PID=""
    MOCKRPC_PID=""
    DEPLOY_PID=""

    init_cleanup() {
        trap - TERM INT EXIT  # prevent recursion

        if [ "$DEPLOY_IN_PROGRESS" = "1" ]; then
            echo
            echo "ERROR: Received SIGTERM during contract deployment — refusing to dump partial state."
            echo "       Only send SIGTERM after external services have finished registering."
            # deploy-local.sh runs in the background (so this trap can fire
            # during a foreground forge/cast child); tear it down explicitly.
            if [ -n "$DEPLOY_PID" ] && kill -0 "$DEPLOY_PID" 2>/dev/null; then
                kill -TERM "$DEPLOY_PID" 2>/dev/null || true
                wait "$DEPLOY_PID" 2>/dev/null || true
            fi
            [ -n "$ANVIL_PID" ] && kill -KILL "$ANVIL_PID" 2>/dev/null || true
            exit 1
        fi

        echo
        echo "=========================================="
        echo "Graceful shutdown: dumping state"
        echo "=========================================="

        # Order matters: stop mockrpc first so no new registration txs sneak
        # in after we've decided to snapshot, then stop anvil to trigger the
        # --dump-state flush.
        if [ -n "$MOCKRPC_PID" ] && kill -0 "$MOCKRPC_PID" 2>/dev/null; then
            echo "Stopping mockrpc..."
            kill -TERM "$MOCKRPC_PID" 2>/dev/null || true
            wait "$MOCKRPC_PID" 2>/dev/null || true
        fi

        if [ -n "$ANVIL_PID" ] && kill -0 "$ANVIL_PID" 2>/dev/null; then
            echo "Stopping anvil..."
            kill -TERM "$ANVIL_PID" 2>/dev/null || true
            wait "$ANVIL_PID" 2>/dev/null || true
        fi

        # Small fs sync window: anvil has just written --dump-state during
        # its exit handler.
        sleep 1

        if [ ! -f "$STATE_FILE_DUMP" ]; then
            echo "ERROR: anvil did not produce $STATE_FILE_DUMP on shutdown"
            exit 1
        fi

        if [ ! -d "$OUTPUT_DIR" ]; then
            mkdir -p "$OUTPUT_DIR" || {
                echo "ERROR: cannot create OUTPUT_DIR=$OUTPUT_DIR (is it mounted?)"
                exit 1
            }
        fi

        # Atomic writes: cp to .tmp then mv. Prevents autodetect on a later
        # boot from seeing a half-written state file and flipping to load mode.
        cp "$STATE_FILE_DUMP" "$OUTPUT_DIR/anvil-state.json.tmp"
        mv "$OUTPUT_DIR/anvil-state.json.tmp" "$OUTPUT_DIR/anvil-state.json"
        cp "$ADDRESSES_FILE" "$OUTPUT_DIR/deployed-addresses.json.tmp"
        mv "$OUTPUT_DIR/deployed-addresses.json.tmp" "$OUTPUT_DIR/deployed-addresses.json"
        chmod 0644 "$OUTPUT_DIR/anvil-state.json" "$OUTPUT_DIR/deployed-addresses.json"

        echo "State dumped to $OUTPUT_DIR/anvil-state.json"
        echo "Addresses dumped to $OUTPUT_DIR/deployed-addresses.json"
        ls -lh "$OUTPUT_DIR/anvil-state.json" "$OUTPUT_DIR/deployed-addresses.json"

        echo
        echo "=========================================="
        echo "State Export Complete!"
        echo "=========================================="
        exit 0
    }

    trap init_cleanup TERM INT

    # Ensure OUTPUT_DIR is writable now, not only at shutdown, so we fail
    # fast rather than after minutes of registration activity.
    if [ ! -d "$OUTPUT_DIR" ]; then
        mkdir -p "$OUTPUT_DIR" || {
            echo "ERROR: OUTPUT_DIR=$OUTPUT_DIR does not exist and cannot be created"
            exit 1
        }
    fi

    echo "=========================================="
    echo "Starting fresh Anvil (init mode)"
    echo "=========================================="
    echo

    anvil --host 0.0.0.0 --port "$ANVIL_PORT" --dump-state "$STATE_FILE_DUMP" \
          --block-time "$ANVIL_BLOCK_TIME" --silent &
    ANVIL_PID=$!

    wait_for_anvil

    echo
    echo "=========================================="
    echo "Deploying Contracts"
    echo "=========================================="
    echo

    # Run deploy in background so the SIGTERM trap can fire during a forge
    # subprocess. Foreground would block the trap until forge returns,
    # letting docker's grace timeout expire and SIGKILL the container.
    ANVIL_RPC="http://localhost:$ANVIL_PORT" OUTPUT_FILE="$ADDRESSES_FILE" \
        /app/service_contracts/localdev/scripts/deploy-local.sh &
    DEPLOY_PID=$!
    # `wait` is interruptible — a trap fires immediately on SIGTERM arrival.
    # set -e with `|| ...` preserves the child exit code for the failure path.
    if ! wait "$DEPLOY_PID"; then
        deploy_exit=$?
        echo "ERROR: deploy-local.sh failed with exit $deploy_exit"
        exit "$deploy_exit"
    fi
    DEPLOY_PID=""

    DEPLOY_IN_PROGRESS=0

    echo
    echo "=========================================="
    echo "Starting Mock Lotus RPC Server"
    echo "=========================================="
    echo

    export LISTEN_ADDR=":$RPC_PORT"
    export ANVIL_ADDR="http://localhost:$ANVIL_PORT"
    /app/mockrpc/mockrpc &
    MOCKRPC_PID=$!

    wait_for_mockrpc

    touch "$READY_SENTINEL"

    echo
    echo "=========================================="
    echo "Local Environment Ready!"
    echo "=========================================="
    echo
    echo "Connect your application to:"
    echo "  RPC URL:  http://localhost:$RPC_PORT"
    echo "  Chain ID: 31337"
    echo
    echo "Contract addresses: cat $ADDRESSES_FILE"
    echo
    echo "Send SIGTERM (e.g. 'docker stop') to dump state to $OUTPUT_DIR"
    echo

    # Block until a signal arrives or a child exits unexpectedly. A child
    # crash propagates non-zero through set -e and bypasses the trap's dump
    # path — which is correct: we should not snapshot a degraded chain.
    wait "$ANVIL_PID" "$MOCKRPC_PID"
    exit $?
fi

# ===========================================
# LOAD MODE: restore state + stay alive
# ===========================================
if [ "$MODE" = "load" ]; then
    if [ ! -f "$STATE_FILE_INPUT" ]; then
        echo "ERROR: MODE=load but $STATE_FILE_INPUT not found"
        echo "       Mount a state file at $STATE_FILE_INPUT (e.g. via -v)"
        exit 1
    fi

    echo "=========================================="
    echo "Loading pre-existing state"
    echo "=========================================="
    echo "State file: $STATE_FILE_INPUT"
    echo

    # --dump-state lets smelt (or any orchestrator) capture the current
    # in-memory chain state on graceful shutdown. Anvil writes the dump file
    # during its own SIGTERM handler; we then copy it to OUTPUT_DIR if the
    # caller mounted one. When OUTPUT_DIR isn't mounted the dump just sits in
    # /tmp and is garbage-collected with the container.
    anvil --host 0.0.0.0 --port "$ANVIL_PORT" --load-state "$STATE_FILE_INPUT" \
          --dump-state "$STATE_FILE_DUMP" \
          --block-time "$ANVIL_BLOCK_TIME" --silent &
    ANVIL_PID=$!

    wait_for_anvil

    echo
    echo "=========================================="
    echo "Starting Mock Lotus RPC Server"
    echo "=========================================="
    echo

    export LISTEN_ADDR=":$RPC_PORT"
    export ANVIL_ADDR="http://localhost:$ANVIL_PORT"
    /app/mockrpc/mockrpc &
    MOCKRPC_PID=$!

    wait_for_mockrpc

    touch "$READY_SENTINEL"

    echo
    echo "=========================================="
    echo "Local Environment Ready!"
    echo "=========================================="
    echo
    echo "Connect your application to:"
    echo "  RPC URL:  http://localhost:$RPC_PORT"
    echo "  Chain ID: 31337"
    echo

    load_cleanup() {
        trap - TERM INT EXIT

        # Mirror init-mode shutdown order: mockrpc first (stop traffic), then
        # anvil (triggers --dump-state flush).
        if [ -n "$MOCKRPC_PID" ] && kill -0 "$MOCKRPC_PID" 2>/dev/null; then
            kill -TERM "$MOCKRPC_PID" 2>/dev/null || true
            wait "$MOCKRPC_PID" 2>/dev/null || true
        fi
        if [ -n "$ANVIL_PID" ] && kill -0 "$ANVIL_PID" 2>/dev/null; then
            kill -TERM "$ANVIL_PID" 2>/dev/null || true
            wait "$ANVIL_PID" 2>/dev/null || true
        fi
        sleep 1  # fs sync after anvil exits

        # Opt-in dump: when the caller bind-mounts a writable OUTPUT_DIR we
        # persist the current state there so they can snapshot it. Silent no-op
        # otherwise — users running the image for normal load-and-serve don't
        # pay for a stray write.
        if [ -f "$STATE_FILE_DUMP" ] && [ -d "$OUTPUT_DIR" ] && [ -w "$OUTPUT_DIR" ]; then
            cp "$STATE_FILE_DUMP" "$OUTPUT_DIR/anvil-state.json.tmp"
            mv "$OUTPUT_DIR/anvil-state.json.tmp" "$OUTPUT_DIR/anvil-state.json"
            if [ -f "$ADDRESSES_FILE" ]; then
                cp "$ADDRESSES_FILE" "$OUTPUT_DIR/deployed-addresses.json.tmp"
                mv "$OUTPUT_DIR/deployed-addresses.json.tmp" "$OUTPUT_DIR/deployed-addresses.json"
            fi
            chmod 0644 "$OUTPUT_DIR/anvil-state.json" 2>/dev/null || true
            [ -f "$OUTPUT_DIR/deployed-addresses.json" ] && \
                chmod 0644 "$OUTPUT_DIR/deployed-addresses.json" 2>/dev/null || true
            echo "Load-mode dump: state copied to $OUTPUT_DIR"
        fi

        exit 0
    }
    trap load_cleanup TERM INT

    wait "$ANVIL_PID" "$MOCKRPC_PID"
    exit $?
fi
