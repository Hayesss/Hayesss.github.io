#!/usr/bin/env Rscript
# 绘制单个通路的 GSEA 详细图（running score + 基因位置）

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
  cat("Usage: Rscript plot_gsea_single.R --job_dir <dir> --params <params.json>\n")
  quit(status = 2)
}

job_dir <- normalizePath(job_dir, mustWork = TRUE)
params_path <- normalizePath(params_path, mustWork = TRUE)

# 加载 lib.R
file_arg <- grep("^--file=", commandArgs(), value = TRUE)
script_dir <- if (length(file_arg) > 0) dirname(normalizePath(sub("^--file=", "", file_arg[[1]]))) else getwd()
source(file.path(script_dir, "lib.R"), local = TRUE)

setwd(job_dir)

suppressPackageStartupMessages({
  library(jsonlite)
})

params <- jsonlite::fromJSON(params_path)
out_dir <- file.path(job_dir, "output")

tryCatch({
  # 检查 plotthis
  if (!requireNamespace("plotthis", quietly = TRUE)) {
    stop("plotthis 包未安装，无法绘制单通路 GSEA 图")
  }
  library(plotthis)
  
  # 读取 gsea_results.csv 和 gsea_core_genes.json
  gsea_csv <- file.path(out_dir, "gsea_results.csv")
  gsea_core_json <- file.path(out_dir, "gsea_core_genes.json")
  
  if (!file.exists(gsea_csv)) stop("找不到 gsea_results.csv")
  if (!file.exists(gsea_core_json)) stop("找不到 gsea_core_genes.json")
  
  gsea_df <- read.csv(gsea_csv, check.names = FALSE, stringsAsFactors = FALSE)
  
  # 需要重新构建 gene_ranks 和 gene_sets（从原始数据）
  # 读取 deseq2_results.csv
  deseq2_csv <- file.path(out_dir, "deseq2_results.csv")
  if (!file.exists(deseq2_csv)) stop("找不到 deseq2_results.csv，无法构建 gene_ranks")
  
  res_df <- read.csv(deseq2_csv, check.names = FALSE, stringsAsFactors = FALSE)
  df_for_ranks <- res_df[!is.na(res_df$log2FoldChange) & !is.na(res_df$pvalue), ]
  gene_list <- df_for_ranks$log2FoldChange
  names(gene_list) <- df_for_ranks$gene
  gene_list <- sort(gene_list, decreasing = TRUE)
  
  # 读取基因集（需要从 params.json 获取物种和 gmt 信息）
  parent_params_path <- file.path(job_dir, "params.json")
  if (file.exists(parent_params_path)) {
    parent_params <- jsonlite::fromJSON(parent_params_path)
    msigdb_dir <- parent_params$msigdb_dir
    species <- parent_params$species %||% "human"
    gmt_file <- parent_params$gmt_file %||% ""
    
    geneset_df <- get_geneset_df(msigdb_dir, species, gmt_file)
    geneset_list <- split(geneset_df$gene_symbol, geneset_df$gs_name)
  } else {
    stop("找不到 params.json，无法获取基因集信息")
  }
  
  # 设置属性
  attr(gsea_df, "gene_ranks") <- gene_list
  attr(gsea_df, "gene_sets") <- geneset_list
  
  # 查找选中的通路
  pathway_id <- params$pathway_id %||% ""
  pathway_desc <- params$pathway_description %||% ""
  
  row <- NULL
  if (pathway_id != "" && "ID" %in% colnames(gsea_df)) {
    row <- gsea_df[gsea_df$ID == pathway_id, , drop = FALSE]
  }
  if ((is.null(row) || nrow(row) == 0) && pathway_desc != "" && "Description" %in% colnames(gsea_df)) {
    row <- gsea_df[gsea_df$Description == pathway_desc, , drop = FALSE]
  }
  if (is.null(row) || nrow(row) == 0) {
    stop(paste0("找不到通路: pathway_id=", pathway_id, ", pathway_description=", pathway_desc))
  }
  
  # 使用 ID 作为 gs 参数
  pathway_gs_id <- as.character(row$ID[1])
  
  # 绘制单通路 GSEA 图
  p <- GSEAPlot(
    data = gsea_df,
    in_form = "dose",
    gene_ranks = "@gene_ranks",
    gene_sets = "@gene_sets",
    gs = pathway_gs_id,
    line_color = "#6BB82D"
  )
  
  # 保存图片
  out_png <- file.path(out_dir, paste0("gsea_pathway_", gsub("[^A-Za-z0-9_-]", "_", pathway_gs_id), ".png"))
  ggplot2::ggsave(out_png, p, width = 10, height = 6, dpi = 150, bg = "white")
  
  cat("单通路 GSEA 图生成成功:", out_png, "\n")
  
}, error = function(e) {
  cat("单通路 GSEA 图生成失败:", e$message, "\n")
  quit(status = 1)
})
