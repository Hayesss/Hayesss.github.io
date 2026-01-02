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
  cat("Usage: Rscript run_job.R --job_dir <dir> --params <params.json>\n")
  quit(status = 2)
}

job_dir <- normalizePath(job_dir, mustWork = TRUE)
params_path <- normalizePath(params_path, mustWork = TRUE)

# Locate lib.R next to this script
file_arg <- grep("^--file=", commandArgs(), value = TRUE)
if (length(file_arg) > 0) {
  script_path <- sub("^--file=", "", file_arg[[1]])
  script_dir <- dirname(normalizePath(script_path))
} else {
  script_dir <- getwd()
}

lib_path <- file.path(script_dir, "lib.R")

source(lib_path, local = TRUE)

setwd(job_dir)

params <- jsonlite::fromJSON(params_path)
status_path <- file.path(job_dir, "status.json")

created_at <- params$created_at
if (file.exists(status_path)) {
  try({
    st <- jsonlite::fromJSON(status_path)
    if (!is.null(st$created_at) && st$created_at != "") created_at <- st$created_at
  }, silent = TRUE)
}

started_at <- utc_now()
write_status(status_path, state = "running", message = "running", created_at = created_at, started_at = started_at, finished_at = NULL)

out_dir <- file.path(job_dir, "output")
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

safe_write <- function(label, expr) {
  tryCatch(expr, error = function(e) {
    stop(paste0(label, " 失败: ", e$message))
  })
}

tryCatch({
  counts_path <- params$input$counts_path
  metadata_path <- params$input$metadata_path

  min_count_filter <- as.integer(params$min_count_filter %||% 10)
  design_var <- params$design_var %||% ""
  contrast_num <- params$contrast_num %||% ""
  contrast_denom <- params$contrast_denom %||% ""
  padj_threshold <- as.numeric(params$padj_threshold %||% 0.05)
  lfc_threshold <- as.numeric(params$lfc_threshold %||% 1.0)

  modules <- params$modules %||% list()
  msigdb_dir <- params$msigdb_dir
  species <- params$species %||% "human"
  gmt_file <- params$gmt_file %||% ""
  cache_dir <- params$cache_dir %||% file.path((params$project_root %||% job_dir), "cache")

  dat <- load_counts_and_metadata(counts_path, metadata_path, min_count_filter = min_count_filter)
  count_matrix <- dat$count_matrix
  metadata <- dat$metadata

  vst_matrix <- compute_vst_or_log(count_matrix, metadata)

  if (!is.null(modules$pca) && isTRUE(modules$pca)) {
    safe_write("PCA", {
      color_var <- if (ncol(metadata) >= 1) colnames(metadata)[1] else ""
      plot_pca(vst_matrix, metadata, color_var, file.path(out_dir, "pca_plot.png"))
    })
  }

  res_df <- NULL
  dds <- NULL

  if (is.null(modules$deseq2) || isTRUE(modules$deseq2)) {
    safe_write("DESeq2", {
      de <- run_deseq2(count_matrix, metadata, design_var, contrast_num, contrast_denom)
      dds <<- de$dds
      res_df <<- de$res_df

      write.csv(res_df, file.path(out_dir, "deseq2_results.csv"), row.names = FALSE)
      plot_volcano(res_df, padj_threshold, lfc_threshold, contrast_num, contrast_denom, file.path(out_dir, "volcano_plot.png"))

      deg <- res_df %>% filter(!is.na(padj)) %>% filter(padj < padj_threshold, abs(log2FoldChange) > lfc_threshold)
      write.csv(deg, file.path(out_dir, "deg_filtered.csv"), row.names = FALSE)

      vsd <- vst(dds, blind = FALSE)
      vst_matrix <<- assay(vsd)
      top_genes <- head(rownames(vst_matrix), 200)
      write.csv(vst_matrix[top_genes, , drop = FALSE], file.path(out_dir, "vst_matrix_top200.csv"))
    })
  }

  if (!is.null(modules$gsea) && isTRUE(modules$gsea)) {
    if (is.null(res_df)) stop("GSEA 需要先运行 DESeq2")
    safe_write("GSEA", {
      # 准备 GSEA 输入
      geneset_df <- get_geneset_df(msigdb_dir, species, gmt_file)
      df_for_gsea <- res_df %>% filter(!is.na(log2FoldChange), !is.na(pvalue))
      gene_list <- df_for_gsea$log2FoldChange
      names(gene_list) <- df_for_gsea$gene
      gene_list <- sort(gene_list, decreasing = TRUE)
      
      gsea_df <- run_gsea(res_df, msigdb_dir, species, gmt_file)
      if (is.null(gsea_df) || nrow(gsea_df) == 0) {
        write.csv(data.frame(), file.path(out_dir, "gsea_results.csv"), row.names = FALSE)
      } else {
        # 保存 GSEA 结果
        write.csv(gsea_df, file.path(out_dir, "gsea_results.csv"), row.names = FALSE)
        
        # 为 plotthis 添加必需的属性
        attr(gsea_df, "gene_ranks") <- gene_list
        geneset_list <- split(geneset_df$gene_symbol, geneset_df$gs_name)
        attr(gsea_df, "gene_sets") <- geneset_list
        # Export core genes for frontend selection (core_enrichment: "GENE1/GENE2/...")
        if ("core_enrichment" %in% colnames(gsea_df)) {
          core_df <- gsea_df[, intersect(c("ID", "Description", "NES", "p.adjust", "core_enrichment"), colnames(gsea_df)), drop = FALSE]
          core_df$core_genes <- lapply(as.character(core_df$core_enrichment), function(x) {
            gs <- trimws(unlist(strsplit(x, "/")))
            gs[gs != ""]
          })
          core_df$core_enrichment <- NULL
          jsonlite::write_json(core_df, file.path(out_dir, "gsea_core_genes.json"), auto_unbox = TRUE, pretty = TRUE)
        }
        # 生成两张图：dotplot 和 barplot（用 ggplot2）
        plot_gsea_dotplot(gsea_df, file.path(out_dir, "gsea_dotplot.png"), top_n = 20)
        plot_gsea_barplot(gsea_df, file.path(out_dir, "gsea_barplot.png"), top_n = 20)
      }
    })
  }

  if (!is.null(modules$gsva) && isTRUE(modules$gsva)) {
    safe_write("GSVA", {
      gsva_scores <- run_gsva(vst_matrix, msigdb_dir, species, gmt_file, method = "gsva")
      gsva_df <- as.data.frame(gsva_scores)
      gsva_df <- cbind(Pathway = rownames(gsva_df), gsva_df)
      write.csv(gsva_df, file.path(out_dir, "gsva_scores.csv"), row.names = FALSE)

      vars <- apply(gsva_scores, 1, var)
      top <- names(sort(vars, decreasing = TRUE))[1:min(50, length(vars))]
      plot_heatmap_png(gsva_scores[top, , drop = FALSE], file.path(out_dir, "gsva_heatmap.png"), title = "GSVA (top variable pathways)")
    })
  }

  if (!is.null(modules$tf) && isTRUE(modules$tf)) {
    safe_write("TF", {
      org <- if (tolower(species) %in% c("human", "homo sapiens", "hs")) "human" else "mouse"
      tf_long <- run_tf_activity(vst_matrix, organism = org, cache_dir = cache_dir, database = "collectri", method = "ulm", minsize = 5)
      write.csv(tf_long, file.path(out_dir, "tf_activity_long.csv"), row.names = FALSE)

      tf_sum <- tf_long %>%
        group_by(source) %>%
        summarise(mean_score = mean(score, na.rm = TRUE), mean_p_value = mean(p_value, na.rm = TRUE), n = dplyr::n(), .groups = "drop") %>%
        arrange(desc(abs(mean_score)))
      write.csv(tf_sum, file.path(out_dir, "tf_activity_summary.csv"), row.names = FALSE)

      plot_tf_barplot(tf_long, file.path(out_dir, "tf_barplot.png"), top_n = 25)
    })
  }

  if (!is.null(modules$heatmap) && isTRUE(modules$heatmap)) {
    safe_write("Heatmap", {
      genes_text <- params$heatmap_genes %||% ""
      genes <- trimws(unlist(strsplit(genes_text, "\n")))
      genes <- genes[genes != ""]

      if (length(genes) == 0 && !is.null(res_df)) {
        genes <- res_df %>% filter(!is.na(padj)) %>% arrange(padj) %>% head(50) %>% pull(gene)
      }

      genes_avail <- intersect(genes, rownames(vst_matrix))
      if (length(genes_avail) < 2) stop("热图基因匹配不足")

      plot_heatmap_png(vst_matrix[genes_avail, , drop = FALSE], file.path(out_dir, "heatmap.png"), title = "Heatmap")
    })
  }

  writeLines(capture.output(sessionInfo()), file.path(out_dir, "sessionInfo.txt"))

  finished_at <- utc_now()
  write_status(status_path, state = "success", message = "success", created_at = created_at, started_at = started_at, finished_at = finished_at)

}, error = function(e) {
  finished_at <- utc_now()
  msg <- paste0("error: ", e$message)
  write_status(status_path, state = "error", message = msg, created_at = created_at, started_at = started_at, finished_at = finished_at)
  cat(msg, "\n")
  quit(status = 1)
})
