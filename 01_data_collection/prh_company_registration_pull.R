# =============================================================================
# PRH YTJ Open Data API — Company Registration Data Retrieval
# =============================================================================
#
# Purpose:
#   Retrieve basic company registration data for three legal entity types
#   from the Finnish Patent and Registration Office (PRH) open data API:
#     - OYJ (Julkinen osakeyhtiö, public limited company): treatment group
#     - OY  (Osakeyhtiö, private limited company): control group
#     - OSK (Osuuskunta, cooperative): robustness group
#
# Data source:
#   PRH YTJ Open Data API v3
#   https://avoindata.prh.fi/opendata-ytj-api/v3/companies
#   Swagger documentation: https://avoindata.prh.fi/ytj_en.html
#   Free, public, no authentication required.
#
# Fields retrieved per company:
#   businessId (Y-tunnus), companyName, registrationDate, companyForm,
#   mainBusinessLine (TOL 2008 industry code), registeredAddress,
#   companySituation (REK/KONK/SANE/SELTILA), endDate (if applicable).
#
# Output:
#   prh_oyj_all.csv  — all OYJ companies (429 total, 294 active)
#   prh_oy_all.csv   — all OY companies matching selected industry codes
#   prh_osk_all.csv  — all OSK cooperatives (6,708 total)
#
# Design choices:
#   - The API returns a maximum of 100 results per page. For company forms
#     with more than 100 records, the script paginates automatically.
#   - OY has hundreds of thousands of companies. To keep the sample
#     tractable and relevant, OY is filtered by mainBusinessLine codes
#     matching the industries represented in the OYJ treatment group.
#   - 0.5-second delay between pages to respect the public endpoint.
#
# Author: [Your name]
# Date:   May 2026
# =============================================================================

library(httr)
library(jsonlite)
library(tidyverse)

api_base <- "https://avoindata.prh.fi/opendata-ytj-api/v3/companies"

# =============================================================================
# Helper function: paginated retrieval from PRH YTJ API
# =============================================================================
pull_prh_companies <- function(company_form,
                               business_line = NULL,
                               page_size = 100,
                               sleep_sec = 0.5) {
  all_results <- list()
  page <- 0
  total <- NA

  repeat {
    # Build query parameters
    params <- list(
      companyForm = company_form,
      page = page,
      size = page_size
    )
    if (!is.null(business_line)) {
      params$mainBusinessLine <- business_line
    }

    resp <- tryCatch(
      GET(api_base, query = params, timeout(60)),
      error = function(e) {
        cat(sprintf("  Error on page %d: %s\n", page, e$message))
        return(NULL)
      }
    )

    if (is.null(resp) || status_code(resp) != 200) {
      cat(sprintf("  Failed page %d (status: %s), retrying...\n",
                  page, ifelse(is.null(resp), "NULL", status_code(resp))))
      Sys.sleep(2)
      next
    }

    data <- fromJSON(content(resp, "text", encoding = "UTF-8"),
                     flatten = TRUE)

    if (is.na(total)) {
      total <- data$totalResults
      cat(sprintf("  Total results: %d (pages: %d)\n",
                  total, ceiling(total / page_size)))
    }

    if (length(data$results) == 0) break

    all_results[[length(all_results) + 1]] <- data$results

    retrieved <- page_size * (page + 1)
    if (retrieved >= total) break

    page <- page + 1

    if (page %% 10 == 0) {
      cat(sprintf("  Page %d/%d\n", page, ceiling(total / page_size)))
    }

    Sys.sleep(sleep_sec)
  }

  if (length(all_results) > 0) {
    df <- bind_rows(all_results)
    cat(sprintf("  Retrieved %d companies\n", nrow(df)))
    return(df)
  } else {
    cat("  No results found\n")
    return(tibble())
  }
}

# =============================================================================
# Pull OYJ (public limited companies) — treatment group
# =============================================================================
cat("\n=== Pulling OYJ ===\n")
oyj_raw <- pull_prh_companies("OYJ")
write_csv(oyj_raw, "prh_oyj_all.csv")
cat(sprintf("Saved prh_oyj_all.csv: %d companies\n", nrow(oyj_raw)))

# Filter active companies
oyj_active <- oyj_raw %>%
  filter(is.na(endDate) | endDate == "")
cat(sprintf("Active OYJ: %d\n", nrow(oyj_active)))

# =============================================================================
# Pull OSK (cooperatives) — robustness group
# =============================================================================
cat("\n=== Pulling OSK ===\n")
osk_raw <- pull_prh_companies("OSK")
write_csv(osk_raw, "prh_osk_all.csv")
cat(sprintf("Saved prh_osk_all.csv: %d companies\n", nrow(osk_raw)))

# =============================================================================
# Pull OY (private limited companies) — control group
# =============================================================================
# OY is filtered by industry codes matching the OYJ treatment group.
# Extract unique 2-digit industry codes from OYJ data first.

cat("\n=== Pulling OY by industry codes ===\n")

# Get industry codes from OYJ (2-digit TOL 2008)
if ("mainBusinessLine.code" %in% names(oyj_raw)) {
  oyj_industries <- oyj_raw %>%
    mutate(ind_2digit = substr(mainBusinessLine.code, 1, 2)) %>%
    pull(ind_2digit) %>%
    unique() %>%
    sort()
  cat("OYJ industry codes (2-digit):", paste(oyj_industries, collapse = ", "), "\n")
} else {
  # Fallback: use broad set of industry codes
  oyj_industries <- c("01", "06", "10", "16", "20", "24", "25", "26",
                       "27", "28", "41", "43", "46", "47", "49", "52",
                       "55", "56", "58", "61", "62", "64", "68", "70",
                       "71", "72", "73", "77", "82", "86")
  cat("Using fallback industry code set\n")
}

# Pull OY for each industry code
oy_results <- list()
for (ind in oyj_industries) {
  cat(sprintf("\n  Industry %s:\n", ind))
  tryCatch({
    df <- pull_prh_companies("OY", business_line = ind)
    if (nrow(df) > 0) {
      df$filter_industry <- ind
      oy_results[[ind]] <- df
    }
  }, error = function(e) {
    cat(sprintf("  Error for industry %s: %s\n", ind, e$message))
  })
}

oy_all <- bind_rows(oy_results)

# Remove duplicates (a company may appear under multiple industry codes)
oy_unique <- oy_all %>%
  distinct(businessId.value, .keep_all = TRUE)

write_csv(oy_unique, "prh_oy_all.csv")
cat(sprintf("\nSaved prh_oy_all.csv: %d unique OY companies\n", nrow(oy_unique)))

# =============================================================================
# Summary
# =============================================================================
cat("\n========== Retrieval complete ==========\n")
cat(sprintf("OYJ:  %d total, %d active\n", nrow(oyj_raw), nrow(oyj_active)))
cat(sprintf("OY:   %d unique (filtered by %d industry codes)\n",
            nrow(oy_unique), length(oyj_industries)))
cat(sprintf("OSK:  %d total\n", nrow(osk_raw)))
