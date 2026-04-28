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
TOKENIZER="${BENCH_TOKENIZER:-${TOKENIZER_ROOT}}"
export HF_HOME="${BENCH_HF_HOME:-$HOME/.cache/huggingface}"

CONCURRENCIES=(${BENCH_CONCURRENCIES:-1 4 8 16 24})
BENCH_PP=128
BENCH_TG=256
BENCH_RUNS=3

MEM_GUARD_LIMIT_PCT="${MEM_GUARD_LIMIT_PCT:-97}"
MEM_GUARD_MIN_AVAILABLE_MIB="${MEM_GUARD_MIN_AVAILABLE_MIB:-9000}"

TS="$(date +%Y%m%d_%H%M%S)"
TOOL_OUT_DIR="$REPO_ROOT/tool-eval-runs"
EVAL_OUT_DIR="$REPO_ROOT/eval-runs"
mkdir -p "$TOOL_OUT_DIR" "$EVAL_OUT_DIR"

LOG_FILE="$CANARY_DIR/dflash_quality_campaign_${TS}.log"
MEM_LOG="$CANARY_DIR/dflash_quality_campaign_${TS}.memguard.log"
FR_PROMPTS="$REPO_ROOT/evals/fr_quality_prompts_20260421.json"
PROD_FR_OUT="$EVAL_OUT_DIR/fr_quality_prod_refresh_for_dflash_${TS}.json"
CANARY_FR_OUT="$EVAL_OUT_DIR/fr_quality_qwen36_27b_fp8_dflash_${TS}.json"
CANARY_TOOL_OUT="$TOOL_OUT_DIR/tool_eval_qwen36_27b_fp8_dflash_full_${TS}.json"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
fail() { log "FATAL: $*"; exit 1; }

PROD_WAS_STOPPED=false
BENCH_MODE_ON=false
CANARY_RUNNING=false
MEM_GUARD_PID=""

stop_mem_guard() {
  if [[ -n "$MEM_GUARD_PID" ]]; then
    kill "$MEM_GUARD_PID" >/dev/null 2>&1 || true
    wait "$MEM_GUARD_PID" >/dev/null 2>&1 || true
    MEM_GUARD_PID=""
  fi
}

start_mem_guard() {
  local parent_pid=$$
  (
    while true; do
      read -r total used avail < <(free -m | awk '/^Mem:/ {print $2, $3, $7}')
      pct=$((used * 100 / total))
      printf '[%s] mem_used_pct=%s available_mib=%s\n' "$(date '+%H:%M:%S')" "$pct" "$avail" >> "$MEM_LOG"
      if (( pct >= MEM_GUARD_LIMIT_PCT || avail < MEM_GUARD_MIN_AVAILABLE_MIB )); then
        printf '[%s] MEM_GUARD_TRIGGER pct=%s avail=%s\n' "$(date '+%H:%M:%S')" "$pct" "$avail" >> "$MEM_LOG"
        kill -TERM "$parent_pid" >/dev/null 2>&1 || true
        exit 0
      fi
      sleep 5
    done
  ) &
  MEM_GUARD_PID=$!
}

restore_prod_and_gateway() {
  stop_mem_guard
  if $CANARY_RUNNING; then
    log "Stopping canary..."
    cd "$CANARY_DIR" && docker compose --env-file .env -f compose.local.yml down 2>/dev/null || true
    CANARY_RUNNING=false
  fi
  if $PROD_WAS_STOPPED; then
    log "Restoring local production..."
    cd "$PROD_DIR" && ./up.sh 2>/dev/null || true
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
    log "Disabling bench mode..."
    "$ROUTER_DIR/disable-bench-mode.sh" 2>/dev/null || true
    BENCH_MODE_ON=false
  fi
}

on_signal() {
  log "=== INTERRUPT/CLEANUP ==="
  restore_prod_and_gateway
  exit 130
}

on_exit() {
  status=$?
  if [[ "$status" -ne 0 ]]; then
    log "=== ERROR CLEANUP status=${status} ==="
    restore_prod_and_gateway
  fi
  exit "$status"
}

trap on_signal INT TERM
trap on_exit EXIT

log "=== Qwen3.6 27B FP8 + DFlash campaign ==="
log "Canary dir: $CANARY_DIR"
log "Target: $MODEL_ROOT"
log "Speculative: $SPECULATIVE_CONFIG"
log "Memory guard: ${MEM_GUARD_LIMIT_PCT}% / ${MEM_GUARD_MIN_AVAILABLE_MIB}MiB"

log "=== STEP 1: Enable bench mode ==="
"$ROUTER_DIR/enable-bench-mode.sh" 2>&1 | tee -a "$LOG_FILE"
BENCH_MODE_ON=true

log "=== STEP 2: Drain prod ==="
DRAIN_TIMEOUT=120
DRAIN_ELAPSED=0
while true; do
  METRICS=$(curl -sf "http://127.0.0.1:${PROD_PORT}/metrics" 2>/dev/null || echo "")
  [[ -z "$METRICS" ]] && { log "prod metrics down already"; break; }
  RUNNING=$(echo "$METRICS" | awk '/^vllm:num_requests_running / {print $2}' || echo "0")
  WAITING=$(echo "$METRICS" | awk '/^vllm:num_requests_waiting / {print $2}' || echo "0")
  RI=$(printf "%.0f" "${RUNNING:-0}" 2>/dev/null || echo "0")
  WI=$(printf "%.0f" "${WAITING:-0}" 2>/dev/null || echo "0")
  [[ "$RI" -eq 0 && "$WI" -eq 0 ]] && { log "Drain complete"; break; }
  DRAIN_ELAPSED=$((DRAIN_ELAPSED + 2))
  [[ "$DRAIN_ELAPSED" -ge "$DRAIN_TIMEOUT" ]] && fail "Drain timeout running=${RI} waiting=${WI}"
  log "draining... running=${RI} waiting=${WI}"
  sleep 2
done

log "=== STEP 3: Capture prod French quality reference ==="
PROD_MODEL_ID=$(curl -sf "http://127.0.0.1:${PROD_PORT}/v1/models" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null || echo "")
if [[ -n "$PROD_MODEL_ID" ]]; then
  python3 "$REPO_ROOT/scripts/run_fr_quality_eval.py" \
    --base-url "http://127.0.0.1:${PROD_PORT}" \
    --model "$PROD_MODEL_ID" \
    --prompts-file "$FR_PROMPTS" \
    --output "$PROD_FR_OUT" 2>&1 | tee -a "$LOG_FILE"
  log "PROD_FR_OUT=$PROD_FR_OUT"
else
  log "WARN: prod model id unknown, skipping prod FR capture"
fi

log "=== STEP 4: Stop local production ==="
cd "$PROD_DIR" && ./down.sh 2>&1 | tee -a "$LOG_FILE"
PROD_WAS_STOPPED=true
sleep 2
for i in $(seq 1 20); do
  if ! curl -sf "http://127.0.0.1:${PROD_PORT}/health" >/dev/null 2>&1; then
    log "Production confirmed DOWN"
    break
  fi
  [[ "$i" -eq 20 ]] && fail "prod still up on :${PROD_PORT}"
  sleep 1
done

log "=== STEP 5: Launch DFlash canary ==="
start_mem_guard
cd "$CANARY_DIR" && docker compose --env-file .env -f compose.local.yml up -d 2>&1 | tee -a "$LOG_FILE"
CANARY_RUNNING=true
for i in $(seq 1 900); do
  if curl -sf "http://127.0.0.1:${CANARY_PORT}/health" >/dev/null 2>&1; then
    log "Canary healthy after ${i}s"
    break
  fi
  if [[ "$i" -eq 900 ]]; then
    docker logs "$CONTAINER_NAME" --tail 120 2>&1 | tee -a "$LOG_FILE"
    fail "canary timeout"
  fi
  sleep 1
done
CANARY_MODEL_ID=$(curl -sf "http://127.0.0.1:${CANARY_PORT}/v1/models" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null || echo "unknown")
log "Canary model: $CANARY_MODEL_ID"

log "=== STEP 6: llama-benchy ==="
BENCH_BASE_URL="http://127.0.0.1:${CANARY_PORT}/v1"
log "--- Warm-up ---"
uvx llama-benchy --base-url "$BENCH_BASE_URL" --model "$CANARY_MODEL" --served-model-name "$CANARY_MODEL" \
  --tokenizer "$TOKENIZER" --pp "$BENCH_PP" --tg "$BENCH_TG" --runs 1 --no-warmup --skip-coherence --concurrency 1 2>&1 | tee -a "$LOG_FILE"
for c in "${CONCURRENCIES[@]}"; do
  SAVE="$CANARY_DIR/llama_benchy_qwen36_27b_fp8_dflash_c${c}_${TS}.md"
  log "--- Bench c${c} ---"
  uvx llama-benchy --base-url "$BENCH_BASE_URL" --model "$CANARY_MODEL" --served-model-name "$CANARY_MODEL" \
    --tokenizer "$TOKENIZER" --pp "$BENCH_PP" --tg "$BENCH_TG" --runs "$BENCH_RUNS" --no-warmup --skip-coherence \
    --save-result "$SAVE" --format md --concurrency "$c" 2>&1 | tee -a "$LOG_FILE"
done

log "=== STEP 7: Tool-eval-bench ==="
uvx --from git+https://github.com/SeraphimSerapis/tool-eval-bench tool-eval-bench \
  --base-url "http://127.0.0.1:${CANARY_PORT}" --parallel 1 --seed 42 2>&1 | tee "$CANARY_TOOL_OUT" | tee -a "$LOG_FILE"
log "CANARY_TOOL_OUT=$CANARY_TOOL_OUT"

log "=== STEP 8: French quality on canary ==="
python3 "$REPO_ROOT/scripts/run_fr_quality_eval.py" \
  --base-url "http://127.0.0.1:${CANARY_PORT}" \
  --model "$CANARY_MODEL" \
  --prompts-file "$FR_PROMPTS" \
  --output "$CANARY_FR_OUT" 2>&1 | tee -a "$LOG_FILE"
log "CANARY_FR_OUT=$CANARY_FR_OUT"

log "=== STEP 9: Stop canary ==="
cd "$CANARY_DIR" && docker compose --env-file .env -f compose.local.yml down 2>&1 | tee -a "$LOG_FILE"
CANARY_RUNNING=false
stop_mem_guard
sleep 2

log "=== STEP 10: Restore prod ==="
cd "$PROD_DIR" && ./up.sh 2>&1 | tee -a "$LOG_FILE"
for i in $(seq 1 240); do
  if curl -sf "http://127.0.0.1:${PROD_PORT}/health" >/dev/null 2>&1; then
    log "Prod healthy after ${i}s"
    PROD_WAS_STOPPED=false
    break
  fi
  [[ "$i" -eq 240 ]] && fail "prod did not restart"
  sleep 1
done

log "=== STEP 11: Disable bench mode ==="
"$ROUTER_DIR/disable-bench-mode.sh" 2>&1 | tee -a "$LOG_FILE"
BENCH_MODE_ON=false

trap - INT TERM EXIT
log "=== CAMPAIGN COMPLETE ==="
log "Perf:      $CANARY_DIR/llama_benchy_qwen36_27b_fp8_dflash_c*_${TS}.md"
log "Tool eval: $CANARY_TOOL_OUT"
log "FR prod:   $PROD_FR_OUT"
log "FR canary: $CANARY_FR_OUT"
log "Log:       $LOG_FILE"
log "Mem guard: $MEM_LOG"
