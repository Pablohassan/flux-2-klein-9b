# PrismaQuant SparkArena MTP k=3 Canary - 2026-04-28

## Scope

Tested the SparkArena-style profile for:

- model: `/models/Qwen3.6-35B-A3B-PrismaQuant-4.75bit-vllm-latest-20260423`
- image: `vllm-node-tf5`
- load format: `instanttensor`
- MTP: `{"method":"mtp","num_speculative_tokens":3}`
- max context: `262144`
- max batched tokens: `32768`
- max sequences: `4`
- GPU memory utilization: `0.60`
- performance mode: `throughput`
- optimization level: `3`
- default chat kwargs: `{"preserve_thinking":true}`

The campaign followed the normal safety workflow: gateway bench mode, drain,
stop local NVFP4 production, launch canary, benchmark, quality eval, stop
canary, restore local NVFP4 production, disable bench mode.

Production was restored successfully and gateway health returned `ok=true`.

## Important Harness Finding

The strict SparkArena profile uses `MAX_NUM_SEQS=4`. Running the usual
`c16/c24` bench against that profile overloaded the engine:

- `c16` produced repeated HTTP `500` responses from vLLM
- `c24` failed during warmup

The campaign script was corrected to run the strict profile at `c1/c4/c8` only
and to restore production automatically on any non-zero exit.

## Performance

Final clean run timestamp: `20260428_210942`.

| Concurrency | PP128 total | TG256 total | TG256 per request | Peak total | TTFR |
| --- | ---: | ---: | ---: | ---: | ---: |
| `c1` | `813.97 tok/s` | `53.33 tok/s` | n/a | `65.67 tok/s` | `205.84 ms` |
| `c4` | `1012.15 tok/s` | `149.15 tok/s` | `41.43 tok/s` | `194.33 tok/s` | `528.08 ms` |
| `c8` | `142.86 tok/s` | `151.22 tok/s` | `41.00 tok/s` | `201.33 tok/s` | `3391.34 ms` |

Read:

- decode is clearly strong at `c1/c4`
- `c8` keeps decode throughput but prefill/TTFR degrades heavily
- this is not a drop-in replacement for our high-concurrency batch profile

For comparison, the current RedHat NVFP4 sampler run reached:

- `c1` TG256: `38.32 tok/s`
- `c4` TG256 total: `101.13 tok/s`
- `c8` TG256 total: `123.00 tok/s`
- `c16` TG256 total: `234.31 tok/s`
- `c24` TG256 total: `296.35 tok/s`

## Quality

Full `tool-eval-bench` result:

| Model | Score | Points | Pass | Partial | Fail | Responsiveness | Deployability | Weakest |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| PrismaQuant SparkArena MTP k=3 | `88/100` | `122/138` | `56` | `10` | `3` | `55` | `78` | Autonomous Planning `67%` |
| RedHat NVFP4 current prod reference | `93/100` | `128/138` | `62` | `4` | `3` | `69` | `86` | Instruction Following `80%` |
| Prior PrismaQuant promo-quality | `90/100` | `124/138` | `59` | `6` | `4` | `73` | `85` | Structured Reasoning `67%` |

Non-pass scenarios:

- partial: `TC-11`, `TC-30`, `TC-35`, `TC-39`, `TC-46`, `TC-47`, `TC-51`,
  `TC-52`, `TC-56`, `TC-62`
- fail: `TC-43`, `TC-45`, `TC-60`

Read:

- `TC-62` remains partial, matching the earlier PrismaQuant weakness on long
  research chains.
- `TC-60` remains a shared sleeper-injection failure class.
- New concerning failures versus the NVFP4 current prod are `TC-43` and `TC-45`.
- Structured output was strong at `100%`, but autonomous planning regressed.

## French Quality

French run artifacts:

- prod reference: `eval-runs/fr_quality_prod_refresh_for_sparkarena_mtp3_20260428_210942.json`
- canary: `eval-runs/fr_quality_prismaquant_sparkarena_mtp3_20260428_210942.json`

Timing and length:

| Prompt | Prod NVFP4 | PrismaQuant SparkArena MTP |
| --- | ---: | ---: |
| analysis | `23.37s / 800 tok` | `17.19s / 800 tok` |
| synthesis | `3.87s / 130 tok` | `14.97s / 800 tok` |
| diplomacy | `3.06s / 102 tok` | `14.98s / 800 tok` |
| expression | `23.53s / 800 tok` | `15.52s / 800 tok` |

Read:

- long French generation is fast, but the profile tends to use the full token
  budget even for prompts where prod answered compactly.
- This is likely influenced by `preserve_thinking=true` and the Arena generation
  config.

## Memory

The memory guard stayed below the doctrine threshold:

- peak observed RAM: `91.60%`
- lowest observed available RAM: `10463 MiB`
- steady quality-run RAM: about `88.6%`, `14 GiB` available

## Recommendation

Do not promote this SparkArena MTP profile as-is.

It is useful as a throughput/long-context canary and confirms the value of
PrismaQuant + MTP for decode throughput. However:

- quality regresses versus current NVFP4 prod,
- `MAX_NUM_SEQS=4` does not match our batch/concurrency needs,
- `c16/c24` overloads this strict profile,
- French answers become too verbose under the Arena generation defaults.

Next useful test, if needed: isolate MTP on the previous promo-quality
PrismaQuant settings rather than adopting the full Arena long-context profile.
