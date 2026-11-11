# The service contracts need solc 0.8.37, which Foundry supports from v1.7.
# The contracts stage and the runtime stage must use the same Foundry, or forge
# at runtime will not trust the build cache and compiles again.
ARG FOUNDRY_IMAGE=ghcr.io/foundry-rs/foundry:v1.7.1

# A multi-platform build emulates every RUN step of a foreign platform, which
# makes compiling slow. The two build stages below run on the build machine's
# own platform instead. Their output (a Go binary built for the target, and
# compiled contracts, which are the same on every platform) is copied into the
# runtime stage.

# ============================================
# Stage 1: Build Mock RPC Server
# ============================================
FROM --platform=$BUILDPLATFORM golang:1.24-bookworm AS go-builder

ARG TARGETOS
ARG TARGETARCH

WORKDIR /build

# Copy go module files
COPY localdev/mockrpc/go.mod localdev/mockrpc/go.sum* ./

# Download dependencies
RUN go mod download || true

# Copy source code
COPY localdev/mockrpc/*.go ./

# Build the binary for the target platform
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -o mockrpc .

# ============================================
# Stage 2: Build Contracts
# ============================================
FROM --platform=$BUILDPLATFORM ${FOUNDRY_IMAGE} AS contracts-builder

USER root

# The build tools and libcurl build the evm assembler. make erc8167 uses jq.
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

# Copy contract sources. The runtime stage keeps the same path, because the
# build cache records it.
COPY . /app/service_contracts/

# Build contracts. PDPVerifier builds with its own foundry.toml. The root build
# covers src, test and script; deploy-local.sh also deploys the contracts in
# localdev/contracts, so build those too.
WORKDIR /app/service_contracts/lib/pdp
RUN forge build --skip test --skip script
WORKDIR /app/service_contracts
RUN make erc8167 && forge build && forge build localdev/contracts/*.sol

# ============================================
# Stage 3: Runtime - Deploy contracts on startup
# ============================================
FROM ${FOUNDRY_IMAGE}

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    jq \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=contracts-builder /app/service_contracts /app/service_contracts

# deploy-local.sh runs forge create and forge script at container start, and
# forge compiles any target its build cache does not cover. Run the same
# compiles here with this platform's forge and fail the build unless forge
# skips them all. This also installs solc for this platform, so a container
# that has to compile can still do it without network access.
WORKDIR /app/service_contracts
RUN expect_no_compile() { \
      output=$(forge build "$@") || { echo "$output"; return 1; }; \
      echo "$output"; \
      case "$output" in \
        *"No files changed, compilation skipped"*) ;; \
        *) echo "ERROR: forge in $PWD compiled contracts the contracts-builder stage had already built"; return 1 ;; \
      esac; \
    }; \
    (cd lib/pdp && expect_no_compile --skip test --skip script) \
 && expect_no_compile \
 && expect_no_compile localdev/contracts/*.sol

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
