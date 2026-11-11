#!/bin/bash
# smoke-test.sh - Start the localdev image and check that it deploys the
# contracts without compiling them.
#
# Usage: smoke-test.sh IMAGE [PLATFORM]
#
# The container runs without network access, so it cannot download anything,
# solc included. forge writes the artifacts of every compile to an out/
# directory, so after the deployment `docker diff` must show no changes there.
# forge also rewrites its build cache (solidity-files-cache.json) on runs that
# compile nothing, so the cache is no signal.

set -euo pipefail

IMAGE="${1:?Usage: smoke-test.sh IMAGE [PLATFORM]}"
PLATFORM="${2:-}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-1200}"
CONTAINER="localdev-smoke-test-$$"

platform_args=()
if [ -n "$PLATFORM" ]; then
    platform_args=(--platform "$PLATFORM")
fi

cleanup() {
    docker rm -f "$CONTAINER" > /dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
    echo "--- container logs ---"
    docker logs "$CONTAINER" 2>&1 || true
    echo "----------------------"
    echo "ERROR: $1"
    exit 1
}

echo "Starting $IMAGE${PLATFORM:+ ($PLATFORM)} without network access"
docker run -d --name "$CONTAINER" --network none \
    ${platform_args[@]+"${platform_args[@]}"} "$IMAGE" > /dev/null
started_at=$SECONDS

until docker exec "$CONTAINER" test -f /tmp/ready 2> /dev/null; do
    if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" != "true" ]; then
        fail "the container exited before it finished deploying the contracts"
    fi
    if (( SECONDS - started_at > TIMEOUT_SECONDS )); then
        fail "the container did not finish deploying within ${TIMEOUT_SECONDS}s"
    fi
    sleep 5
done
echo "Contracts deployed and mockrpc ready after $(( SECONDS - started_at ))s"

compiled=$(docker diff "$CONTAINER" | grep -E '^[AC] /app/service_contracts/(.*/)?out(/|$)' || true)
if [ -n "$compiled" ]; then
    echo "$compiled"
    fail "forge compiled contracts at container start; the image's build cache did not cover them"
fi
echo "OK: forge reused the image's build output"
