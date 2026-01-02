from __future__ import annotations

import json
import os
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass(frozen=True)
class JobPaths:
    job_id: str
    job_dir: Path
    input_dir: Path
    output_dir: Path
    logs_dir: Path
    params_json: Path
    status_json: Path
    run_log: Path


def create_job(jobs_root: Path) -> JobPaths:
    job_id = uuid.uuid4().hex
    job_dir = jobs_root / job_id
    input_dir = job_dir / "input"
    output_dir = job_dir / "output"
    logs_dir = job_dir / "logs"

    input_dir.mkdir(parents=True, exist_ok=False)
    output_dir.mkdir(parents=True, exist_ok=False)
    logs_dir.mkdir(parents=True, exist_ok=False)

    paths = JobPaths(
        job_id=job_id,
        job_dir=job_dir,
        input_dir=input_dir,
        output_dir=output_dir,
        logs_dir=logs_dir,
        params_json=job_dir / "params.json",
        status_json=job_dir / "status.json",
        run_log=logs_dir / "run.log",
    )

    write_status(
        paths.status_json,
        state="queued",
        message="queued",
        created_at=_utc_now(),
        started_at=None,
        finished_at=None,
    )
    return paths


def write_status(status_path: Path, *, state: str, message: str | None, created_at: str | None, started_at: str | None, finished_at: str | None, extra: dict[str, Any] | None = None) -> None:
    payload: dict[str, Any] = {
        "state": state,
        "message": message,
        "created_at": created_at,
        "started_at": started_at,
        "finished_at": finished_at,
    }
    if extra:
        payload.update(extra)
    tmp = status_path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(tmp, status_path)


def read_status(status_path: Path) -> dict[str, Any]:
    if not status_path.exists():
        return {"state": "error", "message": "status.json not found"}
    try:
        return json.loads(status_path.read_text(encoding="utf-8"))
    except Exception as e:
        return {"state": "error", "message": f"failed to read status.json: {e}"}


def safe_job_dir(jobs_root: Path, job_id: str) -> Path:
    if not job_id or any(ch in job_id for ch in ("/", "\\", "..")):
        raise ValueError("invalid job_id")
    job_dir = (jobs_root / job_id).resolve()
    jobs_root_resolved = jobs_root.resolve()
    if jobs_root_resolved not in job_dir.parents:
        raise ValueError("invalid job_id")
    return job_dir

