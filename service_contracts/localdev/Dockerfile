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
FROM ghcr.io/foundry-rs/foundry:stable

USER root

# Install additional tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    jq \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy contract sources for deployment
COPY . /app/service_contracts/

# Build contracts
WORKDIR /app/service_contracts
RUN forge build

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
