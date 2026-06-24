# =============================================================================
# Vero PxWeb Statistical Database — API Exploration and Data Retrieval
# =============================================================================
#
# Purpose:
#   Explore the Vero (Finnish Tax Administration) PxWeb Statistical Database
#   to identify available aggregate tax data, then retrieve VAT monthly data,
#   business tax data by legal entity form, and tax revenue by industry for
#   the 36-month event window (March 2023 – February 2026).
#
# Data source:
#   Vero PxWeb Statistical Database
#   https://vero2.stat.fi/PXWeb/pxweb/en/Vero/
#   Free, public, no authentication required.
#   API base: http://vero2.stat.fi/PXWeb/api/v1/en/Vero/
#
# Why this script exists:
#   Firm-level monthly VAT filing data is not publicly available in Finland
#   (the Vero transactional API requires a certificate and API key reserved
#   for institutional users). This script retrieves aggregate-level tax
#   statistics as an alternative, providing macro-level evidence of fiscal
#   shock transmission that complements the firm-level PRH notification data.
#
# Key constraint:
#   In PxWeb, OY (private limited companies) and OYJ (public limited companies)
#   are merged under "Osakeyhtiö" (code 03: Limited-liability company) and
#   cannot be separated. Firm-level separation is achieved through the Vero
#   Open Data CSV matched with PRH registration data (see 02_data_cleaning/).
#
# Output:
#   Multiple CSV files for different data dimensions (see individual sections).
#
# Dependencies:
#   install.packages("pxweb")
#
# =============================================================================

library(pxweb)
library(tidyverse)

# =============================================================================
# PART 1: Explore the PxWeb directory structure
# =============================================================================
# The PxWeb API is hierarchical. We start at the top level and drill down
# to identify which tables contain data relevant to the research.

# --- Top level: all available categories ---
px_top <- pxweb_get("http://vero2.stat.fi/PXWeb/api/v1/en/Vero/")
print(px_top)
# Expected categories:
#   Elinkeinoverotilasto  -> Business taxes (annual, by legal entity form)
#   Arvonlisavero         -> Value added tax (monthly, by industry)
#   Verotulojen_kehitys   -> Tax revenue development (monthly, by industry)

# --- VAT subcategory ---
px_vat <- pxweb_get("http://vero2.stat.fi/PXWeb/api/v1/en/Vero/Arvonlisavero")
print(px_vat)
# Expected tables:
#   alv_101.px -> VAT by tax period (monthly, by reporting frequency)
#   alv_102.px -> VAT by tax period, cash accounting method
#   alv_103.px -> VAT by tax period by industry

# --- Business taxes subcategory ---
px_biz <- pxweb_get("http://vero2.stat.fi/PXWeb/api/v1/en/Vero/Elinkeinoverotilasto")
print(px_biz)
# Expected subcategories:
#   tulos   -> 01. Profit/Loss
#   verot   -> 03. Taxes (contains tables by legal entity form and municipality)
#   ennakot -> 04. Prepayments, refunds and back taxes

# --- Tax revenue subcategory ---
px_rev <- pxweb_get("http://vero2.stat.fi/PXWeb/api/v1/en/Vero/Verotulojen_kehitys")
print(px_rev)
# Expected tables:
#   010_verotall_tau_101.px  -> Gross tax revenues and refunds (monthly)
#   010_verottol_tau_101.px  -> Gross tax revenues and refunds by industry

# =============================================================================
# PART 2: Inspect table metadata (dimensions and available values)
# =============================================================================

# --- VAT Table 1: monthly data by reporting frequency ---
vat1_meta <- pxweb_get(
  "http://vero2.stat.fi/PXWeb/api/v1/en/Vero/Arvonlisavero/alv_101.px"
)
cat("=== VAT Table 1 dimensions ===\n")
for (v in vat1_meta$variables) {
  cat(sprintf("\n  %s (%s): %d values\n", v$text, v$code, length(v$values)))
  n <- min(10, length(v$values))
  print(data.frame(code = v$values[1:n], text = v$valueTexts[1:n]))
}

# --- VAT Table 3: monthly data by industry ---
vat3_meta <- pxweb_get(
  "http://vero2.stat.fi/PXWeb/api/v1/en/Vero/Arvonlisavero/alv_103.px"
)
cat("\n=== VAT Table 3 dimensions ===\n")
for (v in vat3_meta$variables) {
  cat(sprintf("\n  %s (%s): %d values\n", v$text, v$code, length(v$values)))
  n <- min(10, length(v$values))
  print(data.frame(code = v$values[1:n], text = v$valueTexts[1:n]))
}

# =============================================================================
# PART 3: Retrieve VAT monthly data for the event window
# =============================================================================
# Event window: pre-treatment March 2023 – August 2024 (18 months)
#               post-treatment September 2024 – February 2026 (18 months)

# Generate monthly tax period codes (format: "2023M03", "2023M04", ...)
event_months <- c(
  paste0("2023M", sprintf("%02d", 3:12)),
  paste0("2024M", sprintf("%02d", 1:12)),
  paste0("2025M", sprintf("%02d", 1:12)),
  paste0("2026M", sprintf("%02d", 1:2))
)

# --- VAT Table 1: Total VAT by reporting frequency ---
vat1_query <- pxweb_query(list(
  "Verokausi"    = event_months,
  "Ilmoitusjakso" = c("1", "4", "12"),   # Monthly, Quarterly, Yearly filers
  "Muuttuja"     = "*",                   # All variables
  "Tiedot"       = c("lukumaara", "vpisteN")  # Number of filers, Total VAT
))

vat1_data <- pxweb_get(
  "http://vero2.stat.fi/PXWeb/api/v1/en/Vero/Arvonlisavero/alv_101.px",
  query = vat1_query
)
vat1_df <- as.data.frame(vat1_data, column.name.type = "text")
write_csv(vat1_df, "vat1_by_frequency_eventwindow.csv")
cat("Saved vat1_by_frequency_eventwindow.csv:", nrow(vat1_df), "rows\n")

# --- VAT Table 3: VAT by industry (2-digit TOL 2008 codes) ---
# Selected industries relevant to the Finnish corporate landscape
industry_codes <- c("SSS", "64", "62", "26", "61", "70")
# SSS = All industries total
# 64  = Financial service activities
# 62  = Computer programming, consultancy
# 26  = Manufacture of computer, electronic and optical products
# 61  = Telecommunications
# 70  = Activities of head offices; management consultancy

vat3_query <- pxweb_query(list(
  "Verokausi"  = event_months,
  "Toimiala"   = industry_codes,
  "Muuttuja"   = "*",
  "Tiedot"     = c("lukumaara", "vpisteN")
))

vat3_data <- pxweb_get(
  "http://vero2.stat.fi/PXWeb/api/v1/en/Vero/Arvonlisavero/alv_103.px",
  query = vat3_query
)
vat3_df <- as.data.frame(vat3_data, column.name.type = "text")
write_csv(vat3_df, "vat3_2digit_industry_eventwindow.csv")
cat("Saved vat3_2digit_industry_eventwindow.csv:", nrow(vat3_df), "rows\n")

# =============================================================================
# PART 4: Retrieve tax revenue data (monthly, by industry)
# =============================================================================

rev_months <- c(
  paste0("2023M", sprintf("%02d", 3:12)),
  paste0("2024M", sprintf("%02d", 1:12)),
  paste0("2025M", sprintf("%02d", 1:12)),
  paste0("2026M", sprintf("%02d", 1:2))
)

rev_query <- pxweb_query(list(
  "Toimiala"       = industry_codes,
  "Verolaji"       = c("200", "300"),    # 200 = Corporate income tax, 300 = VAT
  "Kertymäkuukausi" = rev_months,
  "Muuttuja"       = "*",
  "Verovuosi (ajanjakso, jolta veron peruste on syntynyt)" = "*",
  "Tiedot"         = "milj_euroa"        # Millions of euros
))

rev_data <- pxweb_get(
  "http://vero2.stat.fi/PXWeb/api/v1/en/Vero/Verotulojen_kehitys/010_verottol_tau_101.px",
  query = rev_query
)
rev_df <- as.data.frame(rev_data, column.name.type = "text")
write_csv(rev_df, "tax_revenue_industry_monthly_eventwindow.csv")
cat("Saved tax_revenue_industry_monthly_eventwindow.csv:", nrow(rev_df), "rows\n")

# =============================================================================
# PART 5: Retrieve business taxes by legal entity form
# =============================================================================
# Note: In PxWeb, "Limited-liability company" (code 01) includes both OY and
# OYJ. They cannot be separated at this level. Firm-level separation relies
# on the Vero Open Data CSV matched with PRH registration data.

biz316_query <- pxweb_query(list(
  "Toimiala"     = industry_codes,
  "Yhteisömuoto" = c("SSS", "01", "03"),  # Total, Ltd company, Cooperative
  "Verovuosi"    = as.character(2014:2024),
  "Tiedot"       = "*"
))

biz316_data <- pxweb_get(
  "http://vero2.stat.fi/PXWeb/api/v1/en/Vero/Elinkeinoverotilasto/verot/verot_315.px",
  query = biz316_query
)
biz316_df <- as.data.frame(biz316_data, column.name.type = "text")
write_csv(biz316_df, "biz_taxes_316_industry_legalform.csv")
cat("Saved biz_taxes_316_industry_legalform.csv:", nrow(biz316_df), "rows\n")

cat("\n=== All Vero PxWeb data retrieval complete ===\n")
