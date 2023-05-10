#!/usr/bin/env -S Rscript --no-init-file --no-save --no-restore
require(yaml)

parse_args <- function() {
    args <- commandArgs(trailingOnly = TRUE)
    stopifnot(length(args) >= 3L)

    args_list <- as.list(args[1:4])
    names(args_list) <- c("outformat", "infile", "yaml_file", "result_file")

    if (length(args) == 3) {
        args_list$result_file <- NULL
    } 
    args_list
}

get_pandoc_lua_filter <- function() {
    RLib <- .libPaths()[1]
    c("bookdown/rmarkdown/lua/custom-environment.lua",
      "rmarkdown/rmarkdown/lua/pagebreak.lua",
      "rmarkdown/rmarkdown/lua/latex-div.lua") |>
    purrr::map(~ file.path(RLib, .x))
}

complete_config_info <- function(config, default) {
    if (is.null(config)) return(default)
    if (is.null(default)) return(config)

    stopifnot(is.null(names(config)) == is.null(names(default)))
    if (is.null(names(config))) {
        return(union(config, default))
    }

    nms <- union(names(config), names(default))
    names(nms) <- nms
    lapply(nms, function(n) {
        if (is.list(default[[n]]) | is.list(config[[n]])) {
            complete_config_info(default[[n]], config[[n]])
        } else {
            if (is.null(config[[n]])) default[[n]] else config[[n]]
        }
    })
}

get_meta <- function(outformat, infile, yaml_file, ...) {
    default_meta <- list(
        infile            = infile,
        outfile           = sub("\\.[Rr](md|markdown)$", ".knit.md", infile),
        render            = "rmarkdown::render",
        run_pandoc        = FALSE,
        opt               = list(latex_engine     = "xelatex",
                                clean_supporting = FALSE),
        intermediates_dir = tempdir(),
        output_dir        = tempdir()
    )
    config_meta <- yaml::read_yaml(yaml_file)[[outformat]]
    complete_config_info(config_meta, default_meta)
}
write_knit_meta <- function(pares_res, intermediates_dir) {
    knit_meta <- attr(parse_res, 'knit_meta')
    if (is.null(knit_meta)) return(NULL)

    knit_meta <- purrr::map(knit_meta, ~ {
        if (class(.x) == 'latex_dependency') {
            c(gettextf('\\usepackage{%s}', .x[['name']]), .x[['extra_lines']])
        } else {
            NULL
        }
    })

    outfile <- file.path(intermediates_dir, "knit_meta")
    fileConn<-file(outfile)
    writeLines(unlist(knit_meta), fileConn)
    close(fileConn)

    return(outfile)
}

args          <- parse_args()
meta          <- do.call(get_meta, args)
output_format <- rlang::exec(rlang::parse_expr(meta$out), !!!(meta$opt))
parse_res     <- rlang::exec(rlang::parse_expr(meta$render),
                             output_format     = output_format,
                             run_pandoc        = meta$run_pandoc,
                             output_dir        = meta$output_dir,
                             intermediates_dir = meta$intermediates_dir)

if (!is.null(meta$superfluous_dir)) {
    meta$output_dir <- file.path(meta$superfluous_dir, meta$output_dir)
}
meta$outfile     <- file.path(meta$output_dir, meta$outfile)
meta$knit_meta   <- write_knit_meta(parse_res, meta$output_dir)
meta$lua_filters <- get_pandoc_lua_filter()

if (is.null(args$result_file)) {
    args$result_file <- file.path(meta$output_dir, "rmd_meta.yaml")
}

yaml::write_yaml(meta, args$result_file)

cat("Rmarkdown Parse Success\n")
# END
