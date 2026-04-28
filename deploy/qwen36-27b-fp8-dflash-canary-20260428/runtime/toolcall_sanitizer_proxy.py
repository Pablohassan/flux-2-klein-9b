#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from typing import Any

import httpx
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse, PlainTextResponse, StreamingResponse


BACKEND_BASE = os.environ.get("INTERNAL_VLLM_BASE", "http://127.0.0.1:18031").rstrip("/")
PUBLIC_HOST = os.environ.get("VLLM_BIND_HOST", "127.0.0.1")
PUBLIC_PORT = int(os.environ.get("VLLM_PORT", "18030"))

app = FastAPI()
client = httpx.AsyncClient(timeout=httpx.Timeout(600.0))


def _tool_schema_map(tools: list[dict[str, Any]] | None) -> dict[str, set[str]]:
    out: dict[str, set[str]] = {}
    for tool in tools or []:
        fn = tool.get("function") or {}
        name = fn.get("name")
        params = fn.get("parameters") or {}
        props = params.get("properties") or {}
        if name and isinstance(props, dict):
            out[name] = set(props.keys())
    return out


def _sanitize_tool_calls(tool_calls: list[dict[str, Any]] | None, allowed: dict[str, set[str]]) -> None:
    if not tool_calls:
        return
    for call in tool_calls:
        fn = call.get("function") or {}
        name = fn.get("name")
        if not name or name not in allowed:
            continue
        args = fn.get("arguments")
        if isinstance(args, str):
            try:
                parsed = json.loads(args)
            except Exception:
                continue
        elif isinstance(args, dict):
            parsed = args
        else:
            continue
        if not isinstance(parsed, dict):
            continue
        filtered = {k: v for k, v in parsed.items() if k in allowed[name]}
        if isinstance(args, str):
            fn["arguments"] = json.dumps(filtered, ensure_ascii=True, separators=(",", ":"))
        else:
            fn["arguments"] = filtered


def _sanitize_json_payload(payload: dict[str, Any], allowed: dict[str, set[str]]) -> dict[str, Any]:
    choices = payload.get("choices") or []
    for choice in choices:
        message = choice.get("message") or {}
        _sanitize_tool_calls(message.get("tool_calls"), allowed)
    return payload


def _sanitize_stream_chunk(payload: dict[str, Any], allowed: dict[str, set[str]]) -> dict[str, Any]:
    choices = payload.get("choices") or []
    for choice in choices:
        delta = choice.get("delta") or {}
        _sanitize_tool_calls(delta.get("tool_calls"), allowed)
    return payload


def _sanitize_stream_chunk_incremental(
    payload: dict[str, Any],
    allowed: dict[str, set[str]],
    state: dict[int, dict[str, str]],
) -> dict[str, Any]:
    choices = payload.get("choices") or []
    for choice in choices:
        delta = choice.get("delta") or {}
        tool_calls = delta.get("tool_calls") or []
        for tc_delta in tool_calls:
            idx = tc_delta.get("index", 0)
            current = state.setdefault(idx, {"name": "", "raw": "", "sent": ""})
            func = tc_delta.get("function") or {}
            if func.get("name"):
                current["name"] = func["name"]
            frag = func.get("arguments")
            if frag is None:
                continue
            current["raw"] += frag
            name = current["name"]
            try:
                parsed = json.loads(current["raw"])
            except Exception:
                func["arguments"] = ""
                continue
            if not isinstance(parsed, dict) or not name or name not in allowed:
                func["arguments"] = current["raw"][len(current["sent"]):]
                current["sent"] = current["raw"]
                continue
            filtered = {k: v for k, v in parsed.items() if k in allowed[name]}
            sanitized = json.dumps(filtered, ensure_ascii=True, separators=(",", ":"))
            if sanitized.startswith(current["sent"]):
                func["arguments"] = sanitized[len(current["sent"]):]
            else:
                func["arguments"] = sanitized
            current["sent"] = sanitized
    return payload


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"])
async def proxy(path: str, request: Request) -> Response:
    url = f"{BACKEND_BASE}/{path}"
    body = await request.body()
    headers = {k: v for k, v in request.headers.items() if k.lower() != "host"}

    allowed: dict[str, set[str]] = {}
    if request.method in {"POST", "PUT", "PATCH"} and body:
        try:
            req_json = json.loads(body)
            allowed = _tool_schema_map(req_json.get("tools"))
        except Exception:
            allowed = {}

    backend_request = client.build_request(
        request.method,
        url,
        params=request.query_params,
        headers=headers,
        content=body,
    )
    backend_response = await client.send(backend_request, stream=True)

    content_type = backend_response.headers.get("content-type", "")

    if "text/event-stream" in content_type:
        stream_state: dict[int, dict[str, str]] = {}

        async def stream() -> Any:
            async for line in backend_response.aiter_lines():
                if not line.startswith("data: "):
                    yield (line + "\n").encode("utf-8")
                    continue
                raw = line[6:]
                if raw.strip() == "[DONE]":
                    yield b"data: [DONE]\n\n"
                    continue
                try:
                    payload = json.loads(raw)
                    payload = _sanitize_stream_chunk_incremental(payload, allowed, stream_state)
                    yield f"data: {json.dumps(payload, ensure_ascii=True, separators=(',', ':'))}\n\n".encode("utf-8")
                except Exception:
                    yield (line + "\n").encode("utf-8")
            await backend_response.aclose()

        passthrough_headers = {
            k: v for k, v in backend_response.headers.items()
            if k.lower() not in {"content-length", "content-encoding", "transfer-encoding", "connection"}
        }
        return StreamingResponse(stream(), status_code=backend_response.status_code, headers=passthrough_headers, media_type="text/event-stream")

    raw_content = await backend_response.aread()
    await backend_response.aclose()

    if "application/json" in content_type:
        try:
            payload = json.loads(raw_content)
            payload = _sanitize_json_payload(payload, allowed)
            passthrough_headers = {
                k: v for k, v in backend_response.headers.items()
                if k.lower() not in {"content-length", "content-encoding", "transfer-encoding", "connection"}
            }
            return JSONResponse(payload, status_code=backend_response.status_code, headers=passthrough_headers)
        except Exception:
            pass

    passthrough_headers = {
        k: v for k, v in backend_response.headers.items()
        if k.lower() not in {"content-length", "content-encoding", "transfer-encoding", "connection"}
    }
    return Response(content=raw_content, status_code=backend_response.status_code, headers=passthrough_headers, media_type=content_type or None)


@app.on_event("shutdown")
async def shutdown_event() -> None:
    await client.aclose()


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host=PUBLIC_HOST, port=PUBLIC_PORT, log_level="info")
