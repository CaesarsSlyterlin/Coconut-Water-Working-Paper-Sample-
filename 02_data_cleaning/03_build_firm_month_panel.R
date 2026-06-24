# =============================================================================
# Construct Firm-Month Notification Panel for DiD Analysis
# =============================================================================
#
# Purpose:
#   Build a firm x month panel from cleaned PRH notification data for use
#   in difference-in-differences estimation. Each row represents one firm
#   in one month, with notification counts by type, treatment indicators,
#   and pre/post phase labels.
#
# Input:
#   all_notices_clean.csv — cleaned, event-window-filtered notification data
#                           (output of 01_merge_notifications.R)
#
# Output:
#   stata_firm_list.csv        — firm list with treat indicator
#   stata_firm_month_type.csv  — non-zero firm-month-type observations
#   stata_ta_firm_month.csv    — TA (financial statement) specific panel
#
#   These CSVs are designed for import into Stata 17 MP for regression
#   analysis using reghdfe (two-way fixed effects).
#
# Panel structure:
#   - Rows: firm i x month t (36 months: March 2023 – February 2026)
#   - OYJ: 294 firms x 36 months = 10,584 potential observations
#   - OY:  165,192 firms x 36 months = ~5.9 million potential observations
#   - Most firm-month cells are zero (sparse panel), which is expected:
#     OY firms typically file only 1-2 notices per year.
#
# Design note:
#   The full OY panel (5.9M rows) is feasible in Stata 17 MP but large.
#   For exploratory analysis in R, a random subsample of 5,000 OY firms
#   is used. The full panel is constructed in Stata via cross-merge of
#   firm list and month sequence.
#
# =============================================================================

library(tidyverse)

# =============================================================================
# PART 1: Load cleaned notification data
# =============================================================================

all_notices <- read_csv("all_notices_clean.csv",
                        col_types = cols(.default = "c")) %>%
  mutate(
    ym = as.Date(ym),
    reg_date = as.Date(reg_date)
  )

cat("Total notices:", nrow(all_notices), "\n")
cat("Firm types:\n")
all_notices %>% count(firm_type) %>% print()

# =============================================================================
# PART 2: Create firm-month-type counts (sparse format)
# =============================================================================
# Instead of expanding to a full N x T grid (which is >5M rows for OY),
# we count non-zero observations and export. The full panel expansion
# is done in Stata where memory management is more efficient.

firm_month_type <- all_notices %>%
  filter(firm_type %in% c("OYJ", "OY")) %>%
  count(business_id, firm_type, ym, notice_type, name = "type_count") %>%
  mutate(type_dummy = 1)

cat("\nNon-zero firm-month-type rows:", nrow(firm_month_type), "\n")

# =============================================================================
# PART 3: TA-specific panel (for baseline DiD on financial statements)
# =============================================================================

ta_fm <- all_notices %>%
  filter(firm_type %in% c("OYJ", "OY"), notice_type == "TA") %>%
  count(business_id, ym, name = "ta_count") %>%
  mutate(ta_dummy = 1)

cat("TA non-zero firm-months:", nrow(ta_fm), "\n")

# =============================================================================
# PART 4: Firm list with treatment indicator
# =============================================================================

firm_list <- all_notices %>%
  filter(firm_type %in% c("OYJ", "OY")) %>%
  distinct(business_id, firm_type) %>%
  mutate(treat = ifelse(firm_type == "OYJ", 1, 0))

cat("\nFirm list:\n")
firm_list %>% count(firm_type, treat) %>% print()

# =============================================================================
# PART 5: Quick descriptive statistics (R-side, OY subsample)
# =============================================================================

# Full grid for OYJ (small enough)
months_seq <- seq(as.Date("2023-03-01"), as.Date("2026-02-28"), by = "month")
treatment  <- as.Date("2024-09-01")

build_panel <- function(notices, ftype) {
  firms <- unique(notices$business_id[notices$firm_type == ftype])
  panel <- expand_grid(business_id = firms, ym = months_seq)

  counts <- notices %>%
    filter(firm_type == ftype) %>%
    count(business_id, ym, name = "n_notices")

  panel %>%
    left_join(counts, by = c("business_id", "ym")) %>%
    mutate(
      n_notices = replace_na(n_notices, 0),
      firm_type = ftype,
      phase = ifelse(ym < treatment, "pre", "post")
    )
}

# OYJ: full panel
oyj_panel <- build_panel(all_notices, "OYJ")
cat("\nOYJ panel:", nrow(oyj_panel), "rows,",
    n_distinct(oyj_panel$business_id), "firms\n")

# OY: random 5000-firm subsample for R-side exploration
set.seed(42)
oy_sample_ids <- sample(
  unique(all_notices$business_id[all_notices$firm_type == "OY"]),
  5000
)
oy_sample_notices <- all_notices %>%
  filter(firm_type == "OY", business_id %in% oy_sample_ids)
oy_panel_sample <- build_panel(oy_sample_notices, "OY")
cat("OY sample panel:", nrow(oy_panel_sample), "rows,",
    n_distinct(oy_panel_sample$business_id), "firms\n")

# Descriptive statistics
cat("\n=== Notification count by firm type and phase ===\n")
bind_rows(oyj_panel, oy_panel_sample) %>%
  group_by(firm_type, phase) %>%
  summarise(
    n_obs      = n(),
    mean_count = round(mean(n_notices), 3),
    median     = median(n_notices),
    sd         = round(sd(n_notices), 3),
    pct_zero   = round(mean(n_notices == 0) * 100, 1),
    .groups    = "drop"
  ) %>%
  print()

# Quick pooled DiD (R-side check, not the final specification)
cat("\n=== Quick pooled OLS DiD (R-side, OY subsample) ===\n")
did_data <- bind_rows(oyj_panel, oy_panel_sample) %>%
  mutate(
    treat = ifelse(firm_type == "OYJ", 1, 0),
    post  = ifelse(phase == "post", 1, 0)
  )

did_fit <- lm(n_notices ~ treat * post, data = did_data)
cat("Coefficients:\n")
print(round(coef(summary(did_fit)), 4))

# =============================================================================
# PART 6: Export for Stata
# =============================================================================

write_csv(firm_list, "stata_firm_list.csv")
write_csv(firm_month_type, "stata_firm_month_type.csv")
write_csv(ta_fm, "stata_ta_firm_month.csv")

cat("\n=== Exported for Stata ===\n")
cat("stata_firm_list.csv:", nrow(firm_list), "firms\n")
cat("stata_firm_month_type.csv:", nrow(firm_month_type), "rows\n")
cat("stata_ta_firm_month.csv:", nrow(ta_fm), "rows\n")

# Save workspace
save.image("coconut_workspace_panel.RData")
cat("Workspace saved.\n")
