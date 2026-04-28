#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/.env"

ROUTER_DIR="$REPO_ROOT/deploy/qwen-multimodel-v018"
PROD_DIR="$REPO_ROOT/deploy/qwen36a3b-nvfp4-redhat-v0192rc1dev30-flashinfercutlass-toolcallsanitize-canary-20260424"
CANARY_DIR="$SCRIPT_DIR"

CANARY_PORT="${VLLM_PORT}"
CANARY_MODEL="${SERVED_MODEL_NAME}"
PROD_PORT=18000
TOKENIZER="${BENCH_TOKENIZER:-/home/pablo/models/Qwen3.6-35B-A3B-PrismaQuant-4.75bit-vllm-latest-20260423}"
export HF_HOME="${BENCH_HF_HOME:-$HOME/.cache/huggingface}"

CONCURRENCIES=(1 4 8 16 24)
BENCH_PP=128
BENCH_TG=256
BENCH_RUNS=3

TS="$(date +%Y%m%d_%H%M%S)"
TOOL_OUT_DIR="$REPO_ROOT/tool-eval-runs"
EVAL_OUT_DIR="$REPO_ROOT/eval-runs"
mkdir -p "$TOOL_OUT_DIR" "$EVAL_OUT_DIR"

LOG_FILE="$CANARY_DIR/sparkarena_mtp3_campaign_${TS}.log"
MEM_GUARD_LOG_FILE="$CANARY_DIR/sparkarena_mtp3_campaign_${TS}.memguard.log"
FR_PROMPTS="$REPO_ROOT/evals/fr_quality_prompts_20260421.json"
PROD_FR_OUT="$EVAL_OUT_DIR/fr_quality_prod_refresh_for_sparkarena_mtp3_${TS}.json"
CANARY_FR_OUT="$EVAL_OUT_DIR/fr_quality_prismaquant_sparkarena_mtp3_${TS}.json"
CANARY_TOOL_OUT="$TOOL_OUT_DIR/tool_eval_prismaquant_sparkarena_mtp3_full_${TS}.json"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
fail() { log "FATAL: $*"; exit 1; }

PROD_WAS_STOPPED=false
BENCH_MODE_ON=false
CANARY_RUNNING=false
MEM_GUARD_PID=""

ram_used_pct() {
  awk '
    /^MemTotal:/ { total = $2 }
    /^MemAvailable:/ { avail = $2 }
    END { printf "%.2f", ((total - avail) / total) * 100 }
  ' /proc/meminfo
}

ram_available_mib() {
  awk '/^MemAvailable:/ { printf "%.0f", $2 / 1024 }' /proc/meminfo
}

start_mem_guard() {
  local threshold_pct="${MEM_GUARD_THRESHOLD_PERCENT:-97}"
  local min_avail_mib="${MEM_GUARD_AVAILABLE_MIN_MIB:-9000}"
  local poll="${MEM_GUARD_POLL_SECONDS:-5}"
  (
    echo "[$(date '+%F %T')] mem_guard_start threshold=${threshold_pct}% min_avail=${min_avail_mib}MiB poll=${poll}s" >> "$MEM_GUARD_LOG_FILE"
    while true; do
      used="$(ram_used_pct)"
      avail="$(ram_available_mib)"
      echo "[$(date '+%F %T')] ram_used=${used}% ram_avail=${avail}MiB" >> "$MEM_GUARD_LOG_FILE"
      if awk -v u="$used" -v t="$threshold_pct" 'BEGIN { exit !(u >= t) }' || [ "$avail" -lt "$min_avail_mib" ]; then
        echo "[$(date '+%F %T')] LIMIT_HIT ram_used=${used}% ram_avail=${avail}MiB; stopping canary" >> "$MEM_GUARD_LOG_FILE"
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
        kill -TERM "$$" >/dev/null 2>&1 || true
        exit 97
      fi
      sleep "$poll"
    done
  ) &
  MEM_GUARD_PID="$!"
}

stop_mem_guard() {
  if [[ -n "$MEM_GUARD_PID" ]]; then
    kill "$MEM_GUARD_PID" >/dev/null 2>&1 || true
    wait "$MEM_GUARD_PID" >/dev/null 2>&1 || true
    MEM_GUARD_PID=""
  fi
}

restore_prod_and_gateway() {
  if $CANARY_RUNNING; then
    log "Stopping canary..."
    cd "$CANARY_DIR" && docker compose --env-file .env -f compose.local.yml down 2>/dev/null || true
    CANARY_RUNNING=false
  fi
  stop_mem_guard
  if $PROD_WAS_STOPPED; then
    log "Restoring local NVFP4 production..."
    cd "$PROD_DIR" && docker compose --env-file .env -f compose.local.yml up -d 2>/dev/null || true
    for i in $(seq 1 240); do
      if curl -sf "http://127.0.0.1:${PROD_PORT}/health" >/dev/null 2>&1; then
        log "Production healthy after ${i}s"
        PROD_WAS_STOPPED=false
        break
      fi
      sleep 1
    done
  fi
  if $BENCH_MODE_ON; then
    "$ROUTER_DIR/disable-bench-mode.sh" 2>/dev/null || true
    BENCH_MODE_ON=false
  fi
}

on_signal() {
  log "=== INTERRUPT/CLEANUP ==="
  restore_prod_and_gateway
  exit 130
}
trap on_signal INT TERM

log "=== SparkArena PrismaQuant MTP k=3 campaign ==="
log "Canary dir: $CANARY_DIR"
log "Model: $MODEL_ROOT"
log "Tokenizer: $TOKENIZER"
log "Config: max_model_len=$MAX_MODEL_LEN max_num_batched_tokens=$MAX_NUM_BATCHED_TOKENS max_num_seqs=$MAX_NUM_SEQS gpu_memory_utilization=$GPU_MEMORY_UTILIZATION load_format=$LOAD_FORMAT speculative=$SPECULATIVE_CONFIG"

log "=== STEP 1: Enable gateway bench mode ==="
"$ROUTER_DIR/enable-bench-mode.sh" 2>&1 | tee -a "$LOG_FILE"
BENCH_MODE_ON=true

log "=== STEP 2: Drain local prod ==="
DRAIN_TIMEOUT=120
DRAIN_ELAPSED=0
while true; do
  METRICS="$(curl -sf "http://127.0.0.1:${PROD_PORT}/metrics" 2>/dev/null || true)"
  if [[ -z "$METRICS" ]]; then
    log "Prod metrics unavailable; proceeding"
    break
  fi
  RUNNING="$(echo "$METRICS" | awk '/^vllm:num_requests_running / {print $2}' || echo "0")"
  WAITING="$(echo "$METRICS" | awk '/^vllm:num_requests_waiting / {print $2}' || echo "0")"
  RI="$(printf "%.0f" "${RUNNING:-0}" 2>/dev/null || echo "0")"
  WI="$(printf "%.0f" "${WAITING:-0}" 2>/dev/null || echo "0")"
  if [[ "$RI" -eq 0 && "$WI" -eq 0 ]]; then
    log "Drain complete"
    break
  fi
  DRAIN_ELAPSED=$((DRAIN_ELAPSED + 2))
  [[ "$DRAIN_ELAPSED" -ge "$DRAIN_TIMEOUT" ]] && fail "Drain timeout: running=$RI waiting=$WI"
  log "draining... running=$RI waiting=$WI"
  sleep 2
done

log "=== STEP 3: Capture prod French reference ==="
PROD_MODEL_ID="$(curl -sf "http://127.0.0.1:${PROD_PORT}/v1/models" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null || true)"
if [[ -n "$PROD_MODEL_ID" ]]; then
  python3 "$REPO_ROOT/scripts/run_fr_quality_eval.py" \
    --base-url "http://127.0.0.1:${PROD_PORT}" \
    --model "$PROD_MODEL_ID" \
    --prompts-file "$FR_PROMPTS" \
    --output "$PROD_FR_OUT" 2>&1 | tee -a "$LOG_FILE"
else
  log "WARN: prod model id unknown; skipping prod French reference"
fi

log "=== STEP 4: Stop local production model ==="
cd "$PROD_DIR"
docker compose --env-file .env -f compose.local.yml down 2>&1 | tee -a "$LOG_FILE"
PROD_WAS_STOPPED=true
sleep 2
for i in $(seq 1 20); do
  if ! curl -sf "http://127.0.0.1:${PROD_PORT}/health" >/dev/null 2>&1; then
    log "Production confirmed DOWN"
    break
  fi
  [[ "$i" -eq 20 ]] && fail "Production still responds on :${PROD_PORT}"
  sleep 1
done

log "=== STEP 5: Launch canary with memory guard ==="
start_mem_guard
cd "$CANARY_DIR"
docker compose --env-file .env -f compose.local.yml up -d 2>&1 | tee -a "$LOG_FILE"
CANARY_RUNNING=true
for i in $(seq 1 900); do
  if curl -sf "http://127.0.0.1:${CANARY_PORT}/health" >/dev/null 2>&1; then
    log "Canary healthy after ${i}s"
    break
  fi
  if [[ "$i" -eq 900 ]]; then
    docker logs "$CONTAINER_NAME" --tail 120 2>&1 | tee -a "$LOG_FILE"
    fail "Canary health timeout"
  fi
  sleep 1
done
CANARY_MODEL_ID="$(curl -sf "http://127.0.0.1:${CANARY_PORT}/v1/models" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null || echo "unknown")"
log "Canary model: $CANARY_MODEL_ID"

log "=== STEP 6: llama-benchy habitual ==="
BENCH_BASE_URL="http://127.0.0.1:${CANARY_PORT}/v1"
uvx llama-benchy \
  --base-url "$BENCH_BASE_URL" \
  --model "$CANARY_MODEL" \
  --served-model-name "$CANARY_MODEL" \
  --tokenizer "$TOKENIZER" \
  --pp "$BENCH_PP" --tg "$BENCH_TG" \
  --runs 1 --no-warmup --skip-coherence \
  --concurrency 1 2>&1 | tee -a "$LOG_FILE"

for c in "${CONCURRENCIES[@]}"; do
  SAVE="$CANARY_DIR/llama_benchy_prismaquant_sparkarena_mtp3_c${c}_${TS}.md"
  log "--- Bench c${c} ---"
  uvx llama-benchy \
    --base-url "$BENCH_BASE_URL" \
    --model "$CANARY_MODEL" \
    --served-model-name "$CANARY_MODEL" \
    --tokenizer "$TOKENIZER" \
    --pp "$BENCH_PP" --tg "$BENCH_TG" \
    --runs "$BENCH_RUNS" --no-warmup --skip-coherence \
    --save-result "$SAVE" --format md \
    --concurrency "$c" 2>&1 | tee -a "$LOG_FILE"
done

log "=== STEP 7: Tool-eval-bench full quality ==="
uvx --from git+https://github.com/SeraphimSerapis/tool-eval-bench tool-eval-bench \
  --base-url "http://127.0.0.1:${CANARY_PORT}" \
  --parallel 1 \
  --seed 42 2>&1 | tee "$CANARY_TOOL_OUT" | tee -a "$LOG_FILE"
log "CANARY_TOOL_OUT=$CANARY_TOOL_OUT"

log "=== STEP 8: French quality ==="
python3 "$REPO_ROOT/scripts/run_fr_quality_eval.py" \
  --base-url "http://127.0.0.1:${CANARY_PORT}" \
  --model "$CANARY_MODEL" \
  --prompts-file "$FR_PROMPTS" \
  --output "$CANARY_FR_OUT" 2>&1 | tee -a "$LOG_FILE"
log "CANARY_FR_OUT=$CANARY_FR_OUT"

log "=== STEP 9: Stop canary ==="
cd "$CANARY_DIR"
docker compose --env-file .env -f compose.local.yml down 2>&1 | tee -a "$LOG_FILE"
CANARY_RUNNING=false
stop_mem_guard

log "=== STEP 10: Restore production ==="
cd "$PROD_DIR"
docker compose --env-file .env -f compose.local.yml up -d 2>&1 | tee -a "$LOG_FILE"
for i in $(seq 1 240); do
  if curl -sf "http://127.0.0.1:${PROD_PORT}/health" >/dev/null 2>&1; then
    log "Production healthy after ${i}s"
    PROD_WAS_STOPPED=false
    break
  fi
  [[ "$i" -eq 240 ]] && fail "Production failed to recover"
  sleep 1
done

log "=== STEP 11: Disable bench mode ==="
"$ROUTER_DIR/disable-bench-mode.sh" 2>&1 | tee -a "$LOG_FILE"
BENCH_MODE_ON=false

trap - INT TERM
log "=== CAMPAIGN COMPLETE ==="
log "Perf files: $CANARY_DIR/llama_benchy_prismaquant_sparkarena_mtp3_c*_${TS}.md"
log "Tool eval:  $CANARY_TOOL_OUT"
log "FR prod:    $PROD_FR_OUT"
log "FR canary:  $CANARY_FR_OUT"
log "Main log:   $LOG_FILE"
log "Mem guard:  $MEM_GUARD_LOG_FILE"
