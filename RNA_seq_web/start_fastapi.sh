#!/bin/bash
set -euo pipefail

PORT="${PORT:-8000}"
HOST="${HOST:-0.0.0.0}"

echo "========================================="
echo "🧬 RNA-seq 分析平台 (FastAPI)"
echo "========================================="
echo ""
echo "访问地址: http://${HOST}:${PORT}"
echo "按 Ctrl+C 停止"
echo ""

if command -v conda >/dev/null 2>&1; then
  # 强制后端与所有 R 子进程使用 conda env 的 Rscript（避免误用 /opt/R/... 导致缺包）
  export RNA_SEQ_WEB_RSCRIPT="/home/zhs/miniforge3/envs/rna_seq_web/bin/Rscript"
  exec conda run -n rna_seq_web python -m uvicorn backend.main:app --host "${HOST}" --port "${PORT}"
else
  exec python -m uvicorn backend.main:app --host "${HOST}" --port "${PORT}"
fi

