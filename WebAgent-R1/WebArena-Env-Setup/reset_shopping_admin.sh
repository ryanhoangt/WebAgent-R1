#!/usr/bin/env bash
# Shopping Admin-only equivalent of reset_server/reset.sh (which resets all sites).
# Discards the current container's changes; the original image is retained.
set -euo pipefail

SETUP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SETUP_DIR/00_vars.sh"
CONTAINER=shopping_admin
IMAGE=shopping_admin_final_0719:latest
BASE_URL="http://${PUBLIC_HOSTNAME}:${SHOPPING_ADMIN_PORT}/"

docker image inspect "$IMAGE" >/dev/null
if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    # Recreating a container cannot reset externally mounted data. Do not remove it.
    mounts="$(docker inspect "$CONTAINER" --format '{{len .Mounts}}')"
    if [[ "$mounts" != 0 ]]; then
        echo "Cannot reset $CONTAINER: it has external mounts. Restore those separately." >&2
        exit 1
    fi
fi
if [[ "${1:-}" == --check ]]; then
    echo "Reset ready: recreate $CONTAINER from $IMAGE at ${BASE_URL}admin"
    exit 0
elif [[ $# != 0 ]]; then
    echo "Usage: bash reset_shopping_admin.sh [--check]" >&2
    exit 2
fi

if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    docker stop "$CONTAINER"
    docker rm "$CONTAINER"
fi
docker run -d --name "$CONTAINER" -p "${SHOPPING_ADMIN_PORT}:80" "$IMAGE"

# Wait for MySQL, rather than assuming a fixed startup delay.
ready=false
for ((attempt=0; attempt<120; attempt++)); do
    if docker exec "$CONTAINER" mysql -u magentouser -pMyPassword magentodb \
        -e 'SELECT 1' >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 2
done
if [[ "$ready" != true ]]; then
    echo "MySQL did not become ready; inspect: docker logs $CONTAINER" >&2
    exit 1
fi

# Same Magento configuration steps as 05_docker_patch_containers.sh.
docker exec "$CONTAINER" php /var/www/magento2/bin/magento \
    setup:store-config:set --base-url="$BASE_URL"
docker exec "$CONTAINER" mysql -u magentouser -pMyPassword magentodb \
    -e "UPDATE core_config_data SET value='${BASE_URL}' WHERE path IN ('web/unsecure/base_url','web/secure/base_url');"
docker exec "$CONTAINER" php /var/www/magento2/bin/magento \
    config:set admin/security/password_is_forced 0
docker exec "$CONTAINER" php /var/www/magento2/bin/magento \
    config:set admin/security/password_lifetime 0
docker exec "$CONTAINER" php /var/www/magento2/bin/magento cache:flush

for ((attempt=0; attempt<60; attempt++)); do
    code="$(curl -sS -L -o /dev/null --max-redirs 5 --max-time 10 \
        -w '%{http_code}' "${BASE_URL}admin" || true)"
    if [[ "$code" == 200 ]]; then
        echo "Shopping Admin reset complete: ${BASE_URL}admin"
        exit 0
    fi
    sleep 2
done
echo "Shopping Admin did not become ready at ${BASE_URL}admin" >&2
exit 1
