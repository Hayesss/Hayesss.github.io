#!/usr/bin/env Rscript

# 下载并保存 decoupleR 的 TF 网络文件到本地
# 用法: Rscript scripts/download_tf_networks.R [cache_dir]

args <- commandArgs(trailingOnly = TRUE)
cache_dir <- if (length(args) > 0) args[1] else "cache"

if (!requireNamespace("decoupleR", quietly = TRUE)) {
  if (!requireNamespace("BiocManager", quietly = TRUE)) {
    install.packages("BiocManager", repos = "https://cloud.r-project.org")
  }
  BiocManager::install("decoupleR", ask = FALSE, update = FALSE)
}

if (!dir.exists(cache_dir)) {
  dir.create(cache_dir, recursive = TRUE)
}

message("开始下载 TF 网络文件到: ", cache_dir)

# 下载 collectri 网络 (human 和 mouse)
for (org in c("human", "mouse")) {
  cache_file <- file.path(cache_dir, paste0("collectri_", org, ".rds"))
  if (file.exists(cache_file)) {
    message("[跳过] 已存在: ", cache_file)
    next
  }
  message("[下载] collectri_", org, "...")
  tryCatch({
    network <- decoupleR::get_collectri(organism = org, split_complexes = FALSE)
    if (!is.null(network) && nrow(network) > 0) {
      saveRDS(network, cache_file)
      message("[成功] 保存: ", cache_file, " (", nrow(network), " 条边)")
    } else {
      message("[警告] collectri_", org, " 网络为空")
    }
  }, error = function(e) {
    message("[错误] collectri_", org, ": ", e$message)
  })
}

# 下载 dorothea 网络 (human 和 mouse, 不同置信度级别)
for (org in c("human", "mouse")) {
  for (levels in list(c("A"), c("A", "B"), c("A", "B", "C"), c("A", "B", "C", "D"))) {
    levels_str <- paste(sort(levels), collapse = "")
    cache_file <- file.path(cache_dir, paste0("dorothea_", org, "_", levels_str, ".rds"))
    if (file.exists(cache_file)) {
      message("[跳过] 已存在: ", cache_file)
      next
    }
    message("[下载] dorothea_", org, "_", levels_str, "...")
    tryCatch({
      network <- decoupleR::get_dorothea(organism = org, levels = levels)
      if (!is.null(network) && nrow(network) > 0) {
        saveRDS(network, cache_file)
        message("[成功] 保存: ", cache_file, " (", nrow(network), " 条边)")
      } else {
        message("[警告] dorothea_", org, "_", levels_str, " 网络为空")
      }
    }, error = function(e) {
      message("[错误] dorothea_", org, "_", levels_str, ": ", e$message)
    })
  }
}

message("完成！所有网络文件已保存到: ", cache_dir)
