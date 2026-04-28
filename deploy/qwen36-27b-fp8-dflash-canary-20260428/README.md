# Qwen3.6 27B FP8 + DFlash Canary - 2026-04-28

This canary tests the Z-Lab DFlash drafter against the local Qwen3.6 27B FP8
target.

- target model: `/models/Qwen3.6-27B-FP8-latest-20260423`
- DFlash drafter: `/models/Qwen3.6-27B-DFlash`
- bench tokenizer: `/home/pablo/models/Qwen3.6-27B-FP8-latest-20260423`
- served name: `qwen36-27b-fp8-dflash`
- attention backend: `flash_attn`
- KV cache dtype: `auto`
- max batched tokens: `32768`
- speculative config:
  `{"method":"dflash","model":"/models/Qwen3.6-27B-DFlash","num_speculative_tokens":15}`

The campaign script follows the DGX Spark safety flow: enable bench mode, drain
traffic, stop local production, run canary benchmark and quality tests, stop the
canary, restore local production, and disable bench mode.
