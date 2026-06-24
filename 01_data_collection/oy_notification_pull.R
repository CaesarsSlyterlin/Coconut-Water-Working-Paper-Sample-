# =============================================================================
# PRH Registered Notices API — Batch Pull for OY (Private Limited Companies)
# =============================================================================
#
# Purpose:
#   Retrieve all public notices (registered notifications) for 169,301
#   Finnish private limited companies (Osakeyhtiö, OY) from the PRH
#   (Finnish Patent and Registration Office) open data API.
#
# Data source:
#   PRH Registered Notices API v3
#   https://avoindata.prh.fi/opendata-registerednotices-api/v3
#   Free, public, no authentication required.
#
# Input:
#   prh_oy_matched.csv — list of OY companies with Business IDs,
#   previously retrieved from the PRH YTJ Open Data API and matched
#   with Vero (Finnish Tax Administration) corporate income tax records.
#
# Output:
#   170 batch CSV files (batch_1.csv ... batch_170.csv) in oy_bid_notices/
#   Each CSV contains all public notices for 1,000 companies (last batch: 301).
#   Fields: business_id, noticeType, registrationDate, plus all other
#   fields returned by the API (varies by notice type).
#
# Design choices:
#   - Batch size of 1,000 chosen to balance checkpoint frequency against
#     I/O overhead. Each batch produces one CSV, enabling granular progress
#     tracking and fault isolation.
#   - Checkpoint/resume: on restart, the script detects completed batch
#     files and skips them. No data is re-downloaded.
#   - 0.5s delay between API calls to avoid overloading the public
#     endpoint (approximately 10 minutes per batch of 1,000).
#   - 60-second timeout per request with tryCatch error handling.
#     Failed requests are counted but do not halt the batch.
#   - Progress reporting every 200 companies within each batch, with
#     elapsed time and ETA displayed in console.
#
# Runtime:
#   Approximately 29 hours.
#
# Post-processing:
#   After all 170 batches complete, run the companion retry script to
#   re-pull any companies that failed/missing due to transient server errors,
#   then merge all CSVs into a single dataset.
# =============================================================================

library(httr)
library(jsonlite)
library(tidyverse)

# === Configuration ===
input_file  <- "prh_oy_matched.csv"
output_dir  <- "oy_bid_notices"
batch_size  <- 1000
sleep_sec   <- 0.5
api_base    <- "https://avoindata.prh.fi/opendata-registerednotices-api/v3"

# === Load company list ===
oy      <- read_csv(input_file, col_types = cols(.default = "c"))
all_ids <- oy$businessId.value
cat("Total companies:", length(all_ids), "\n")

# === Prepare output directory ===
dir.create(output_dir, showWarnings = FALSE)

# === Calculate batches ===
n_batches <- ceiling(length(all_ids) / batch_size)
cat("Total batches:", n_batches, "\n")

# === Checkpoint: detect completed batches ===
done_files   <- list.files(output_dir, pattern = "^batch_\\d+\\.csv$")
done_batches <- as.integer(gsub("batch_|\\.csv", "", done_files))
cat("Completed batches:", length(done_batches), "\n\n")

# === Main loop ===
t0 <- Sys.time()

for (b in 1:n_batches) {
  # Skip completed batches (checkpoint resume)
  if (b %in% done_batches) next

  # Determine ID range for this batch
  start_idx <- (b - 1) * batch_size + 1
  end_idx   <- min(b * batch_size, length(all_ids))
  batch_ids <- all_ids[start_idx:end_idx]

  cat(sprintf("\n=== Batch %d/%d (companies %d-%d) ===\n",
              b, n_batches, start_idx, end_idx))

  batch_results <- list()
  errors <- 0

  for (i in seq_along(batch_ids)) {
    bid <- batch_ids[i]

    # API request with error handling
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
        batch_results[[length(batch_results) + 1]] <- pn
      }
    } else {
      errors <- errors + 1
    }

    # Progress report every 200 companies
    if (i %% 200 == 0) {
      total_notices <- sum(sapply(batch_results, nrow))
      cat(sprintf("  %d/%d | notices:%d | errors:%d\n",
                  i, length(batch_ids), total_notices, errors))
    }

    Sys.sleep(sleep_sec)
  }

  # Save batch to CSV
  if (length(batch_results) > 0) {
    batch_df <- bind_rows(batch_results)
  } else {
    batch_df <- tibble()
  }

  outfile <- file.path(output_dir, sprintf("batch_%d.csv", b))
  write_csv(batch_df, outfile)

  # Batch summary with elapsed time and ETA
  elapsed <- as.numeric(difftime(Sys.time(), t0, units = "hours"))
  done_total <- end_idx
  remaining  <- length(all_ids) - done_total
  rate       <- done_total / elapsed
  eta        <- if (rate > 0) remaining / rate else NA

  cat(sprintf("  Saved %s | %d notices | errors:%d | %.1fh elapsed | ETA:%.1fh\n",
              basename(outfile), nrow(batch_df), errors, elapsed, eta))
}

# === Final summary ===
elapsed_total <- as.numeric(difftime(Sys.time(), t0, units = "hours"))

cat("\n========== Pull complete ==========\n")
cat(sprintf("Total companies:  %d\n", length(all_ids)))
cat(sprintf("Total batches:    %d\n", n_batches))
cat(sprintf("Total time:       %.1f hours\n", elapsed_total))
cat(sprintf("Output directory: %s/\n", output_dir))

# Save workspace for recovery
save.image("coconut_workspace_oy_notices.RData")
cat("Workspace saved.\n")
