# =============================================================================
# PRH Registered Notices API — Retry Failed Companies
# =============================================================================
#
# Purpose:
#   After the main batch pull (oy_notification_pull.R) completes, some
#   companies may have failed due to transient server errors. This script
#   identifies missing Business IDs by comparing the full company list
#   against successfully retrieved IDs, then re-pulls their notices.
#
# Input:
#   prh_oy_matched.csv — full company list (169,301 Business IDs)
#   oy_bid_notices/batch_*.csv — completed batch files from main pull
#
# Output:
#   oy_bid_notices/batch_retry.csv — notices for previously failed companies
#
# Runtime:
#   Typically under 2 minutes for ~77 failed companies.

# =============================================================================

library(httr)
library(jsonlite)
library(tidyverse)

# === Configuration ===
input_file <- "prh_oy_matched.csv"
output_dir <- "oy_bid_notices"
api_base   <- "https://avoindata.prh.fi/opendata-registerednotices-api/v3"

# === Load full company list ===
oy      <- read_csv(input_file, col_types = cols(.default = "c"))
all_ids <- oy$businessId.value

# === Find successfully pulled Business IDs ===
batch_files <- list.files(output_dir, pattern = "^batch_\\d+\\.csv$",
                          full.names = TRUE)
pulled_ids  <- character(0)

for (f in batch_files) {
  df <- read_csv(f, col_types = cols(.default = "c"))
  if ("business_id" %in% names(df) && nrow(df) > 0) {
    pulled_ids <- c(pulled_ids, unique(df$business_id))
  }
}
pulled_ids <- unique(pulled_ids)

# === Identify missing companies ===
missing_ids <- setdiff(all_ids, pulled_ids)
cat("Total companies:", length(all_ids), "\n")
cat("Successfully pulled:", length(pulled_ids), "\n")
cat("Missing (to retry):", length(missing_ids), "\n\n")

if (length(missing_ids) == 0) {
  cat("No missing companies. Nothing to retry.\n")
  quit(save = "no")
}

# === Retry missing companies ===
retry_results <- list()
errors <- 0

for (i in seq_along(missing_ids)) {
  bid <- missing_ids[i]

  resp <- tryCatch(
    GET(paste0(api_base, "/", bid), timeout(60)),
    error = function(e) NULL
  )

  if (!is.null(resp) && status_code(resp) == 200) {
    data <- fromJSON(content(resp, "text", encoding = "UTF-8"),
                     flatten = TRUE)

    if (!is.null(data$publicNotices) &&
        is.data.frame(data$publicNotices) &&
        nrow(data$publicNotices) > 0) {
      pn <- data$publicNotices
      pn$business_id <- bid
      retry_results[[length(retry_results) + 1]] <- pn
    }
  } else {
    errors <- errors + 1
    cat(sprintf("  Failed again: %s\n", bid))
  }

  if (i %% 20 == 0) {
    cat(sprintf("  %d/%d retried\n", i, length(missing_ids)))
  }

  Sys.sleep(0.5)
}

# === Save retry results ===
if (length(retry_results) > 0) {
  retry_df <- bind_rows(retry_results)
  write_csv(retry_df, file.path(output_dir, "batch_retry.csv"))
  cat(sprintf("\nRetry complete: %d notices recovered, %d still failed.\n",
              nrow(retry_df), errors))
} else {
  cat(sprintf("\nNo notices recovered. %d companies have no notices or still failed.\n",
              errors))
}
