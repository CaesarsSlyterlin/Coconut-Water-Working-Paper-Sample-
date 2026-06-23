* =============================================================================
* Sample DiD Analysis — PRH Notification Data (Layer 2)
* =============================================================================
*
* Purpose:
*   Run baseline difference-in-differences regressions on the firm-month
*   notification panel, using financial statement filings (TA) as the
*   dependent variable. This is a sample analysis demonstrating the
*   methodology and data pipeline; it does not represent the final
*   specification of the working paper.
*
* Data:
*   Imported from R output (see 02_data_cleaning/03_build_firm_month_panel.R):
*     stata_firm_list.csv       — firm list with treatment indicator
*     stata_ta_firm_month.csv   — TA-specific non-zero observations
*     stata_firm_month_type.csv — all notice types, non-zero observations
*
* Panel structure:
*   165,496 firms x 36 months = 5,957,856 observations
*   OYJ (treatment): 304 firms x 36 = 10,944 obs
*   OY (control): 165,192 firms x 36 = 5,946,912 obs
*
* Dependent variables:
*   ta_count — monthly count of TA (financial statement) filings
*   ta_dummy — binary: 1 if firm filed at least one TA in the month
*
* Models:
*   (1) Pooled OLS — benchmark, no fixed effects
*   (2) TWFE — firm FE + month FE, clustered SE at firm level
*   (3) M (change notification) placebo — confirm null effect
*
* Required packages:
*   ssc install reghdfe
*   ssc install ftools
*
* Author: [Your name]
* Date:   May 2026
* =============================================================================

clear all
set more off

* =============================================================================
* STEP 1: Build panel from CSV imports
* =============================================================================

* --- Import firm list ---
import delimited "stata_firm_list.csv", clear
gen treat = (firm_type == "OYJ")
tab firm_type treat
save firm_list.dta, replace

* --- Import TA filing data ---
import delimited "stata_ta_firm_month.csv", clear
gen ym_date = date(ym, "YMD")
format ym_date %td
save ta_fm.dta, replace

* --- Generate 36-month sequence (March 2023 – February 2026) ---
clear
set obs 36
gen m = _n - 1
gen year = 2023 + floor((m + 2) / 12)
gen month = mod(m + 2, 12) + 1
gen ym_date = mdy(month, 1, year)
format ym_date %td
drop m year month
save months.dta, replace

* --- Cross-merge: all firms x all months ---
use firm_list.dta, clear
cross using months.dta
count

* --- Merge TA data (non-zero observations) ---
merge m:1 business_id ym_date using ta_fm.dta, keep(master match)
replace ta_count = 0 if _merge == 1
replace ta_dummy = 0 if _merge == 1
drop _merge ym

* --- Generate regression variables ---
gen post = (ym_date >= mdy(9, 1, 2024))
gen treat_post = treat * post

encode business_id, gen(firm_id)
gen ym_num = mofd(ym_date)
format ym_num %tm

* =============================================================================
* STEP 2: Descriptive statistics
* =============================================================================

di "========== DESCRIPTIVE STATISTICS =========="
di ""
di "=== Panel dimensions ==="
count
tab firm_type post

di ""
di "=== Summary statistics ==="
summarize ta_count ta_dummy

di ""
di "=== Mean TA filing rate by group and phase ==="
table firm_type post, stat(mean ta_dummy) stat(mean ta_count) stat(freq)

* =============================================================================
* STEP 3: Pooled OLS (benchmark)
* =============================================================================

di ""
di "========== MODEL 1: Pooled OLS =========="
reg ta_count treat post treat_post, robust

* =============================================================================
* STEP 4: Two-way fixed effects (baseline DiD)
* =============================================================================

di ""
di "========== MODEL 2: TWFE — ta_count =========="
reghdfe ta_count treat_post, absorb(firm_id ym_num) vce(cluster firm_id)

di ""
di "========== MODEL 3: TWFE — ta_dummy =========="
reghdfe ta_dummy treat_post, absorb(firm_id ym_num) vce(cluster firm_id)

* =============================================================================
* STEP 5: M (change notification) placebo test
* =============================================================================
* If the DiD estimate captures a genuine disclosure response to VAT reform,
* we should see no significant effect on M (routine change notifications),
* which are not directly related to financial disclosure obligations.

di ""
di "=== Importing M data for placebo test ==="
preserve
import delimited "stata_firm_month_type.csv", varnames(1) clear
keep if notice_type == "M"
gen ym_date = date(ym, "YMD")
format ym_date %td
rename type_count m_count
rename type_dummy m_dummy
keep business_id ym_date m_count m_dummy
save m_fm.dta, replace
restore

* Merge M into panel
merge m:1 business_id ym_date using m_fm.dta
replace m_count = 0 if _merge == 1
replace m_dummy = 0 if _merge == 1
drop _merge

di ""
di "========== MODEL 4: PLACEBO — M count =========="
reghdfe m_count treat_post, absorb(firm_id ym_num) vce(cluster firm_id)

di ""
di "========== MODEL 5: PLACEBO — M dummy =========="
reghdfe m_dummy treat_post, absorb(firm_id ym_num) vce(cluster firm_id)

* =============================================================================
* STEP 6: Save panel
* =============================================================================

compress
save coconut_panel_sample.dta, replace
di ""
di "========== ALL SAMPLE ANALYSES COMPLETE =========="
