# =============================================================================
# Vero Corporate Income Tax CSV — Encoding Fix and PRH Cross-Match
# =============================================================================
#
# Purpose:
#   1. Read Vero Open Data corporate income tax CSV files (FY2020–2024),
#      handling Finnish-specific encoding and format issues.
#   2. Match Vero tax records to PRH company registration data via
#      Business ID (Y-tunnus) to create a firm-level panel that separates
#      OYJ from OY (which PxWeb aggregate data cannot do).
#
# Data source:
#   Vero Open Data — Corporate income tax by Business ID
#   https://www.vero.fi/tietoa-verohallinnosta/tilastot/avoin_dat/
#   Free, public, CSV download.
#
# Encoding issues:
#   Vero CSV files use Latin-1 (ISO 8859-1) encoding, not UTF-8.
#   Finnish field names contain special characters (ä, ö).
#   Numeric fields use Finnish decimal comma (e.g., "1 234,56").
#   These must be converted before analysis in R or Stata.
#
# Key fields in Vero CSV:
#   Y-tunnus                    — Business ID (format: 1234567-8)
#   Verovuosi                   — Tax year (fiscal year)
#   Verotettava tulo valtiov.   — Taxable income (state taxation)
#   Maksuunpantu vero yhteensä  — Total tax assessed
#   Veronpalautus               — Tax refund
#   Jäännösvero                 — Back tax (residual tax)
#   Ennakot yhteensä            — Total prepayments
#
# Output:
#   vero_panel_matched.csv — 5-year balanced panel with firm_type labels
#   Match rates: OYJ 93.9%, OY 61.2%
#
# Author: [Your name]
# Date:   May 2026
# =============================================================================

library(tidyverse)

# =============================================================================
# PART 1: Read Vero CSV with correct encoding
# =============================================================================

# Vero publishes one CSV per fiscal year.
# File names follow the pattern: yhteisovero_YYYY.csv
vero_files <- list(
  "2020" = "yhteisovero_2020.csv",
  "2021" = "yhteisovero_2021.csv",
  "2022" = "yhteisovero_2022.csv",
  "2023" = "yhteisovero_2023.csv",
  "2024" = "yhteisovero_2024.csv"
)

read_vero_csv <- function(filepath, fy) {
  # Read with Latin-1 encoding
  df <- read_delim(
    filepath,
    delim = ";",                    # Vero uses semicolon delimiter
    locale = locale(
      encoding = "latin1",          # Finnish Latin-1 encoding
      decimal_mark = ",",           # Finnish decimal comma
      grouping_mark = " "           # Space as thousands separator
    ),
    col_types = cols(.default = "c"),
    trim_ws = TRUE
  )

  # Standardise column names (remove Finnish special characters for portability)
  df <- df %>%
    rename_with(~ str_replace_all(.x, "[äÄ]", "a")) %>%
    rename_with(~ str_replace_all(.x, "[öÖ]", "o")) %>%
    rename_with(~ str_replace_all(.x, " ", "_")) %>%
    rename_with(tolower)

  # Parse numeric fields (remove spaces, convert comma to period)
  numeric_cols <- c("verotettava_tulo_valtiov.", "maksuunpantu_vero_yhteensa",
                    "veronpalautus", "jaannosvero", "ennakot_yhteensa")

  for (col in intersect(numeric_cols, names(df))) {
    df[[col]] <- df[[col]] %>%
      str_replace_all("\\s", "") %>%     # Remove space grouping
      str_replace(",", ".") %>%          # Comma to period
      as.numeric()
  }

  df$fiscal_year <- as.integer(fy)
  return(df)
}

# Read all years
vero_all <- map2_dfr(vero_files, names(vero_files), function(f, fy) {
  cat(sprintf("Reading %s (FY%s)...\n", f, fy))
  read_vero_csv(f, fy)
})

cat("\nTotal Vero records:", nrow(vero_all), "\n")
cat("Unique Business IDs:", n_distinct(vero_all$`y-tunnus`), "\n")
cat("Fiscal years:", paste(sort(unique(vero_all$fiscal_year)), collapse = ", "), "\n")

# Standardise Business ID column name
vero_all <- vero_all %>%
  rename(business_id = `y-tunnus`)

# =============================================================================
# PART 2: Load PRH company registration data
# =============================================================================

prh_oyj <- read_csv("prh_oyj_all.csv", col_types = cols(.default = "c")) %>%
  mutate(firm_type = "OYJ")
prh_oy  <- read_csv("prh_oy_all.csv", col_types = cols(.default = "c")) %>%
  mutate(firm_type = "OY")
prh_osk <- read_csv("prh_osk_all.csv", col_types = cols(.default = "c")) %>%
  mutate(firm_type = "OSK")

prh_all <- bind_rows(prh_oyj, prh_oy, prh_osk) %>%
  select(business_id = businessId.value, firm_type) %>%
  distinct(business_id, .keep_all = TRUE)

cat("\nPRH companies loaded:\n")
prh_all %>% count(firm_type) %>% print()

# =============================================================================
# PART 3: Cross-match via Business ID
# =============================================================================

vero_matched <- vero_all %>%
  inner_join(prh_all, by = "business_id")

cat("\nMatched records:", nrow(vero_matched), "\n")
cat("Matched unique firms:", n_distinct(vero_matched$business_id), "\n")

# Match rates by firm type
match_summary <- prh_all %>%
  count(firm_type, name = "prh_total") %>%
  left_join(
    vero_matched %>%
      distinct(business_id, firm_type) %>%
      count(firm_type, name = "matched"),
    by = "firm_type"
  ) %>%
  mutate(
    matched = replace_na(matched, 0),
    match_rate = round(matched / prh_total * 100, 1)
  )

cat("\nMatch rates:\n")
print(match_summary)
# Expected: OYJ ~93.9%, OY ~61.2%, OSK varies

# =============================================================================
# PART 4: Build balanced panel
# =============================================================================
# A firm is in the balanced panel if it has tax records for all 5 fiscal years.

firm_year_counts <- vero_matched %>%
  count(business_id, firm_type, name = "n_years")

balanced_firms <- firm_year_counts %>%
  filter(n_years == 5)

cat("\nBalanced panel (5 years):\n")
balanced_firms %>% count(firm_type) %>% print()

vero_panel <- vero_matched %>%
  semi_join(balanced_firms, by = "business_id")

cat("Balanced panel records:", nrow(vero_panel), "\n")

# =============================================================================
# Save
# =============================================================================

write_csv(vero_panel, "vero_panel_matched.csv")
cat("\nSaved vero_panel_matched.csv:", nrow(vero_panel), "rows\n")
