# =============================================================================
# PRH API Response Parser — Nested JSON to Flat Data Frame
# =============================================================================
#
# Purpose:
#   Parse the nested JSON structure returned by the PRH YTJ Open Data API
#   into a clean, flat data frame suitable for analysis and cross-matching.
#
#   The PRH API returns company records with deeply nested list columns:
#     - names: list of company names by language (type 1 = Finnish,
#       type 2 = English) and validity period (endDate = NULL if current)
#     - addresses: list of addresses by type (type 1 = street address),
#       each containing a nested postOffices sub-list with city name
#       and municipality code by language
#
#   This function extracts the current Finnish company name, English name
#   (if available), registered street address, postal code, city, and
#   municipality code from these nested structures.
#
# Input:
#   Raw data frame from PRH API (e.g., output of prh_company_registration_pull.R)
#   with nested list columns: $names, $addresses, $businessId.value, etc.
#
# Output:
#   Flat data frame with one row per company:
#     business_id, company_name, company_name_en, status, registration_date,
#     last_modified, street, post_code, city, municipality_code,
#     business_line, website
#
# Usage:
#   oyj_clean <- parse_prh_companies(oyj_raw)
#   write_csv(oyj_clean, "prh_oyj_clean.csv")
#
# Author: [Your name]
# Date:   May 2026
# =============================================================================

library(tidyverse)

parse_prh_companies <- function(df) {
  n <- nrow(df)

  # Helper: safely extract first non-NA value from a vector
  safe <- function(x) {
    if (is.null(x) || length(x) == 0 || all(is.na(x))) NA_character_
    else as.character(x[1])
  }

  # Pre-allocate output vectors
  company_name    <- character(n)
  company_name_en <- character(n)
  street          <- character(n)
  post_code       <- character(n)
  city            <- character(n)
  municipality_code <- character(n)

  for (i in 1:n) {

    # --- Parse company names ---
    # The names column is a nested data frame with columns: name, type, endDate
    # type 1 = Finnish name, type 2 = English name
    # endDate = NA means the name is currently valid
    nms <- df$names[[i]]

    if (is.null(nms) || nrow(nms) == 0) {
      company_name[i]    <- NA_character_
      company_name_en[i] <- NA_character_
    } else {
      # Current Finnish name (type 1, no end date)
      fi <- nms[nms$type == "1" & is.na(nms$endDate), ]
      company_name[i] <- if (nrow(fi) > 0) safe(fi$name) else safe(nms$name)

      # English name if available (type 2, no end date)
      en <- nms[nms$type == "2" & is.na(nms$endDate), ]
      company_name_en[i] <- if (nrow(en) > 0) safe(en$name) else NA_character_
    }

    # --- Parse registered address ---
    # The addresses column is a nested data frame with columns:
    #   type, street, postCode, postOffices (sub-list)
    # type 1 = street address (katuosoite)
    # postOffices is itself a nested data frame with: city, municipalityCode,
    #   languageCode (1 = Finnish, 2 = Swedish)
    addr <- df$addresses[[i]]

    if (is.null(addr) || !is.data.frame(addr) || nrow(addr) == 0) {
      street[i]            <- NA_character_
      post_code[i]         <- NA_character_
      city[i]              <- NA_character_
      municipality_code[i] <- NA_character_
      next
    }

    # Select street address (type 1), fall back to first available
    a1 <- tryCatch({
      tmp <- addr[addr$type == 1, ]
      if (is.null(tmp) || nrow(tmp) == 0) addr[1, , drop = FALSE]
      else tmp[1, , drop = FALSE]
    }, error = function(e) addr[1, , drop = FALSE])

    street[i]    <- safe(a1$street)
    post_code[i] <- safe(a1$postCode)

    # Extract city from nested postOffices sub-list (Finnish version)
    city[i] <- tryCatch({
      po <- a1$postOffices[[1]]
      if (!is.null(po) && is.data.frame(po) && nrow(po) > 0) {
        fi_po <- po[po$languageCode == "1", ]
        if (nrow(fi_po) > 0) safe(fi_po$city) else safe(po$city)
      } else NA_character_
    }, error = function(e) NA_character_)

    # Extract municipality code from the same sub-list
    municipality_code[i] <- tryCatch({
      po <- a1$postOffices[[1]]
      if (!is.null(po) && is.data.frame(po) && nrow(po) > 0) {
        fi_po <- po[po$languageCode == "1", ]
        if (nrow(fi_po) > 0) safe(fi_po$municipalityCode)
        else safe(po$municipalityCode)
      } else NA_character_
    }, error = function(e) NA_character_)
  }

  # Assemble flat data frame
  data.frame(
    business_id       = df$businessId.value,
    company_name      = company_name,
    company_name_en   = company_name_en,
    status            = df$status,
    registration_date = df$registrationDate,
    last_modified     = df$lastModified,
    street            = street,
    post_code         = post_code,
    city              = city,
    municipality_code = municipality_code,
    business_line     = df$mainBusinessLine.type,
    website           = df$website.url,
    stringsAsFactors  = FALSE
  )
}

# =============================================================================
# Example usage
# =============================================================================

# Parse OYJ companies
oyj_clean <- parse_prh_companies(oyj_raw)
cat("Parsed:", nrow(oyj_clean), "companies\n")
cat("With city info:", sum(!is.na(oyj_clean$city)), "\n")
cat("With postal code:", sum(!is.na(oyj_clean$post_code)), "\n")
write_csv(oyj_clean, "prh_oyj_clean.csv")

# Parse OY companies
oy_clean <- parse_prh_companies(oy_raw)
cat("Parsed:", nrow(oy_clean), "companies\n")
write_csv(oy_clean, "prh_oy_clean.csv")

# Parse OSK companies
osk_clean <- parse_prh_companies(osk_raw)
cat("Parsed:", nrow(osk_clean), "companies\n")
write_csv(osk_clean, "prh_osk_clean.csv")
