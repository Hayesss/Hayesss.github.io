from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any


def launch_r_job(
    *,
    rscript: str,
    analysis_script: Path,
    job_dir: Path,
    params: dict[str, Any],
    log_path: Path,
) -> None:
    """
    Fire-and-forget: starts an Rscript subprocess and returns immediately.
    The R script is responsible for updating status.json in job_dir.
    """
    analysis_script = analysis_script.resolve()
    job_dir = job_dir.resolve()

    params_json = job_dir / "params.json"
    params_json.write_text(json.dumps(params, ensure_ascii=False, indent=2), encoding="utf-8")

    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_f = log_path.open("ab", buffering=0)

    try:
        subprocess.Popen(
            [
                rscript,
                str(analysis_script),
                "--job_dir",
                str(job_dir),
                "--params",
                str(params_json),
            ],
            stdout=log_f,
            stderr=subprocess.STDOUT,
            cwd=str(job_dir),
            close_fds=True,
        )
    finally:
        # Child inherits the fd; we can close our reference.
        try:
            log_f.close()
        except Exception:
            pass


def run_r_action(
    *,
    rscript: str,
    analysis_script: Path,
    job_dir: Path,
    params: dict[str, Any],
    params_path: Path,
    log_path: Path,
) -> int:
    """
    Run-and-wait: runs an Rscript subprocess and waits until it finishes.

    Unlike launch_r_job(), this will NOT overwrite job_dir/params.json.
    It writes params to the given params_path, and passes it via --params.
    """
    analysis_script = analysis_script.resolve()
    job_dir = job_dir.resolve()
    params_path = params_path.resolve()

    params_path.parent.mkdir(parents=True, exist_ok=True)
    params_path.write_text(json.dumps(params, ensure_ascii=False, indent=2), encoding="utf-8")

    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("ab", buffering=0) as log_f:
        proc = subprocess.run(
            [
                rscript,
                str(analysis_script),
                "--job_dir",
                str(job_dir),
                "--params",
                str(params_path),
            ],
            stdout=log_f,
            stderr=subprocess.STDOUT,
            cwd=str(job_dir),
            close_fds=True,
        )
        return int(proc.returncode)

