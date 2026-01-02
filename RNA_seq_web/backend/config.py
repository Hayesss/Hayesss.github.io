from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import os


@dataclass(frozen=True)
class Settings:
    project_root: Path
    jobs_root: Path
    frontend_dir: Path
    msigdb_dir: Path
    cache_dir: Path
    rscript_path: str


def get_settings() -> Settings:
    project_root = Path(__file__).resolve().parents[1]
    jobs_root = Path(os.environ.get("RNA_SEQ_WEB_JOBS_ROOT", project_root / "var" / "jobs")).resolve()
    frontend_dir = Path(os.environ.get("RNA_SEQ_WEB_FRONTEND_DIR", project_root / "frontend")).resolve()
    msigdb_dir = Path(os.environ.get("RNA_SEQ_WEB_MSIGDB_DIR", project_root / "msigdb")).resolve()
    cache_dir = Path(os.environ.get("RNA_SEQ_WEB_CACHE_DIR", project_root / "cache")).resolve()
    rscript_path = os.environ.get("RNA_SEQ_WEB_RSCRIPT", "Rscript")

    return Settings(
        project_root=project_root,
        jobs_root=jobs_root,
        frontend_dir=frontend_dir,
        msigdb_dir=msigdb_dir,
        cache_dir=cache_dir,
        rscript_path=rscript_path,
    )

