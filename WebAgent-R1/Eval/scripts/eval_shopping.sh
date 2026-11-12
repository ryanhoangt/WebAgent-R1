#!/usr/bin/env bash
# Shopping customer site only; common reset/retry/resume runner.
set -euo pipefail
export EVAL_SITE=shopping
exec bash "$(dirname -- "${BASH_SOURCE[0]}")/eval_site.sh" "$@"
