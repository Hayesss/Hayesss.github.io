from __future__ import annotations

from datetime import datetime
from pydantic import BaseModel, Field
from typing import Any
from typing import Literal


JobState = Literal["queued", "running", "success", "error"]


class JobCreateResponse(BaseModel):
    job_id: str


class JobOutputItem(BaseModel):
    name: str
    url: str
    size_bytes: int = 0


class JobStatusResponse(BaseModel):
    job_id: str
    state: JobState
    message: str | None = None
    created_at: datetime | None = None
    started_at: datetime | None = None
    finished_at: datetime | None = None
    outputs: list[JobOutputItem] = Field(default_factory=list)
    extra: dict[str, Any] | None = None

