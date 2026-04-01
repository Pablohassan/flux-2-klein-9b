#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp -n "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env" 2>/dev/null || true
set -a
source "$SCRIPT_DIR/.env"
set +a

mkdir -p "$LOG_DIR" "$OUTPUTS_DIR"

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  "$SCRIPT_DIR/setup.sh"
fi

if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "qwen-image-api already running (pid $(cat "$PID_FILE"))"
  exit 0
fi

nohup "$VENV_DIR/bin/python" -m uvicorn app:app \
  --app-dir "$SCRIPT_DIR" \
  --host "$API_HOST" \
  --port "$API_PORT" \
  > "$LOG_DIR/api.log" 2>&1 &

echo $! > "$PID_FILE"
echo "started pid $(cat "$PID_FILE")"
