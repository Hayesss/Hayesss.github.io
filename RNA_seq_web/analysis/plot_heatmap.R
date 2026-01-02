#!/usr/bin/env Rscript

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
  cat("Usage: Rscript plot_heatmap.R --job_dir <dir> --params <params.json>\n")
  quit(status = 2)
}

job_dir <- normalizePath(job_dir, mustWork = TRUE)
params_path <- normalizePath(params_path, mustWork = TRUE)

file_arg <- grep("^--file=", commandArgs(), value = TRUE)
script_dir <- if (length(file_arg) > 0) dirname(normalizePath(sub("^--file=", "", file_arg[[1]]))) else getwd()
source(file.path(script_dir, "lib.R"), local = TRUE)

setwd(job_dir)

params <- jsonlite::fromJSON(params_path)
status_path <- file.path(job_dir, "status.json")
created_at <- params$created_at %||% utc_now()
started_at <- utc_now()
write_status(status_path, state = "running", message = "running", created_at = created_at, started_at = started_at, finished_at = NULL)

out_dir <- file.path(job_dir, "output")
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

tryCatch({
  parent_dir <- params$parent_job_dir
  gsea_csv <- file.path(parent_dir, "output", "gsea_results.csv")
  if (!file.exists(gsea_csv)) stop("parent gsea_results.csv not found")

  # We compute vst from parent inputs to ensure genes exist (no DESeq2 rerun)
  counts_path <- file.path(parent_dir, "input", "counts.csv")
  meta_path <- file.path(parent_dir, "input", "metadata.csv")
  if (!file.exists(counts_path)) {
    # try other extensions
    cand <- list.files(file.path(parent_dir, "input"), pattern = "^counts\\.", full.names = TRUE)
    if (length(cand) > 0) counts_path <- cand[[1]]
  }
  if (!file.exists(meta_path)) {
    cand <- list.files(file.path(parent_dir, "input"), pattern = "^metadata\\.", full.names = TRUE)
    if (length(cand) > 0) meta_path <- cand[[1]]
  }
  if (!file.exists(counts_path) || !file.exists(meta_path)) stop("parent input counts/metadata not found")

  min_count_filter <- as.integer(params$min_count_filter %||% 10)

  dat <- load_counts_and_metadata(counts_path, meta_path, min_count_filter = min_count_filter)
  vst_matrix <- compute_vst_or_log(dat$count_matrix, dat$metadata)

  gsea_df <- read.csv(gsea_csv, check.names = FALSE, stringsAsFactors = FALSE)
  if (!("core_enrichment" %in% colnames(gsea_df))) stop("gsea_results.csv missing core_enrichment column")

  pathway_id <- params$pathway_id %||% ""
  pathway_desc <- params$pathway_description %||% ""

  row <- NULL
  if (pathway_id != "" && ("ID" %in% colnames(gsea_df))) {
    row <- gsea_df[gsea_df$ID == pathway_id, , drop = FALSE]
  }
  if ((is.null(row) || nrow(row) == 0) && pathway_desc != "" && ("Description" %in% colnames(gsea_df))) {
    row <- gsea_df[gsea_df$Description == pathway_desc, , drop = FALSE]
  }
  if (is.null(row) || nrow(row) == 0) stop("selected pathway not found in gsea_results.csv")
  row <- row[1, , drop = FALSE]

  core <- as.character(row$core_enrichment)
  core_genes <- trimws(unlist(strsplit(core, "/")))
  core_genes <- core_genes[core_genes != ""]
  if (length(core_genes) < 2) stop("core_enrichment genes too few")

  genes_avail <- intersect(core_genes, rownames(vst_matrix))
  if (length(genes_avail) < 2) stop("core genes not found in expression matrix")

  title <- if ("Description" %in% colnames(row)) as.character(row$Description) else "GSEA core genes"
  title <- substr(title, 1, 80)

  plot_heatmap_png(vst_matrix[genes_avail, , drop = FALSE], file.path(out_dir, "heatmap.png"), title = title)
  write.csv(data.frame(gene = genes_avail), file.path(out_dir, "heatmap_genes.csv"), row.names = FALSE)

  finished_at <- utc_now()
  write_status(status_path, state = "success", message = "success", created_at = created_at, started_at = started_at, finished_at = finished_at)
}, error = function(e) {
  finished_at <- utc_now()
  write_status(status_path, state = "error", message = paste0("error: ", e$message), created_at = created_at, started_at = started_at, finished_at = finished_at)
  cat("error:", e$message, "\n")
  quit(status = 1)
})

