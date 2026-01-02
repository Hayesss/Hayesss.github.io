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
  cat("Usage: Rscript plot_volcano.R --job_dir <dir> --params <params.json>\n")
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
  in_csv <- file.path(parent_dir, "output", "deseq2_results.csv")
  if (!file.exists(in_csv)) stop("parent deseq2_results.csv not found")

  top_n <- as.integer(params$top_n %||% 10)
  mark_genes_text <- params$mark_genes %||% ""
  mark_genes <- trimws(unlist(strsplit(mark_genes_text, "[,\n\r\t ]+")))
  mark_genes <- mark_genes[mark_genes != ""]

  df <- read.csv(in_csv, check.names = FALSE, stringsAsFactors = FALSE)
  # ensure required columns
  if (!("gene" %in% colnames(df))) stop("missing column: gene")
  if (!("log2FoldChange" %in% colnames(df))) stop("missing column: log2FoldChange")
  if (!("padj" %in% colnames(df))) stop("missing column: padj")

  # thresholds from parent params if present
  padj_threshold <- as.numeric(params$padj_threshold %||% 0.05)
  lfc_threshold <- as.numeric(params$lfc_threshold %||% 1.0)

  df$padj[is.na(df$padj)] <- 1
  df$log2FoldChange[is.na(df$log2FoldChange)] <- 0
  df$neg_log10_padj <- -log10(df$padj)

  df$significant <- "NS"
  df$significant[df$padj < padj_threshold & df$log2FoldChange > lfc_threshold] <- "Up"
  df$significant[df$padj < padj_threshold & df$log2FoldChange < -lfc_threshold] <- "Down"
  df$significant <- factor(df$significant, levels = c("Down", "NS", "Up"))

  # Top N (by padj among significant)
  top_df <- df %>%
    dplyr::filter(significant != "NS") %>%
    dplyr::arrange(padj) %>%
    head(top_n)  # head() is from base R, not dplyr

  df$marked <- if (length(mark_genes) > 0) df$gene %in% mark_genes else FALSE

  p <- ggplot2::ggplot(df, ggplot2::aes(x = log2FoldChange, y = neg_log10_padj)) +
    ggplot2::geom_point(ggplot2::aes(color = significant), alpha = 0.55, size = 1.4) +
    ggplot2::scale_color_manual(values = c("Down" = "#2166AC", "NS" = "grey70", "Up" = "#B2182B")) +
    ggplot2::geom_vline(xintercept = c(-lfc_threshold, lfc_threshold), linetype = "dashed", color = "grey40") +
    ggplot2::geom_hline(yintercept = -log10(padj_threshold), linetype = "dashed", color = "grey40") +
    ggplot2::theme_bw(base_size = 13) +
    ggplot2::theme(legend.position = "bottom") +
    ggplot2::labs(title = "Volcano (derived)", x = "log2FoldChange", y = "-log10(padj)")

  if (any(df$marked)) {
    p <- p + ggplot2::geom_point(
      data = df[df$marked, , drop = FALSE],
      ggplot2::aes(x = log2FoldChange, y = neg_log10_padj),
      shape = 21, fill = "#FFD54F", color = "black", stroke = 0.3, size = 2.2
    )
  }

  if (nrow(top_df) > 0 && top_n > 0) {
    if (requireNamespace("ggrepel", quietly = TRUE)) {
      p <- p + ggrepel::geom_text_repel(
        data = top_df,
        ggplot2::aes(label = gene),
        size = 3,
        max.overlaps = Inf,
        box.padding = 0.4,
        point.padding = 0.2
      )
    } else {
      p <- p + ggplot2::geom_text(
        data = top_df,
        ggplot2::aes(label = gene),
        size = 3,
        vjust = -0.5,
        check_overlap = TRUE
      )
    }
  }

  ggplot2::ggsave(file.path(out_dir, "volcano_plot.png"), p, width = 7, height = 6, dpi = 150, bg = "white")
  write.csv(top_df, file.path(out_dir, "volcano_top_genes.csv"), row.names = FALSE)
  if (length(mark_genes) > 0) {
    write.csv(df[df$marked, , drop = FALSE], file.path(out_dir, "volcano_marked_genes.csv"), row.names = FALSE)
  }

  finished_at <- utc_now()
  write_status(status_path, state = "success", message = "success", created_at = created_at, started_at = started_at, finished_at = finished_at)
}, error = function(e) {
  finished_at <- utc_now()
  write_status(status_path, state = "error", message = paste0("error: ", e$message), created_at = created_at, started_at = started_at, finished_at = finished_at)
  cat("error:", e$message, "\n")
  quit(status = 1)
})

