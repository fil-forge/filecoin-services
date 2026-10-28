# ============================================
# Stage 1: Build Mock RPC Server
# ============================================
FROM golang:1.24-bookworm AS go-builder

WORKDIR /build

# Copy go module files
COPY localdev/mockrpc/go.mod localdev/mockrpc/go.sum* ./

# Download dependencies
RUN go mod download || true

# Copy source code
COPY localdev/mockrpc/*.go ./

# Build the binary
RUN CGO_ENABLED=0 go build -o mockrpc .

# ============================================
# Stage 2: Runtime - Deploy contracts on startup
# ============================================
# The service contracts need solc 0.8.37, which Foundry supports from v1.7.
FROM ghcr.io/foundry-rs/foundry:v1.7.1

USER root

# Install additional tools. The build tools and libcurl build the evm assembler.
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    jq \
    curl \
    ca-certificates \
    build-essential autoconf automake libtool pkg-config libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

# The evm assembler builds the ERC-8167 dispatcher FWSS runs on, at the
# revision service_contracts/Makefile pins (EVM_REVISION). This image's git
# predates `clone --revision`, so fetch the commit directly.
COPY Makefile /tmp/service_contracts.Makefile
RUN EVM_REVISION=$(sed -n 's/^EVM_REVISION := //p' /tmp/service_contracts.Makefile) \
 && test -n "$EVM_REVISION" \
 && git init -q /opt/evm && cd /opt/evm \
 && git remote add origin https://github.com/wjmelements/evm.git \
 && git fetch -q --depth 1 origin "$EVM_REVISION" && git checkout -q FETCH_HEAD \
 && git submodule update -q --init --recursive --depth 1 \
 && make bin/evm && install bin/evm /usr/local/bin/evm \
 && cd / && rm -rf /opt/evm /tmp/service_contracts.Makefile

WORKDIR /app

# Copy contract sources for deployment
COPY . /app/service_contracts/

# Build contracts. PDPVerifier builds with its own foundry.toml.
WORKDIR /app/service_contracts/lib/pdp
RUN forge build --skip test --skip script
WORKDIR /app/service_contracts
RUN make erc8167 && forge build

# Make scripts executable
RUN chmod +x /app/service_contracts/localdev/scripts/*.sh

WORKDIR /app

# Copy the mock RPC server binary
COPY --from=go-builder /build/mockrpc /app/mockrpc/mockrpc

# Copy entrypoint script
COPY localdev/entrypoint.sh /app/localdev/entrypoint.sh
RUN chmod +x /app/localdev/entrypoint.sh

# Expose RPC port
EXPOSE 8545

# Set entrypoint
ENTRYPOINT ["/app/localdev/entrypoint.sh"]
