#!/usr/bin/env bash
# Reset only GitLab from its populated image; preserve other websites.
set -euo pipefail
SETUP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SETUP_DIR/00_vars.sh"
CONTAINER=gitlab
IMAGE=gitlab-populated-final-port8023:latest
BASE_URL="http://${PUBLIC_HOSTNAME}:${GITLAB_PORT}"
docker image inspect "$IMAGE" >/dev/null
if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    mounts="$(docker inspect "$CONTAINER" --format '{{len .Mounts}}')"
    if [[ "$mounts" != 0 ]]; then
        echo "Cannot reset GitLab with external mounts; restore those separately." >&2
        exit 1
    fi
fi
if [[ "${1:-}" == --check ]]; then
    echo "Reset ready: recreate $CONTAINER from $IMAGE at $BASE_URL"
    exit 0
elif [[ $# != 0 ]]; then
    echo "Usage: bash reset_gitlab.sh [--check]" >&2
    exit 2
fi
if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    docker stop "$CONTAINER"
    docker rm "$CONTAINER"
fi
# Patch before starting services so the image's original hostname is never used.
docker create --name "$CONTAINER" --shm-size=256m \
    -p "${GITLAB_PORT}:${GITLAB_PORT}" "$IMAGE" \
    /opt/gitlab/embedded/bin/runsvdir-start
config="$(mktemp /tmp/webarena_gitlab_config.XXXXXX.rb)"
trap 'rm -f -- "$config"' EXIT
docker cp "$CONTAINER:/etc/gitlab/gitlab.rb" "$config"
python3 - "$config" "$BASE_URL" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
s = p.read_text()
s = re.sub(r"(?m)^external_url\s+.*$", "# external_url supplied below", s)
s += "\nexternal_url " + repr(sys.argv[2]) + "\n"
# Two Puma workers keep GitLab usable on this laptop's 7 GB WSL budget.
# Avoid loading the bundled monitoring stack during local evaluation.
s += "\npuma['worker_processes'] = 2\nprometheus_monitoring['enable'] = false\n"
p.write_text(s)
PY
docker cp "$config" "$CONTAINER:/etc/gitlab/gitlab.rb"
docker start "$CONTAINER"
docker exec "$CONTAINER" gitlab-ctl reconfigure
for ((attempt=0; attempt<120; attempt++)); do
    code="$(curl -sS -o /dev/null --max-time 10 -w '%{http_code}' "${BASE_URL}/users/sign_in" || true)"
    if [[ "$code" == 200 ]]; then
        echo "GitLab reset complete: $BASE_URL"
        exit 0
    fi
    sleep 5
done
echo "GitLab is not ready; inspect: docker logs gitlab; docker exec gitlab gitlab-ctl status" >&2
exit 1
