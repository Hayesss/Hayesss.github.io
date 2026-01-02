from __future__ import annotations

import mimetypes
import os
from datetime import datetime
from pathlib import Path
from typing import Any

from fastapi import BackgroundTasks, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles

from .config import get_settings
from .derived_jobs import create_derived_job
from .job_store import create_job, read_status, safe_job_dir, write_status
from .r_runner import launch_r_job, run_r_action
from .schemas import JobCreateResponse, JobOutputItem, JobStatusResponse


app = FastAPI(title="RNA-seq Web (FastAPI)", version="0.1.0")
settings = get_settings()


def _list_outputs(job_id: str, job_dir: Path) -> list[JobOutputItem]:
    out_dir = job_dir / "output"
    if not out_dir.exists():
        return []
    items: list[JobOutputItem] = []
    for p in sorted(out_dir.glob("*")):
        if not p.is_file():
            continue
        size = 0
        try:
            size = p.stat().st_size
        except Exception:
            pass
        items.append(
            JobOutputItem(
                name=p.name,
                url=f"/api/jobs/{job_id}/outputs/{p.name}",
                size_bytes=size,
            )
        )
    return items


@app.get("/", response_class=HTMLResponse)
def index() -> HTMLResponse:
    index_path = settings.frontend_dir / "index.html"
    if not index_path.exists():
        return HTMLResponse(
            "<h3>frontend/index.html not found</h3>",
            status_code=500,
        )
    return HTMLResponse(index_path.read_text(encoding="utf-8"))


if settings.frontend_dir.exists():
    app.mount("/static", StaticFiles(directory=str(settings.frontend_dir)), name="static")


@app.get("/api/health")
def health() -> dict[str, Any]:
    return {
        "ok": True,
        "jobs_root": str(settings.jobs_root),
        "msigdb_dir": str(settings.msigdb_dir),
        "rscript": settings.rscript_path,
    }


@app.get("/api/genesets")
def list_genesets(species: str) -> dict[str, Any]:
    species = species.strip().lower()
    if species in ("homo sapiens", "human", "hs"):
        sub = "human"
    elif species in ("mus musculus", "mouse", "mm"):
        sub = "mouse"
    else:
        raise HTTPException(status_code=400, detail="species must be human or mouse")

    dir_path = settings.msigdb_dir / sub
    if not dir_path.exists():
        raise HTTPException(
            status_code=500,
            detail=f"MSigDB directory not found: {dir_path}. Set RNA_SEQ_WEB_MSIGDB_DIR to your local msigdb root.",
        )

    gmt_files = sorted([p.name for p in dir_path.glob("*.gmt") if p.is_file()])
    if not gmt_files:
        raise HTTPException(
            status_code=500,
            detail=f"No .gmt files under: {dir_path}. Please provide local MSigDB gmt files for {sub}.",
        )
    return {"species": sub, "files": gmt_files, "mode": "local"}

@app.post("/api/jobs", response_model=JobCreateResponse)
async def create_job_api(
    background_tasks: BackgroundTasks,
    count_file: UploadFile = File(...),
    metadata_file: UploadFile = File(...),
    # Core parameters
    min_count_filter: int = Form(10),
    design_var: str = Form(""),
    contrast_num: str = Form(""),
    contrast_denom: str = Form(""),
    padj_threshold: float = Form(0.05),
    lfc_threshold: float = Form(1.0),
    # Optional modules switches
    run_pca: bool = Form(True),
    run_deseq2: bool = Form(True),
    run_gsea: bool = Form(True),
    run_gsva: bool = Form(False),
    run_tf: bool = Form(False),
    run_heatmap: bool = Form(False),
    # Species / genesets
    species: str = Form("human"),
    gmt_file: str = Form(""),
    # Heatmap genes
    heatmap_genes: str = Form(""),
) -> JobCreateResponse:
    settings.jobs_root.mkdir(parents=True, exist_ok=True)
    paths = create_job(settings.jobs_root)

    # Save uploads (keep original extensions when possible)
    count_ext = Path(count_file.filename).suffix.lower() or ".csv"
    meta_ext = Path(metadata_file.filename).suffix.lower() or ".csv"
    count_dst = paths.input_dir / f"counts{count_ext}"
    meta_dst = paths.input_dir / f"metadata{meta_ext}"

    paths.input_dir.mkdir(parents=True, exist_ok=True)
    count_dst.write_bytes(await count_file.read())
    meta_dst.write_bytes(await metadata_file.read())

    params: dict[str, Any] = {
        "job_id": paths.job_id,
        "created_at": datetime.utcnow().isoformat() + "Z",
        "input": {
            "counts_path": str(count_dst),
            "metadata_path": str(meta_dst),
        },
        "min_count_filter": int(min_count_filter),
        "design_var": design_var,
        "contrast_num": contrast_num,
        "contrast_denom": contrast_denom,
        "padj_threshold": float(padj_threshold),
        "lfc_threshold": float(lfc_threshold),
        "modules": {
            "pca": bool(run_pca),
            "deseq2": bool(run_deseq2),
            "gsea": bool(run_gsea),
            "gsva": bool(run_gsva),
            "tf": bool(run_tf),
            "heatmap": bool(run_heatmap),
        },
        "species": species,
        "gmt_file": gmt_file,
        "heatmap_genes": heatmap_genes,
        "msigdb_dir": str(settings.msigdb_dir),
        "cache_dir": str(settings.cache_dir),
        "project_root": str(settings.project_root),
    }

    analysis_script = settings.project_root / "analysis" / "run_job.R"
    if not analysis_script.exists():
        raise HTTPException(status_code=500, detail=f"analysis script not found: {analysis_script}")

    background_tasks.add_task(
        launch_r_job,
        rscript=settings.rscript_path,
        analysis_script=analysis_script,
        job_dir=paths.job_dir,
        params=params,
        log_path=paths.run_log,
    )
    return JobCreateResponse(job_id=paths.job_id)


@app.get("/api/jobs/{job_id}", response_model=JobStatusResponse)
def get_job_status(job_id: str) -> JobStatusResponse:
    job_dir = safe_job_dir(settings.jobs_root, job_id)
    status = read_status(job_dir / "status.json")
    outputs = _list_outputs(job_id, job_dir)

    # Some actions (inplace plotting) store their state at top-level in status.json
    # due to legacy write_status() behavior (flattening "extra"). Normalize here so
    # frontend can always read st.extra.* consistently.
    extra_out: dict[str, Any] = {}
    if isinstance(status.get("extra"), dict):
        extra_out.update(status.get("extra") or {})
    for k in ("gsea_single_plot", "heatmap_from_gsea", "volcano_inplace"):
        if k not in extra_out and isinstance(status.get(k), dict):
            extra_out[k] = status[k]

    # #region agent log (debug-session)
    try:
        import json as _json
        from time import time as _time
        with open("/home/zhs/.cursor/debug.log", "a", encoding="utf-8") as _f:
            _f.write(
                _json.dumps(
                    {
                        "sessionId": "debug-session",
                        "runId": "backend",
                        "hypothesisId": "H",
                        "location": "backend/main.py:get_job_status",
                        "message": "status_extra_normalized",
                        "data": {
                            "jobId": job_id,
                            "hasExtraField": isinstance(status.get("extra"), dict),
                            "normalizedKeys": sorted(list(extra_out.keys()))[:20],
                            "outputsCount": len(outputs),
                        },
                        "timestamp": int(_time() * 1000),
                    },
                    ensure_ascii=False,
                )
                + "\n"
            )
    except Exception:
        pass
    # #endregion

    def parse_dt(s: Any) -> datetime | None:
        if not s or not isinstance(s, str):
            return None
        try:
            return datetime.fromisoformat(s.replace("Z", "+00:00"))
        except Exception:
            return None

    return JobStatusResponse(
        job_id=job_id,
        state=status.get("state", "error"),
        message=status.get("message"),
        created_at=parse_dt(status.get("created_at")),
        started_at=parse_dt(status.get("started_at")),
        finished_at=parse_dt(status.get("finished_at")),
        outputs=outputs,
        extra=extra_out if extra_out else None,
    )


@app.post("/api/jobs/{job_id}/volcano", response_model=JobCreateResponse)
def derive_volcano_job(
    job_id: str,
    background_tasks: BackgroundTasks,
    top_n: int = Form(10),
    mark_genes: str = Form(""),
) -> JobCreateResponse:
    parent_dir = safe_job_dir(settings.jobs_root, job_id)
    parent_out = parent_dir / "output" / "deseq2_results.csv"
    if not parent_out.exists():
        raise HTTPException(status_code=400, detail="parent job missing output/deseq2_results.csv")

    settings.jobs_root.mkdir(parents=True, exist_ok=True)
    paths, params = create_derived_job(
        jobs_root=settings.jobs_root,
        parent_job_id=job_id,
        derived_type="volcano",
        parent_job_dir=parent_dir,
        extra_params={
            "top_n": int(top_n),
            "mark_genes": mark_genes,
        },
    )

    analysis_script = settings.project_root / "analysis" / "plot_volcano.R"
    if not analysis_script.exists():
        raise HTTPException(status_code=500, detail=f"analysis script not found: {analysis_script}")

    background_tasks.add_task(
        launch_r_job,
        rscript=settings.rscript_path,
        analysis_script=analysis_script,
        job_dir=paths.job_dir,
        params=params,
        log_path=paths.run_log,
    )
    return JobCreateResponse(job_id=paths.job_id)


@app.post("/api/jobs/{job_id}/heatmap_from_gsea", response_model=JobCreateResponse)
def derive_heatmap_from_gsea_job(
    job_id: str,
    background_tasks: BackgroundTasks,
    pathway_id: str = Form(""),
    pathway_description: str = Form(""),
) -> JobCreateResponse:
    parent_dir = safe_job_dir(settings.jobs_root, job_id)
    parent_out = parent_dir / "output" / "gsea_results.csv"
    if not parent_out.exists():
        raise HTTPException(status_code=400, detail="parent job missing output/gsea_results.csv")
    if not pathway_id and not pathway_description:
        raise HTTPException(status_code=400, detail="pathway_id or pathway_description is required")

    settings.jobs_root.mkdir(parents=True, exist_ok=True)
    paths, params = create_derived_job(
        jobs_root=settings.jobs_root,
        parent_job_id=job_id,
        derived_type="heatmap_from_gsea",
        parent_job_dir=parent_dir,
        extra_params={
            "pathway_id": pathway_id,
            "pathway_description": pathway_description,
        },
    )

    analysis_script = settings.project_root / "analysis" / "plot_heatmap.R"
    if not analysis_script.exists():
        raise HTTPException(status_code=500, detail=f"analysis script not found: {analysis_script}")

    background_tasks.add_task(
        launch_r_job,
        rscript=settings.rscript_path,
        analysis_script=analysis_script,
        job_dir=paths.job_dir,
        params=params,
        log_path=paths.run_log,
    )
    return JobCreateResponse(job_id=paths.job_id)


@app.get("/api/jobs/{job_id}/outputs/{filename}")
def download_output_file(job_id: str, filename: str) -> FileResponse:
    job_dir = safe_job_dir(settings.jobs_root, job_id)
    out_path = (job_dir / "output" / filename).resolve()
    if (job_dir / "output").resolve() not in out_path.parents:
        raise HTTPException(status_code=400, detail="invalid filename")
    if not out_path.exists() or not out_path.is_file():
        raise HTTPException(status_code=404, detail="file not found")

    mime, _ = mimetypes.guess_type(out_path.name)
    return FileResponse(path=str(out_path), media_type=mime or "application/octet-stream", filename=out_path.name)


@app.post("/api/jobs/{job_id}/heatmap_from_gsea_inplace", response_model=JobCreateResponse)
def generate_heatmap_from_gsea_inplace(
    job_id: str,
    background_tasks: BackgroundTasks,
    pathway_id: str = Form(""),
    pathway_description: str = Form(""),
) -> JobCreateResponse:
    """
    就地生成热图（不创建新 job）：从父 job 的 GSEA 结果选择通路，
    在同一 job_dir/output/ 下生成/覆盖 heatmap.png。
    使用锁避免并发，用 status.json 的 extra 字段记录动作状态。
    """
    job_dir = safe_job_dir(settings.jobs_root, job_id)
    
    # 校验必需文件
    gsea_results = job_dir / "output" / "gsea_results.csv"
    gsea_core = job_dir / "output" / "gsea_core_genes.json"
    if not gsea_results.exists():
        raise HTTPException(status_code=400, detail="缺少 output/gsea_results.csv")
    if not gsea_core.exists():
        raise HTTPException(status_code=400, detail="缺少 output/gsea_core_genes.json")
    
    if not pathway_id and not pathway_description:
        raise HTTPException(status_code=400, detail="pathway_id 或 pathway_description 必须提供一个")
    
    # 并发锁：避免同时生成多个热图覆盖
    lock_file = job_dir / ".lock_heatmap"
    if lock_file.exists():
        raise HTTPException(status_code=409, detail="热图正在生成中，请稍后再试")
    
    # 写锁
    lock_file.write_text("locked", encoding="utf-8")
    
    # 准备参数（不覆盖主 params.json，单独写一个 heatmap_request.json）
    import json
    from datetime import datetime, timezone
    
    heatmap_req = {
        "job_id": job_id,
        "pathway_id": pathway_id,
        "pathway_description": pathway_description,
        "requested_at": datetime.now(timezone.utc).isoformat(),
    }
    heatmap_req_path = job_dir / "output" / "heatmap_request.json"
    heatmap_req_path.write_text(json.dumps(heatmap_req, ensure_ascii=False, indent=2), encoding="utf-8")
    
    # 更新 status.json 的 extra.heatmap_from_gsea（不改主状态）
    status_path = job_dir / "status.json"
    status = read_status(status_path)
    extra = status.get("extra", {}) if isinstance(status.get("extra"), dict) else {}
    extra["heatmap_from_gsea"] = {
        "state": "running",
        "message": "正在生成热图...",
        "started_at": datetime.now(timezone.utc).isoformat(),
    }
    write_status(
        status_path,
        state=status.get("state", "success"),
        message=status.get("message"),
        created_at=status.get("created_at"),
        started_at=status.get("started_at"),
        finished_at=status.get("finished_at"),
        extra=extra,
    )
    
    # 启动 R 脚本（新建一个 plot_heatmap_inplace.R）
    analysis_script = settings.project_root / "analysis" / "plot_heatmap_inplace.R"
    if not analysis_script.exists():
        lock_file.unlink(missing_ok=True)
        raise HTTPException(status_code=500, detail=f"分析脚本不存在: {analysis_script}")
    
    # 用一个临时 params 传给 R（禁止覆盖主 params.json）
    temp_params = {
        "job_id": job_id,
        "job_dir": str(job_dir),
        "pathway_id": pathway_id,
        "pathway_description": pathway_description,
    }

    def _run_and_cleanup() -> None:
        # 运行并等待（后台任务中阻塞，不影响请求线程）
        rc = 1
        try:
            rc = run_r_action(
                rscript=settings.rscript_path,
                analysis_script=analysis_script,
                job_dir=job_dir,
                params=temp_params,
                params_path=job_dir / "logs" / "heatmap_inplace_params.json",
                log_path=job_dir / "logs" / "heatmap_inplace.log",
            )
        finally:
            # 释放锁（即便失败也释放，允许重试）
            try:
                lock_file.unlink(missing_ok=True)
            except Exception:
                pass

        # 更新动作状态（不改主状态）
        st = read_status(status_path)
        ex = st.get("extra", {}) if isinstance(st.get("extra"), dict) else {}
        if rc == 0:
            ex["heatmap_from_gsea"] = {
                "state": "success",
                "message": "热图生成完成",
                "finished_at": datetime.now(timezone.utc).isoformat(),
                "outputs": ["heatmap.png", "heatmap_genes.csv"],
            }
        else:
            ex["heatmap_from_gsea"] = {
                "state": "error",
                "message": "热图生成失败（请查看 logs/heatmap_inplace.log）",
                "finished_at": datetime.now(timezone.utc).isoformat(),
            }
        write_status(
            status_path,
            state=st.get("state", "success"),
            message=st.get("message"),
            created_at=st.get("created_at"),
            started_at=st.get("started_at"),
            finished_at=st.get("finished_at"),
            extra=ex,
        )

    background_tasks.add_task(_run_and_cleanup)
    
    return JobCreateResponse(job_id=job_id)


@app.post("/api/jobs/{job_id}/gsea_single_plot_inplace", response_model=JobCreateResponse)
def gsea_single_plot_inplace(
    job_id: str,
    background_tasks: BackgroundTasks,
    pathway_id: str = Form(""),
    pathway_description: str = Form(""),
) -> JobCreateResponse:
    """
    就地生成单通路 GSEA 详细图（plotthis::GSEAPlot）：
    在同一 job_dir/output/ 下生成/覆盖 gsea_pathway_{id}.png，不创建新 job。
    """
    from datetime import datetime, timezone
    import re

    job_dir = safe_job_dir(settings.jobs_root, job_id)

    if not pathway_id and not pathway_description:
        raise HTTPException(status_code=400, detail="pathway_id 或 pathway_description 必须提供一个")

    # 校验依赖文件
    need = [
        job_dir / "output" / "gsea_results.csv",
        job_dir / "output" / "gsea_core_genes.json",
        job_dir / "output" / "deseq2_results.csv",
        job_dir / "params.json",
    ]
    missing = [p.name for p in need if not p.exists()]
    if missing:
        raise HTTPException(status_code=400, detail=f"缺少必要文件: {', '.join(missing)}")

    lock_file = job_dir / ".lock_gsea_single"
    if lock_file.exists():
        raise HTTPException(status_code=409, detail="单通路 GSEA 图正在生成中，请稍后再试")
    lock_file.write_text("locked", encoding="utf-8")

    safe_id = re.sub(r"[^A-Za-z0-9_-]", "_", pathway_id or pathway_description or "pathway")
    out_name = f"gsea_pathway_{safe_id}.png"

    status_path = job_dir / "status.json"
    st = read_status(status_path)
    ex = st.get("extra", {}) if isinstance(st.get("extra"), dict) else {}
    ex["gsea_single_plot"] = {
        "state": "running",
        "message": "正在生成单通路 GSEA 详细图...",
        "started_at": datetime.now(timezone.utc).isoformat(),
        "output": out_name,
        "pathway_id": pathway_id,
        "pathway_description": pathway_description,
    }
    write_status(
        status_path,
        state=st.get("state", "success"),
        message=st.get("message"),
        created_at=st.get("created_at"),
        started_at=st.get("started_at"),
        finished_at=st.get("finished_at"),
        extra=ex,
    )

    analysis_script = settings.project_root / "analysis" / "plot_gsea_single.R"
    if not analysis_script.exists():
        lock_file.unlink(missing_ok=True)
        raise HTTPException(status_code=500, detail=f"analysis script not found: {analysis_script}")

    params = {
        "job_id": job_id,
        "pathway_id": pathway_id,
        "pathway_description": pathway_description,
    }

    def _run_and_cleanup() -> None:
        rc = 1
        try:
            rc = run_r_action(
                rscript=settings.rscript_path,
                analysis_script=analysis_script,
                job_dir=job_dir,
                params=params,
                params_path=job_dir / "logs" / "gsea_single_params.json",
                log_path=job_dir / "logs" / "gsea_single.log",
            )
        finally:
            try:
                lock_file.unlink(missing_ok=True)
            except Exception:
                pass

        st2 = read_status(status_path)
        ex2 = st2.get("extra", {}) if isinstance(st2.get("extra"), dict) else {}
        if rc == 0 and (job_dir / "output" / out_name).exists():
            ex2["gsea_single_plot"] = {
                "state": "success",
                "message": "单通路 GSEA 图生成完成",
                "finished_at": datetime.now(timezone.utc).isoformat(),
                "output": out_name,
                "pathway_id": pathway_id,
                "pathway_description": pathway_description,
            }
        else:
            ex2["gsea_single_plot"] = {
                "state": "error",
                "message": "单通路 GSEA 图生成失败（请查看 logs/gsea_single.log）",
                "finished_at": datetime.now(timezone.utc).isoformat(),
                "output": out_name,
                "pathway_id": pathway_id,
                "pathway_description": pathway_description,
            }
        write_status(
            status_path,
            state=st2.get("state", "success"),
            message=st2.get("message"),
            created_at=st2.get("created_at"),
            started_at=st2.get("started_at"),
            finished_at=st2.get("finished_at"),
            extra=ex2,
        )

    background_tasks.add_task(_run_and_cleanup)
    return JobCreateResponse(job_id=job_id)


@app.post("/api/jobs/{job_id}/volcano_inplace", response_model=JobCreateResponse)
def volcano_inplace(
    job_id: str,
    background_tasks: BackgroundTasks,
    top_n: int = Form(10),
    mark_genes: str = Form(""),
) -> JobCreateResponse:
    """
    就地生成火山图增强版（TopN + 标记基因）：不创建新 job，
    在同一 job_dir/output/ 下生成 volcano_custom.png 等文件。
    """
    from datetime import datetime, timezone

    job_dir = safe_job_dir(settings.jobs_root, job_id)
    in_csv = job_dir / "output" / "deseq2_results.csv"
    if not in_csv.exists():
        raise HTTPException(status_code=400, detail="缺少 output/deseq2_results.csv（请先完成 DESeq2）")

    lock_file = job_dir / ".lock_volcano_inplace"
    if lock_file.exists():
        raise HTTPException(status_code=409, detail="火山图正在生成中，请稍后再试")
    lock_file.write_text("locked", encoding="utf-8")

    status_path = job_dir / "status.json"
    st = read_status(status_path)
    ex = st.get("extra", {}) if isinstance(st.get("extra"), dict) else {}
    ex["volcano_inplace"] = {
        "state": "running",
        "message": "正在生成火山图...",
        "started_at": datetime.now(timezone.utc).isoformat(),
        "outputs": ["volcano_custom.png"],
        "top_n": int(top_n),
        "mark_genes": mark_genes,
    }
    write_status(
        status_path,
        state=st.get("state", "success"),
        message=st.get("message"),
        created_at=st.get("created_at"),
        started_at=st.get("started_at"),
        finished_at=st.get("finished_at"),
        extra=ex,
    )

    analysis_script = settings.project_root / "analysis" / "plot_volcano_inplace.R"
    if not analysis_script.exists():
        lock_file.unlink(missing_ok=True)
        raise HTTPException(status_code=500, detail=f"analysis script not found: {analysis_script}")

    params = {"job_id": job_id, "top_n": int(top_n), "mark_genes": mark_genes}

    def _run_and_cleanup() -> None:
        rc = 1
        try:
            rc = run_r_action(
                rscript=settings.rscript_path,
                analysis_script=analysis_script,
                job_dir=job_dir,
                params=params,
                params_path=job_dir / "logs" / "volcano_inplace_params.json",
                log_path=job_dir / "logs" / "volcano_inplace.log",
            )
        finally:
            try:
                lock_file.unlink(missing_ok=True)
            except Exception:
                pass

        st2 = read_status(status_path)
        ex2 = st2.get("extra", {}) if isinstance(st2.get("extra"), dict) else {}
        if rc == 0 and (job_dir / "output" / "volcano_custom.png").exists():
            ex2["volcano_inplace"] = {
                "state": "success",
                "message": "火山图生成完成",
                "finished_at": datetime.now(timezone.utc).isoformat(),
                "outputs": ["volcano_custom.png", "volcano_custom_top_genes.csv", "volcano_custom_marked_genes.csv"],
                "top_n": int(top_n),
            }
        else:
            ex2["volcano_inplace"] = {
                "state": "error",
                "message": "火山图生成失败（请查看 logs/volcano_inplace.log）",
                "finished_at": datetime.now(timezone.utc).isoformat(),
                "outputs": ["volcano_custom.png"],
                "top_n": int(top_n),
            }
        write_status(
            status_path,
            state=st2.get("state", "success"),
            message=st2.get("message"),
            created_at=st2.get("created_at"),
            started_at=st2.get("started_at"),
            finished_at=st2.get("finished_at"),
            extra=ex2,
        )

    background_tasks.add_task(_run_and_cleanup)
    return JobCreateResponse(job_id=job_id)


@app.get("/api/jobs/{job_id}/log")
def get_job_log(job_id: str) -> FileResponse:
    job_dir = safe_job_dir(settings.jobs_root, job_id)
    log_path = job_dir / "logs" / "run.log"
    if not log_path.exists():
        raise HTTPException(status_code=404, detail="log not found")
    return FileResponse(path=str(log_path), media_type="text/plain", filename="run.log")


@app.get("/api/jobs/{job_id}/download")
def download_job_zip(job_id: str) -> FileResponse:
    import zipfile

    job_dir = safe_job_dir(settings.jobs_root, job_id)
    out_dir = job_dir / "output"
    if not out_dir.exists():
        raise HTTPException(status_code=404, detail="output not found")
    zip_path = job_dir / "output.zip"
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for p in sorted(out_dir.rglob("*")):
            if p.is_file():
                zf.write(p, arcname=str(p.relative_to(job_dir)))
        status_path = job_dir / "status.json"
        if status_path.exists():
            zf.write(status_path, arcname="status.json")
        params_path = job_dir / "params.json"
        if params_path.exists():
            zf.write(params_path, arcname="params.json")
        log_path = job_dir / "logs" / "run.log"
        if log_path.exists():
            zf.write(log_path, arcname="logs/run.log")
    return FileResponse(path=str(zip_path), media_type="application/zip", filename=f"{job_id}.zip")

