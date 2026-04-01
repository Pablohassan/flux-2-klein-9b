from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class ImageGenerationRequest(BaseModel):
    prompt: str
    negative_prompt: str = ""
    width: int = Field(default=1024, ge=256, le=2048)
    height: int = Field(default=1024, ge=256, le=2048)
    steps: int | None = Field(default=None, ge=1, le=100)
    guidance: float | None = Field(default=None, ge=0.0, le=20.0)
    seed: int | None = None
    response_mode: Literal["sync", "async"] = "sync"
    timeout_seconds: int = Field(default=600, ge=30, le=3600)


class JobRecord(BaseModel):
    id: str
    kind: Literal["generation"]
    status: Literal["queued", "running", "completed", "failed"]
    prompt_id: str | None = None
    result_path: str | None = None
    error: str | None = None


class JobResponse(BaseModel):
    id: str
    status: str
    prompt_id: str | None = None
    result_url: str | None = None
    error: str | None = None
