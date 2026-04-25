#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ROUTER_DIR="$REPO_ROOT/deploy/qwen-multimodel-v018"
OLD_PROD_DIR="$REPO_ROOT/deploy/qwen35a3b-fp8-tp1-chat-20260330"
LOG_FILE="$SCRIPT_DIR/promotion_redhat_nvfp4_$(date +%Y%m%d_%H%M%S).log"
PROD_PORT=18000
MEM_LIMIT="${MEM_THRESHOLD_PERCENT:-97}"

log() {
  echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

mem_used_percent() {
  awk '
    /^MemTotal:/ { total = $2 }
    /^MemAvailable:/ { avail = $2 }
    END {
      if (total == 0) print "0.00";
      else printf "%.2f", ((total - avail) / total) * 100;
    }
  ' /proc/meminfo
}

mem_summary() {
  awk '
    /^MemTotal:/ { total = $2 }
    /^MemAvailable:/ { avail = $2 }
    END {
      used = total - avail;
      printf "ram_used=%.2f%% ram_used_gib=%.1f ram_avail_gib=%.1f",
        (used / total) * 100, used / 1024 / 1024, avail / 1024 / 1024;
    }
  ' /proc/meminfo
}

assert_mem_safe() {
  local used
  used="$(mem_used_percent)"
  log "$(mem_summary)"
  if awk -v used="$used" -v limit="$MEM_LIMIT" 'BEGIN { exit !(used >= limit) }'; then
    log "ERROR: memory guard hit at ${used}% >= ${MEM_LIMIT}%"
    return 1
  fi
}

wait_health() {
  local port="$1"
  local label="$2"
  local timeout="$3"
  for i in $(seq 1 "$timeout"); do
    assert_mem_safe
    if curl -fsS "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      log "$label healthy after ${i}s"
      return 0
    fi
    sleep 1
  done
  return 1
}

drain_prod() {
  local elapsed=0
  local timeout="${DRAIN_TIMEOUT_SECONDS:-120}"
  while true; do
    assert_mem_safe
    local metrics running waiting ri wi
    metrics="$(curl -sf "http://127.0.0.1:${PROD_PORT}/metrics" 2>/dev/null || true)"
    if [[ -z "$metrics" ]]; then
      log "prod metrics unavailable; treating prod as already drained/down"
      return 0
    fi
    running="$(echo "$metrics" | awk '/^vllm:num_requests_running / {print $2}' | tail -n1)"
    waiting="$(echo "$metrics" | awk '/^vllm:num_requests_waiting / {print $2}' | tail -n1)"
    ri="$(printf "%.0f" "${running:-0}" 2>/dev/null || echo 0)"
    wi="$(printf "%.0f" "${waiting:-0}" 2>/dev/null || echo 0)"
    if [[ "$ri" -eq 0 && "$wi" -eq 0 ]]; then
      log "drain complete"
      return 0
    fi
    elapsed=$((elapsed + 2))
    if [[ "$elapsed" -ge "$timeout" ]]; then
      log "ERROR: drain timeout with running=${ri} waiting=${wi}"
      return 1
    fi
    sleep 2
  done
}

compose_nvfp4() {
  cd "$SCRIPT_DIR"
  set -a
  source ./.env
  source ./prod.env
  set +a
  docker compose --env-file .env -f compose.local.yml "$@"
}

rollback_fp8() {
  log "rollback: stopping RedHat NVFP4 prod candidate"
  compose_nvfp4 down >/dev/null 2>&1 || true
  log "rollback: restoring previous FP8 prod"
  (cd "$OLD_PROD_DIR" && ./up.sh) >>"$LOG_FILE" 2>&1 || true
  wait_health "$PROD_PORT" "previous FP8 prod" 240 || true
  "$ROUTER_DIR/disable-bench-mode.sh" >>"$LOG_FILE" 2>&1 || true
}

log "=== RedHat NVFP4 production promotion start ==="
log "log_file=$LOG_FILE"

trap 'log "promotion interrupted"; rollback_fp8; exit 130' INT TERM

log "enable gateway bench mode"
"$ROUTER_DIR/enable-bench-mode.sh" 2>&1 | tee -a "$LOG_FILE"

log "drain current prod on :${PROD_PORT}"
drain_prod

log "stop previous FP8 prod"
(cd "$OLD_PROD_DIR" && ./down.sh) 2>&1 | tee -a "$LOG_FILE"
for i in $(seq 1 30); do
  if ! curl -fsS "http://127.0.0.1:${PROD_PORT}/health" >/dev/null 2>&1; then
    log "previous prod is down"
    break
  fi
  if [[ "$i" -eq 30 ]]; then
    log "ERROR: previous prod still answers on :${PROD_PORT}"
    rollback_fp8
    exit 1
  fi
  sleep 1
done

log "launch RedHat NVFP4 as prod on :${PROD_PORT}"
if ! compose_nvfp4 up -d 2>&1 | tee -a "$LOG_FILE"; then
  rollback_fp8
  exit 1
fi

if ! wait_health "$PROD_PORT" "RedHat NVFP4 prod" 600; then
  docker logs vllm_qwen_chat --tail 100 >>"$LOG_FILE" 2>&1 || true
  rollback_fp8
  exit 1
fi

log "model endpoint:"
curl -fsS "http://127.0.0.1:${PROD_PORT}/v1/models" 2>&1 | tee -a "$LOG_FILE"
log ""

log "disable gateway bench mode"
"$ROUTER_DIR/disable-bench-mode.sh" 2>&1 | tee -a "$LOG_FILE"

log "router health after promotion:"
curl -fsS "http://127.0.0.1:8088/health" 2>&1 | tee -a "$LOG_FILE" || true
log ""

log "=== RedHat NVFP4 production promotion complete ==="

