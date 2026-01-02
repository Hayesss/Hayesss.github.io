## RNA-seq 分析平台（FastAPI 后端 + 原生 Web 前端）

本项目将 RNA-seq 的常用分析流程（PCA / DESeq2 / GSEA / GSVA / TF / 热图）封装为 **Job-ID 异步任务**：

- **后端**：FastAPI
- **前端**：原生 HTML/CSS/JS
- **并发**：每次提交生成一个 `job_id`，后台用 FastAPI `BackgroundTasks` **启动独立 R 子进程**执行分析（不使用 Celery）
- **物种**：仅支持 **human/mouse**

### 目录结构

- `backend/`：FastAPI API
- `frontend/`：原生前端（由后端静态托管）
- `analysis/`：R CLI 流水线
  - `analysis/run_job.R`：R 子进程入口（读取 params.json -> 生成 output/ -> 写 status.json）
  - `analysis/lib.R`：公共函数
- `var/jobs/{job_id}/`：每个任务的独立工作目录（输入/输出/日志/状态）
- `data/input/`：示例输入数据

---

## 快速开始

### 1) 创建 conda 环境

在 `RNA_seq_web/` 目录下：

```bash
conda env create -f environment.yml
conda activate rna_seq_web
```

### 2) 补齐可选 R 包（建议执行一次）

```bash
conda activate rna_seq_web
Rscript scripts/install_r_extra.R
```

> `TF(decoupleR/OmnipathR)` 与 `plotthis` 等包在不同平台上 conda 可用性不一致，所以提供了该脚本兜底。

### 2.5) 下载 TF 网络文件（可选，但建议执行）

如果计划使用 TF 分析功能，建议预先下载网络文件到本地：

```bash
conda activate rna_seq_web
Rscript scripts/download_tf_networks.R [cache_dir]
```

> 默认保存到 `cache/` 目录。下载的网络文件包括：
> - `collectri_human.rds` / `collectri_mouse.rds`
> - `dorothea_human_*.rds` / `dorothea_mouse_*.rds` (不同置信度级别)
>
> 这些文件会被自动缓存，避免每次分析时重新下载。如果网络与表达矩阵交集为空，系统会自动尝试降低 `minsize` 参数。

### 3) 启动服务

```bash
./start_fastapi.sh
# 默认 http://0.0.0.0:8000
```

浏览器打开 `http://localhost:8000`。

---

## 使用说明

### 提交任务

在页面上传：
- **counts**：第一列基因名（Gene Symbol），其余列为样本计数
- **metadata**：第一列样本名（需与 counts 列名一致），其余列为分组变量

选择：
- `species`：human / mouse
- `design_var`：从 metadata 的列中选择
- `contrast_num` / `contrast_denom`：处理组/对照组

提交后会返回 `job_id`。

### 查询任务

- 页面会自动轮询 `/api/jobs/{job_id}`
- 也可手动输入 `job_id` 查询

### 输出文件

分析完成后，输出写入：`var/jobs/{job_id}/output/`，常见包括：
- `pca_plot.png`
- `deseq2_results.csv`
- `deg_filtered.csv`
- `volcano_plot.png`
- `gsea_results.csv` / `gsea_core_genes.json` / `gsea_dotplot.png` / `gsea_barplot.png`（**两张图用 plotthis 绘制**）
- `gsva_scores.csv` / `gsva_heatmap.png`
- `tf_activity_summary.csv` / `tf_barplot.png`
- `heatmap.png` / `heatmap_genes.csv`（可从 GSEA 选通路就地生成，见下方"新增动线"）
- `gsea_pathway_{id}.png`（GSEA 页选择通路后，就地生成单通路详细图）
- `volcano_custom.png`（火山图页就地生成增强版；不覆盖 `volcano_plot.png`）
- `sessionInfo.txt`

下载：
- `GET /api/jobs/{job_id}/download`：打包 zip
- `GET /api/jobs/{job_id}/log`：查看 R 子进程日志

---

## 示例数据

示例数据在：
- `data/input/counts.csv`
- `data/input/metadata.csv`

可直接用网页上传测试。

---

## 环境变量（可选）

- `RNA_SEQ_WEB_JOBS_ROOT`：job 根目录（默认 `var/jobs`）
- `RNA_SEQ_WEB_RSCRIPT`：Rscript 路径（默认 `Rscript`）
- `RNA_SEQ_WEB_MSIGDB_DIR`：**本地 MSigDB 根目录（必须）**，结构要求：`{msigdb_dir}/human/*.gmt` 与 `{msigdb_dir}/mouse/*.gmt`
- `PORT` / `HOST`：启动端口与地址（`start_fastapi.sh` 使用）

---

## API 列表（简要）

- `POST /api/jobs`：提交任务（multipart/form-data）
- `GET /api/jobs/{job_id}`：查询状态
- `GET /api/jobs/{job_id}/outputs/{filename}`：下载单个输出
- `GET /api/jobs/{job_id}/download`：下载 zip
- `GET /api/jobs/{job_id}/log`：查看日志
- `GET /api/genesets?species=human|mouse`：geneset 选项（**严格本地**：若缺失会报错，禁止联网/禁止 msigdbr 兜底）
- `POST /api/jobs/{job_id}/heatmap_from_gsea`：从父 job 的 `gsea_results.csv` 选择通路（core_enrichment）派生生成热图（**旧版：创建新 job_id，不推荐**）
- `POST /api/jobs/{job_id}/heatmap_from_gsea_inplace`：**新版（推荐）**：从父 job 的 GSEA 结果选择通路，就地生成/覆盖 `heatmap.png`（不创建新 job，带锁机制）
- `POST /api/jobs/{job_id}/gsea_single_plot_inplace`：GSEA 页选择通路后，就地生成单通路详细图 `gsea_pathway_{id}.png`（不创建新 job）
- `POST /api/jobs/{job_id}/volcano`：基于父 job 的 `deseq2_results.csv` 派生生成火山图（TopN 标注/标记基因集，新 job_id）
- `POST /api/jobs/{job_id}/volcano_inplace`：火山图增强就地生成 `volcano_custom.png`（不创建新 job）

---

## 重要说明：MSigDB 只从服务器本地读取

本项目 **不会联网下载基因集**，也不会使用 `msigdbr` 兜底。\n\n部署到海外服务器时请提前把 `msigdb/` 目录上传到服务器，并设置：\n\n```bash\nexport RNA_SEQ_WEB_MSIGDB_DIR=/path/to/msigdb\n```\n\n你的目录应类似：\n- `${RNA_SEQ_WEB_MSIGDB_DIR}/human/*.gmt`\n- `${RNA_SEQ_WEB_MSIGDB_DIR}/mouse/*.gmt`\n+
---

## 新增动线：GSEA → 热图（无新 job + plotthis 绘图）

### GSEA 结果可视化（双视图）
- 主任务（`POST /api/jobs`）完成 GSEA 后会输出：
  - `gsea_results.csv`
  - `gsea_core_genes.json`
  - `gsea_dotplot.png`（**改进版 ggplot2 绘制**，点图展示）
  - `gsea_barplot.png`（**改进版 ggplot2 绘制**，柱状图展示）
- 在前端 **GSEA 页面** 可切换查看 Dotplot / Barplot 两种视图

### 从 GSEA 选通路生成热图（就地覆盖）
- **用户动线**：GSEA 页面选择通路 → 跳转到热图页 → 点击"生成热图" → 在同一 job_id 下生成/覆盖 `heatmap.png`
- **后端行为**：
  - 调用 `POST /api/jobs/{job_id}/heatmap_from_gsea_inplace`
  - **不创建新 job**，而是在父 job 的 `output/` 下生成/覆盖 `heatmap.png` 和 `heatmap_genes.csv`
  - 使用锁文件（`.lock_heatmap`）避免并发覆盖
  - 在 `status.json` 的 `extra.heatmap_from_gsea` 字段记录生成状态（不影响主任务状态）
- **前端行为**：
  - GSEA 页面：行点击只选择通路（不触发派生任务），显示"已选择：xxx"并提供"去热图页"按钮
  - 热图页面：显示当前选中通路，点击生成后轮询状态并刷新预览

### 火山图 TopN+标记（保留派生模式）
- 在前端 **火山图页面** 可设置 `Top N` 并粘贴/导入基因集（可从 GSEA 通路导入 core genes）来标记
- 触发 `volcano` 派生 job，输出 `volcano_plot.png`（新 job_id）
