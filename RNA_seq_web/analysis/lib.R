#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(dplyr)
  library(tidyr)
  library(tibble)
  library(ggplot2)
  library(DESeq2)
  library(ComplexHeatmap)
  library(circlize)
})


`%||%` <- function(a, b) if (!is.null(a)) a else b

utc_now <- function() {
  format(as.POSIXct(Sys.time(), tz = "UTC"), "%Y-%m-%dT%H:%M:%SZ")
}

write_status <- function(status_path, state, message = NULL,
                         created_at = NULL, started_at = NULL, finished_at = NULL,
                         extra = list()) {
  payload <- c(
    list(
      state = state,
      message = message,
      created_at = created_at,
      started_at = started_at,
      finished_at = finished_at
    ),
    extra
  )
  tmp <- paste0(status_path, ".tmp")
  writeLines(jsonlite::toJSON(payload, auto_unbox = TRUE, pretty = TRUE), tmp)
  ok <- file.rename(tmp, status_path)
  if (!ok) {
    unlink(tmp)
    stop("写入 status.json 失败")
  }
}

read_table_auto <- function(path) {
  ext <- tolower(tools::file_ext(path))
  if (ext %in% c("csv")) {
    return(read.csv(path, check.names = FALSE, stringsAsFactors = FALSE))
  }
  read.delim(path, check.names = FALSE, stringsAsFactors = FALSE)
}

load_counts_and_metadata <- function(count_path, meta_path, min_count_filter = 10) {
  count_data <- read_table_auto(count_path)
  if (ncol(count_data) < 2) stop("counts 列数不足：需要第一列 gene + 至少 1 个样本列")

  gene_names <- as.character(count_data[[1]])
  mat <- as.matrix(count_data[, -1, drop = FALSE])
  mode(mat) <- "numeric"

  if (any(duplicated(gene_names))) {
    uniq <- unique(gene_names)
    merged <- matrix(0, nrow = length(uniq), ncol = ncol(mat))
    rownames(merged) <- uniq
    colnames(merged) <- colnames(mat)
    for (g in uniq) {
      rows <- gene_names == g
      if (sum(rows) == 1) merged[g, ] <- mat[rows, ]
      else merged[g, ] <- colSums(mat[rows, , drop = FALSE])
    }
    mat <- merged
  } else {
    rownames(mat) <- gene_names
    colnames(mat) <- colnames(count_data)[-1]
  }

  keep <- rowSums(mat) >= min_count_filter
  mat <- mat[keep, , drop = FALSE]

  meta_raw <- read_table_auto(meta_path)
  # try treat first column as sample name
  meta <- meta_raw
  rownames(meta) <- as.character(meta[[1]])
  meta <- meta[, -1, drop = FALSE]

  common <- intersect(colnames(mat), rownames(meta))
  if (length(common) == 0) stop("样本名不匹配：counts 列名与 metadata 行名没有交集")

  mat <- mat[, common, drop = FALSE]
  meta <- meta[common, , drop = FALSE]

  list(count_matrix = mat, metadata = meta)
}

compute_vst_or_log <- function(count_matrix, metadata) {
  meta <- metadata
  if (ncol(meta) < 1) {
    meta <- data.frame(group = rep("group", ncol(count_matrix)))
    rownames(meta) <- colnames(count_matrix)
  }
  meta[[1]] <- as.factor(meta[[1]])

  tryCatch({
    dds <- DESeqDataSetFromMatrix(
      countData = round(count_matrix),
      colData = meta,
      design = as.formula(paste0("~", colnames(meta)[1]))
    )
    vsd <- vst(dds, blind = TRUE)
    assay(vsd)
  }, error = function(e) {
    log2(count_matrix + 1)
  })
}

plot_pca <- function(vst_matrix, metadata, color_var, out_png) {
  if (is.null(color_var) || color_var == "" || !(color_var %in% colnames(metadata))) {
    color_var <- colnames(metadata)[1]
  }

  gene_vars <- apply(vst_matrix, 1, var)
  top <- names(sort(gene_vars, decreasing = TRUE))[1:min(1000, length(gene_vars))]
  mat <- vst_matrix[top, , drop = FALSE]

  pca <- prcomp(t(mat), center = TRUE, scale. = TRUE)
  df <- as.data.frame(pca$x[, 1:2, drop = FALSE])
  df$sample <- rownames(df)
  df$color <- metadata[[color_var]]
  var_expl <- summary(pca)$importance[2, ] * 100

  p <- ggplot(df, aes(x = PC1, y = PC2, color = color)) +
    geom_point(size = 3, alpha = 0.85) +
    theme_bw(base_size = 13) +
    labs(
      title = "PCA",
      x = sprintf("PC1 (%.1f%%)", var_expl[1]),
      y = sprintf("PC2 (%.1f%%)", var_expl[2]),
      color = color_var
    )

  ggsave(out_png, p, width = 7, height = 6, dpi = 150, bg = "white")
}

run_deseq2 <- function(count_matrix, metadata, design_var, contrast_num, contrast_denom) {
  if (is.null(design_var) || design_var == "" || !(design_var %in% colnames(metadata))) {
    stop("design_var 缺失或不在 metadata 列中")
  }
  if (contrast_num == "" || contrast_denom == "" || contrast_num == contrast_denom) {
    stop("contrast_num/contrast_denom 缺失或相同")
  }

  coldata <- metadata
  keep_samples <- coldata[[design_var]] %in% c(contrast_num, contrast_denom)
  coldata <- coldata[keep_samples, , drop = FALSE]
  cnt <- count_matrix[, rownames(coldata), drop = FALSE]

  coldata[[design_var]] <- factor(coldata[[design_var]], levels = c(contrast_denom, contrast_num))

  dds <- DESeqDataSetFromMatrix(
    countData = round(cnt),
    colData = coldata,
    design = as.formula(paste0("~", design_var))
  )

  keep <- rowSums(counts(dds) >= 10) >= 3
  dds <- dds[keep, ]
  dds <- DESeq(dds)

  res <- results(dds, contrast = c(design_var, contrast_num, contrast_denom))
  res_df <- as.data.frame(res)
  res_df$gene <- rownames(res_df)
  res_df <- res_df[order(res_df$padj), ]

  list(dds = dds, res_df = res_df)
}

plot_volcano <- function(res_df, padj_threshold, lfc_threshold, contrast_num, contrast_denom, out_png) {
  df <- res_df
  df$padj[is.na(df$padj)] <- 1
  df$log2FoldChange[is.na(df$log2FoldChange)] <- 0
  df$significant <- "NS"
  df$significant[df$padj < padj_threshold & df$log2FoldChange > lfc_threshold] <- "Up"
  df$significant[df$padj < padj_threshold & df$log2FoldChange < -lfc_threshold] <- "Down"
  df$significant <- factor(df$significant, levels = c("Down", "NS", "Up"))
  df$neg_log10_padj <- -log10(df$padj)
  max_y <- max(df$neg_log10_padj[is.finite(df$neg_log10_padj)], na.rm = TRUE) * 1.1
  df$neg_log10_padj[is.infinite(df$neg_log10_padj)] <- max_y

  p <- ggplot(df, aes(x = log2FoldChange, y = neg_log10_padj, color = significant)) +
    geom_point(alpha = 0.55, size = 1.4) +
    scale_color_manual(values = c("Down" = "#2166AC", "NS" = "grey70", "Up" = "#B2182B")) +
    geom_vline(xintercept = c(-lfc_threshold, lfc_threshold), linetype = "dashed", color = "grey40") +
    geom_hline(yintercept = -log10(padj_threshold), linetype = "dashed", color = "grey40") +
    theme_bw(base_size = 13) +
    theme(legend.position = "bottom") +
    labs(
      title = sprintf("Volcano (%s vs %s)", contrast_num, contrast_denom),
      x = "log2FoldChange",
      y = "-log10(padj)"
    )

  ggsave(out_png, p, width = 7, height = 6, dpi = 150, bg = "white")
}

read_gmt_file <- function(gmt_file) {
  lines <- readLines(gmt_file)
  geneset_list <- list()
  for (line in lines) {
    if (trimws(line) == "") next
    fields <- strsplit(line, "\t")[[1]]
    if (length(fields) < 3) next
    geneset_name <- fields[1]
    genes <- fields[3:length(fields)]
    genes <- genes[genes != ""]
    if (length(genes) > 0) geneset_list[[geneset_name]] <- genes
  }

  out <- lapply(names(geneset_list), function(gs) {
    genes <- geneset_list[[gs]]
    data.frame(gs_name = rep(gs, length(genes)), gene_symbol = genes, stringsAsFactors = FALSE)
  })
  do.call(rbind, out)
}

resolve_msigdb_gmt <- function(msigdb_dir, species, gmt_file = NULL) {
  sp <- tolower(species)
  sub <- if (sp %in% c("human", "homo sapiens", "hs")) "human" else "mouse"
  dir_path <- file.path(msigdb_dir, sub)
  if (is.null(gmt_file) || gmt_file == "") {
    gmt_file <- if (sub == "human") "h.all.v2025.1.Hs.symbols.gmt" else "mh.all.v2025.1.Mm.symbols.gmt"
  }
  gmt_path <- file.path(dir_path, gmt_file)
  if (!file.exists(gmt_path)) stop(paste0("找不到 GMT 文件: ", gmt_path))
  gmt_path
}

get_geneset_df <- function(msigdb_dir, species, gmt_file = NULL) {
  # Strict local: only allow reading local GMT files under msigdb_dir/{human|mouse}/
  gmt_path <- resolve_msigdb_gmt(msigdb_dir, species, gmt_file)
  read_gmt_file(gmt_path)
}

run_gsea <- function(res_df, msigdb_dir, species, gmt_file, minGSSize = 15, maxGSSize = 500) {
  if (!requireNamespace("clusterProfiler", quietly = TRUE)) stop("缺少 clusterProfiler")

  geneset_df <- get_geneset_df(msigdb_dir, species, gmt_file)
  term2gene <- geneset_df %>% select(gs_name, gene_symbol)

  df <- res_df %>% filter(!is.na(log2FoldChange), !is.na(pvalue))
  gene_list <- df$log2FoldChange
  names(gene_list) <- df$gene
  gene_list <- sort(gene_list, decreasing = TRUE)

  gsea <- clusterProfiler::GSEA(
    geneList = gene_list,
    TERM2GENE = term2gene,
    minGSSize = minGSSize,
    maxGSSize = maxGSSize,
    pvalueCutoff = 1,
    verbose = FALSE
  )

  if (is.null(gsea) || nrow(gsea) == 0) return(NULL)
  as.data.frame(gsea)
}

plot_gsea_dotplot <- function(gsea_df, out_png, top_n = 20) {
  if (is.null(gsea_df) || nrow(gsea_df) == 0) return(invisible(NULL))

  # 检查是否有 plotthis 以及必需的属性
  has_plotthis <- requireNamespace("plotthis", quietly = TRUE)
  gene_ranks <- attr(gsea_df, "gene_ranks")
  gene_sets <- attr(gsea_df, "gene_sets")
  
  if (has_plotthis && !is.null(gene_ranks) && !is.null(gene_sets)) {
    # 使用 plotthis 的 GSEASummaryPlot
    tryCatch({
      library(plotthis)
      
      # 确保属性存在
      attr(gsea_df, "gene_ranks") <- gene_ranks
      attr(gsea_df, "gene_sets") <- gene_sets
      
      p <- GSEASummaryPlot(
        data = gsea_df,
        in_form = "dose",
        gene_ranks = "@gene_ranks",
        gene_sets = "@gene_sets",
        top_term = top_n,
        metric = "p.adjust",
        cutoff = 1,
        line_by = "running_score",
        palette = "RdYlBu"
      )
      
      ggsave(out_png, p, width = 12, height = max(6, 0.4 * top_n + 2), dpi = 150, bg = "white")
      return(invisible(NULL))
    }, error = function(e) {
      warning("plotthis GSEASummaryPlot failed, using ggplot2 fallback: ", e$message)
    })
  }
  
  # ggplot2 兜底方案
  df <- gsea_df
  df <- df[order(df$p.adjust), ]
  df <- head(df, top_n)
  df$Description <- factor(df$Description, levels = rev(df$Description))
  
  p <- ggplot(df, aes(x = NES, y = Description, size = setSize, color = p.adjust)) +
    geom_point(alpha = 0.8) +
    scale_color_gradient(low = "#d73027", high = "#4575b4", 
                        trans = "log10",
                        name = "p.adjust") +
    scale_size_continuous(range = c(3, 10), name = "Gene Set Size") +
    theme_bw(base_size = 13) +
    theme(
      axis.text.y = element_text(size = 11),
      panel.grid.major.y = element_line(color = "grey90"),
      panel.grid.minor = element_blank()
    ) +
    labs(
      title = sprintf("GSEA Enrichment Dotplot (top %d pathways)", nrow(df)),
      x = "Normalized Enrichment Score (NES)",
      y = NULL
    )
  
  ggsave(out_png, p, width = 10, height = max(5, 0.3 * nrow(df) + 2), dpi = 150, bg = "white")
}

plot_gsea_barplot <- function(gsea_df, out_png, top_n = 20) {
  if (is.null(gsea_df) || nrow(gsea_df) == 0) return(invisible(NULL))
  
  # barplot 使用简化的 ggplot2 版本（plotthis 的 BarPlot 不适合GSEA）
  df <- gsea_df
  df <- df[order(df$p.adjust), ]
  df <- head(df, top_n)
  df$Description <- factor(df$Description, levels = df$Description)  # 保持排序
  
  # 使用 NES 的符号着色
  df$Direction <- ifelse(df$NES > 0, "Enriched", "Depleted")
  
  p <- ggplot(df, aes(x = NES, y = Description, fill = Direction)) +
    geom_col(alpha = 0.85) +
    scale_fill_manual(values = c("Enriched" = "#d73027", "Depleted" = "#4575b4")) +
    theme_bw(base_size = 13) +
    theme(
      axis.text.y = element_text(size = 11),
      panel.grid.major.y = element_line(color = "grey90"),
      panel.grid.minor = element_blank(),
      legend.position = "bottom"
    ) +
    labs(
      title = sprintf("GSEA Enrichment Barplot (top %d pathways)", nrow(df)),
      x = "Normalized Enrichment Score (NES)",
      y = NULL,
      fill = "Enrichment Direction"
    )
  
  ggsave(out_png, p, width = 10, height = max(5, 0.3 * nrow(df) + 2), dpi = 150, bg = "white")
}

run_gsva <- function(vst_matrix, msigdb_dir, species, gmt_file, method = "gsva") {
  if (!requireNamespace("GSVA", quietly = TRUE)) stop("缺少 GSVA")

  geneset_df <- get_geneset_df(msigdb_dir, species, gmt_file)
  geneset_list_raw <- split(geneset_df$gene_symbol, geneset_df$gs_name)

  expr_genes <- rownames(vst_matrix)
  geneset_list <- lapply(geneset_list_raw, function(genes) intersect(genes, expr_genes))
  geneset_list <- geneset_list[sapply(geneset_list, length) > 0]
  if (length(geneset_list) == 0) stop("没有匹配的基因集（GSVA）")

  GSVA::gsva(
    expr = vst_matrix,
    gset.idx.list = geneset_list,
    method = method,
    min.sz = 5,
    max.sz = 500,
    verbose = FALSE
  )
}

zscore_matrix <- function(mat) {
  t(scale(t(mat)))
}

plot_heatmap_png <- function(mat, out_png, title = "Heatmap") {
  mat_scaled <- zscore_matrix(mat)
  mat_scaled[is.na(mat_scaled)] <- 0
  mat_scaled[is.infinite(mat_scaled)] <- 0
  col_fun <- circlize::colorRamp2(breaks = c(-2, 0, 2), colors = c("#2166AC", "#F7F7F7", "#B2182B"))

  ht <- ComplexHeatmap::Heatmap(
    matrix = mat_scaled,
    col = col_fun,
    name = "Z",
    show_row_names = TRUE,
    show_column_names = TRUE,
    cluster_rows = TRUE,
    cluster_columns = TRUE,
    column_title = title
  )

  png(out_png, width = 1400, height = 1200, res = 150)
  ComplexHeatmap::draw(ht, heatmap_legend_side = "right")
  dev.off()
}

get_tf_network_cached <- function(database, organism, cache_dir, levels = c("A", "B", "C")) {
  if (!requireNamespace("decoupleR", quietly = TRUE)) stop("缺少 decoupleR")

  if (!dir.exists(cache_dir)) dir.create(cache_dir, recursive = TRUE)
  if (database == "collectri") {
    cache_file <- file.path(cache_dir, paste0("collectri_", organism, ".rds"))
  } else {
    levels_str <- paste(sort(levels), collapse = "")
    cache_file <- file.path(cache_dir, paste0("dorothea_", organism, "_", levels_str, ".rds"))
  }

  # 优先使用本地缓存文件
  if (file.exists(cache_file)) {
    tryCatch({
      network <- readRDS(cache_file)
      if (!is.null(network) && nrow(network) > 0) {
        return(network)
      }
    }, error = function(e) {
      warning("读取缓存文件失败，将重新下载: ", e$message)
    })
  }

  # 如果缓存不存在或读取失败，尝试下载
  tryCatch({
    if (database == "collectri") {
      network <- decoupleR::get_collectri(organism = organism, split_complexes = FALSE)
    } else {
      network <- decoupleR::get_dorothea(organism = organism, levels = levels)
    }

    if (!is.null(network) && nrow(network) > 0) {
      saveRDS(network, cache_file)
      return(network)
    }
  }, error = function(e) {
    warning("下载网络失败: ", e$message)
  })

  stop(paste0("无法获取 TF 网络 (database=", database, ", organism=", organism, ")。请运行 scripts/download_tf_networks.R 下载网络文件。"))
}

run_tf_activity <- function(vst_matrix, organism, cache_dir,
                            database = "collectri", method = "ulm",
                            dorothea_levels = c("A", "B", "C"),
                            minsize = 5) {
  if (!requireNamespace("decoupleR", quietly = TRUE)) stop("缺少 decoupleR")
  if (!requireNamespace("OmnipathR", quietly = TRUE)) stop("缺少 OmnipathR")

  net <- get_tf_network_cached(database = database, organism = organism, cache_dir = cache_dir, levels = dorothea_levels)
  if (is.null(net) || nrow(net) == 0) stop("无法获取 TF 网络")

  mat <- as.matrix(vst_matrix)
  
  # 检查网络与矩阵的基因交集
  network_targets <- unique(net$target)
  matrix_genes <- rownames(mat)
  common_genes <- intersect(network_targets, matrix_genes)
  
  if (length(common_genes) == 0) {
    stop(paste0(
      "网络与表达矩阵没有共同的基因。",
      " 网络中的target基因数: ", length(network_targets),
      ", 矩阵中的基因数: ", length(matrix_genes),
      "。请检查基因命名是否一致（Gene Symbol vs Ensembl ID等）。"
    ))
  }
  
  # 过滤网络，只保留矩阵中存在的target
  net_filtered <- net[net$target %in% common_genes, , drop = FALSE]
  
  # 检查每个source有多少个target
  source_target_counts <- table(net_filtered$source)
  sources_with_enough_targets <- names(source_target_counts)[source_target_counts >= minsize]
  
  if (length(sources_with_enough_targets) == 0) {
    # 尝试降低minsize
    max_targets <- max(source_target_counts)
    suggested_minsize <- max(1, floor(max_targets * 0.5))
    warning(paste0(
      "使用 minsize=", minsize, " 时没有source满足条件。",
      " 最大target数: ", max_targets,
      "。尝试使用 minsize=", suggested_minsize
    ))
    minsize <- suggested_minsize
    sources_with_enough_targets <- names(source_target_counts)[source_target_counts >= minsize]
    
    if (length(sources_with_enough_targets) == 0) {
      stop(paste0(
        "Network is empty after intersecting it with mat and filtering it by sources with at least ", minsize, " targets.",
        " 共同基因数: ", length(common_genes),
        ", 网络边数: ", nrow(net_filtered),
        ", 最大source的target数: ", max_targets,
        "。请检查数据或降低minsize参数。"
      ))
    }
  }
  
  # 进一步过滤网络
  net_filtered <- net_filtered[net_filtered$source %in% sources_with_enough_targets, , drop = FALSE]

  # 运行TF活性分析
  result <- tryCatch({
    if (method == "ulm") {
      decoupleR::run_ulm(mat = mat, network = net_filtered, .source = "source", .target = "target", .mor = "mor", minsize = minsize)
    } else if (method == "viper") {
      decoupleR::run_viper(mat = mat, network = net_filtered, .source = "source", .target = "target", .mor = "mor", minsize = minsize)
    } else {
      decoupleR::run_wmean(mat = mat, network = net_filtered, .source = "source", .target = "target", .mor = "mor", minsize = minsize)
    }
  }, error = function(e) {
    # 如果仍然失败，提供详细诊断信息
    stop(paste0(
      "TF分析失败: ", e$message,
      "\n诊断信息:",
      "\n  - 共同基因数: ", length(common_genes),
      "\n  - 过滤后网络边数: ", nrow(net_filtered),
      "\n  - 有效source数: ", length(sources_with_enough_targets),
      "\n  - 使用的minsize: ", minsize,
      "\n  - 网络数据库: ", database,
      "\n  - 物种: ", organism
    ))
  })
  
  result
}

plot_tf_barplot <- function(tf_long, out_png, top_n = 25) {
  df <- tf_long %>%
    group_by(source) %>%
    summarise(mean_score = mean(score, na.rm = TRUE), .groups = "drop") %>%
    arrange(desc(abs(mean_score))) %>%
    head(top_n) %>%
    arrange(mean_score) %>%
    mutate(source = factor(source, levels = source))

  p <- ggplot(df, aes(x = mean_score, y = source, fill = mean_score)) +
    geom_col() +
    scale_fill_gradient2(low = "#2166AC", mid = "#F7F7F7", high = "#B2182B", midpoint = 0) +
    theme_bw(base_size = 12) +
    theme(legend.position = "none") +
    labs(x = "Mean TF activity", y = NULL, title = sprintf("Top %d TF", nrow(df)))

  ggsave(out_png, p, width = 8, height = max(6, 0.22 * nrow(df) + 2), dpi = 150, bg = "white")
}
