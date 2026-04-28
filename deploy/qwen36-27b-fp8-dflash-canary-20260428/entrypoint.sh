#!/bin/bash
set -euo pipefail

cd /workspace
export WORKSPACE_DIR=/workspace

apply_mod() {
  local mod_dir="$1"
  (
    cd "$mod_dir"
    chmod +x run.sh
    ./run.sh
  )
}

apply_mod /workspace/deploy/runtime/mods/fix-qwen3-coder-next
if [[ "${ENABLE_QWEN3CODER_ARG_FILTER:-0}" == "1" ]]; then
  apply_mod /workspace/deploy/runtime/mods/qwen3coder-arg-filter
fi
if [[ "${ENABLE_QWEN35_CHAT_TEMPLATE_FIX:-0}" == "1" ]]; then
  apply_mod /workspace/deploy/runtime/mods/fix-qwen3.5-chat-template
fi
if [[ "${ENABLE_PR38361_CANDIDATE:-0}" == "1" ]]; then
  apply_mod /workspace/deploy/runtime/mods/candidate-pr38361-gdn-prefill
fi

if [[ "${ENABLE_TOOLCALL_SANITIZER:-0}" == "1" ]]; then
  export INTERNAL_VLLM_PORT="${INTERNAL_VLLM_PORT:-18031}"
  export INTERNAL_VLLM_BASE="http://127.0.0.1:${INTERNAL_VLLM_PORT}"
  export VLLM_BACKEND_PID=""

  cleanup() {
    if [[ -n "${VLLM_BACKEND_PID}" ]]; then
      kill "${VLLM_BACKEND_PID}" >/dev/null 2>&1 || true
      wait "${VLLM_BACKEND_PID}" >/dev/null 2>&1 || true
    fi
  }
  trap cleanup EXIT INT TERM

  VLLM_PORT="${INTERNAL_VLLM_PORT}" /workspace/deploy/serve.sh &
  VLLM_BACKEND_PID=$!

  for _ in $(seq 1 240); do
    if curl -fsS "http://127.0.0.1:${INTERNAL_VLLM_PORT}/health" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  exec python3 /workspace/deploy/runtime/toolcall_sanitizer_proxy.py
fi

exec /workspace/deploy/serve.sh
