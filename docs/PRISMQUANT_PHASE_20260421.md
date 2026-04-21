# PrismQuant Evaluation Phase - 2026-04-21

## Scope

This document summarizes the full evaluation phase around:

- `rdtand/Qwen3.6-35B-A3B-PrismQuant-4.75bit-vllm`
- DGX Spark / GB10
- `vLLM 0.19.2rc1.dev30`
- `FlashInfer 0.6.8`

The objective was to determine whether PrismQuant could become a realistic replacement candidate for the current FP8 production stack, with a particular focus on:

- throughput and latency
- tool-calling quality
- French analysis and writing quality
- suitability for the actual workload: text analysis, web search, and RAG

All canary runs followed the usual DGX Spark safety protocol:

1. pause gateway
2. drain traffic
3. stop local prod
4. verify prod is down
5. launch canary
6. test
7. stop canary
8. restore prod
9. verify prod health
10. reopen gateway

## Main Technical Path

The phase converged on the following serving path as the best PrismQuant candidate:

- `vLLM 0.19.2rc1.dev30+g2aab9acf4.d20260420`
- `FlashInfer 0.6.8`
- `flashinfer`
- `CutlassFP8ScaledMMLinearKernel` for `CompressedTensorsW8A8Fp8`
- response-side tool-call sanitizer
- SSE-aware incremental sanitization for streamed tool call arguments

This path matters because earlier PrismQuant runs showed that the model was promising, but quality issues remained around tool-call argument handling, especially on schema-constrained cases.

## Performance Summary

Compared against the drained production baseline, the best PrismQuant substrate showed:

| Concurrency | PP128 delta vs prod | TG256 delta vs prod | TTFR delta vs prod |
|---|---:|---:|---:|
| `c1`  | `+21.95%` | `-13.79%` | `-22.56%` |
| `c4`  | `-13.55%` | `-2.84%`  | `-0.36%`  |
| `c8`  | `+14.51%` | `+6.58%`  | `-18.10%` |
| `c16` | `+22.17%` | `+17.76%` | `-25.74%` |
| `c24` | `+25.33%` | `+28.66%` | `-22.75%` |

Interpretation:

- not a universal win at low concurrency
- clearly attractive from `c8` upward
- especially strong at medium/high concurrency

## Tool-Calling Quality

### Before the sanitizer

On the first full `tool-eval-bench` run, PrismQuant was close to production but slightly behind:

- production: `124/138`, score `90`
- PrismQuant: `123/138`, score `89`

The most visible regression cluster included:

- `TC-14`
- `TC-39`
- `TC-42`

### What was learned

- `TC-14` was model behavior, not runtime-specific
- `TC-42` was a schema/tool-call output issue
- parser-side filtering alone was not enough
- the benchmark evaluates the OpenAI-compatible `message.tool_calls` output
- the real fix had to happen on the response wire format, including SSE streaming

### After the sanitizer

The final promo-quality canary reached full parity with the production baseline on the complete benchmark:

- production baseline full run: `124/138`, score `90`
- PrismQuant promo-quality full run: `124/138`, score `90`

Net result:

- parity on aggregate score
- different tradeoff profile scenario-by-scenario

Improved scenarios vs production baseline:

- `TC-31`
- `TC-50`
- `TC-68`

Regressed scenarios vs production baseline:

- `TC-21`
- `TC-39`
- `TC-56`
- `TC-62`

However, targeted reruns showed that not all of those regressions are stable.

## Targeted Regression Isolation

Focused reruns were performed on:

- `TC-21`
- `TC-39`
- `TC-56`
- `TC-62`

Result:

| Scenario | Production | PrismQuant promo-quality | Read |
|---|---:|---:|---|
| `TC-21` | pass | pass | no persistent issue |
| `TC-39` | partial | pass | not a stable canary regression |
| `TC-56` | pass | pass | no persistent issue |
| `TC-62` | pass | partial | persistent weak point |

The practical conclusion is that the only credible remaining blocker is `TC-62`.

### What `TC-62` means

`TC-62` is a long, revision-sensitive, multi-step chain:

1. use internal information
2. account for a correction
3. pivot to competitor lookup
4. keep context stable across turns
5. finish with a final action

Production completes the chain.

The PrismQuant canary starts correctly but can drift into repeated internal-file steps and fail to reach the final CFO email action within the turn budget.

This is relevant for:

- long autonomous agent workflows
- complex multi-tool chaining
- revision-heavy task sequences

It is much less central for:

- text analysis
- direct web search
- RAG-style retrieve-read-summarize flows

## French Quality

A dedicated French evaluation set was run on both:

- production
- PrismQuant promo-quality canary

The comparison covered:

- technical analysis
- executive incident summary
- diplomatic disagreement
- explanatory writing

Observed result:

- French expression quality is broadly equivalent
- the canary is not weaker than production in French
- if anything, the canary sounds slightly more controlled and polished
- production is often a bit more expansive and more classroom-like

Important nuance:

- both models shared the same blind spot on a benchmark/drain prompt
- this looked like a shared reasoning miss, not a French fluency issue

## Fit For Actual Usage

The actual intended usage is mainly:

- text analysis
- web search as a tool
- RAG / retrieval-driven workflows

When read through that lens, the canary looks better than the raw full benchmark might suggest.

Relevant scenarios aligned with this usage were strong:

- `TC-07`
- `TC-13`
- `TC-20`
- `TC-33`
- `TC-52`
- `TC-55`
- `TC-57`
- `TC-58`

All of those passed in the full promo-quality canary run.

Only `TC-62` remained partially unresolved, and that scenario is more agentic and orchestration-heavy than the primary target workload.

## Final Read

At the end of this phase:

- PrismQuant became a serious candidate
- performance is attractive, especially at medium/high concurrency
- tool-calling reached aggregate parity with production
- French quality is equivalent
- the main remaining weakness is concentrated in one long-chain agentic scenario (`TC-62`)

## Recommendation

The outcome of this phase is:

- **not an automatic promotion**
- but **promotion is now defensible for the actual workload**

Recommended framing:

1. acceptable for text analysis, web search, and RAG-heavy usage
2. still not ideal to market as a fully reliable long-chain autonomous agent runtime
3. next targeted work should focus specifically on `TC-62`

In other words:

- for the real workload, the candidate is close enough to move forward cautiously
- for long multi-step autonomous chaining, more hardening is still needed
