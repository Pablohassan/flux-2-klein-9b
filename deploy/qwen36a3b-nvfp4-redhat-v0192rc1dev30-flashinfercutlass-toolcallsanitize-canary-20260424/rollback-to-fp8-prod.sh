#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ROUTER_DIR="$REPO_ROOT/deploy/qwen-multimodel-v018"
OLD_PROD_DIR="$REPO_ROOT/deploy/qwen35a3b-fp8-tp1-chat-20260330"
LOG_FILE="$SCRIPT_DIR/rollback_redhat_nvfp4_to_fp8_$(date +%Y%m%d_%H%M%S).log"
PROD_PORT=18000

log() {
  echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

compose_nvfp4() {
  cd "$SCRIPT_DIR"
  set -a
  source ./.env
  source ./prod.env
  set +a
  docker compose --env-file .env -f compose.local.yml "$@"
}

wait_health() {
  local port="$1"
  local label="$2"
  local timeout="$3"
  for i in $(seq 1 "$timeout"); do
    if curl -fsS "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      log "$label healthy after ${i}s"
      return 0
    fi
    sleep 1
  done
  return 1
}

log "=== rollback RedHat NVFP4 -> previous FP8 prod start ==="
log "log_file=$LOG_FILE"

log "enable gateway bench mode"
"$ROUTER_DIR/enable-bench-mode.sh" 2>&1 | tee -a "$LOG_FILE"

log "stop RedHat NVFP4 prod candidate"
compose_nvfp4 down 2>&1 | tee -a "$LOG_FILE" || true

log "restore previous FP8 prod"
(cd "$OLD_PROD_DIR" && ./up.sh) 2>&1 | tee -a "$LOG_FILE"
wait_health "$PROD_PORT" "previous FP8 prod" 240

log "model endpoint:"
curl -fsS "http://127.0.0.1:${PROD_PORT}/v1/models" 2>&1 | tee -a "$LOG_FILE"
log ""

log "disable gateway bench mode"
"$ROUTER_DIR/disable-bench-mode.sh" 2>&1 | tee -a "$LOG_FILE"

log "router health after rollback:"
curl -fsS "http://127.0.0.1:8088/health" 2>&1 | tee -a "$LOG_FILE" || true
log ""

log "=== rollback complete ==="

