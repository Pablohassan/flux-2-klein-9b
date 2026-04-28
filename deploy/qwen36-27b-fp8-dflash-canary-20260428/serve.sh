#!/bin/bash
set -euo pipefail

API_ARGS=()
if [[ -n "${VLLM_API_KEY:-}" ]]; then
  API_ARGS+=(--api-key "${VLLM_API_KEY}")
fi

SCHEDULER_ARGS=()
if [[ -n "${SCHEDULING_POLICY:-}" ]]; then
  SCHEDULER_ARGS+=(--scheduling-policy "${SCHEDULING_POLICY}")
fi

KV_SCALE_ARGS=()
if [[ "${CALCULATE_KV_SCALES:-0}" == "1" ]]; then
  KV_SCALE_ARGS+=(--calculate-kv-scales)
fi

KV_CACHE_ARGS=()
if [[ -n "${KV_CACHE_MEMORY_BYTES:-}" ]]; then
  KV_CACHE_ARGS+=(--kv-cache-memory-bytes "${KV_CACHE_MEMORY_BYTES}")
fi

ASYNC_ARGS=()
if [[ "${ASYNC_SCHEDULING:-}" == "1" ]]; then
  ASYNC_ARGS+=(--async-scheduling)
elif [[ "${ASYNC_SCHEDULING:-}" == "0" ]]; then
  ASYNC_ARGS+=(--no-async-scheduling)
fi

OTLP_ARGS=()
if [[ -n "${OTLP_TRACES_ENDPOINT:-}" ]]; then
  OTLP_ARGS+=(--otlp-traces-endpoint "${OTLP_TRACES_ENDPOINT}")
  OTLP_ARGS+=(--collect-detailed-traces "${OTLP_TRACES_DETAIL:-all}")
fi

EPLB_ARGS=()
if [[ "${ENABLE_EPLB:-0}" == "1" ]]; then
  EPLB_ARGS+=(--enable-eplb)
  EPLB_ARGS+=(--eplb-config "${EPLB_CONFIG:-{\"log_balancedness\":true,\"window_size\":1000,\"step_interval\":3000}}")
fi

CHAT_TEMPLATE_ARGS=()
if [[ -n "${CHAT_TEMPLATE_PATH:-}" ]]; then
  CHAT_TEMPLATE_ARGS+=(--chat-template "${CHAT_TEMPLATE_PATH}")
fi
case "${DEFAULT_CHAT_TEMPLATE_KWARGS:-}" in
  "{enable_thinking:false}")
    DEFAULT_CHAT_TEMPLATE_KWARGS='{"enable_thinking":false}'
    ;;
  "{preserve_thinking:true}")
    DEFAULT_CHAT_TEMPLATE_KWARGS='{"preserve_thinking":true}'
    ;;
esac
if [[ -n "${DEFAULT_CHAT_TEMPLATE_KWARGS:-}" ]]; then
  CHAT_TEMPLATE_ARGS+=(--default-chat-template-kwargs "${DEFAULT_CHAT_TEMPLATE_KWARGS}")
fi

SPECULATIVE_ARGS=()
if [[ -n "${SPECULATIVE_CONFIG:-}" ]]; then
  SPECULATIVE_ARGS+=(--speculative-config "${SPECULATIVE_CONFIG}")
fi

QUANTIZATION_ARGS=()
if [[ -n "${QUANTIZATION:-}" ]]; then
  QUANTIZATION_ARGS+=(--quantization "${QUANTIZATION}")
fi

LOAD_FORMAT_ARGS=()
if [[ -n "${LOAD_FORMAT:-}" ]]; then
  LOAD_FORMAT_ARGS+=(--load-format "${LOAD_FORMAT}")
fi

vllm serve "${MODEL_ROOT:-rdtand/Qwen3.6-35B-A3B-PrismQuant-4.75bit-vllm}" \
    --host "${VLLM_BIND_HOST:-0.0.0.0}" \
    --port "${VLLM_PORT:-18000}" \
    --served-model-name "${SERVED_MODEL_NAME:-qwen36a3b-prismquant475}" \
    --tensor-parallel-size 1 \
    --language-model-only \
    --reasoning-parser "${REASONING_PARSER:-qwen3}" \
    --enable-auto-tool-choice \
    --tool-call-parser "${TOOL_CALL_PARSER:-qwen3_coder}" \
    --max-model-len "${MAX_MODEL_LEN:-32768}" \
    --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION:-0.50}" \
    --max-num-batched-tokens "${MAX_NUM_BATCHED_TOKENS:-4096}" \
    --max-num-seqs "${MAX_NUM_SEQS:-8}" \
    --kv-cache-dtype "${KV_CACHE_DTYPE:-fp8}" \
    "${KV_CACHE_ARGS[@]}" \
    "${QUANTIZATION_ARGS[@]}" \
    "${LOAD_FORMAT_ARGS[@]}" \
    --attention-backend "${ATTENTION_BACKEND:-flashinfer}" \
    --enable-prefix-caching \
    "${SPECULATIVE_ARGS[@]}" \
    "${ASYNC_ARGS[@]}" \
    --generation-config vllm \
    --compilation-config '{"pass_config":{"fuse_act_quant":false}}' \
    "${CHAT_TEMPLATE_ARGS[@]}" \
    --enable-request-id-headers \
    --enable-mfu-metrics \
    --trust-remote-code \
    "${KV_SCALE_ARGS[@]}" \
    "${SCHEDULER_ARGS[@]}" \
    "${EPLB_ARGS[@]}" \
    "${OTLP_ARGS[@]}" \
    "${API_ARGS[@]}"
