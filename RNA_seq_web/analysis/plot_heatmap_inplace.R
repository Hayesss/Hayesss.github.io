#!/usr/bin/env Rscript
# 就地生成热图（从 GSEA 选通路）：不创建新 job，直接写回父 job output/

`%||%` <- function(a, b) if (!is.null(a)) a else b

args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(flag) {
  idx <- match(flag, args)
  if (is.na(idx)) return(NULL)
  if (idx == length(args)) return(NULL)
  args[[idx + 1]]
}

job_dir <- get_arg("--job_dir")
params_path <- get_arg("--params")

if (is.null(job_dir) || is.null(params_path)) {
  cat("Usage: Rscript plot_heatmap_inplace.R --job_dir <dir> --params <params.json>\n")
  quit(status = 2)
}

job_dir <- normalizePath(job_dir, mustWork = TRUE)
params_path <- normalizePath(params_path, mustWork = TRUE)

# 加载 lib.R
file_arg <- grep("^--file=", commandArgs(), value = TRUE)
script_dir <- if (length(file_arg) > 0) dirname(normalizePath(sub("^--file=", "", file_arg[[1]]))) else getwd()
source(file.path(script_dir, "lib.R"), local = TRUE)

setwd(job_dir)

params <- jsonlite::fromJSON(params_path)
status_path <- file.path(job_dir, "status.json")
lock_file <- file.path(job_dir, ".lock_heatmap")

# 辅助：更新 status.json extra.heatmap_from_gsea（不改主状态）
update_heatmap_status <- function(hm_state, hm_message) {
  tryCatch({
    st <- if (file.exists(status_path)) jsonlite::fromJSON(status_path) else list()
    extra <- if (!is.null(st$extra) && is.list(st$extra)) st$extra else list()
    extra$heatmap_from_gsea <- list(
      state = hm_state,
      message = hm_message,
      finished_at = utc_now()
    )
    write_status(
      status_path,
      state = st$state %||% "success",
      message = st$message,
      created_at = st$created_at,
      started_at = st$started_at,
      finished_at = st$finished_at,
      extra = extra
    )
  }, silent = TRUE)
}

# 清理锁
cleanup_lock <- function() {
  if (file.exists(lock_file)) unlink(lock_file)
}

tryCatch({
  # 读取 gsea_core_genes.json
  core_json <- file.path(job_dir, "output", "gsea_core_genes.json")
  if (!file.exists(core_json)) stop("找不到 output/gsea_core_genes.json")
  
  core_data <- jsonlite::fromJSON(core_json)
  if (is.null(core_data) || nrow(core_data) == 0) stop("gsea_core_genes.json 为空")
  
  pathway_id <- params$pathway_id %||% ""
  pathway_desc <- params$pathway_description %||% ""
  
  # 匹配通路
  row <- NULL
  if (pathway_id != "" && "ID" %in% colnames(core_data)) {
    row <- core_data[core_data$ID == pathway_id, , drop = FALSE]
  }
  if ((is.null(row) || nrow(row) == 0) && pathway_desc != "" && "Description" %in% colnames(core_data)) {
    row <- core_data[core_data$Description == pathway_desc, , drop = FALSE]
  }
  if (is.null(row) || nrow(row) == 0) {
    stop(paste0("找不到通路: pathway_id=", pathway_id, ", pathway_description=", pathway_desc))
  }
  row <- row[1, , drop = FALSE]
  
  # 提取 core genes
  core_genes <- row$core_genes[[1]]
  if (is.null(core_genes) || length(core_genes) == 0) {
    stop("该通路的 core_genes 为空")
  }
  
  # 读取表达矩阵（从父 job 的 input 重新计算 vst）
  counts_path <- file.path(job_dir, "input", "counts.csv")
  meta_path <- file.path(job_dir, "input", "metadata.csv")
  
  # 尝试其他扩展名
  if (!file.exists(counts_path)) {
    cand <- list.files(file.path(job_dir, "input"), pattern = "^counts\\.", full.names = TRUE)
    if (length(cand) > 0) counts_path <- cand[[1]]
  }
  if (!file.exists(meta_path)) {
    cand <- list.files(file.path(job_dir, "input"), pattern = "^metadata\\.", full.names = TRUE)
    if (length(cand) > 0) meta_path <- cand[[1]]
  }
  
  if (!file.exists(counts_path) || !file.exists(meta_path)) {
    stop("找不到父 job 的 input/counts 或 input/metadata")
  }
  
  # 加载数据并计算 vst
  dat <- load_counts_and_metadata(counts_path, meta_path, min_count_filter = 10)
  vst_matrix <- compute_vst_or_log(dat$count_matrix, dat$metadata)
  
  # 匹配基因
  genes_avail <- intersect(core_genes, rownames(vst_matrix))
  if (length(genes_avail) == 0) {
    stop(paste0(
      "core genes 与表达矩阵无交集。core genes 数: ", length(core_genes),
      ", 表达矩阵基因数: ", nrow(vst_matrix)
    ))
  }
  if (length(genes_avail) < 2) {
    stop("匹配的基因数不足 2 个，无法绘制热图")
  }
  
  # 生成热图
  title <- if ("Description" %in% colnames(row)) as.character(row$Description) else "GSEA core genes"
  title <- substr(title, 1, 80)
  
  out_png <- file.path(job_dir, "output", "heatmap.png")
  plot_heatmap_png(vst_matrix[genes_avail, , drop = FALSE], out_png, title = title)
  
  # 输出基因列表
  out_csv <- file.path(job_dir, "output", "heatmap_genes.csv")
  write.csv(data.frame(gene = genes_avail), out_csv, row.names = FALSE)
  
  # 尝试生成单通路 GSEA 图（如果 plotthis 可用）
  if (requireNamespace("plotthis", quietly = TRUE)) {
    tryCatch({
      library(plotthis)
      
      # 读取 GSEA 数据和构建必需属性
      gsea_csv <- file.path(job_dir, "output", "gsea_results.csv")
      deseq2_csv <- file.path(job_dir, "output", "deseq2_results.csv")
      
      if (file.exists(gsea_csv) && file.exists(deseq2_csv)) {
        gsea_df <- read.csv(gsea_csv, check.names = FALSE, stringsAsFactors = FALSE)
        res_df <- read.csv(deseq2_csv, check.names = FALSE, stringsAsFactors = FALSE)
        
        # 构建 gene_ranks
        df_for_ranks <- res_df[!is.na(res_df$log2FoldChange) & !is.na(res_df$pvalue), ]
        gene_list <- df_for_ranks$log2FoldChange
        names(gene_list) <- df_for_ranks$gene
        gene_list <- sort(gene_list, decreasing = TRUE)
        
        # 读取基因集
        parent_params_path <- file.path(job_dir, "params.json")
        if (file.exists(parent_params_path)) {
          parent_params <- jsonlite::fromJSON(parent_params_path)
          msigdb_dir <- parent_params$msigdb_dir
          species <- parent_params$species %||% "human"
          gmt_file <- parent_params$gmt_file %||% ""
          
          geneset_df <- get_geneset_df(msigdb_dir, species, gmt_file)
          geneset_list <- split(geneset_df$gene_symbol, geneset_df$gs_name)
          
          # 设置属性
          attr(gsea_df, "gene_ranks") <- gene_list
          attr(gsea_df, "gene_sets") <- geneset_list
          
          # 找到通路 ID
          matched_row <- row
          pathway_gs_id <- as.character(matched_row$ID[1])
          
          # 绘制单通路图
          p_single <- GSEAPlot(
            data = gsea_df,
            in_form = "dose",
            gene_ranks = "@gene_ranks",
            gene_sets = "@gene_sets",
            gs = pathway_gs_id,
            line_color = "#6BB82D"
          )
          
          out_gsea_png <- file.path(job_dir, "output", paste0("gsea_pathway_", gsub("[^A-Za-z0-9_-]", "_", pathway_gs_id), ".png"))
          ggplot2::ggsave(out_gsea_png, p_single, width = 10, height = 6, dpi = 150, bg = "white")
          
          cat("单通路 GSEA 图生成成功:", out_gsea_png, "\n")
        }
      }
    }, error = function(e) {
      warning("单通路 GSEA 图生成失败（不影响热图）: ", e$message)
    })
  }
  
  # 更新状态为成功
  update_heatmap_status("success", paste0("热图生成成功，使用 ", length(genes_avail), " 个基因"))
  cleanup_lock()
  
  cat("热图生成完成:", out_png, "\n")
  
}, error = function(e) {
  msg <- paste0("热图生成失败: ", e$message)
  update_heatmap_status("error", msg)
  cleanup_lock()
  cat(msg, "\n")
  quit(status = 1)
})
