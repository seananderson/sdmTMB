#' Turn sdmTMB model output into a tidy data frame
#'
#' @param x Output from [sdmTMB()].
#' @param effects A character vector including one or more of "fixed"
#'   (fixed-effect parameters), "ran_pars" (standard deviations, spatial range,
#'   and other random effect terms).
#' @param conf.int Include a confidence interval?
#' @param conf.level Confidence level for CI.
#' @param exponentiate Whether to exponentiate the fixed-effect coefficient
#'   estimates and confidence intervals.
#' @param ... Extra arguments (not used).
#'
#' @return A data frame
#' @details
#' Follows the conventions of the \pkg{broom} and \pkg{broom.mixed} packages.
#'
#' Note that the standard errors for variance terms are not in natural
#' and not log space and so are a very rough approximation.
#' @export
#'
#' @importFrom assertthat assert_that
#' @examples
#' # See ?sdmTMB
tidy.sdmTMB <- function(x, effects = c("fixed", "ran_pars"),
                 conf.int = FALSE, conf.level = 0.95, exponentiate = FALSE, ...) {
  effects <- match.arg(effects)
  assert_that(is.logical(exponentiate))
  assert_that(is.logical(conf.int))
  if (conf.int) {
    assert_that(is.numeric(conf.level),
      conf.level > 0, conf.level < 1,
      length(conf.level) == 1,
      msg = "`conf.level` must be length 1 and between 0 and 1")
  }

  # .formula <- check_and_parse_thresh_params(x$formula, x$data)$formula
  .formula <- x$split_formula$fixedFormula
  if (!"mgcv" %in% names(x)) x[["mgcv"]] <- FALSE
  if (isFALSE(x$mgcv)) {
    fe_names <- colnames(model.matrix(.formula, x$data))
  } else {
    fe_names <- colnames(model.matrix(mgcv::gam(.formula, data = x$data)))
  }

  se_rep <- as.list(x$sd_report, "Std. Error", report = TRUE)
  est_rep <- as.list(x$sd_report, "Estimate", report = TRUE)
  se <- as.list(x$sd_report, "Std. Error", report = FALSE)
  est <- as.list(x$sd_report, "Estimate", report = FALSE)
  b_j <- est$b_j[!fe_names == "offset"]
  b_j_se <- se$b_j[!fe_names == "offset"]
  fe_names <- fe_names[!fe_names == "offset"]
  out <- data.frame(term = fe_names, estimate = b_j, std.error = b_j_se, stringsAsFactors = FALSE)
  crit <- stats::qnorm(1 - (1 - conf.level) / 2)
  if (exponentiate) trans <- exp else trans <- I
  if (exponentiate) out$estimate <- trans(out$estimate)

  if (x$tmb_data$threshold_func > 0) {
    if (x$threshold_function == 1L) {
      par_name <- paste0(x$threshold_parameter, c("-slope", "-breakpt"))
    } else {
      par_name <- paste0(x$threshold_parameter, c("-s50", "-s95", "-smax"))
    }
    out <- rbind(
      out,
      data.frame(
        term = par_name, estimate = est$b_threshold,
        std.error = se$b_threshold, stringsAsFactors = FALSE
      )
    )
  }

  if (conf.int) {
    out$conf.low <- as.numeric(trans(out$estimate - crit * out$std.error))
    out$conf.high <- as.numeric(trans(out$estimate + crit * out$std.error))
  }

  se <- c(se, se_rep)
  est <- c(est, est_rep)
  ii <- 1
  if (length(unique(est$sigma_E)) == 1L) {
    se$sigma_E <- se$sigma_E[1]
    est$sigma_E <- est$sigma_E[1]
    se$log_sigma_E <- se$log_sigma_E[1]
    est$log_sigma_E <- est$log_sigma_E[1]
  }

  out_re <- list()
  log_name <- c("log_range")
  name <- c("range")
  if (!isTRUE(is.na(x$tmb_map$ln_phi))) {
    log_name <- c(log_name, "ln_phi")
    name <- c(name, "phi")
  }
  if (x$tmb_data$include_spatial) {
    log_name <- c(log_name, "log_sigma_O")
    name <- c(name, "sigma_O")
  }
  if (!x$tmb_data$spatial_only) {
    log_name <- c(log_name, "log_sigma_E")
    name <- c(name, "sigma_E")
  }
  if (x$tmb_data$spatial_trend) {
    log_name <- c(log_name, "log_sigma_O_trend", "ln_tau_V")
    name <- c(name, "sigma_O_trend", "ln_tau_V")
  }
  if (x$tmb_data$include_spatial) {
    log_name <- c(log_name, "log_sigma_O_trend")
    name <- c(name, "sigma_O_trend")
  }
  if (length(est$ln_tau_G) > 0L) {
    log_name <- c(log_name, "ln_tau_G")
    name <- c(name, "ln_tau_G")
  }
  j <- 0
  for (i in name) {
    j <- j + 1
    if (i %in% names(est)) {
      .e <- est[[log_name[j]]]
      .se <- se[[log_name[j]]]
      out_re[[i]] <- data.frame(
        term = i, estimate = est[[i]], std.error = NA,
        conf.low = exp(.e - crit * .se),
        conf.high = exp(.e + crit * .se),
        stringsAsFactors = FALSE
      )
      if (i == "sigma_O_trend") out_re[[i]]$term <- "sigma_Z"
      ii <- ii + 1
    }
    out_re[[i]]$std.error <- NA
  }
  if ("ln_tau_G" %in% names(out_re)) {
    out_re$ln_tau_G$estimate <- exp(out_re$ln_tau_G$estimate)
    out_re$ln_tau_G$term <- "tau_G"
  }

  r <- x$tmb_obj$report()
  if (!is.null(r$rho) && r$rho != 0L) {
    ar_phi <- est$ar1_phi
    ar_phi_se <- se$ar1_phi
    rho_est <- 2 * stats::plogis(ar_phi) - 1
    rho_lwr <- 2 * stats::plogis(ar_phi - crit * ar_phi_se) - 1
    rho_upr <- 2 * stats::plogis(ar_phi + crit * ar_phi_se) - 1
    out_re[[ii]] <- data.frame(
      term = "rho", estimate = rho_est, std.error = NA,
      conf.low = rho_lwr, conf.high = rho_upr, stringsAsFactors = FALSE
    )
    ii <- ii + 1
  }

  out_re <- do.call("rbind", out_re)
  row.names(out_re) <- NULL

  if (identical(est$ln_tau_E, 0)) out_re <- out_re[out_re$term != "sigma_E", ]
  if (identical(est$ln_tau_V, 0)) out_re <- out_re[out_re$term != "tau_V", ]
  if (identical(est$ln_tau_O, 0)) out_re <- out_re[out_re$term != "sigma_O", ]
  if (identical(est$ln_tau_O_trend, 0)) out_re <- out_re[out_re$term != "sigma_Z", ]

  if (!conf.int) {
    out_re[["conf.low"]] <- NULL
    out_re[["conf.high"]] <- NULL
  }

  if (effects == "fixed") {
    return(out)
  } else {
    return(out_re)
  }
}

#' @importFrom generics tidy
#' @export
generics::tidy
