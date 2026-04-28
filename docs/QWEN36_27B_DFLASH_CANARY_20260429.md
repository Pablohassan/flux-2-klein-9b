# Qwen3.6 27B DFlash Canary - 2026-04-29

## Scope

Tested `z-lab/Qwen3.6-27B-DFlash` as a DFlash drafter for the local target:

- target: `/models/Qwen3.6-27B-FP8-latest-20260423`
- drafter: `/models/Qwen3.6-27B-DFlash`
- image: `vllm-node-tf5`
- served model name: `qwen36-27b-fp8-dflash`
- speculative config:
  `{"method":"dflash","model":"/models/Qwen3.6-27B-DFlash","num_speculative_tokens":15}`
- attention backend: `flash_attn`
- KV cache dtype: `auto`
- KV cache reservation: `11811160064` bytes
- max model len: `32768`
- max batched tokens: `32768`
- max seqs: `44`

The campaign followed the DGX Spark safety workflow: bench mode, drain, stop
local NVFP4 production, launch canary, stop canary, restore local NVFP4
production, disable bench mode.

Production was restored successfully and gateway health returned `ok=true`.

## Setup Findings

The DFlash repo is gated on Hugging Face. Download succeeded after access was
approved for the local `pablohassan` account.

The first backend attempts were useful but not viable:

| Attempt | Result |
| --- | --- |
| `flashinfer` + fp8 KV | vLLM rejected backend: non-causal attention not supported |
| `flash_attn` + fp8 KV | vLLM rejected backend: KV cache dtype not supported |
| `flash_attn` + `auto` KV | canary started and became healthy |

The final viable configuration loaded both target and drafter:

- target weights load: about `22-25s` after cache warm
- drafter weights load: about `1-3s`
- combined model memory reported by vLLM: `31.02 GiB`
- compile/profiling first run was long but completed
- DFlash auxiliary layers detected: `(1, 16, 31, 46, 61)`

Important capacity warning from vLLM with `auto` KV and 11GB reserved:

- GPU KV cache size: `38,016` tokens
- maximum concurrency for `32,768` tokens/request: `1.85x`

This does not match our long-context + high-concurrency doctrine.

## Benchmark

Clean partial run timestamp: `20260429_001244`.

The run was stopped after `c4`. Continuing to `c8/c16/c24` and then full
quality would have monopolized the box for little value because decode was
already far below production.

| Concurrency | PP128 total | TG256 total | TG256 per request | Peak total | Peak per request | TTFR |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `c1` | `547.73 ± 24.85 tok/s` | `13.29 ± 2.54 tok/s` | n/a | `38.33 ± 23.84 tok/s` | n/a | `236.58 ± 10.81 ms` |
| `c4` | `660.27 ± 125.23 tok/s` | `28.73 ± 2.98 tok/s` | `8.07 ± 0.75 tok/s` | `48.00 ± 2.94 tok/s` | `17.25 ± 3.54 tok/s` | `566.38 ± 234.55 ms` |
| `c8` | not run | not run | not run | not run | not run | not run |
| `c16` | not run | not run | not run | not run | not run | not run |
| `c24` | not run | not run | not run | not run | not run | not run |

For comparison, current RedHat NVFP4 prod reference reached:

| Concurrency | PP128 total | TG256 total | TG256 per request | Peak total | Peak per request | TTFR |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `c1` | `1457.16 ± 47.86 tok/s` | `38.32 ± 0.18 tok/s` | n/a | `40.00 ± 0.00 tok/s` | n/a | `90.94 ± 2.82 ms` |
| `c4` | `2798.71 ± 390.87 tok/s` | `101.13 ± 24.09 tok/s` | `27.45 ± 3.81 tok/s` | `128.00 ± 16.97 tok/s` | `32.25 ± 3.96 tok/s` | `165.24 ± 23.08 ms` |
| `c8` | `3769.49 ± 606.96 tok/s` | `123.00 ± 1.98 tok/s` | `19.29 ± 1.27 tok/s` | `153.33 ± 9.43 tok/s` | `23.54 ± 2.56 tok/s` | `252.88 ± 49.58 ms` |
| `c16` | `4321.32 ± 154.92 tok/s` | `234.31 ± 4.71 tok/s` | `15.83 ± 0.48 tok/s` | `277.33 ± 16.76 tok/s` | `19.21 ± 1.24 tok/s` | `430.74 ± 107.18 ms` |
| `c24` | `5174.63 ± 465.25 tok/s` | `296.35 ± 9.46 tok/s` | `13.89 ± 0.31 tok/s` | `348.00 ± 8.64 tok/s` | `16.02 ± 0.66 tok/s` | `573.32 ± 109.03 ms` |

## Quality

Full `tool-eval-bench` was intentionally not run.

Reason: DFlash decode was already only `13.29 tok/s` at `c1` and `28.73 tok/s`
total at `c4`. A full tool quality pass would be slow enough to provide little
additional value after the benchmark disqualified the profile for our stated
goal of reasonable speed.

French production reference was captured before the canary launches:

- `eval-runs/fr_quality_prod_refresh_for_dflash_20260429_001244.json`

No DFlash French quality result was produced because the canary was stopped
before the quality phase.

## Memory

The memory guard did not trigger.

Observed peak during the final partial run:

- peak RAM: about `74%` on earlier successful-start run, `68%` during final
  measured run
- lowest available RAM during final measured run: about `39 GiB`

## Recommendation

Do not pursue this exact profile for production or promotion.

It proves that DFlash can start locally with the right backend combination, but
the measured decode speed is far below current NVFP4 production and the KV
capacity collapses when switching away from fp8 KV to satisfy `flash_attn`.

Potential future work only if DFlash upstream changes materially:

- test with a native non-FP8 target matching `Qwen/Qwen3.6-27B`,
- retest on a newer vLLM/DFlash build where `flashinfer` or fp8 KV is supported
  for this attention path,
- reduce `num_speculative_tokens` from `15` only as a diagnostic, not as a
  likely production path.
