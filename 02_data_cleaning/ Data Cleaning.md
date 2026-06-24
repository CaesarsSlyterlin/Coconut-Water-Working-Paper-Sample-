# 02 Data Cleaning
 
Scripts for cleaning, transforming, and matching raw data from multiple sources.
 
## Key Operations
 
- **Encoding conversion:** Vero Open Data CSV files use Latin-1 encoding with Finnish decimal comma format; conversion to UTF-8 and standard numeric format.
- **PRH data cleaning:** Filtering active companies (status = REK), handling missing company names, removing duplicates across API batches.
- **Cross-database matching:** Linking PRH company registration data to Vero corporate income tax records via Business ID (Y-tunnus). Match rates: 93.9% for OYJ, 61.2% for OY across a 5-year balanced panel (FY2020–2024).
- **Panel construction:** Building firm-month notification panels from PRH notice data; defining pre-treatment (March 2023 – August 2024) and post-treatment (September 2024 – February 2026) windows.
- **Event window filtering:** Restricting sample to 36-month event window and excluding firms registered after the start of the sample period.
## Scripts 
 
- **01_merge_notifications.R.** Merged 170 batch CSV files from the OY notification (including the retry batch for previously failed companies) in one dataset. Combined OYJ, OY, and OSK notification data into a unified dataset. Contains parse dates, assign firm type labels, filter to the 36-month event window.
- **02_vero_encoding_and_match.R.** Vero Open Data corporate income tax CSV files (FY2020–2024), handling Finnish-specific encoding and format issues (Latin-1 v.s. UTF-8);Vero tax records to PRH company registration data via Business ID (Y-tunnus) to create a firm-level panel that separates OYJ from OY.
- **03_build_firm_month_panel.R.** Firm-Month Notification Panel for DiD Analysis- firm x month panel from cleaned PRH notification data.
- **04_parse_prh_addresses.R.** Parse the nested JSON structure returned by the PRH YTJ Open Data API into a clean, flat data frame suitable for analysis and cross-matching.

  
 
