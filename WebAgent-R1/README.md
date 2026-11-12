
# WebAgent-R1

This repository contains the implementation of **WebAgent-R1: Training Web Agents via End-to-End Multi-Turn Reinforcement Learning**. The codebase is organized into several main components for environment setup, training, and evaluation.

## 🚀 Quick Start

### Installation

#### 1. WebArena Environment Setup

Before training or evaluation, you need to set up the WebArena environment for the LLM agent to interact with:

```bash
cd WebArena-Env-Setup

# Follow the instructions in WebArena-Env-Setup to download required images

# Edit 00_vars.sh with your ports and hostname (optional)

# Load Docker images and start the environment
# Note: You may need to run with sudo depending on your Docker setup
bash 01_docker_load_images.sh
bash 02_docker_remove_containers.sh
bash 03_docker_create_containers.sh
bash 04_docker_start_containers.sh
bash 05_docker_patch_containers.sh
bash 06_serve_homepage.sh
```

#### 2. Evaluation Setup
```bash
# Create Python environment
conda create -n webagent-r1 python=3.10 -y
conda activate webagent-r1

# Install dependencies for evaluation
cd Eval
pip install -r requirements.txt
playwright install
pip install -e .
pip install lxml dashscope anthropic openai==1.64.0
```

#### 3. Training Setup
```bash
cd Train
conda env create -f environment.yml
```

## 📖 Usage

### Evaluation
```bash
cd Eval
bash evaluate.sh
python score.py <path_to_eval_result>
```

#### Local WebArena-Lite evaluation

Commands below run from the **outer workspace root**, containing `WebAgent-R1/`.
Use Docker with the required site images loaded; configure local ports in
`WebArena-Env-Setup/00_vars.sh`. See the [environment setup guide](WebArena-Env-Setup/README.md)
for image downloads and Map source extraction.

**Install the local evaluator** (Python 3.10):

```bash
python3.10 -m venv .venv
.venv/bin/python -m pip install torch==2.2.2 --index-url https://download.pytorch.org/whl/cpu
.venv/bin/python -m pip install -r WebAgent-R1/Eval/requirements-local-eval.txt
.venv/bin/python -m playwright install --with-deps chromium
cp WebAgent-R1/Eval/.env.example WebAgent-R1/Eval/.env
chmod 600 WebAgent-R1/Eval/.env
```

Edit `Eval/.env` with the judge model, endpoint and key. The runner loads it;
keep judge credentials separate from the remote actor's credentials.

```bash
export OPENAI_API_URL="https://your-model-endpoint/v1"
export OPENAI_API_KEY="EMPTY"
export MODEL="Qwen/Qwen3.5-9B"
```

**Select a website** using its script key:

| Website | Script key | Tasks | Default local URL |
|---|---|---:|---|
| Shopping Admin | `shopping_admin` | 35 | `http://localhost:8083/admin` |
| GitLab | `gitlab` | 30 | `http://localhost:9001` |
| Reddit | `reddit` | 19 | `http://localhost:8080` |
| Shopping | `shopping` | 45 | `http://localhost:8082` |
| Map | `map` | 26 | `http://localhost:9003` |

These are **155 single-site tasks**; the 10 cross-site Lite tasks are excluded.

```bash
SITE=shopping
bash "WebAgent-R1/Eval/scripts/eval_${SITE}.sh" --list
bash WebAgent-R1/Eval/scripts/eval_local_task.sh --check-models

THINKING=false LLM_STREAM=true \
RESULT_DIR="eval_results/${SITE}_nonthinking_$(date +%Y%m%d_%H%M%S)" \
bash "WebAgent-R1/Eval/scripts/eval_${SITE}.sh"
```

Use `THINKING=true` and a new `..._thinking_...` directory for thinking mode.
Defaults: temperature **0**, top-p **0.9**, max steps **30**, and early stop after
**5** identical actions or parsing failures. Token budgets differ: **2048** for
non-thinking and **8192** for thinking. Set `MAX_TOKENS` to compare equal budgets.
Streaming/retry are enabled; inspect resolved settings with `--print-config` on
`eval_local_task.sh`.

A fresh batch resets **only the selected website once**, then runs sequentially.
Do not run two agents on the same website instance. Reset scripts require local
images; they do not download them. Keep other sites stopped on limited-RAM laptops.

**Resume an interrupted batch** with its original mode and result directory:

```bash
THINKING=false \
RESULT_DIR="eval_results/shopping_nonthinking_<timestamp>" \
bash WebAgent-R1/Eval/scripts/eval_shopping.sh --resume
```

Do not reset/recreate the container before resume. Scored PASS/FAIL tasks are
skipped; the first unscored task restarts from its beginning. Partial output is
archived, but website writes are not rolled back. Add `--list` to preview pending
tasks. Changed model/settings or container identity block resume.

Results are under `WebAgent-R1/Eval/eval_results/`; `RESULT_DIR` is relative to
`WebAgent-R1/Eval`. Each batch saves `summary.json` (subset SR), `task_ids.txt`,
config/endpoint metadata, container identity, actions, HTML reports and traces.

**Map requires external backends.** Copy `WebArena-Env-Setup/map.env.example` to
`map.env` and explicitly select a fixed `benchmark` backend or live `public`
services. The public setup uses cached/rate-limited Nominatim plus OSM tiles and
OSRM; live data may differ from benchmark answers. Temporary `MAP_DNS_OVERRIDES`
are propagated to the container and eval browser. Review public-service usage
restrictions before running a batch; rate limiting does not permit systematic
POI scraping. Map resume checks both web and database containers.

For research reporting, retain the judge/model budgets, local grading fixes,
backend choice and known observation limitations described in
[local evaluation notes](Eval/LOCAL_EVAL_NOTES.md) and
[GitLab setup notes](Eval/LOCAL_GITLAB_NOTES.md).

### Training
```bash
cd Train/verifiers
conda activate verifiers-new
bash run.sh
```

## Bugs or Questions?
If you have any questions related to the code or the paper, feel free to email Zhepei (zhepei.wei@virginia.edu). If you encounter any problems when using the code, or want to report a bug, feel free to open an issue! Please try to specify the problem with details so we can help you better and quicker!

## Citation
Please cite our paper if you find this repository helpful in your work:

```bibtex
@inproceedings{
wei2025webagent-r1,
title={{WebAgent-R1}: Training Web Agents via End-to-End Multi-Turn Reinforcement Learning},
author={Wei, Zhepei and Yao, Wenlin and Liu, Yao and Zhang, Weizhi and Lu, Qin and Qiu, Liang and Yu, Changlong and Xu, Puyang and Zhang, Chao and Yin, Bing and Yun, Hyokun and Li, Lihong},
booktitle={The 2025 Conference on Empirical Methods in Natural Language Processing (EMNLP 2025)},
year={2025},
url={https://arxiv.org/abs/2505.16421}
}
```
