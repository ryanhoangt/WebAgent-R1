#!/usr/bin/env bash
set -euo pipefail
export EVAL_SITE=map
exec bash "$(dirname -- "${BASH_SOURCE[0]}")/eval_site.sh" "$@"
