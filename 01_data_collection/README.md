# 01 Data Collection

Scripts for retrieving raw data from Finnish public data sources.

## Data Sources Covered

- **PRH YTJ Open Data API** — Company registration data (OYJ, OY, OSK): business ID, company name, registration date, company form, industry codes, registered address.
- **PRH Registered Notices API** — Public notices for all company types: financial statement filings (TA), change notifications (M), establishment notices (U), creditor announcements (JH), merger applications (FUU), dissolution notices (END), and others.
- **Vero Open Data** — Firm-level corporate income tax CSV (FY2020–2024): taxable income, total tax, tax refund, back tax, by Business ID.
- **Vero PxWeb Statistical Database** — Aggregate VAT monthly data, business taxes by industry and legal entity form, tax revenue by industry.
- **Statistics Finland**- From StatFin PxWeb API, monthly company bankruptcy data, 13fl -- Business restructuring proceedings quarterly by region.
## Scripts 

- **oy_notification_pull.R.**  Retrieve all public notices (registered notifications) for 169,301 matched Finnish private limited companies (Osakeyhtiö, OY) from the PRH open data API.
- **oy_notification_retry.R.** The supplement script companies to thoese may have failed due to transient server errors and identifies missing Business IDs by comparing the full company list to retry.
- **prh_company_registration_pull.R.** Basic company registration data for three legal entity types from the Finnish Patent and Registration Office (PRH) open data API:
   - OYJ (Julkinen osakeyhtiö, public limited company): treatment group
   - OY  (Osakeyhtiö, private limited company): control group
   - OSK (Osuuskunta, cooperative): robustness group
- **statfin_bankruptcy_restructuring_pull.R.** Retrieve bankruptcy and corporate restructuring statistics from Statistics Finland's PxWeb Statistical Database. These datasets provide marco-level evidence of fiscal stress transmission following the VAT rate voltilities from 24% to 25.5% on 1 Setpember 2024.
- **vero_pxweb_explore_and_pull.R.** Explore the Vero (Finnish Tax Administration) PxWeb Statistical Database's structure to identify available aggregate tax data and etrieve VAT monthly data,business tax data by legal entity form, and tax revenue by industry for the 36-month event window (March 2023 – February 2026).
