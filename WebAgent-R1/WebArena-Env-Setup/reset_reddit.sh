#!/usr/bin/env bash
# Recreate only Reddit's forum container from the populated image.
set -euo pipefail
SETUP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SETUP_DIR/00_vars.sh"
CONTAINER=forum
IMAGE=postmill-populated-exposed-withimg:latest
BASE_URL="http://${PUBLIC_HOSTNAME}:${REDDIT_PORT}"
docker image inspect "$IMAGE" >/dev/null
if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    mounts="$(docker inspect "$CONTAINER" --format '{{len .Mounts}}')"
    [[ "$mounts" == 0 ]] || { echo 'Cannot reset forum with external mounts.' >&2; exit 1; }
fi
if [[ "${1:-}" == --check ]]; then
    echo "Reset ready: recreate $CONTAINER from $IMAGE at $BASE_URL"
    exit 0
elif [[ $# != 0 ]]; then
    echo 'Usage: bash reset_reddit.sh [--check]' >&2; exit 2
fi
if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    docker stop "$CONTAINER"
    docker rm "$CONTAINER"
fi
docker run -d --name "$CONTAINER" -p "${REDDIT_PORT}:80" "$IMAGE"
for ((attempt=0; attempt<300; attempt++)); do
    code="$(curl -sS -L -c /dev/null --max-redirs 5 -o /dev/null --max-time 10 \
        -w '%{http_code}' "${BASE_URL}/login" || true)"
    if [[ "$code" == 200 ]]; then
        echo "Reddit reset complete: $BASE_URL"
        exit 0
    fi
    sleep 2
done
echo 'Reddit is not ready; inspect: docker logs forum' >&2
exit 1
