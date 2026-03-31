#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp -n "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env" 2>/dev/null || true
set -a
source "$SCRIPT_DIR/.env"
set +a

if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "flux2-klein-api running pid $(cat "$PID_FILE")"
else
  echo "flux2-klein-api stopped"
fi

curl -fsS "http://127.0.0.1:${API_PORT}/health" || true
