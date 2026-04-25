# Monica TTS Gateway Integration - 2026-04-25

## Decision

Expose the existing `monica-tts` container through the local multimodel gateway
so the TTS service is part of the visible stack instead of running as an
untracked side service.

The TTS backend remains a separate container:

- container: `monica-tts`
- image: `monica-tts:latest`
- internal service URL: `http://127.0.0.1:8080`
- backend endpoint: `POST /blabla`
- health endpoint: `GET /health`
- model id exposed by the gateway: `monica-tts`

## Runtime Model

The Monica service uses `ResembleAI/chatterbox` from the Docker volume
`chatterbox_hf_cache`, mounted in the container at `/app/hf_cache`.

The Monica voice identity is provided by the reference audio:

- `/app/26-monica--interview.wav`
- `/app/hf_cache/monica_reference_120s.wav`

Health observed before gateway integration:

```json
{
  "status": "ok",
  "device": "cuda",
  "model_loaded": true,
  "default_voice_preset": "p2_seed77",
  "available_voice_presets": ["p2_seed77", "p5_seed11"]
}
```

## Gateway Changes

Local runtime changes applied in `deploy/qwen-multimodel-v018`:

- router env:
  - `BACKEND_TTS_URL=http://127.0.0.1:8080`
  - `MODEL_TTS=monica-tts`
- `.env`:
  - `TTS_PORT=8080`
  - `TTS_MODEL_NAME=monica-tts`
- router app:
  - `monica-tts` included in `/health`
  - `monica-tts` included in `/v1/models`
  - `POST /v1/audio/speech` routed to `monica-tts:/blabla`
  - `POST /blabla` also routed through the gateway for compatibility

The active gateway deploy directory is ignored by git in this repository, so
this document records the runtime integration point.

## Client Contract

OpenAI-style TTS route through the gateway:

```bash
curl -X POST http://127.0.0.1:8088/v1/audio/speech \
  -H 'Content-Type: application/json' \
  -d '{"model":"monica-tts","input":"Test Monica gateway.","voice":"p2_seed77"}' \
  -o monica.wav
```

Compatibility route:

```bash
curl -X POST http://127.0.0.1:8088/blabla \
  -H 'Content-Type: application/json' \
  -d '{"text":"Test Monica gateway.","voice_preset":"p2_seed77"}' \
  -o monica.wav
```

## Validation

Gateway was rebuilt and restarted with bench mode active, then bench mode was
disabled after validation.

Final gateway health:

```json
{
  "ok": true,
  "backends": {
    "qwen35a3b-prod": true,
    "qwen35a3b-batch": true,
    "qwen3-embedding-8b": true,
    "qwen3-reranker-8b": true,
    "reranker-fast": true,
    "qwen3.5-2b": true,
    "qwen3.5-4b": true,
    "monica-tts": true
  }
}
```

Smoke test result:

- route: `POST /v1/audio/speech`
- response: `HTTP 200`
- routed backend: `tts:http://127.0.0.1:8080`
- output: WAV PCM, mono, 24 kHz
- output size: `77324` bytes
- generation time: `2.31s`

