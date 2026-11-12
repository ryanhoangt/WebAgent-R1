#!/usr/bin/env bash
# Run one local WebArena-Lite task using a remote OpenAI-compatible model.
set -euo pipefail

EVAL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$EVAL_DIR/.env" ]]; then
    set -a
    source "$EVAL_DIR/.env"
    set +a
fi
PYTHON_BIN="${PYTHON_BIN:-${EVAL_DIR}/../../.venv/bin/python}"
if [[ "${EVAL_SITE:-}" == map ]]; then
    MAP_ENV="${MAP_CONFIG_FILE:-$EVAL_DIR/../WebArena-Env-Setup/map.env}"
    if [[ -f "$MAP_ENV" ]]; then
        set -a
        source "$MAP_ENV"
        set +a
    fi
    export WEB_ARENA_BROWSER_ARGS="$("$PYTHON_BIN" - <<'PY'
import ipaddress,json,os
overrides=json.loads(os.environ.get('MAP_DNS_OVERRIDES','{}'))
rules=[]
for host,ip in overrides.items():
    if host not in {'tile.openstreetmap.org','nominatim.openstreetmap.org'}:
        raise SystemExit('Unexpected Map DNS hostname')
    ipaddress.ip_address(ip)
    rules.append(f'MAP {host} {ip}')
args=json.loads(os.environ.get('WEB_ARENA_BROWSER_ARGS','[]'))
if rules: args.append('--host-resolver-rules='+', '.join(rules))
print(json.dumps(args))
PY
)"
fi
export PATH="$(dirname -- "$PYTHON_BIN"):$PATH"
export PYTHONPATH="${EVAL_DIR}${PYTHONPATH:+:$PYTHONPATH}"
export DATASET=webarena
export SHOPPING="${SHOPPING:-http://localhost:8082}"
export SHOPPING_ADMIN="${SHOPPING_ADMIN:-http://localhost:8083/admin}"
export REDDIT="${REDDIT:-http://localhost:8080}"
export GITLAB="${GITLAB:-http://localhost:9001}"
export MAP="${MAP:-http://localhost:9003}"
export WIKIPEDIA="${WIKIPEDIA:-http://localhost:8087/wikipedia_en_all_maxi_2022-05/A/User:The_other_Kiwix_guy/Landing}"
export HOMEPAGE="${HOMEPAGE:-http://localhost:8077}"
export OPENAI_API_URL="${OPENAI_API_URL:-https://desired-more-vulture.ngrok-free.app/v1}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-EMPTY}"
export LLM_MAX_RETRIES="${LLM_MAX_RETRIES:-20}"
export LLM_RETRY_INITIAL_DELAY="${LLM_RETRY_INITIAL_DELAY:-30}"
export LLM_RETRY_MAX_DELAY="${LLM_RETRY_MAX_DELAY:-120}"
export LLM_RETRY_WINDOW="${LLM_RETRY_WINDOW:-1800}"
export LLM_STREAM="${LLM_STREAM:-true}"
# Keep the original non-thinking profile by default. THINKING=true overrides only
# the native thinking switch, preserving any other chat-template options.
profile="$("$PYTHON_BIN" - <<'PY'
import json, os
options = json.loads(os.environ.get('OPENAI_CHAT_TEMPLATE_KWARGS') or '{"enable_thinking":false}')
if not isinstance(options, dict):
    raise SystemExit('OPENAI_CHAT_TEMPLATE_KWARGS must be a JSON object')
if 'THINKING' in os.environ:
    value = os.environ['THINKING'].lower()
    if value not in {'true', 'false', '1', '0'}:
        raise SystemExit('THINKING must be true/false or 1/0')
    options['enable_thinking'] = value in {'true', '1'}
enabled = options.get('enable_thinking', True)  # Qwen native default
if not isinstance(enabled, bool):
    raise SystemExit('enable_thinking must be a JSON boolean')
print(('thinking' if enabled else 'nonthinking') + '\t' + json.dumps(options))
PY
)"
IFS=$'\t' read -r THINKING_MODE OPENAI_CHAT_TEMPLATE_KWARGS <<< "$profile"
export OPENAI_CHAT_TEMPLATE_KWARGS
if [[ "$THINKING_MODE" == thinking ]]; then
    DEFAULT_MAX_TOKENS=8192
    DEFAULT_REQUEST_TIMEOUT=600
else
    DEFAULT_MAX_TOKENS=2048
    DEFAULT_REQUEST_TIMEOUT=180
fi
export LLM_REQUEST_TIMEOUT="${LLM_REQUEST_TIMEOUT:-$DEFAULT_REQUEST_TIMEOUT}"
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-${EVAL_DIR}/../../.cache/ms-playwright}"
export NLTK_DATA="${NLTK_DATA:-${EVAL_DIR}/../../.cache/nltk_data}"
export MPLCONFIGDIR="${MPLCONFIGDIR:-${EVAL_DIR}/../../.cache/matplotlib}"
export HF_HOME="${HF_HOME:-${EVAL_DIR}/../../.cache/huggingface}"
LOCAL_BROWSER_LIBS="${EVAL_DIR}/../../.cache/browser-libs/root/usr/lib/x86_64-linux-gnu"
if [[ -d "$LOCAL_BROWSER_LIBS" ]]; then
    export LD_LIBRARY_PATH="${LOCAL_BROWSER_LIBS}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
TASK_ID="${TASK_ID:-0}"
RESULT_DIR="${RESULT_DIR:-eval_results/qwen35_9b_task${TASK_ID}_${THINKING_MODE}_$(date +%Y%m%d_%H%M%S)}"

cd -- "$EVAL_DIR"
run_args=(
    --instruction_path agent/prompts/jsons/p_webrl_chat_think.json
    --test_config_base_dir config_files/wa/test_webarena_lite
    --test_start_idx "$TASK_ID"
    --test_end_idx "$((TASK_ID + 1))"
    --result_dir "$RESULT_DIR"
    --provider openai
    --model "${MODEL:-Qwen/Qwen3.5-9B}"
    --mode chat
    --planner_ip "$OPENAI_API_URL"
    --temperature "${TEMPERATURE:-0}"
    --top_p "${TOP_P:-0.9}"
    --max_tokens "${MAX_TOKENS:-$DEFAULT_MAX_TOKENS}"
    --max_steps 30
    --max_obs_length 0
    --viewport_width 1280
    --viewport_height 720
    --parsing_failure_th 5
    --repeating_action_failure_th 5
    --action_set_tag webrl_id
    --observation_type webrl
)

run_metadata() {
    "$PYTHON_BIN" - "${run_args[@]}" "$@" <<'PY'
import argparse, json, math, os
parser = argparse.ArgumentParser(add_help=False, allow_abbrev=False)
fields = {
    'model': str, 'planner_ip': str, 'temperature': float, 'top_p': float,
    'max_tokens': int, 'max_steps': int, 'max_obs_length': int,
    'viewport_width': int, 'viewport_height': int,
    'instruction_path': str, 'observation_type': str, 'action_set_tag': str,
    'parsing_failure_th': int, 'repeating_action_failure_th': int,
}
for name, kind in fields.items():
    parser.add_argument('--' + name, type=kind)
args, _ = parser.parse_known_args()
options = json.loads(os.environ['OPENAI_CHAT_TEMPLATE_KWARGS'])
timeout = float(os.environ['LLM_REQUEST_TIMEOUT'])
retries = int(os.environ['LLM_MAX_RETRIES'])
initial_delay = float(os.environ['LLM_RETRY_INITIAL_DELAY'])
max_delay = float(os.environ['LLM_RETRY_MAX_DELAY'])
retry_window = float(os.environ['LLM_RETRY_WINDOW'])
stream_value = os.environ['LLM_STREAM'].lower()
if stream_value not in {'true', 'false', '1', '0'}:
    raise SystemExit('LLM_STREAM must be true/false or 1/0')
if retries < 0 or any(not math.isfinite(v) or v <= 0 for v in (timeout, initial_delay, max_delay, retry_window)):
    raise SystemExit('LLM timeout/delays/window must be positive and finite; LLM_MAX_RETRIES non-negative')
metadata = {
    'browser': {'args': json.loads(os.environ.get('WEB_ARENA_BROWSER_ARGS', '[]'))},
    'run_mode': 'thinking' if options.get('enable_thinking', True) else 'nonthinking',
    'agent': {'model': args.model, 'base_url': args.planner_ip, 'chat_template_kwargs': options},
    'inference': {name: getattr(args, name) for name in fields if name not in {'model', 'planner_ip'}},
    'judge': {'model': os.environ.get('EVAL_JUDGE_MODEL', 'gpt-4-1106-preview'),
              'base_url': os.environ.get('EVAL_JUDGE_API_URL', os.environ['OPENAI_API_URL'])},
    'request_policy': {'stream': stream_value in {'true', '1'},
                       'timeout_seconds': timeout, 'max_retries': retries, 'sdk_max_retries': 0,
                       'initial_delay_seconds': initial_delay, 'max_delay_seconds': max_delay,
                       'retry_window_seconds': retry_window},
}
print(json.dumps(metadata, indent=2))
PY
}

if [[ "${1:-}" == --print-config ]]; then
    run_metadata "$@"
    exit 0
fi
if [[ "${1:-}" == --check-site ]]; then
    case "${2:-}" in gitlab|reddit|shopping) ;; *) echo 'Supported site checks: gitlab, reddit, shopping' >&2; exit 2 ;; esac
    "$PYTHON_BIN" - "$2" <<'PY'
import tempfile, time, sys
from browser_env.auto_login import renew_comb
from browser_env.env_config import GITLAB, REDDIT, SHOPPING, ACCOUNTS
site = sys.argv[1]
profile = {'gitlab': f'{GITLAB}/-/profile',
           'reddit': f'{REDDIT}/user/{ACCOUNTS["reddit"]["username"]}/account',
           'shopping': f'{SHOPPING}/customer/account/'}[site]
from playwright.sync_api import sync_playwright

# A sign-in page can return 200 before cold authenticated Rails requests work.
# Reuse the benchmark login and verify the resulting session, before any task.
with tempfile.TemporaryDirectory(prefix=f'webarena-{site}-check-') as auth:
    for attempt in range(3):
        try:
            renew_comb([site], auth_folder=auth)
            with sync_playwright() as p:
                browser = p.chromium.launch(headless=True)
                context = browser.new_context(storage_state=f'{auth}/{site}_state.json')
                page = context.new_page()
                response = page.goto(profile, timeout=120000)
                assert response and response.status == 200 and page.url.rstrip('/') == profile.rstrip('/')
                browser.close()
            print(f'{site} ready: benchmark login and authenticated profile verified.')
            break
        except Exception as exc:
            if attempt == 2:
                raise SystemExit(f'{site} login check failed ({type(exc).__name__}); no task started.') from None
            print(f'{site} login is warming up ({type(exc).__name__}); retry {attempt+1}/2.', flush=True)
            time.sleep(10)
PY
    exit 0
fi
if [[ "${1:-}" == --check-models ]]; then
    "$PYTHON_BIN" - "${MODEL:-Qwen/Qwen3.5-9B}" <<'PY'
import os, sys
from openai import OpenAI
from evaluation_harness.helper_functions import get_judge_config
from llms.providers.openai_utils import retry_with_exponential_backoff, get_client_options

configs = [dict(model=sys.argv[1], api_key=os.environ['OPENAI_API_KEY'],
                base_url=os.environ['OPENAI_API_URL']), get_judge_config()]
@retry_with_exponential_backoff
def check_model(config):
    options = get_client_options()
    options['timeout'] = min(20, options['timeout'])
    client = OpenAI(api_key=config['api_key'], base_url=config['base_url'], **options)
    available = {model.id for model in client.models.list().data}
    if config['model'] not in available:
        raise ValueError('Model not listed by the endpoint')

for role, config in zip(('Agent', 'Judge'), configs):
    try:
        check_model(config)
    except Exception as exc:
        raise SystemExit(f'{role} model check failed ({config["model"]}): {type(exc).__name__}. '
                         'Check endpoint, credentials and EVAL_JUDGE_MODEL before running the batch.') from None
    print(f'{role} model ready: {config["model"]}')
PY
    exit 0
fi
if [[ "${1:-}" != --help ]]; then
    mkdir -p "$RESULT_DIR"
    run_metadata "$@" > "$RESULT_DIR/model_endpoints.json"
fi
exec "$PYTHON_BIN" -u run.py "${run_args[@]}" "$@"
