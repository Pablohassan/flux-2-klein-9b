# Daily Log - Batch FP8 Memory Guard - 2026-04-27

## Decision

The PrismaQuant batch backend was abandoned for the current production test
phase. The batch slot now runs the local FP8 build:

- served model: `qwen3.6-35B-3A-batch`
- model root: `/models/Qwen3.6-35B-A3B-FP8`
- tokenizer root: `/models/Qwen3.6-35B-A3B-FP8`
- load format: `fastsafetensors`
- explicit quantization flag: empty; vLLM detects `quantization=fp8`

The chat slot remains on RedHat NVFP4.

## Batch Runtime Settings

The active batch settings were kept compatible with production concurrency:

- `MAX_NUM_SEQS=44`
- `MAX_NUM_BATCHED_TOKENS=8192`
- `KV_CACHE_MEMORY_BYTES=10737418240` (`10 GiB`)
- `GPU_MEMORY_UTILIZATION=0.38`
- `ENABLE_TOOLCALL_SANITIZER=1`

The previous PrismaQuant `.env` was backed up on the batch node:

`/home/pablo/qwen36a3b-prismaquant475v2-batch-20260423/.env.prismaquant-backup-20260427-140048`

## Validation

Direct batch health:

- `http://127.0.0.1:18100/health` returned HTTP `200`
- `/v1/models` exposed `qwen3.6-35B-3A-batch`
- model root returned by vLLM: `/models/Qwen3.6-35B-A3B-FP8`

Gateway health returned `ok=true` with:

- `qwen3.6-35B-3A-chat=true`
- `qwen3.6-35B-3A-batch=true`
- embeddings, rerankers, small Qwen models, and `monica-tts=true`

Smoke tests:

- direct batch response: `OK-FP8`
- gateway batch response: `Le backend batch FP8 est confirmé comme fonctionnel.`

## Memory Guard

Docker has no hard memory cap on this container (`Memory=0`), and `docker stats`
does not account for the GPU/unified memory used by the vLLM engine. For this
reason, a user systemd memory guard was installed on the batch node:

`~/.config/systemd/user/qwen-batch-memory-guard.service`

It runs:

`/home/pablo/qwen36a3b-prismaquant475v2-batch-20260423/qwen_batch_memory_guard.sh`

Guard thresholds:

- stop batch if vLLM GPU/unified memory exceeds `50000 MiB`
- stop batch if system RAM exceeds `97%`
- stop batch if available RAM drops below `9000 MiB`
- require `2` consecutive breaches before stopping

On breach, the guard first disables the Docker restart policy with
`docker update --restart=no vllm_qwen_batch`, then stops the batch container.
This avoids a restart loop that would immediately consume memory again.

Observed after FP8 startup:

- batch vLLM engine memory: `47221 MiB`
- system RAM: about `78.6%` used
- available RAM: about `25-26 GiB`
- guard status: `active`

## Rollback Notes

To rollback to the previous PrismaQuant batch configuration, restore the backup
`.env`, restart the batch bundle, and verify gateway health. This rollback is
available but is not the preferred path for the current test phase.
