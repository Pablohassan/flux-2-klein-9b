#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a
source "$SCRIPT_DIR/.env"
set +a

if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  PID="$(cat "$PID_FILE")"
  echo "qwen-image-api running (pid $PID)"
  curl -s "http://127.0.0.1:$API_PORT/health" 2>/dev/null || echo "(health check failed)"
else
  echo "qwen-image-api not running"
fi
