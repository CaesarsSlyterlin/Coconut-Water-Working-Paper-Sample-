# Data and Code Sample Analysis  for Coconut Water Working Paper: A Discussion VAT Tax Reform, Financial Disclosure and Fiscal Stress Test 

## Introduction

This repository provides sample codes and sample datasets from my ongoing working paper **"Who Takes My Coconut Water from the Fridge: A Discussion of Firm's Disclosure and  Responses in Finland"**,shortly called *"Coconut Water Working Paper"*.

The paper investigates how Finnish firms' disclosure behaviour responds to the VAT rate increase from 24% to 25.5%, effective from 1 September 2024, using a difference-in-differences framework. The identification exploits institutional heterogeneity between public limited companies (Julkinen osakeyhtiö, OYJ) and limited companies (Osakeyhtiö, OY) in their statutory disclosure obligations.The working paper was inspired by my shopping experience about coconut water at an Asian market in summer 2024 in Finland.

**Note:** This repo provides sample code and preliminary analysis only. It does not represent the final results or complete specification of the working paper. 03_sample_analysis provides the sample empirical results and regression analysis from an early stage research design test in April 2026, it doesn't indicate any complete results in this paper.

## Research Design

The research design builds on a multi-layer conceptual framework of fiscal stress transmission:

- **Layer 1 — Tax compliance level:** VAT rate change directly affects firms' tax filing behaviour (aggregate-level evidence only; firm-level monthly VAT data is not publicly available in Finland).
- **Layer 2 — Registry compliance level:** Firms' interaction patterns with the Finnish Patent and Registration Office (PRH) — financial statement filings, change notifications,notification frequencies and distress-related filings.
- **Layer 3 — Capital market disclosure level:** Listed firms' disclosure behaviour datasets via NASDAQ Helsinki and NASDAQ First North Market,eg. financial calendar announcements, reporting frequency changes.
  
**Note:** This repo focuses primarily on ***Layer 2***, demonstrating the data collection, cleaning, and preliminary analysis for PRH(Finnish Patent and Registration Office) and Verohallinto (Finnish Tax Administration) data.

## Data Sources

| Source | Description | Access |
|--------|-------------|--------|
| **PRH (Finnish Patent and Registration Office)** | Company registration data and public notices for OYJ, OY, and OSK (cooperatives) via the YTJ open data API and registered notices API | Free, public API |
| **Vero (Finnish Tax Administration)** | Firm-level corporate income tax data (Open Data CSV) and aggregate VAT/business tax statistics (PxWeb Statistical Database) | Free, public |
| **Statistics Finland** | Bankruptcy statistics, regional unemployment | Free, public |

## Sample Size
 
- **Treatment group (OYJ):** 294 active public limited companies (429 total in trade register)
- **Control group (OY):** 169,301 private limited companies (matched by industrial codes)
- **Robustness group (OSK):** 6,708 cooperatives
- **Event window:** 1 March 2023 – 28 February 2026 (18 months pre- and post-treatment, treatment date: 1 September 2024)

## Repository Structure
 
```
├── 01_data_collection/       # Scripts for retrieving data from PRH API, Vero Open Data, and Vero PxWeb
├── 02_data_cleaning/         # Cleaning, encoding fixes, cross-matching PRH ↔ Vero via Business ID
├── 03_sample_analysis/       # Preliminary descriptive statistics and sample DiD tests
├── 04.data_samples/          # Small sample datasets and summary statistics (no full datasets)
├── 05_python_replication/    # Python replication of the R pipeline (pandas / requests), visualized geodata test of Finland municipality map
└── README.md
```
**Note:** **05_python_replication README.md** contains **sample visualization geodata of Finland municipality map**

## Key Technical Challenges 
 
- **Large-scale API data retrieval:** Batch-pulling loop 169,301 firms' public notices from the PRH API (29.2 hours, automated retry and checkpoint logic).
- **Cross-database matching:** Linking PRH company registration data to Vero corporate tax records via Business ID (Y-tunnus), handling a 61.2% match rate for OY and 93.9% for OYJ across a 5-year balanced panel.
- **Encoding and format issues:** Finnish-language data sources using Latin-1 encoding, Finnish decimal comma format, and mixed-language field names.[Key terminology index](#appendix-finnishenglish-terminology) is attached in this README document.
- **API endpoint discovery:** Identifying undocumented API structures through scrappy tools for additional data sources.
- **GIS dependencies:** dtype=str keeps the zero-padded three-digit municipality codes intact to avoid pandas read as integers.

## Tools
 
- **R** (httr, jsonlite, tidyverse, pxweb) for API access, data cleaning, and panel construction
- **Stata 17 MP** for regression analysis
- **Python (requests, pandas)** a self-contained replication of the R data pipeline is provided in 05_python_replication/, runnable in demo mode on Google Colab 

## Preliminary Findings (Sample Analysis)
 
Based on PRH notification data (Layer 2):
 
- OYJ financial statement (TA) filings declined by approximately 49% in the post-treatment period.
- OY creditor announcements (JH) increased by 352%, consistent with rising financial distress among small firms.
- Sample DiD on monthly notification count: β = −0.091, t = −4.34 (p < 0.001).
These are preliminary results from one data layer and do not represent the paper's final conclusions.

## Appendix: Finnish–English Terminology
 
### A. Key Terms
 
| Finnish | English |
|---------|---------|
| Finanssivalvonta, FIN-FSA | Finnish Financial Supervisory Authority |
| julkinen osakeyhtiö, oyj | public limited company |
| osakeyhtiö, oy | limited company |
| osuukunta, osk | cooperative |
| Pohjois-Pohjanmaa | North Ostrobothnia |
| PRH-patentti ja rekisterihallitus, PRH | Finnish Patent and Registration Office |
| Talouselämä list, TE500 lista | Talouselämä magazine list of Finland, annual TE500 survey of Finland's largest companies by revenue, published annually in June |
| Verohallinto, Vero | Finnish Tax Administration |

### B. Company Forms in Finland (Finnish Trade Register)
 
| Code | Finnish | English |
|------|---------|---------|
| AOY | Asunto-osakeyhtiö | Housing company |
| ASH | Asukashallintoalue | Resident-administered area |
| ASY | Asumisoikeusyhdistys | Right-of-occupancy association |
| AY | Avoin yhtiö | Partnership |
| AYH | Aatteellinen yhdistys | Non-profit association |
| ETS | Euroopp.taloudell.etuyht.sivutoimipaikka | Finnish branch of a European economic interest grouping |
| ETY | Eurooppalainen taloudellinen etuyhtymä | European economic interest grouping |
| SCE | Eurooppaosuuskunta | European Co-operative society |
| SCP | Eurooppaosuuspankki | European co-operative bank |
| HY | Hypoteekkiyhdistys | Mortgage society |
| KOY | Keskinäinen kiinteistöosakeyhtiö | Limited liability joint-stock property company |
| KVJ | Julkinen keskinäinen vakuutusyhtiö | Public mutual insurance company |
| KVY | Keskinäinen vakuutusyhtiö | Mutual insurance company |
| KY | Kommandiittiyhtiö | Limited partnership |
| OK | Osuuskunta | Co-operative |
| OP | Osuuspankki | Co-operative bank |
| OY | Osakeyhtiö | Limited company |
| OYJ | Julkinen osakeyhtiö | Public limited company |
| SE | Eurooppayhtiö | European company |
| SL | Sivuliike | Branch of a foreign trader |
| SP | Säästöpankki | Savings bank |
| SÄÄ | Säätiö | Foundation |
| TYH | Taloudellinen yhdistys | Association for carrying on economic activity |
| VOJ | Julkinen vakuutusosakeyhtiö | Public limited insurance company |
| VOY | Vakuutusosakeyhtiö | Limited insurance company |
| VY | Vakuutusyhdistys | Insurance association |
| VALTLL | Valtion liikelaitos | State-owned company |
 
Source: Finnish Trade Register (PRH)
 
### C. Company Status Codes (Finnish Trade Register)
 
| Code | Finnish | English |
|------|---------|---------|
| REK | Rekisterissä | Active / In the register |
| KONK | Konkurssissa | Bankrupt |
| SANE | Saneerauksessa | Company re-organisation |
| SELTILA | Selvitystilassa | Liquidation |
 
Source: Finnish Trade Register (PRH)


## Author 
Wenfei Cai

## Related 
- The working paper preprint version is available on SSRN with private access. Please contact me by request.
-The paper's identification strategy draws on Bischof, Daske, Elfers & Hail (2022, *Contemporary Accounting Research*,)and the voluntary disclosure literature (Verrecchia 1983; Wagenhofer 1990).

## Main References Included in this Repo and Working Paper

Bischof, J., Daske, H., Elfers, F., & Hail, L. (2022). A Tale of Two Supervisors: Compliance with Risk Disclosure Regulation in the Banking Sector. *Contemporary Accounting Research*, *39*(1), 498–536. https://doi.org/10.1111/1911-3846.12715 

Verrecchia, R. E. (1983). Discretionary disclosure. *Journal of Accounting and Economics*, *5*, 179–194. https://doi.org/10.1016/0165-4101(83)90011-3

Wagenhofer, A. (1990). Voluntary disclosure with a strategic opponent. *Journal of Accounting and Economics*, *12*(4), 341–363. https://doi.org/10.1016/0165-4101(90)90020-5 
