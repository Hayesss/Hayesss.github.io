from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .job_store import JobPaths, create_job


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def create_derived_job(
    *,
    jobs_root: Path,
    parent_job_id: str,
    derived_type: str,
    parent_job_dir: Path,
    extra_params: dict[str, Any],
) -> tuple[JobPaths, dict[str, Any]]:
    paths = create_job(jobs_root)
    params: dict[str, Any] = {
        "job_id": paths.job_id,
        "parent_job_id": parent_job_id,
        "derived_type": derived_type,
        "parent_job_dir": str(parent_job_dir),
    }
    params.update(extra_params)
    return paths, params

