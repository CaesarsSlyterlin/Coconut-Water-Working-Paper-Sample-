# 03 Sample Analysis
 
Preliminary descriptive statistics and sample regression tests based on PRH notification data (Layer 2 of the conceptual framework).
 
**Note:** These are sample analyses demonstrating methodology and data pipeline. They do not represent the final results or complete specification of the working paper. The full research design involves multiple data layers and a more comprehensive identification strategy.
 
## Contents 
 
- Descriptive statistics: pre/post comparison of notification counts by company type (OYJ, OY, OSK) and notification type (TA, M, JH, FUU, etc.)
- Sample DiD specification using firm-month notification panel
- Event window visualisation
## Preliminary Findings from Sample Tests
 
- OYJ financial statement (TA) filings: approximately −49% in post-treatment period.
- OY creditor announcements (JH): +352%, consistent with rising financial distress among small firms.
- Sample DiD on monthly notification count: β = −0.091, t = −4.34 (p < 0.001).
## Scripts 
 
- **sample_did_analysis.do.** Run baseline difference-in-differences regressions on the firm-month notification panel, using financial statement filings (TA) as the dependent variable. Data imported from 02_data_cleaning/03_build_firm_month_panel.R. 
 
## Models, Results and Main Findings

- **Panel dimensions.** 5,957,856 observations (165,496 firms x 36 months)
  - OYJ: 304 firms x 36 = 10,944 obs (treatment)
  - OY: 165,192 firms x 36 = 5,946,912 obs (control)
    
- **Definition of  Dependent Variables.**
   - ta_count= monthly TA filing amount, ta_count: mean = 0.0729, sd = 0.2754, min = 0, max = 11;
   - ta_dummy= 0 binary indicator,1 if at least one TA filing in the month, 0 otherwise. ta_dummy: mean = 0.0693, sd = 0.2540, min = 0, max = 1.
     
- **Three specifications and their corresponding coefficients**
  
   - **For Pooled OLS**:   treat_post = -0.086  (t = -9.33)
     
   - **For reghdfe (ta_count)**:  treat_post = -0.086  (t = -13.84)
     
   - **For reghdfe (ta_dummy)**:  treat_post = -0.057  (t = -16.58)

   ***Note***: All p-values are 0.000, with standard errors clustered at the firm level.
  
 ### Pooled OLS and TWFE

- In the **pooled OLS regression**, the **treatment effect is significantly negative (-0.0860)**, the **post-period coefficient** is **-0.0096**, and the **baseline treatment effect** is 0.1167.
-  When using **reghdfe** for two-way fixed effects (TWFE) estimation, the **coefficient of the post-treatment interaction term** is -0.0860, with a **t-statistic of -13.84** and a **clustered standard error** of 0.006214. The model's within **R-squared** is close to **0**.
    
 ### Results,Findings and Limitations

   - The **VAT shock** led to an **additional 5.7 percentage point decline** in the monthly TA filing probability for OYJ relative to OY, which is **equivalent to a 43% reduction** from the **baseline level of 0.133**.
   - The **coefficients from Pooled OLS and TWFE are completely identical**, the two-way fixed effects do not alter the estimates and that the identifying variation is clean.
   - **Limitations.** TA filings exhibit **strong seasonality** (with **peaks in May and October** tied to the Finnish fiscal year deadline), which distorts the visualization of parallel trends in the event study; even **quarterly aggregation** does not fully resolve this issue.
   - This sample analysis confirms that **TA, as the dependent variable**, yields **strong and robust results under the baseline DiD framework**. However, addressing **parallel trends** in the event study, controlling for seasonality, and integrating other data layers are deferred to the subsequent working paper and fall outside the scope of this sample analysis.
