# RedHat Qwen3.6 NVFP4 Production Trial - 2026-04-25

## Decision

Promote `RedHatAI/Qwen3.6-35B-A3B-NVFP4` to the local chat production slot
for a multi-day trial.

Promotion executed on `2026-04-25 11:54:36 Europe/Paris`.

Promotion log:

`deploy/qwen36a3b-nvfp4-redhat-v0192rc1dev30-flashinfercutlass-toolcallsanitize-canary-20260424/promotion_redhat_nvfp4_20260425_115436.log`

The public/router-facing model names stay unchanged during the trial:

- router public chat model: `qwen35a3b-prod`
- upstream vLLM served name: `qwen35a3b-chat`
- production port: `18000`
- container name: `vllm_qwen_chat`

This keeps clients and router configuration stable while the backend model
changes from the previous FP8 prod to RedHat NVFP4.

## Promoted Candidate

- model root: `/models/RedHatAI-Qwen3.6-35B-A3B-NVFP4`
- tokenizer root: `/models/RedHatAI-Qwen3.6-35B-A3B-NVFP4`
- image: `vllm-node-tf5-prismquant-v0192rc1dev30-20260421`
- runtime: `vLLM 0.19.2rc1.dev30`
- port override: `18000`
- bind override: `0.0.0.0`
- sanitizer: `ENABLE_TOOLCALL_SANITIZER=1`
- qwen3 coder argument filter: `ENABLE_QWEN3CODER_ARG_FILTER=1`
- attention backend: `flashinfer`
- MoE backend: `flashinfer_cutlass`
- quantization: `compressed-tensors`
- max context: `32768`
- max batched tokens: `8192`
- max seqs: `44`
- KV cache dtype: `fp8`
- KV cache memory: `11811160064`

Production overrides live in:

`deploy/qwen36a3b-nvfp4-redhat-v0192rc1dev30-flashinfercutlass-toolcallsanitize-canary-20260424/prod.env`

## Previous Production Baseline

Previous local prod before this trial:

- folder: `deploy/qwen35a3b-fp8-tp1-chat-20260330`
- image: `vllm-node-fp8-main-prodsubstrate-pr35568-pr37700-clean-20260411`
- model root exposed by `/v1/models`: `/models/Qwen3.6-35B-A3B-FP8`
- served model name: `qwen35a3b-chat`
- port: `18000`
- max context: `32768`
- max batched tokens: `8192`
- max seqs: `24`
- KV cache dtype: `fp8`
- KV cache memory: `11811160064`

## Quality And Performance Basis

Latest valid full quality run before promotion:

- artifact: `tool-eval-runs/tool_eval_redhat_qwen36a3b_nvfp4_full_20260425_112431.json`
- score: `91/100`
- points: `126/138`
- pass / partial / fail: `60 / 6 / 3`
- responsiveness: `68`
- deployability: `84`

Production baseline used for comparison:

- artifact: `tool-eval-runs/tool_eval_prod_full_20260421_090844.json`
- score: `90/100`
- points: `124/138`
- pass / partial / fail: `60 / 4 / 5`
- responsiveness: `72`
- deployability: `85`

Known caveats to watch during the trial:

- `TC-60` remains a shared sleeper-injection failure.
- `TC-68` still fails on NVFP4 without request-level mitigation.
- `TC-62` was partial on the latest full run.
- single-user decode throughput is lower than previous FP8 prod; high
  concurrency and prefill are stronger.

## Promotion Command

Run from the repository root:

```bash
MEM_THRESHOLD_PERCENT=97 \
deploy/qwen36a3b-nvfp4-redhat-v0192rc1dev30-flashinfercutlass-toolcallsanitize-canary-20260424/promote-to-prod.sh
```

The script:

1. enables router bench mode,
2. drains current prod,
3. stops previous FP8 prod,
4. verifies `:18000` is down,
5. starts RedHat NVFP4 as `vllm_qwen_chat` on `:18000`,
6. waits for health with a `97%` RAM guard,
7. verifies `/v1/models`,
8. disables bench mode.

If promotion fails after stopping FP8 prod, the script attempts automatic
rollback to the previous FP8 prod.

## Manual Rollback

Fast rollback command:

```bash
deploy/qwen36a3b-nvfp4-redhat-v0192rc1dev30-flashinfercutlass-toolcallsanitize-canary-20260424/rollback-to-fp8-prod.sh
```

Manual equivalent:

```bash
cd deploy/qwen-multimodel-v018
./enable-bench-mode.sh

cd ../qwen36a3b-nvfp4-redhat-v0192rc1dev30-flashinfercutlass-toolcallsanitize-canary-20260424
set -a
source ./.env
source ./prod.env
set +a
docker compose --env-file .env -f compose.local.yml down

cd ../qwen35a3b-fp8-tp1-chat-20260330
./up.sh

curl -fsS http://127.0.0.1:18000/health
curl -fsS http://127.0.0.1:18000/v1/models

cd ../qwen-multimodel-v018
./disable-bench-mode.sh
```

Expected rollback model root:

`/models/Qwen3.6-35B-A3B-FP8`

## Trial Watchpoints

- Keep an eye on direct `:18000` health and router `:8088/health`.
- Watch RAM during the first hour after promotion.
- Watch real traffic for `tool_calls` schema cleanliness.
- If user-facing French or political-analysis answers become shorter or less
  useful, compare against the saved FR artifacts from `20260425_112431`.

## Post-Promotion Verification

Observed immediately after promotion:

- `:18000/v1/models` returned model id `qwen35a3b-chat`.
- model root returned by vLLM: `/models/RedHatAI-Qwen3.6-35B-A3B-NVFP4`.
- container `vllm_qwen_chat` is running image
  `vllm-node-tf5-prismquant-v0192rc1dev30-20260421`.
- env check confirmed `ENABLE_TOOLCALL_SANITIZER=1`.
- env check confirmed `ENABLE_QWEN3CODER_ARG_FILTER=1`.
- env check confirmed `MAX_NUM_SEQS=44`.
- router chat backend reports `qwen35a3b-prod=true`.
- router global health still reports `ok=false` because
  `qwen35a3b-batch=false`; this was already observed before the promotion and
  is not caused by the chat backend swap.
- direct smoke completion on `:18000` returned `OK NVFP4`.
- router smoke completion through `qwen35a3b-prod` returned
  `OK routeur NVFP4`.
- bench mode flag was removed after promotion.
- RAM after stabilization: about `60%` used, well below the `97%` guard.
