#!/usr/bin/env bash
# Own only the isolated webarena-map Compose project. Never reset other sites.
set -euo pipefail
SETUP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SETUP_DIR/00_vars.sh"
if [[ -f "${MAP_CONFIG_FILE:-$SETUP_DIR/map.env}" ]]; then
    set -a
    source "${MAP_CONFIG_FILE:-$SETUP_DIR/map.env}"
    set +a
fi
export MAP_PORT PUBLIC_HOSTNAME
case "${1:-}" in
    --prepare|--check|'') ;;
    *) echo 'Usage: bash reset_map.sh [--prepare|--check]' >&2; exit 2 ;;
esac
RUNTIME_DIR="$SETUP_DIR/../../.cache/webarena-map"
export MAP_RUNTIME_DIR="$RUNTIME_DIR"
python3 "$SETUP_DIR/prepare_map.py"
COMPOSE=(docker compose -p webarena-map -f "$RUNTIME_DIR/compose.json")
if [[ "${1:-}" == --prepare ]]; then
    echo "Prepared Map configuration only: $RUNTIME_DIR"
    exit 0
fi
docker image inspect openstreetmap-website-web:latest openstreetmap-website-db:latest >/dev/null
for container in map map_db; do
    if docker container inspect "$container" >/dev/null 2>&1; then
        project="$(docker inspect "$container" --format '{{index .Config.Labels "com.docker.compose.project"}}')"
        [[ "$project" == webarena-map ]] || { echo "Refusing to replace unmanaged $container" >&2; exit 1; }
    fi
done
"${COMPOSE[@]}" config --quiet
if [[ "${1:-}" == --check ]]; then
    echo 'Map images and Compose configuration ready; no containers changed.'
    exit 0
fi
# All database/cache volumes here are owned by this isolated project.
"${COMPOSE[@]}" down --volumes
"${COMPOSE[@]}" up -d --no-build --pull never
ready=false
for ((attempt=0; attempt<90; attempt++)); do
    if docker exec map_db pg_isready -U postgres -d openstreetmap >/dev/null 2>&1; then
        ready=true; break
    fi
    sleep 2
done
[[ "$ready" == true ]] || { echo 'Map database is not ready.' >&2; exit 1; }
docker exec map env RAILS_ENV=development bin/rails db:migrate
for ((attempt=0; attempt<90; attempt++)); do
    code="$(curl -sS -o /dev/null --max-time 10 -w '%{http_code}' "http://${PUBLIC_HOSTNAME}:${MAP_PORT}/" || true)"
    if [[ "$code" == 200 ]]; then
        echo "Map reset complete: http://${PUBLIC_HOSTNAME}:${MAP_PORT}/"
        echo 'Verify search and car/bike/foot routing in a browser before evaluating.'
        exit 0
    fi
    sleep 2
done
echo 'Map is not ready; inspect: docker logs map' >&2
exit 1
