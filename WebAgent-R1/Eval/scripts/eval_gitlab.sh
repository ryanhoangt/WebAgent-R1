#!/usr/bin/env bash
# Site-specific entry point; shared batch logic preserves reset/resume behavior.
set -euo pipefail
export EVAL_SITE=gitlab
exec bash "$(dirname -- "${BASH_SOURCE[0]}")/eval_site.sh" "$@"
