#!/usr/bin/env bash
# Reddit-only subset; use the common reset/retry/resume runner.
set -euo pipefail
export EVAL_SITE=reddit
exec bash "$(dirname -- "${BASH_SOURCE[0]}")/eval_site.sh" "$@"
