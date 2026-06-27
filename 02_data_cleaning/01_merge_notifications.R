# =============================================================================
# Merge OY Notification Batch Files and Clean PRH Notice Data
# =============================================================================
#
# Purpose:
#   1. Merge 170 batch CSV files from the OY notification pull into a single
#      dataset (including the retry batch for previously failed companies).
#   2. Combine OYJ, OY, and OSK notification data into a unified dataset.
#   3. Clean and standardise fields: parse dates, assign firm type labels,
#      filter to the 36-month event window.
#
# Input:
#   oy_bid_notices/batch_1.csv ... batch_170.csv, batch_retry.csv
#   oyj_notices.csv   — OYJ notices (pulled separately, 294 firms)
#   osk_notices.csv   — OSK notices (pulled separately, 6,708 firms)
#
# Output:
#   all_notices_clean.csv — unified dataset with fields:
#     business_id, notice_type, registration_date, ym (year-month),
#     firm_type (OYJ/OY/OSK), phase (pre/post)
#
# =============================================================================

library(tidyverse)

# =============================================================================
# PART 1: Merge OY batch files
# =============================================================================

batch_dir <- "oy_bid_notices"
batch_files <- list.files(batch_dir, pattern = "^batch_.*\\.csv$",
                          full.names = TRUE)
cat("Batch files found:", length(batch_files), "\n")

# Read and bind all batch files
# Some batches may have slightly different column sets due to API response
# variation, so use bind_rows which handles mismatched columns gracefully.
oy_notices <- map_dfr(batch_files, function(f) {
  tryCatch({
    df <- read_csv(f, col_types = cols(.default = "c"))
    df$source_file <- basename(f)
    return(df)
  }, error = function(e) {
    cat("  Error reading", basename(f), ":", e$message, "\n")
    return(tibble())
  })
})

cat("OY raw notices:", nrow(oy_notices), "\n")
cat("OY unique firms:", n_distinct(oy_notices$business_id), "\n")

# =============================================================================
# PART 2: Load OYJ and OSK notices
# =============================================================================

oyj_notices <- read_csv("oyj_notices.csv", col_types = cols(.default = "c"))
osk_notices <- read_csv("osk_notices.csv", col_types = cols(.default = "c"))

cat("OYJ raw notices:", nrow(oyj_notices), "\n")
cat("OSK raw notices:", nrow(osk_notices), "\n")

# =============================================================================
# PART 3: Unify and clean
# =============================================================================

# Tag firm type
oy_notices$firm_type  <- "OY"
oyj_notices$firm_type <- "OYJ"
osk_notices$firm_type <- "OSK"

# Select common columns and bind
# The key fields are: business_id, noticeType (notice category code),
# registrationDate (when the notice was registered at PRH)
common_cols <- c("business_id", "noticeType", "registrationDate", "firm_type")

all_notices <- bind_rows(
  oy_notices  %>% select(any_of(common_cols)),
  oyj_notices %>% select(any_of(common_cols)),
  osk_notices %>% select(any_of(common_cols))
)

cat("\nCombined raw notices:", nrow(all_notices), "\n")

# Parse registration date and create year-month variable
all_notices <- all_notices %>%
  rename(notice_type = noticeType,
         registration_date = registrationDate) %>%
  mutate(
    reg_date = as.Date(registration_date),
    ym = floor_date(reg_date, "month")
  ) %>%
  filter(!is.na(reg_date))

cat("After date parsing:", nrow(all_notices), "\n")

# =============================================================================
# PART 4: Filter to event window
# =============================================================================
# Event window: March 2023 – February 2026 (36 months)
# Pre-treatment:  March 2023 – August 2024 (18 months)
# Post-treatment: September 2024 – February 2026 (18 months)

event_start <- as.Date("2023-03-01")
event_end   <- as.Date("2026-02-28")
treatment   <- as.Date("2024-09-01")

all_notices <- all_notices %>%
  filter(ym >= event_start, ym <= event_end) %>%
  mutate(phase = ifelse(ym < treatment, "pre", "post"))

cat("\nEvent window notices:", nrow(all_notices), "\n")
cat("By firm type:\n")
all_notices %>% count(firm_type) %>% print()
cat("\nBy phase:\n")
all_notices %>% count(firm_type, phase) %>% print()

# =============================================================================
# PART 5: Notice type distribution
# =============================================================================
# PRH notice type codes:
#   TA  = Tilinpäätös (Financial statement / annual accounts)
#   M   = Muutosilmoitus (Amendment notification)
#   U   = Perustamisilmoitus (Establishment notice)
#   JH  = Julkinen haaste (Public creditor summons / creditor announcement)
#   FUU = Sulautumishakemus (Merger application)
#   END = Lopettamisilmoitus (Dissolution notice)
#   Y   = Tilinpäätös, yhteisö (Financial statement, community)
#   H   = Hakemus (Application)
#   VA  = Valvonta-asia (Supervision matters/under supervision)
#   R   = Rekisteröinti (Registration)
#   J   = Julkistamisilmoitus (Publication notice)

cat("\nNotice type distribution:\n")
all_notices %>%
  count(firm_type, notice_type) %>%
  pivot_wider(names_from = firm_type, values_from = n, values_fill = 0) %>%
  arrange(desc(OY)) %>%
  print(n = 20)

# =============================================================================
# Save
# =============================================================================

write_csv(all_notices, "all_notices_clean.csv")
cat("\nSaved all_notices_clean.csv:", nrow(all_notices), "rows\n")
