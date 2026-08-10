# =============================================================================
# Coconut Water Working Paper - R data pipeline
#
# VAT Reform, Financial Disclosure and Fiscal Stress: Evidence from Finland
#
# This is the production pipeline. It retrieves firm registration and
# disclosure data from three Finnish government APIs, cross-matches them by
# Business ID, constructs the estimation panels, and runs the difference-in-
# differences specifications reported in the paper.
#
# Production run: 169,301 limited companies, 196 listed firms, 6,708
# cooperatives. The notice retrieval in Part 3 took 29.2 hours for the
# control group and 3.8 minutes for the treatment group.
#
# 
# Last updated: August 2026
# =============================================================================

library(httr)
library(jsonlite)
library(data.table)
library(tidyverse)
library(fixest)

# --- paths -------------------------------------------------------------------
# Note the double space in the directory name; fread() must be called with the
# file= argument rather than positionally, because when a path does not exist
# data.table treats the first argument as a shell command and the space breaks
# the call with a misleading error.
cw <- path.expand("~/Desktop/Coconut water/coconut  water/")
cd <- paste0(cw, "cleaned data/")

PRH_BASE  <- "https://avoindata.prh.fi/opendata-registerednotices-api/v3"
YTJ_BASE  <- "https://avoindata.prh.fi/opendata-ytj-api/v3"

EVENT_START    <- as.Date("2023-03-01")
TREATMENT_DATE <- as.Date("2024-09-01")
EVENT_END      <- as.Date("2026-02-28")


# =============================================================================
# PART 1  Missing-value guard
# =============================================================================
# The PRH API returns irregular nested structures: a field may be absent, NULL,
# an empty list, or an empty string depending on the company. Every nested
# access in Part 2 passes through this guard. Without it the parser fails with
# "replacement has length zero" on the first company that lacks an English
# trade name.

safe <- function(x) {
  if (is.null(x) || length(x) == 0 || all(is.na(x))) return(NA_character_)
  v <- as.character(x[[1]])
  if (!nzchar(trimws(v))) return(NA_character_)
  trimws(v)
}


# =============================================================================
# PART 2  Nested JSON parsing
# =============================================================================
# Flattens one company record. Field logic:
#   business_id       businessId$value (nested object, not a plain string)
#   company_name      names[] entry with type "1" (Finnish) and no endDate,
#                     i.e. the name currently in force; falls back to the
#                     first name on record
#   company_name_en   names[] entry with type "2" (English), current
#   street/post_code  addresses[] entry with type 1 (visiting address)
#   city              nested inside addresses[]$postOffices, preferring
#                     languageCode "1" (Finnish)
#   company_situation SANE (restructuring) / SELTILA (liquidation) /
#                     KONK (bankruptcy) markers used to build the exit series

parse_company <- function(rec) {

  pick_name <- function(nm_list, type_code) {
    if (is.null(nm_list) || length(nm_list) == 0) return(NA_character_)
    hit <- Filter(function(n) {
      identical(safe(n$type), type_code) && is.null(n$endDate)
    }, nm_list)
    if (length(hit) == 0) hit <- nm_list
    safe(hit[[1]]$name)
  }

  addr <- NULL
  if (!is.null(rec$addresses) && length(rec$addresses) > 0) {
    visiting <- Filter(function(a) identical(safe(a$type), "1"), rec$addresses)
    addr <- if (length(visiting) > 0) visiting[[1]] else rec$addresses[[1]]
  }

  city <- NA_character_; muni <- NA_character_
  if (!is.null(addr$postOffices) && length(addr$postOffices) > 0) {
    fi <- Filter(function(p) identical(safe(p$languageCode), "1"),
                 addr$postOffices)
    po <- if (length(fi) > 0) fi[[1]] else addr$postOffices[[1]]
    city <- safe(po$city)
    muni <- safe(po$municipalityCode)
  }

  sit <- NA_character_
  if (!is.null(rec$companySituations) && length(rec$companySituations) > 0) {
    sit <- paste(unique(vapply(rec$companySituations,
                               function(s) safe(s$type), character(1))),
                 collapse = ";")
  }

  data.table(
    business_id       = safe(rec$businessId$value),
    company_name      = pick_name(rec$names, "1"),
    company_name_en   = pick_name(rec$names, "2"),
    registration_date = safe(rec$registrationDate),
    end_date          = safe(rec$endDate),
    street            = safe(addr$street),
    post_code         = safe(addr$postCode),
    city              = city,
    municipality_code = muni,
    company_situation = sit
  )
}


# =============================================================================
# PART 3  Paginated registration retrieval
# =============================================================================
# The YTJ endpoint caps every response at 100 rows and its pagination is
# ONE-BASED. Verified empirically: page=0 and page=1 return identical content,
# because the API silently coerces 0 to 1. Starting the loop at 0 therefore
# double-fetches the first page and, worse, trips the (n >= total) stop
# condition one page early, silently dropping the final partial page - 28 of
# 428 public limited companies in the verification run. Duplicate-page
# detection is included as a second line of defence.

fetch_companies <- function(company_form, max_pages = NULL) {

  records <- list()
  page <- 1L
  prev_first_id <- NULL

  repeat {
    resp <- GET(paste0(YTJ_BASE, "/companies"),
                query = list(companyForm = company_form, page = page),
                timeout(60))

    if (http_error(resp)) {
      warning(sprintf("page %d returned HTTP %d", page, status_code(resp)))
      break
    }

    payload <- fromJSON(content(resp, "text", encoding = "UTF-8"),
                        simplifyVector = FALSE)
    batch <- payload$companies
    total <- payload$totalResults

    if (length(batch) == 0) break

    first_id <- safe(batch[[1]]$businessId$value)
    if (!is.null(prev_first_id) && identical(first_id, prev_first_id)) {
      warning(sprintf("page %d duplicates page %d - stopping", page, page - 1))
      break
    }
    prev_first_id <- first_id

    records <- c(records, batch)
    cat(sprintf("  page %3d  (%d/%d fetched)\n", page, length(records), total))

    if (length(records) >= total) break
    if (!is.null(max_pages) && page >= max_pages) break

    page <- page + 1L
    Sys.sleep(0.5)
  }

  rbindlist(lapply(records, parse_company), fill = TRUE)
}


# =============================================================================
# PART 4  Notice retrieval with checkpointing
# =============================================================================
# One GET per Business ID. The batch-search endpoint was tried first but fails
# with HTTP 504 from roughly page 6 onward, so the per-company endpoint is the
# only route that completes at this scale.
#
# Two design points that matter over a 29-hour run:
#   1. done_ids is tracked independently of the output, so firms that legit-
#      imately have zero notices are not re-fetched on every restart. 94 of
#      169,301 control firms have no notice history at all.
#   2. Results are flushed to disk every batch_size firms and dropped from
#      memory. Holding 3.5 million notice records in a single list exhausts
#      RAM on the production machine.
#
# The retrieval returns each firm's COMPLETE history rather than the event
# window. This matters: computing compliance rates from event-window extracts
# understates listed-firm compliance in the t-3 window as 3.1 per cent against
# a true value of 97.3 per cent, because a firm's earlier filings simply fall
# outside the extract. The registry's own boundary is 7 November 2014.

fetch_notices <- function(business_ids, out_dir, progress_file,
                          batch_size = 1000, sleep_sec = 0.5,
                          max_retry = 3) {

  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  done_ids <- if (file.exists(progress_file)) readRDS(progress_file)
              else character(0)

  todo <- setdiff(business_ids, done_ids)
  cat(sprintf("total %d | done %d | remaining %d\n",
              length(business_ids), length(done_ids), length(todo)))

  buffer <- list()
  batch_no <- length(list.files(out_dir, pattern = "\\.csv$"))
  errors <- character(0)

  for (i in seq_along(todo)) {
    bid <- todo[i]
    ok <- FALSE

    for (attempt in seq_len(max_retry)) {
      resp <- try(GET(paste0(PRH_BASE, "/", bid), timeout(60)), silent = TRUE)

      if (!inherits(resp, "try-error") && status_code(resp) == 200) {
        payload <- fromJSON(content(resp, "text", encoding = "UTF-8"),
                            simplifyVector = FALSE)
        notices <- payload[["publicNotices"]]

        # Absent key, not an empty list, when a firm has no notices.
        if (!is.null(notices) && length(notices) > 0) {
          buffer[[length(buffer) + 1L]] <- rbindlist(lapply(notices, function(n) {
            data.table(
              business_id        = bid,
              registrationDate   = safe(n$registrationDate),
              typeOfRegistration = safe(n$typeOfRegistration),
              recordNumber       = safe(n$recordNumber),
              entryCodes         = paste(unlist(n$entryCodes), collapse = ";")
            )
          }), fill = TRUE)
        }
        ok <- TRUE
        break
      }
      Sys.sleep(2 ^ attempt)   # exponential backoff
    }

    if (!ok) errors <- c(errors, bid)
    done_ids <- c(done_ids, bid)

    if (i %% batch_size == 0 || i == length(todo)) {
      batch_no <- batch_no + 1L
      if (length(buffer) > 0) {
        fwrite(rbindlist(buffer, fill = TRUE),
               file.path(out_dir, sprintf("batch_%04d.csv", batch_no)))
        buffer <- list()
      }
      saveRDS(done_ids, progress_file)
      cat(sprintf("  [%s] %d/%d done, %d errors\n",
                  format(Sys.time(), "%H:%M:%S"), i, length(todo),
                  length(errors)))
    }

    Sys.sleep(sleep_sec)
  }

  if (length(errors) > 0) {
    writeLines(errors, file.path(out_dir, "failed_ids.txt"))
    cat("failed ids written for a patch run:", length(errors), "\n")
  }
  invisible(errors)
}


# =============================================================================
# PART 5  Notice type reference
# =============================================================================
# Retrieved from the /description?code=NRT endpoint rather than inferred from
# the data, so the grouping below is the registry's own taxonomy and not a
# guess. Two historical codes (END, TASE) appear in the data but not in the
# published table.

NOTICE_TYPES <- data.table(
  code = c("TA", "M", "U", "OI", "JH", "FUU", "DIF", "END",
           "H", "T", "VA", "KM", "TASE"),
  label = c("Financial statements", "Amendment notification",
            "Start-up notification", "Rectification",
            "Public summons to creditors", "Merger application",
            "Demerger application", "Termination (historical code)",
            "Application", "Notice", "Supervision",
            "Municipal change notification", "Balance sheet (historical)"),
  group = c("mandatory", "routine", "routine", "routine",
            "distress", "distress", "distress", "distress",
            "other", "other", "other", "other", "other")
)

fetch_notice_types <- function(lang = "EN") {
  resp <- GET(paste0(PRH_BASE, "/description"),
              query = list(code = "NRT", lang = lang))
  fromJSON(content(resp, "text", encoding = "UTF-8"))
}


# =============================================================================
# PART 6  Firm-month panel with extensive-margin outcomes
# =============================================================================
# Builds the balanced firm x month skeleton, merges notice counts onto it, and
# generates both count and binary outcomes. The paper uses the binary ones;
# the counts are retained for the functional-form comparison in Table 4.
#
# Entry and exit truncation: firms that leave the register are retained
# through the month of exit and firms that enter are retained from the month
# of entry, so that structural zeros are not read as non-compliance.

build_firm_month_panel <- function(notices, firm_list, entry_exit = NULL) {

  months <- seq(EVENT_START, EVENT_END, by = "month")
  ym_all <- format(months, "%Y-%m")

  skeleton <- CJ(business_id = unique(firm_list$business_id),
                 ym = ym_all, unique = TRUE)

  nw <- notices[registrationDate >= EVENT_START &
                registrationDate <= EVENT_END]
  nw[, ym := format(registrationDate, "%Y-%m")]

  agg <- nw[, .(
    y_total  = .N,
    y_ta     = sum(typeOfRegistration %in% c("TA", "TASE")),
    y_m      = sum(typeOfRegistration == "M"),
    y_stress = sum(typeOfRegistration %in% c("JH", "FUU", "DIF", "END"))
  ), by = .(business_id, ym)]

  panel <- merge(skeleton, agg, by = c("business_id", "ym"), all.x = TRUE)
  for (v in c("y_total", "y_ta", "y_m", "y_stress")) {
    set(panel, which(is.na(panel[[v]])), v, 0L)
  }

  # extensive margin
  panel[, `:=`(d_any = as.integer(y_total > 0),
               d_ta  = as.integer(y_ta    > 0),
               d_m   = as.integer(y_m     > 0))]

  # treatment structure
  panel <- merge(panel, firm_list[, .(business_id, firm_type)],
                 by = "business_id", all.x = TRUE)
  panel[, treat := as.integer(firm_type %in% c("OYJ", "OY_listed"))]
  panel[, post  := as.integer(ym >= format(TREATMENT_DATE, "%Y-%m"))]
  panel[, did   := treat * post]
  panel[, moy   := as.integer(substr(ym, 6, 7))]

  # entry / exit truncation
  if (!is.null(entry_exit)) {
    panel <- merge(panel, entry_exit[, .(business_id, event_type, event_ym)],
                   by = "business_id", all.x = TRUE)
    panel <- panel[is.na(event_type) |
                   (event_type == "exit"  & ym <= event_ym) |
                   (event_type == "entry" & ym >= event_ym)]
    panel[, c("event_type", "event_ym") := NULL]
  }

  cat(sprintf("panel: %s rows = %s firms x %d months\n",
              format(nrow(panel), big.mark = ","),
              format(uniqueN(panel$business_id), big.mark = ","),
              length(months)))
  panel[]
}


# =============================================================================
# PART 7  Firm-window panel
# =============================================================================
# Aggregates to four 12-month windows anchored on the treatment date. This is
# the specification that is robust to the forwarding delay between the tax
# authority and the registry: statements submitted with a tax return are
# forwarded within 7 days, but those submitted through the tax authority's
# dividend function can take up to 15 months, so a monthly timestamp is a
# noisy measure of when the firm acted. Within a 12-month window the question
# is only whether the firm filed at all, which is invariant to that delay.
#
# on_time is defined as a filing in the first 8 months of the window, matching
# the statutory free-filing period that runs 8 months from fiscal year end.

WINDOWS <- list(
  `t-3` = c("2021-09-01", "2022-08-31"),
  `t-2` = c("2022-09-01", "2023-08-31"),
  `t-1` = c("2023-09-01", "2024-08-31"),
  `t+1` = c("2024-09-01", "2025-08-31")
)

build_firm_window_panel <- function(notices, firm_list) {

  out <- rbindlist(lapply(names(WINDOWS), function(w) {
    lo <- as.Date(WINDOWS[[w]][1]); hi <- as.Date(WINDOWS[[w]][2])

    ta <- notices[typeOfRegistration %in% c("TA", "TASE") &
                  registrationDate >= lo & registrationDate <= hi]

    ta_agg <- ta[, .(
      d_ta     = 1L,
      d_ontime = as.integer(any(registrationDate <= lo + 243))  # 8 months
    ), by = business_id]

    base <- data.table(business_id = unique(firm_list$business_id), win = w)
    merge(base, ta_agg, by = "business_id", all.x = TRUE)
  }), fill = TRUE)

  out[is.na(d_ta),     d_ta     := 0L]
  out[is.na(d_ontime), d_ontime := 0L]

  out <- merge(out, firm_list[, .(business_id, firm_type)],
               by = "business_id", all.x = TRUE)
  out[, treat := as.integer(firm_type %in% c("OYJ", "OY_listed"))]
  out[, post  := as.integer(win == "t+1")]
  out[, did   := treat * post]
  out[]
}


# =============================================================================
# PART 8  Nasdaq disclosure classification
# =============================================================================
# The exchange feed carries 27 category labels. They are collapsed into six
# buckets, and one measurement problem has to be handled explicitly.
#
# Between the pre- and post-periods, share buyback announcements migrated out
# of the dedicated "Changes in company's own shares" category into the residual
# "Other information" category: the residual category's buyback content rose
# from 83 to 602 releases while the count of the underlying transactions barely
# moved (4,213 to 4,275). The same behaviour was relabelled. Any outcome that
# separates voluntary from ad hoc disclosure inherits this artefact, which is
# why the discretionary bucket is kept combined rather than split.

classify_nasdaq <- function(dt) {

  mech_cats <- c("Managers' Transactions",
                 "Changes in company's own shares",
                 "Total number of voting rights and capital",
                 "Net Asset Value")
  disc_cats <- c("Company Announcement", "Inside information", "Investor News")
  peri_cats <- c("Annual Financial Report", "Annual report",
                 "Financial Statement Release", "Half Year financial report",
                 "Interim report (Q1 and Q3)", "Interim information")
  gov_pat   <- "nomination|remuneration|board|general meeting|articles"
  spec_cats <- c("Tender offer", "Prospectus")

  dt[, is_buyback := grepl("own shares|buy-?back|repurchase",
                           headline, ignore.case = TRUE)]

  dt[, bucket3 := fifelse(
    cnsCategory %in% mech_cats |
      (cnsCategory == "Other information" & is_buyback), "mech",
    fifelse(cnsCategory %in% peri_cats, "periodic",
    fifelse(cnsCategory == "Financial Calendar", "fincal",
    fifelse(cnsCategory %in% spec_cats, "special",
    fifelse(grepl(gov_pat, headline, ignore.case = TRUE), "governance",
    fifelse(cnsCategory %in% disc_cats |
              cnsCategory == "Other information", "discretionary",
            "other"))))))]

  cat("bucket counts:\n"); print(dt[, .N, by = bucket3][order(-N)])
  dt[]
}

build_nasdaq_panel <- function(news, firm_list) {

  news[, ym := format(as.Date(releaseTime), "%Y-%m")]
  months <- format(seq(EVENT_START, EVENT_END, by = "month"), "%Y-%m")

  agg <- dcast(news[ym %in% months], business_id + ym ~ bucket3,
               value.var = "disclosureId", fun.aggregate = length)

  skeleton <- CJ(business_id = unique(firm_list$business_id),
                 ym = months, unique = TRUE)
  panel <- merge(skeleton, agg, by = c("business_id", "ym"), all.x = TRUE)

  for (v in setdiff(names(panel), c("business_id", "ym"))) {
    set(panel, which(is.na(panel[[v]])), v, 0L)
  }

  panel[, post := as.integer(ym >= format(TREATMENT_DATE, "%Y-%m"))]
  panel[, event_time := as.integer(
    (as.integer(substr(ym, 1, 4)) * 12 + as.integer(substr(ym, 6, 7))) -
    (2024 * 12 + 9))]

  # segments: the single post dummy averages an initial null against a later
  # decline and reports nothing, so the post period is split
  panel[, seg := fifelse(post == 0, "pre",
                  fifelse(event_time <= 6,  "post_early",
                  fifelse(event_time <= 10, "post_mid", "post_late")))]
  panel[, seg := factor(seg, levels = c("pre", "post_early",
                                        "post_mid", "post_late"))]
  panel[]
}


# =============================================================================
# PART 9  Cross-database matching against the tax register
# =============================================================================
# Matching is on Business ID (Y-tunnus). The diagnostic below is the point of
# this step: a match rate on its own says nothing about whether the shortfall
# is benign. Coverage is therefore broken down by registration cohort and
# cross-checked against filing behaviour.
#
# Production result: 145,746 of 169,294 control firms match (86.1 per cent).
# Coverage by cohort is 98.5 per cent for firms registered up to 2010, 99.3,
# 99.7 and 99.2 per cent for the subsequent cohorts, and 18.4 per cent for
# firms registered from 2024. Firms outside the tax data have a filing rate of
# 34.4 per cent against 97.5 per cent for those inside. The shortfall is
# therefore mechanical - recent registrations have not yet entered the FY2024
# tax file - rather than a selection on profitability.

diagnose_vero_match <- function(vero, registry, panel_ids) {

  vero_ids <- unique(vero$business_id)
  hit      <- intersect(panel_ids, vero_ids)

  cat(sprintf("panel     %s firms\n", format(length(panel_ids), big.mark = ",")))
  cat(sprintf("tax data  %s firms\n", format(length(vero_ids),  big.mark = ",")))
  cat(sprintf("matched   %s (%.1f%%)\n", format(length(hit), big.mark = ","),
              100 * length(hit) / length(panel_ids)))
  cat(sprintf("in tax data but not in panel: %d\n",
              length(setdiff(vero_ids, panel_ids))))

  reg <- registry[, .(business_id = businessId.value,
                      reg_year = as.integer(substr(registrationDate, 1, 4)))]
  reg[, in_vero := as.integer(business_id %in% vero_ids)]
  reg[, cohort := cut(reg_year, c(-Inf, 2010, 2015, 2020, 2023, Inf),
                      labels = c("<=2010", "2011-15", "2016-20",
                                 "2021-23", "2024+"))]

  cat("\ncoverage by registration cohort:\n")
  print(reg[!is.na(cohort), .(n = .N, covered = sum(in_vero),
                              rate = round(mean(in_vero), 3)), by = cohort])

  cat("\nzero rates in the tax variables:\n")
  for (v in c("taxable_income", "total_tax", "tax_refund", "back_tax")) {
    if (v %in% names(vero)) {
      cat(sprintf("  %-16s NA %5.2f%%   zero %5.2f%%\n", v,
                  100 * mean(is.na(vero[[v]])),
                  100 * mean(vero[[v]] == 0, na.rm = TRUE)))
    }
  }
  invisible(hit)
}


# =============================================================================
# PART 10  Estimation
# =============================================================================
# fixest is used rather than reghdfe or plm. On 6.1 million rows with 169,490
# firm fixed effects, Stata's encode() fails outright (its value-label limit is
# 65,536) and reghdfe exhausts memory on the production machine; feols absorbs
# the same specification in seconds.

estimate_baseline <- function(panel) {

  m_any <- feols(d_any ~ did | business_id + ym, panel, cluster = ~business_id)
  m_ta  <- feols(d_ta  ~ did | business_id + ym, panel, cluster = ~business_id)
  m_m   <- feols(d_m   ~ did | business_id + ym, panel, cluster = ~business_id)

  # Seasonality controls. Reported but not preferred: see the placebo below.
  m_ta_moy <- feols(d_ta ~ did | business_id + ym + treat^moy,
                    panel, cluster = ~business_id)

  # Functional-form comparison. The Poisson semi-elasticity is three to four
  # times the proportional effect implied by the linear model, which is the
  # sensitivity Roth and Sant'Anna (2023) describe: with a skewed count
  # outcome and large baseline differences between groups, parallel trends
  # cannot hold in levels and in logs at the same time.
  m_cnt <- feols(y_ta ~ did | business_id + ym, panel, cluster = ~business_id)
  m_poi <- fepois(y_ta ~ did | business_id + ym, panel, cluster = ~business_id)

  etable(m_any, m_ta, m_m, m_cnt, m_poi,
         headers = c("d_any", "d_ta", "d_m", "count OLS", "count Poisson"),
         se.below = TRUE, fitstat = c("n", "r2", "wr2"))

  list(any = m_any, ta = m_ta, m = m_m, ta_moy = m_ta_moy,
       count = m_cnt, poisson = m_poi)
}


# Placebo. The cut-point sits entirely inside the pre-treatment window, so no
# post-reform observation enters and a well-specified design should return
# zero. Note that 2024 cannot be used as a pseudo-treatment year - the reform
# splits it - which is a mistake worth naming because it looks reasonable.

estimate_placebo <- function(panel, cut_ym = "2023-12") {

  pre <- panel[ym < format(TREATMENT_DATE, "%Y-%m")]
  pre[, fake_post := as.integer(ym >= cut_ym)]
  pre[, fake_did  := treat * fake_post]

  p_any <- feols(d_any ~ fake_did | business_id + ym, pre, cluster = ~business_id)
  p_ta  <- feols(d_ta  ~ fake_did | business_id + ym, pre, cluster = ~business_id)
  p_moy <- feols(y_ta  ~ fake_did | business_id + ym + treat^moy,
                 pre, cluster = ~business_id)

  etable(p_any, p_ta, p_moy,
         headers = c("d_any", "d_ta", "count + seasonality"),
         se.below = TRUE)
  list(any = p_any, ta = p_ta, moy = p_moy)
}


# Event study on the firm-window panel. The monthly event study is NOT usable
# for this purpose: at any sub-annual frequency the pre-treatment coefficients
# oscillate with the filing calendar, and interacting treatment with
# month-of-year alongside event-time indicators is collinear by construction -
# month-of-year is fully determined by event time within a single-cohort
# design, so ten interaction terms are dropped whatever package is used.

estimate_event_study <- function(fw) {

  fw[, win_f := factor(win, levels = c("t-3", "t-2", "t-1", "t+1"))]

  es_ta <- feols(d_ta ~ i(win_f, treat, ref = "t-1") | business_id + win_f,
                 fw, cluster = ~business_id)
  es_ot <- feols(d_ontime ~ i(win_f, treat, ref = "t-1") | business_id + win_f,
                 fw, cluster = ~business_id)

  cat("\njoint test of the pre-treatment interactions:\n")
  print(wald(es_ta, keep = "t-3|t-2"))
  print(wald(es_ot, keep = "t-3|t-2"))

  etable(es_ta, es_ot, headers = c("Any filing", "On-time"), se.below = TRUE)
  list(ta = es_ta, ontime = es_ot)
}


estimate_nasdaq <- function(pA) {

  # Firm fixed effects only. There is no control group in this layer -
  # unlisted firms do not file with the exchange - so these are before-and-
  # after comparisons, not difference-in-differences, and the pre-period
  # coefficients are descriptive dynamics rather than a parallel-trends test.
  post_disc <- feols(discretionary ~ post | business_id, pA, cluster = ~business_id)
  post_peri <- feols(periodic      ~ post | business_id, pA, cluster = ~business_id)
  post_mech <- feols(mech          ~ post | business_id, pA, cluster = ~business_id)

  seg_disc <- feols(discretionary ~ i(seg, ref = "pre") | business_id,
                    pA, cluster = ~business_id)
  seg_peri <- feols(periodic      ~ i(seg, ref = "pre") | business_id,
                    pA, cluster = ~business_id)
  seg_mech <- feols(mech          ~ i(seg, ref = "pre") | business_id,
                    pA, cluster = ~business_id)

  etable(post_disc, post_peri, post_mech,
         seg_disc, seg_peri, seg_mech, se.below = TRUE)

  list(post = list(post_disc, post_peri, post_mech),
       seg  = list(seg_disc, seg_peri, seg_mech))
}


# =============================================================================
# MAIN
# =============================================================================

main <- function(demo = TRUE) {

  cat("== 1. registrations ==\n")
  oyj <- fetch_companies("OYJ", max_pages = if (demo) 2 else NULL)

  cat("\n== 2. notice histories ==\n")
  ids <- if (demo) head(oyj$business_id, 25) else oyj$business_id
  fetch_notices(ids,
                out_dir = file.path(cw, "oyj_notices"),
                progress_file = file.path(cw, "oyj_progress.rds"))

  files <- list.files(file.path(cw, "oyj_notices"), "\\.csv$", full.names = TRUE)
  notices <- rbindlist(lapply(files, function(f) fread(file = f)), fill = TRUE)
  notices[, registrationDate := as.Date(registrationDate)]

  cat("\n== 3. panels ==\n")
  firm_list <- oyj[, .(business_id, firm_type = "OYJ")]
  pm <- build_firm_month_panel(notices, firm_list)
  fw <- build_firm_window_panel(notices, firm_list)

  cat("\n== 4. estimation ==\n")
  if (uniqueN(pm$treat) > 1) {
    estimate_baseline(pm)
    estimate_placebo(pm)
    estimate_event_study(fw)
  } else {
    cat("demo mode: treatment group only, no contrast to estimate\n")
  }

  invisible(list(panel_month = pm, panel_window = fw))
}

if (sys.nframe() == 0) main(demo = TRUE)
