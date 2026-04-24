# RedHatAI Qwen3.6 35B A3B NVFP4 Canary Prep - 2026-04-24

## Source Examined

- Model: `RedHatAI/Qwen3.6-35B-A3B-NVFP4`
- HF URL: `https://huggingface.co/RedHatAI/Qwen3.6-35B-A3B-NVFP4`
- HF commit observed during prep: `e850c696e6d75f965367e816c16bc7dacd955ffa`
- Storage reported by HF API: `25075941348` bytes
- Tags: `qwen3_5_moe`, `nvfp4`, `vllm`, `compressed-tensors`

The model card describes this as a preliminary NVFP4 quantization of
`Qwen/Qwen3.6-35B-A3B`, with weights and activations quantized through
`llm-compressor`.

Relevant upstream launch hint:

```bash
vllm serve RedHatAI/Qwen3.6-35B-A3B-NVFP4 \
  --reasoning-parser qwen3 \
  --moe_backend flashinfer_cutlass
```

## Config Signals

The remote `config.json` uses:

- architecture: `Qwen3_5MoeForConditionalGeneration`
- quantization method: `compressed-tensors`
- quantization format: `nvfp4-pack-quantized`
- weights: 4-bit float, group size `16`, FP8 E4M3 scales
- input activations: 4-bit float, local dynamic tensor-group strategy
- text model max position embeddings: `262144`
- MoE: `256` experts, `8` experts per token

## Local Runtime Choice

Preferred test substrate:

- image: `vllm-node-tf5-prismquant-v0192rc1dev30-20260421`
- checked locally without loading a model:
  - `vLLM 0.19.2rc1.dev30+g2aab9acf4.d20260420.cu132`
  - `FlashInfer 0.6.8`
  - `compressed-tensors 0.15.0.1`
  - `torch 2.11.0+cu130`

Reasoning:

- It is newer than the April 12 Qwen3.5 NVFP4 images.
- It has Qwen3.6-era runtime fixes already used by the recent PrismaQuant
  canaries.
- It contains vLLM NVFP4 compressed-tensors paths, including
  `compressed_tensors_w4a4_nvfp4`.
- It supports the current tool-call sanitizer and qwen3-coder argument filter.

The older image
`vllm-node-qwen35a3b-nvfp4-fi-cutlass-aligned-20260412` remains a fallback
reference, but it is based on:

- `vLLM 0.19.1rc1.dev183`
- `FlashInfer 0.6.7.dev20260410`
- `compressed-tensors 0.14.0.1`

## Prepared Local Bundle

Local ignored bundle:

```text
deploy/qwen36a3b-nvfp4-redhat-v0192rc1dev30-flashinfercutlass-toolcallsanitize-canary-20260424
```

Key settings:

- `MODEL_ROOT=RedHatAI/Qwen3.6-35B-A3B-NVFP4`
- `SERVED_MODEL_NAME=qwen36a3b-redhat-nvfp4-v0192rc1dev30-toolcallsanitize`
- `VLLM_PORT=18054`
- `INTERNAL_VLLM_PORT=18055`
- `MAX_MODEL_LEN=32768`
- `MAX_NUM_BATCHED_TOKENS=8192`
- `MAX_NUM_SEQS=44`
- `KV_CACHE_MEMORY_BYTES=11811160064`
- `KV_CACHE_DTYPE=fp8`
- `QUANTIZATION=compressed-tensors`
- `LOAD_FORMAT=auto`
- `ATTENTION_BACKEND=flashinfer`
- `MOE_BACKEND=flashinfer_cutlass`
- `VLLM_NVFP4_GEMM_BACKEND=flashinfer-cutlass`
- `VLLM_USE_FLASHINFER_MOE_FP4=1`
- `ENABLE_QWEN3CODER_ARG_FILTER=1`
- `ENABLE_TOOLCALL_SANITIZER=1`

Static validation done:

- `bash -n` on bundle shell scripts
- `python3 -m py_compile` on the sanitizer proxy
- `docker compose --env-file .env -f compose.local.yml config`
- container metadata checks for runtime versions, without loading the model

## Safety Gate

Do not launch this canary without explicit operator confirmation.

The normal test must follow the repository canary procedure:

1. Enable router bench mode / pause external traffic.
2. Drain current local production traffic.
3. Stop local production model.
4. Verify production is fully down.
5. Launch the NVFP4 canary.
6. Run `llama-benchy` at `c1,c4,c8,c16,c24`.
7. Run tool eval and French quality eval only if bench/health are acceptable.
8. Stop canary.
9. Restore local production model.
10. Verify production health.
11. Disable bench mode / restore gateway.

Memory guard rule remains active: stop immediately if RAM reaches the hard
`97%` limit.
