# Qwen3.6 PrismaQuant SparkArena MTP k=3 Canary - 2026-04-28

Purpose: reproduce the SparkArena-style PrismaQuant profile, then run the
usual local campaign: llama-benchy, full tool quality, and French quality.

Key runtime settings:

- model: `/models/Qwen3.6-35B-A3B-PrismaQuant-4.75bit-vllm-latest-20260423`
- image: `vllm-node-tf5`
- load format: `instanttensor`
- quantization: `compressed-tensors`
- speculative decoding: `{"method":"mtp","num_speculative_tokens":3}`
- max model length: `262144`
- max batched tokens: `32768`
- max sequences: `4`
- GPU memory utilization: `0.60`
- KV cache dtype: `fp8`
- chat kwargs: `{"preserve_thinking":true}`
- performance mode: `throughput`
- optimization level: `3`

The campaign script follows the DGX Spark safety workflow:

1. enable gateway bench mode
2. drain local production
3. capture production French reference
4. stop local NVFP4 production
5. verify production is down
6. start canary with a `97%` RAM guard
7. run llama-benchy
8. run full tool-eval quality
9. run French quality
10. stop canary
11. restore local NVFP4 production
12. disable gateway bench mode

Run only after explicit confirmation:

```bash
cd deploy/qwen36a3b-prismaquant475-sparkarena-mtp3-canary-20260428
./run-sparkarena-quality-campaign.sh
```
