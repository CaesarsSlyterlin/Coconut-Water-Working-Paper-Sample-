# 02 Data Cleaning
 
Scripts for cleaning, transforming, and matching raw data from multiple sources.
 
## Key Operations
 
- **Encoding conversion:** Vero Open Data CSV files use Latin-1 encoding with Finnish decimal comma format; conversion to UTF-8 and standard numeric format.
- **PRH data cleaning:** Filtering active companies (status = REK), handling missing company names, removing duplicates across API batches.
- **Cross-database matching:** Linking PRH company registration data to Vero corporate income tax records via Business ID (Y-tunnus). Match rates: 93.9% for OYJ, 61.2% for OY across a 5-year balanced panel (FY2020–2024).
- **Panel construction:** Building firm-month notification panels from PRH notice data; defining pre-treatment (March 2023 – August 2024) and post-treatment (September 2024 – February 2026) windows.
- **Event window filtering:** Restricting sample to 36-month event window and excluding firms registered after the start of the sample period.
## Scripts (to be added)
 
Placeholder — sample scripts will be added to this folder.
 
