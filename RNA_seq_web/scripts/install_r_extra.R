#!/usr/bin/env Rscript

# 在 conda 环境中补齐可能缺失的 R/Bioc 包

cran_pkgs <- c(
  'ggsci',
  'plotthis'
)

bioc_pkgs <- c(
  'OmnipathR',
  'decoupleR'
)

ensure_cran <- function(pkgs) {
  for (p in pkgs) {
    if (!requireNamespace(p, quietly = TRUE)) {
      message('[CRAN] installing: ', p)
      install.packages(p, repos = 'https://cloud.r-project.org')
    } else {
      message('[CRAN] ok: ', p)
    }
  }
}

ensure_bioc <- function(pkgs) {
  if (!requireNamespace('BiocManager', quietly = TRUE)) {
    install.packages('BiocManager', repos = 'https://cloud.r-project.org')
  }
  for (p in pkgs) {
    if (!requireNamespace(p, quietly = TRUE)) {
      message('[Bioc] installing: ', p)
      BiocManager::install(p, ask = FALSE, update = FALSE)
    } else {
      message('[Bioc] ok: ', p)
    }
  }
}

ensure_cran(cran_pkgs)
ensure_bioc(bioc_pkgs)

message('done')
