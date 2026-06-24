# =============================================================================
# Statistics Finland (StatFin) PxWeb API — Bankruptcy and Corporate
# Restructuring Data Retrieval
# =============================================================================
#
# Purpose:
#   Retrieve bankruptcy and corporate restructuring statistics from
#   Statistics Finland's PxWeb Statistical Database. These data provide
#   macro-level evidence of fiscal stress transmission following the
#   VAT rate increase (24% → 25.5%, effective 1 September 2024).
#
# Data source:
#   Statistics Finland StatFin PxWeb API
#   https://pxdata.stat.fi/PXWeb/pxweb/en/StatFin/
#   Free, public, no authentication required.
#
# Tables retrieved:
#   13fd — Monthly bankruptcies filed, by industry (TOL 2008)
#   13fe — Monthly bankruptcies filed, by region (maakunta)
#   13fl — Quarterly corporate restructuring proceedings, by region
#
# Why these data matter:
#   The VAT rate increase affects all firms, but the fiscal stress it
#   generates transmits unevenly. Bankruptcy filings and restructuring
#   proceedings are direct indicators of corporate distress. Examining
#   their time-series patterns around the treatment date provides
#   corroborating macro evidence that the VAT shock induced real
#   financial stress, complementing the firm-level disclosure analysis
#   based on PRH notification data.
#
#   Key finding from Vero's own reporting (April 2025): bankruptcy
#   applications filed by Vero increased 57% in 2025Q1 vs 2024Q1,
#   with VAT debt reaching EUR 1.78 billion (+8% YoY). Vero's risk
#   officer explicitly attributed the increase to the September 2024
#   VAT rate hike affecting small service-sector firms.
#
# Output:
#   statfin_bankruptcy_monthly_by_industry.csv
#   statfin_bankruptcy_monthly_by_region.csv
#   statfin_restructuring_quarterly_by_region.csv
#
# Dependencies:
#   install.packages("pxweb")
#
# Author: [Your name]
# Date:   May 2026
# =============================================================================

library(pxweb)
library(tidyverse)

api_base <- "https://pxdata.stat.fi/PXWeb/api/v1/en/StatFin/"

# =============================================================================
# PART 1: Explore the StatFin directory structure
# =============================================================================

# --- Bankruptcy statistics (konkurssit) ---
px_konk <- pxweb_get(paste0(api_base, "StatFin__konk/"))
cat("=== Bankruptcy tables ===\n")
print(px_konk)
# Key tables:
#   statfin_konk_pxt_13fd.px — Monthly bankruptcies by industry
#   statfin_konk_pxt_13fe.px — Monthly bankruptcies by region

# --- Corporate restructuring (yrityssaneeraukset) ---
px_kony <- pxweb_get(paste0(api_base, "StatFin__kony/"))
cat("\n=== Corporate restructuring tables ===\n")
print(px_kony)
# Key tables:
#   statfin_kony_pxt_13fl.px — Quarterly restructuring by region

# =============================================================================
# PART 2: Inspect table metadata
# =============================================================================

# --- 13fd: Monthly bankruptcies by industry ---
meta_13fd <- pxweb_get(
  paste0(api_base, "StatFin__konk/statfin_konk_pxt_13fd.px")
)
cat("\n=== Table 13fd dimensions ===\n")
for (v in meta_13fd$variables) {
  cat(sprintf("  %s (%s): %d values\n", v$text, v$code, length(v$values)))
  n <- min(5, length(v$values))
  print(data.frame(code = v$values[1:n], text = v$valueTexts[1:n]))
}

# --- 13fe: Monthly bankruptcies by region ---
meta_13fe <- pxweb_get(
  paste0(api_base, "StatFin__konk/statfin_konk_pxt_13fe.px")
)
cat("\n=== Table 13fe dimensions ===\n")
for (v in meta_13fe$variables) {
  cat(sprintf("  %s (%s): %d values\n", v$text, v$code, length(v$values)))
  n <- min(5, length(v$values))
  print(data.frame(code = v$values[1:n], text = v$valueTexts[1:n]))
}

# --- 13fl: Quarterly restructuring by region ---
meta_13fl <- pxweb_get(
  paste0(api_base, "StatFin__kony/statfin_kony_pxt_13fl.px")
)
cat("\n=== Table 13fl dimensions ===\n")
for (v in meta_13fl$variables) {
  cat(sprintf("  %s (%s): %d values\n", v$text, v$code, length(v$values)))
  n <- min(5, length(v$values))
  print(data.frame(code = v$values[1:n], text = v$valueTexts[1:n]))
}

# =============================================================================
# PART 3: Retrieve monthly bankruptcies by industry (13fd)
# =============================================================================
# Event window months: March 2023 – February 2026

event_months_konk <- c(
  paste0("2023M", sprintf("%02d", 3:12)),
  paste0("2024M", sprintf("%02d", 1:12)),
  paste0("2025M", sprintf("%02d", 1:12)),
  paste0("2026M", sprintf("%02d", 1:2))
)

# Selected industries matching OYJ/OY sample
# SSS = All industries, plus key sectors
industry_codes_konk <- c("SSS", "C", "F", "G", "H", "I", "J", "K",
                          "L", "M", "N")
# C = Manufacturing, F = Construction, G = Wholesale/retail,
# H = Transport, I = Accommodation/food, J = ICT,
# K = Finance/insurance, L = Real estate, M = Professional/scientific,
# N = Administrative/support

query_13fd <- pxweb_query(list(
  "Kuukausi"   = event_months_konk,
  "Toimiala"   = industry_codes_konk,
  "Tiedot"     = "*"
))

data_13fd <- pxweb_get(
  paste0(api_base, "StatFin__konk/statfin_konk_pxt_13fd.px"),
  query = query_13fd
)
df_13fd <- as.data.frame(data_13fd, column.name.type = "text")

write_csv(df_13fd, "statfin_bankruptcy_monthly_by_industry.csv")
cat("\nSaved statfin_bankruptcy_monthly_by_industry.csv:",
    nrow(df_13fd), "rows\n")

# =============================================================================
# PART 4: Retrieve monthly bankruptcies by region (13fe)
# =============================================================================

# All 19 regions (maakunta) plus national total
# MK17 = Pohjois-Pohjanmaa (North Ostrobothnia) — primary region of interest
region_codes <- c("SSS",
                  "MK01", "MK02", "MK04", "MK05", "MK06", "MK07",
                  "MK08", "MK09", "MK10", "MK11", "MK12", "MK13",
                  "MK14", "MK15", "MK16", "MK17", "MK18", "MK19",
                  "MK21")

query_13fe <- pxweb_query(list(
  "Kuukausi" = event_months_konk,
  "Alue"     = region_codes,
  "Tiedot"   = "*"
))

data_13fe <- pxweb_get(
  paste0(api_base, "StatFin__konk/statfin_konk_pxt_13fe.px"),
  query = query_13fe
)
df_13fe <- as.data.frame(data_13fe, column.name.type = "text")

write_csv(df_13fe, "statfin_bankruptcy_monthly_by_region.csv")
cat("Saved statfin_bankruptcy_monthly_by_region.csv:",
    nrow(df_13fe), "rows\n")

# Quick look at North Ostrobothnia
cat("\n=== North Ostrobothnia monthly bankruptcies ===\n")
df_13fe %>%
  filter(grepl("Pohjanmaa|Ostrobothnia", Alue)) %>%
  print(n = 40)

# =============================================================================
# PART 5: Retrieve quarterly corporate restructuring by region (13fl)
# =============================================================================

event_quarters <- c(
  "2023Q1", "2023Q2", "2023Q3", "2023Q4",
  "2024Q1", "2024Q2", "2024Q3", "2024Q4"
)
# Note: 13fl data availability may lag; check metadata for latest quarter.

query_13fl <- pxweb_query(list(
  "Vuosineljännes" = event_quarters,
  "Alue"           = region_codes,
  "Tiedot"         = "*"
))

data_13fl <- pxweb_get(
  paste0(api_base, "StatFin__kony/statfin_kony_pxt_13fl.px"),
  query = query_13fl
)
df_13fl <- as.data.frame(data_13fl, column.name.type = "text")

write_csv(df_13fl, "statfin_restructuring_quarterly_by_region.csv")
cat("Saved statfin_restructuring_quarterly_by_region.csv:",
    nrow(df_13fl), "rows\n")

# Quick look at North Ostrobothnia
cat("\n=== North Ostrobothnia quarterly restructuring ===\n")
df_13fl %>%
  filter(grepl("Pohjanmaa|Ostrobothnia", Alue)) %>%
  print(n = 20)

# =============================================================================
# Summary
# =============================================================================
cat("\n========== StatFin data retrieval complete ==========\n")
cat("Bankruptcy by industry:", nrow(df_13fd), "rows\n")
cat("Bankruptcy by region:", nrow(df_13fe), "rows\n")
cat("Restructuring by region:", nrow(df_13fl), "rows\n")
