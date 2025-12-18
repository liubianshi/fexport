#!/usr/bin/env Rscript
# parse_rmd.R

suppressPackageStartupMessages({
  require(yaml)
  require(rmarkdown)
  require(rlang)
})

# ------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------

# 更健壮的 Lua Filter 查找
get_pandoc_lua_filter <- function() {
  filters <- c(
    "rmarkdown/lua/custom-environment.lua",
    "rmarkdown/lua/pagebreak.lua",
    "rmarkdown/lua/latex-div.lua"
  )

  # 在 rmarkdown 包安装目录中查找
  paths <- sapply(filters, function(x) system.file(x, package = "rmarkdown"))

  # 过滤掉找不到的路径
  paths[paths != ""]
}

# 准备元数据
prepare_meta <- function(outformat, infile, config_path) {
  # 默认配置
  default_meta <- list(
    infile = infile,
    outfile = sub("\\.[^.]+$", paste0(".", outformat), infile),
    render = "rmarkdown::render",
    run_pandoc = FALSE,
    opt = list(fig_caption = TRUE),
    intermediates_dir = "./cache/draft",
    output_dir = "./cache/draft"
  )

  # 读取 YAML 配置
  full_config <- yaml::read_yaml(config_path)
  if (!outformat %in% names(full_config)) {
    warning(paste("Format", outformat, "not found in config file."))
  }

  config_meta <- full_config[[outformat]]

  # 特殊处理：如果是 PDF/HTML 中间格式
  if (outformat %in% c("pdf", "html", "beamer")) {
    config_meta$outfile <- sub("\\.[^.]+$", ".knit.md", infile)
  }

  utils::modifyList(default_meta, config_meta)
}

# 导出 LaTeX 依赖 (knit_meta)
write_knit_meta_file <- function(parse_res, output_dir) {
  knit_meta <- attr(parse_res, 'knit_meta')
  if (is.null(knit_meta) || length(knit_meta) == 0) {
    return(NULL)
  }

  lines <- c()
  for (item in knit_meta) {
    if (inherits(item, 'latex_dependency')) {
      pkg_line <- sprintf('\\usepackage{%s}', item[['name']])
      if (!is.null(item[['options']])) {
        # fmt: skip
        pkg_line <- sprintf('\\usepackage[%s]{%s}', paste(item[['options']], collapse = ","), item[['name']])
      }
      lines <- c(lines, pkg_line, item[['extra_lines']])
    }
  }

  if (length(lines) == 0) {
    return(NULL)
  }

  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE)
  }
  outfile <- file.path(output_dir, "knit_meta")
  writeLines(lines, outfile)
  return(outfile)
}

# 执行渲染
do_render <- function(meta) {
  output_format_func <- rlang::parse_expr(meta$out)
  output_format_obj <- rlang::exec(output_format_func, !!!meta$opt)

  # 处理 .md 输入 (复制为 .Rmd)
  infile <- meta$infile
  temp_rmd <- NULL

  if (grepl("\\.md$", infile, ignore.case = TRUE)) {
    temp_rmd <- sub("\\.md$", ".Rmd", infile, ignore.case = TRUE)
    if (file.exists(temp_rmd)) {
      stop(paste(temp_rmd, "already exists, aborting safely."))
    }
    file.copy(infile, temp_rmd)
    infile <- temp_rmd
  }

  # 确保清理临时 .Rmd
  on.exit({
    if (!is.null(temp_rmd) && file.exists(temp_rmd)) file.remove(temp_rmd)
  })

  render_func <- rlang::parse_expr(meta$render)

  # 调用 Render
  result_path <- rlang::exec(
    render_func,
    input = infile,
    output_format = output_format_obj,
    run_pandoc = meta$run_pandoc,
    output_file = basename(meta$outfile), # 通常 render 只需要文件名
    output_dir = meta$output_dir,
    intermediates_dir = meta$intermediates_dir,
    quiet = TRUE
  )

  return(result_path)
}

# ------------------------------------------------------------------------------
# Main Logic
# ------------------------------------------------------------------------------

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 3) {
  stop("Usage: parse_rmd.R <format> <infile> <config_yaml> [output_yaml]")
}

outformat <- args[1]
infile <- args[2]
config_path <- args[3]
result_file <- if (length(args) >= 4) args[4] else "rmd_meta.yaml"

tryCatch(
  {
    # 1. 准备配置
    meta <- prepare_meta(outformat, infile, config_path)

    # 2. 执行渲染
    render_res <- do_render(meta)

    # 3. 处理路径修正 (Bookdown 特有)
    if (!is.null(meta$superfluous_dir)) {
      meta$output_dir <- file.path(meta$superfluous_dir, meta$output_dir)
    }

    # 确定最终输出文件绝对路径
    # render_res 通常返回的是最终文件的路径，如果是相对路径，结合 output_dir
    if (!is_absolute_path(render_res)) {
      meta$outfile <- file.path(meta$output_dir, basename(render_res))
    } else {
      meta$outfile <- render_res
    }

    # 4. 提取副作用 (Lua Filters, Dependencies)
    meta$knit_meta <- write_knit_meta_file(render_res, meta$output_dir)
    meta$lua_filters <- get_pandoc_lua_filter()

    # 5. 写回结果给 Perl
    yaml::write_yaml(meta, result_file)

    cat("[R] RMarkdown Render Success:", meta$outfile, "\n")
  },
  error = function(e) {
    cat("[R Error]", conditionMessage(e), "\n")
    quit(save = "no", status = 1)
  }
)

# END
