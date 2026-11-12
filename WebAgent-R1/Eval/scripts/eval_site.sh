#!/usr/bin/env bash
# Run one supported single-site WebArena-Lite subset, sequentially.
# Reset once before the whole evaluation round, not between individual tasks.
set -euo pipefail
SITE="${EVAL_SITE:-shopping_admin}"
case "$SITE" in
    shopping_admin) SITE_LABEL="Shopping Admin" ;;
    gitlab) SITE_LABEL="GitLab" ;;
    map) SITE_LABEL="Map" ;;
    reddit) SITE_LABEL="Reddit" ;;
    shopping) SITE_LABEL="Shopping" ;;
    *) echo "Unsupported EVAL_SITE: $SITE" >&2; exit 2 ;;
esac
export EVAL_SITE="$SITE" SITE_LABEL
CONTAINER="$SITE"
if [[ "$SITE" == reddit ]]; then CONTAINER=forum; fi

EVAL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-${EVAL_DIR}/../../.venv/bin/python}"
TASK_DIR="$EVAL_DIR/config_files/wa/test_webarena_lite"
RESET_SCRIPT="$EVAL_DIR/../WebArena-Env-Setup/reset_${SITE}.sh"
resume=false
list_only=false
for arg in "$@"; do
    case "$arg" in
        --resume) resume=true ;;
        --list) list_only=true ;;
        *) echo "Usage: bash scripts/eval_${SITE}.sh [--resume] [--list]" >&2; exit 2 ;;
    esac
done

task_ids="$("$PYTHON_BIN" - "$TASK_DIR" "$SITE" <<'PY'
import json, sys
from pathlib import Path
tasks = [json.loads(p.read_text()) for p in Path(sys.argv[1]).glob('[0-9]*.json')]
for task in sorted(tasks, key=lambda x: x['task_id']):
    if set(task['sites']) == {sys.argv[2]}:
        print(task['task_id'])
PY
)"
if [[ -z "$task_ids" ]]; then
    echo "No ${SITE_LABEL}-only tasks found." >&2
    exit 1
fi
mapfile -t TASK_IDS <<< "$task_ids"
echo "Selected ${#TASK_IDS[@]} ${SITE_LABEL}-only tasks: ${TASK_IDS[*]}"
if [[ "$list_only" == true && "$resume" == false ]]; then exit 0; fi

cd -- "$EVAL_DIR"
if [[ "$resume" == true && -z "${RESULT_DIR:-}" ]]; then
    echo "--resume requires RESULT_DIR pointing to the interrupted batch." >&2
    exit 1
fi
run_config="$(bash "$EVAL_DIR/scripts/eval_local_task.sh" --print-config)"
run_mode="$("$PYTHON_BIN" -c 'import json,sys; print(json.load(sys.stdin)["run_mode"])' <<< "$run_config")"
export RESULT_DIR="${RESULT_DIR:-eval_results/${SITE}_${run_mode}_$(date +%Y%m%d_%H%M%S)}"
export PYTHON_BIN
if [[ "$resume" == true ]]; then
    pending_ids="$("$PYTHON_BIN" - "$RESULT_DIR" "$run_config" "$task_ids" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
current = json.loads(sys.argv[2])
ids = [int(x) for x in sys.argv[3].split()]
try:
    saved_ids = [int(x) for x in (root / 'task_ids.txt').read_text().split()]
    saved = json.loads((root / 'run_config.json').read_text())
except (OSError, ValueError) as exc:
    raise SystemExit(f'Cannot resume: missing/invalid saved batch metadata ({type(exc).__name__}).')
if saved_ids != ids:
    raise SystemExit('Cannot resume: the selected task IDs differ from the original batch.')
def profile(config):
    return {key: config[key] for key in ('run_mode', 'agent', 'inference', 'judge')}
old, new = profile(saved), profile(current)
# An endpoint URL/key may change after reconnecting ngrok. Model/settings must not.
for config in (old, new):
    for role in ('agent', 'judge'):
        config[role] = {k: v for k, v in config[role].items() if k != 'base_url'}
if old != new:
    raise SystemExit('Cannot resume: model/mode/inference/judge changed. Use the original settings (e.g. THINKING=true).')
pending = []
gap = False
for task_id in ids:
    try:
        result = json.loads((root / 'actions' / f'{task_id}.json').read_text())
        valid = result['task_id'] == task_id and 0 <= float(result['score']) <= 1
    except (OSError, ValueError, KeyError, TypeError):
        valid = False
    if valid and gap:
        raise SystemExit('Cannot resume: scored tasks occur after an incomplete task; website state/order needs review.')
    if not valid:
        gap = True
        pending.append(task_id)
print(f'Resume: keeping {len(ids)-len(pending)} scored tasks; {len(pending)} tasks remain.', file=sys.stderr)
print('\n'.join(map(str, pending)))
PY
)"
elif [[ -e "$RESULT_DIR" ]]; then
    echo "Use a new RESULT_DIR: resuming after a reset would mix website states." >&2
    exit 1
else
    pending_ids="$task_ids"
fi
RUN_IDS=()
if [[ -n "$pending_ids" ]]; then mapfile -t RUN_IDS <<< "$pending_ids"; fi
if [[ "$list_only" == true ]]; then
    echo "Tasks to run: ${RUN_IDS[*]}"
    exit 0
fi

mkdir -p "$EVAL_DIR/../../.cache"
exec 9>"$EVAL_DIR/../../.cache/${SITE}_eval.lock"
flock -n 9 || { echo "Another ${SITE_LABEL} batch is running." >&2; exit 1; }
if [[ ${#RUN_IDS[@]} -gt 0 ]]; then
    # Check imports and APIs before changing container or result state.
    bash "$EVAL_DIR/scripts/eval_local_task.sh" --help >/dev/null
    bash "$EVAL_DIR/scripts/eval_local_task.sh" --check-models
    if [[ "$resume" == false ]]; then
        bash "$RESET_SCRIPT"
        mkdir -p "$RESULT_DIR"
        printf '%s\n' "${TASK_IDS[@]}" > "$RESULT_DIR/task_ids.txt"
        printf '%s\n' "$run_config" > "$RESULT_DIR/run_config.json"
    fi
    if [[ "$SITE" == map ]]; then
        container_state="$(docker inspect map map_db | "$PYTHON_BIN" -c '
import json,sys
web,db=json.load(sys.stdin)
print(json.dumps(dict(id=web["Id"],created=web["Created"],
    running=web["State"]["Running"] and db["State"]["Running"],
    dependencies={"map_db":db["Id"]},
    map_backend=json.loads((web["Config"].get("Labels") or {})["webarena.map.backend"]))))')"
    else
        container_state="$(docker inspect "$CONTAINER" --format '{"id":{{json .Id}},"created":{{json .Created}},"running":{{json .State.Running}}}')"
    fi
    "$PYTHON_BIN" - "$RESULT_DIR" "$container_state" "$resume" "$run_config" <<'PY'
import json, sys, os
from pathlib import Path
from datetime import datetime, timezone
root = Path(sys.argv[1]); current = json.loads(sys.argv[2]); resume = sys.argv[3] == 'true'
if not current['running']:
    raise SystemExit(f'{os.environ["SITE_LABEL"]} is stopped. Start the existing container before resuming; do not recreate it.')
snapshot = root / 'container_state.json'
if resume:
    if snapshot.exists():
        if any(json.loads(snapshot.read_text()).get(key) != current.get(key) for key in ('id', 'dependencies', 'map_backend')):
            raise SystemExit('Cannot resume: website container was recreated. Start a fresh batch.')
    else:
        # Older batches did not save container IDs. Reject a clearly newer container.
        files = list((root / 'actions').glob('*.json'))
        created = datetime.strptime(current['created'][:19], '%Y-%m-%dT%H:%M:%S').replace(tzinfo=timezone.utc).timestamp()
        if files and created > min(p.stat().st_mtime for p in files):
            raise SystemExit('Cannot resume: current container was created after this batch began.')
        print('Legacy batch: container age checked; resume still assumes its database has not been reset.')
    entry = dict(time=datetime.now(timezone.utc).isoformat(), container=current, config=json.loads(sys.argv[4]))
    with (root / 'resume_history.jsonl').open('a') as f:
        f.write(json.dumps(entry) + '\n')
snapshot.write_text(json.dumps(current, indent=2) + '\n')
PY
    if [[ "$SITE" == gitlab || "$SITE" == reddit || "$SITE" == shopping ]]; then
        bash "$EVAL_DIR/scripts/eval_local_task.sh" --check-site "$SITE"
    fi
fi
echo "Mode: $run_mode; results: $RESULT_DIR"

for task_id in "${RUN_IDS[@]}"; do
    echo "=== ${SITE_LABEL} task $task_id ==="
    if [[ "$resume" == true ]]; then
        "$PYTHON_BIN" - "$RESULT_DIR" "$task_id" <<'PY'
from pathlib import Path
from datetime import datetime, timezone
import shutil, sys
root = Path(sys.argv[1]); task = int(sys.argv[2])
paths = [root / 'actions' / f'{task}.json', root / f'render_{task}.html',
         root / 'traces' / f'{task}.jsonl', root / 'traces' / f'{task}.zip',
         root / 'screehshots' / str(task)]
existing = [p for p in paths if p.exists()]
if existing:
    archive = root / 'interrupted' / f'task_{task}_{datetime.now(timezone.utc):%Y%m%d_%H%M%S_%f}'
    for path in existing:
        dest = archive / path.relative_to(root)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(path), str(dest))
    print(f'Previous partial attempt preserved in {archive}')
PY
    fi
    TASK_ID="$task_id" bash "$EVAL_DIR/scripts/eval_local_task.sh"
    # run.py catches infrastructure exceptions and can exit 0 without a valid score.
    "$PYTHON_BIN" - "$RESULT_DIR/actions/$task_id.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
try:
    result = json.loads(p.read_text())
    score = float(result['score'])
    assert 0 <= score <= 1
except (OSError, ValueError, KeyError, TypeError, AssertionError):
    raise SystemExit(f'Infrastructure error: no valid score in {p}. Check error.txt and logs; batch stopped.')
print(f"Task {result['task_id']}: {'PASS' if score == 1 else 'FAIL'}")
PY
done

# score.py uses 165 as its denominator; compute this subset's denominator instead.
"$PYTHON_BIN" - "$RESULT_DIR" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
ids = [int(x) for x in (root / 'task_ids.txt').read_text().split()]
results = [json.loads((root / 'actions' / f'{i}.json').read_text()) for i in ids]
passed = [r['task_id'] for r in results if r['score'] == 1]
summary = dict(total=len(ids), passed=len(passed), failed=len(ids)-len(passed),
               success_rate=round(100 * len(passed) / len(ids), 2), passed_task_ids=passed,
               reset_policy='before_batch')
(root / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary, indent=2))
print(f'Results: {root.resolve()}')
PY
