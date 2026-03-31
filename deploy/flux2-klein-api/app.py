from __future__ import annotations

import asyncio
import base64
import io
import os
import secrets
from pathlib import Path

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import FileResponse
from PIL import Image

from models import ImageEditRequest, ImageGenerationRequest, JobRecord, JobResponse
from runtime import load_runtime_from_env


API_KEY = os.getenv("API_KEY", "")
API_PORT = int(os.getenv("API_PORT", "18291"))
OUTPUTS_DIR = Path(os.environ["OUTPUTS_DIR"])

app = FastAPI(title="flux2-klein-api", version="0.2.0")
runtime = load_runtime_from_env()
JOBS: dict[str, JobRecord] = {}


async def require_api_key(x_api_key: str | None = Header(default=None)) -> None:
    if API_KEY and x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="invalid api key")


def job_result_url(job_id: str) -> str:
    return f"http://127.0.0.1:{API_PORT}/v1/images/jobs/{job_id}/result"


def decode_image(data: str) -> Image.Image:
    return Image.open(io.BytesIO(base64.b64decode(data))).convert("RGB")


async def execute_job(
    job_id: str,
    *,
    kind: str,
    prompt: str,
    width: int,
    height: int,
    steps: int | None,
    guidance: float | None,
    seed: int | None,
    input_images: list[Image.Image] | None = None,
) -> None:
    record = JOBS[job_id]
    record.status = "running"
    record.prompt_id = job_id
    try:
        result_path = await asyncio.to_thread(
            runtime.generate,
            prompt=prompt,
            width=width,
            height=height,
            steps=steps,
            guidance=guidance,
            seed=seed,
            input_images=input_images,
            output_prefix=job_id,
        )
        record.result_path = str(result_path)
        record.status = "completed"
    except Exception as exc:  # noqa: BLE001
        record.status = "failed"
        record.error = str(exc)


@app.get("/health")
async def health() -> dict:
    try:
        loaded = runtime._loaded
        return {"ok": True, "loaded": loaded}
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": str(exc)}


@app.post("/v1/images/generations", response_model=JobResponse)
async def create_generation(
    request: ImageGenerationRequest,
    _: None = Depends(require_api_key),
) -> JobResponse:
    job_id = secrets.token_hex(8)
    JOBS[job_id] = JobRecord(id=job_id, kind="generation", status="queued")
    if request.response_mode == "sync":
        await execute_job(
            job_id,
            kind="generation",
            prompt=request.prompt,
            width=request.width,
            height=request.height,
            steps=request.steps,
            guidance=request.guidance,
            seed=request.seed,
        )
    else:
        asyncio.create_task(
            execute_job(
                job_id,
                kind="generation",
                prompt=request.prompt,
                width=request.width,
                height=request.height,
                steps=request.steps,
                guidance=request.guidance,
                seed=request.seed,
            )
        )
    record = JOBS[job_id]
    return JobResponse(
        id=record.id,
        status=record.status,
        prompt_id=record.prompt_id,
        result_url=job_result_url(job_id) if record.result_path else None,
        error=record.error,
    )


@app.post("/v1/images/edits", response_model=JobResponse)
async def create_edit(
    request: ImageEditRequest,
    _: None = Depends(require_api_key),
) -> JobResponse:
    job_id = secrets.token_hex(8)
    JOBS[job_id] = JobRecord(id=job_id, kind="edit", status="queued")
    input_images = [decode_image(request.image_base64)]
    if request.response_mode == "sync":
        await execute_job(
            job_id,
            kind="edit",
            prompt=request.prompt,
            width=request.width,
            height=request.height,
            steps=request.steps,
            guidance=request.guidance,
            seed=request.seed,
            input_images=input_images,
        )
    else:
        asyncio.create_task(
            execute_job(
                job_id,
                kind="edit",
                prompt=request.prompt,
                width=request.width,
                height=request.height,
                steps=request.steps,
                guidance=request.guidance,
                seed=request.seed,
                input_images=input_images,
            )
        )
    record = JOBS[job_id]
    return JobResponse(
        id=record.id,
        status=record.status,
        prompt_id=record.prompt_id,
        result_url=job_result_url(job_id) if record.result_path else None,
        error=record.error,
    )


@app.get("/v1/images/jobs/{job_id}", response_model=JobResponse)
async def get_job(job_id: str, _: None = Depends(require_api_key)) -> JobResponse:
    record = JOBS.get(job_id)
    if record is None:
        raise HTTPException(status_code=404, detail="job not found")
    return JobResponse(
        id=record.id,
        status=record.status,
        prompt_id=record.prompt_id,
        result_url=job_result_url(job_id) if record.result_path else None,
        error=record.error,
    )


@app.get("/v1/images/jobs/{job_id}/result")
async def get_job_result(job_id: str, _: None = Depends(require_api_key)) -> FileResponse:
    record = JOBS.get(job_id)
    if record is None:
        raise HTTPException(status_code=404, detail="job not found")
    if record.status != "completed" or not record.result_path:
        raise HTTPException(status_code=409, detail="job not completed")
    return FileResponse(record.result_path, media_type="image/png")
