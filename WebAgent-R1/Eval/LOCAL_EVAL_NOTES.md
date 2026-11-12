# Local evaluation notes

These notes describe local changes used for WebArena-Lite evaluation with
`Qwen/Qwen3.5-9B` on a remote OpenAI-compatible endpoint. This setup is not a
verified reproduction of the original paper's environment or judge.

## Evaluation scope and turn counts

The five single-site scripts cover 155 of 165 Lite tasks. The other 10 tasks
combine GitLab/Reddit (4), Map/Wikipedia (4), Map/Shopping Admin (1), or
Reddit/Shopping (1). No script silently includes these mixed-site tasks.

A fresh batch resets once before all selected tasks, not between tasks. Resume
keeps the website state and all scored tasks; an interrupted task is restarted,
so earlier writes may remain. Infrastructure failures stay unscored and stop the
batch. SR uses the selected subset denominator, unlike `score.py`'s fixed 165.
Our reported mean turns count recorded environment action attempts, including
repeated/invalid attempts but excluding the final exit/STOP. They exclude API
retries, judge calls, smoke tests and archived interrupted attempts. Overall
means are task-weighted, not an unweighted average of website means.

## Model, judge and recovery

- Non-thinking: temperature 0, top-p 0.9, max tokens 2048. Thinking changes the
  native `enable_thinking` switch and uses 8192 tokens. Both modes use 30 max
  steps and early-stop thresholds of 5. Report the unequal token budgets.
- The judge uses separate `EVAL_JUDGE_MODEL`, `EVAL_JUDGE_API_URL` and
  `EVAL_JUDGE_API_KEY`. Local runs used `gpt-4.1`, replacing the legacy default
  `gpt-4-1106-preview`. This is a material difference for score comparisons.
- Actor streaming joins content and waits for a finish reason before executing
  an action. Separate reasoning fields are counted in logs, not saved as full
  reasoning text. Interrupted streams discard partial output before retry.
- Defaults: 20 retries, delays increasing from about 30 to 120 seconds, and an
  1800-second recovery window. Read timeouts are 180s non-thinking / 600s thinking.
  For streams, this limits idle reads; the recovery deadline is checked on chunks.
  Progress appears about every 30 seconds while chunks arrive, not on a separate
  heartbeat. Bad credentials, invalid requests and missing models fail fast.
- Override `LLM_STREAM`, `LLM_REQUEST_TIMEOUT`, `LLM_MAX_RETRIES`,
  `LLM_RETRY_INITIAL_DELAY`, `LLM_RETRY_MAX_DELAY` or `LLM_RETRY_WINDOW` as needed.
  Transport settings can change during resume and are recorded in metadata.

## Local grading corrections

- GitLab task 96: `must_include: "Good idea"` became `["Good idea"]` to match the
  evaluator schema. Expected text, locator, URL and intent are unchanged.
- HTML fuzzy matching returns 0 for empty extracted text with a nonempty
  reference, without asking a judge to grade absent content. This is restricted
  to HTML fuzzy evidence, not a blanket conversion of errors or `N/A` to FAIL.
- The fuzzy judge accepts complete `correct`, `incorrect`, or `partially correct`
  labels (with case/whitespace/final-period normalization). Invalid replies get
  up to three verdict attempts. Persistent format/API failures remain unscored;
  valid verdicts retain scores 1/0/0. This replaces assertion crashes and avoids
  treating `not correct` as a positive substring match.

These are local dataset/grading implementation changes. Disclose them; existing
saved scores were not automatically rewritten.

## Website setup differences

Reset helpers recreate only their site's containers from loaded images and wait
for readiness. No image rebuild/commit was used. Magento base URLs are configured
for localhost; Shopping uses the existing reset script's scheduled indexers.
GitLab uses two Puma workers, disables bundled monitoring, and gets longer login
navigation timeouts. See [GitLab notes](LOCAL_GITLAB_NOTES.md) for details.
Login preflight uses benchmark accounts and may update normal session/login
metadata. The default host/port configuration is in `00_vars.sh`.

## Map public backend

Public mode uses Nominatim (`https://nominatim.openstreetmap.org/`), OSM tiles
(`https://tile.openstreetmap.org/{z}/{x}/{y}.png`), and FOSSGIS OSRM
(`https://routing.openstreetmap.de` with `/routed-car`, `/routed-bike`, `/routed-foot`).
These live services are not a frozen benchmark dataset. Choosing `benchmark`
mode requires explicit URLs/suffixes and does not itself verify dataset provenance.

The public adapter is a bind-mounted Rails initializer, not a rebuilt image. Both
browser directions and server-side search use same-origin `/public-geocoder/`.
It identifies the application, caches successful responses for 24 hours keyed by
upstream/endpoint/query, and uses a shared file lock with 1.1s minimum spacing
between upstream requests. Cache lives in `.cache/webarena-map/public-geocoder-cache`
and survives website/DB resets; failed HTTP responses are not cached. Benchmark
mode does not mount the adapter. Routing and tile service policies still apply.

Nominatim's [usage policy](https://operations.osmfoundation.org/policies/nominatim/)
limits requests to 1/s, requires an identifying User-Agent/Referer and cached
repeated bulk queries, and forbids autocomplete/systematic scraping. Rate control
alone does not make every inventory task suitable for the public service.

Initial testing hit DNS failures for tile/Nominatim hosts. Temporary mappings to
`151.101.1.91` were verified via DNS-over-HTTPS on 2026-11-12. `MAP_DNS_OVERRIDES`
applies Docker `extra_hosts` and browser resolver rules; no global DNS or HTTPS
verification change was made. CDN IPs may change: refresh/remove these mappings
when appropriate. An initial search probe falsely matched a loading placeholder;
later probes verified actual CMU results, tiles, and all three route modes.
The backend manifest and browser args record the active configuration.

Known observation issue (not fixed in these runs): the DOM simplifier can retain
stale `selected` annotations on dropdown options. After Car-to-Foot selection,
both may appear selected although the browser selected only Foot. The underlying
DOM did update; repeated typing/clicking can legitimately leave later observations
unchanged. Map results therefore reflect both public-backend differences and this
observation limitation; do not attribute every FAIL to the actor or Docker image.

## Reproducibility artifacts

Retain batch config, model endpoints, task IDs, summary, container state, resume
history, actions and traces locally. Record immutable image IDs and the reset
scripts, not just mutable tags. Credentials, generated configs/cache, logs and
result directories are not included in the staged submission. Regression tests
were run during development but are also excluded from that submission.
