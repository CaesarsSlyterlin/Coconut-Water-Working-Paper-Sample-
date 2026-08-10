# Python Replication of the PRH Data Pipeline
This folder contains a self-contained Python replication (prh_pipeline.py) of the R data pipeline in **01_data_collection/** ,and **02_data_cleaning/** and **03_sample_analysis/** . 

It is organised in two files:

| File | Contents |
|---|---|
| `prh_pipeline.py` | The original six-step replication: paginated retrieval from the PRH YTJ companies API, parsing of nested JSON with missing-value protection, checkpointed retrieval of registered notices per Business ID, event-window filtering, aggregation to a firm-month panel with DiD indicators, and an optional municipality choropleth. |
| `main empirical and specification.py` | Modules added June–August 2026: full-history notice retrieval, extensive-margin outcomes and entry/exit truncation, the firm-window panel, Nasdaq disclosure classification, tax register cross-match diagnostics, and estimation. |

 `prh_pipeline.py` runs in *DEMO_MODE* by default (full OYJ register, a 25-firm notice sample) and completes in a few minutes on Google Colab. Set DEMO_MODE = False only if you intend a full-scale pull; the equivalent R production run over 169,301 firms took 29.2 hours and it is the equivalent to R pull.It reproduces the same logic with requests and pandas: paginated retrieval from the PRH YTJ companies API, parsing of nested JSON records with missing-value protection, checkpointed retrieval of registered notices per Business ID, event-window filtering, and aggregation to a firm-month panel with DiD indicator variables.
The script runs in *DEMO_MODE* by default (full OYJ register, a 25-firm notice sample) and completes in a few minutes on Google Colab. Set DEMO_MODE = False only if you intend a full-scale pull; the equivalent R production run over 169,301 firms took 29.2 hours.
Two implementation notes came out of empirical verification against the live API (July 2026): pagination on the YTJ companies endpoint is 1-based (page=0 silently duplicates page 1), and firms with no registered notices omit the publicNotices key entirely rather than returning an empty list. Both behaviours are handled and documented in the code.status filtering keeps registered non-deregistered firms (420 at verification time); The paper's treatment group further restricts to firms with FY2024 tax records (294, cross-validated against PRH's official statistics) status filtering keeps registered non-deregistered firms (420 at verification time); the paper's treatment group further restricts to firms with FY2024 tax records (294, cross-validated against PRH's official statistics). 

`main empirical and specification.py`contains functions rather than a script. 

## Samples and scope
 
The paper compares 196 firms listed on Nasdaq Helsinki (194 OYJ and 2 limited
companies that are listed) with 169,294 active limited companies, over a
36-month event window from March 2023 to February 2026. The treatment date is
1 September 2024, giving symmetric 18-month pre- and post-treatment windows.
A further 6,708 cooperatives are retained for a replacement test.
 
Status filtering on the PRH register keeps registered, non-deregistered firms.
The treatment group is **not** derived from that register directly: it is the
whitelist of 196 firms constructed from the Nasdaq Helsinki and First North
Finland company news feeds and matched back to PRH by Business ID
(`all_nasdaq_news_final3.csv`). An earlier version of this pipeline documented
a treatment group of 294 firms drawn from the PRH register and filtered on
FY2024 tax records; that definition has been superseded and should not be used.
 
---
## Implementation notes from empirical verification against the live API
 
**Pagination on the YTJ companies endpoint is 1-based.** `page=0` and `page=1`
return identical content, because the API silently coerces 0 to 1. Iterating
from page 0 therefore double-fetches the first page and, worse, trips the
`len(records) >= total` stop condition one page early, silently dropping the
final partial page — 28 of 428 public limited companies in the verification
run. Duplicate-page detection is included as a second line of defence.
 
**Firms with no registered notices omit the `publicNotices` key entirely**
rather than returning an empty list. 94 of 169,301 limited companies have no
notice history at all. Progress tracking is therefore kept independent of the
output, so those firms are not re-fetched on every restart.
 
**The batch-search endpoint is unusable at scale.** It returns HTTP 504 from
roughly page 6 onward. The per-company endpoint is the only route that
completes.
 
**Retrieve full histories, not event-window extracts.** The registry's own
boundary is 7 November 2014 and responses run to the current date. Computing
compliance rates from event-window extracts understates listed-firm compliance
in the earliest comparison window as 3.1 per cent, against a true value of
97.3 per cent computed from full histories, because a firm's earlier filings
fall outside the extract. Filter to the event window downstream, not at
retrieval.
 
**The `market` field in the Nasdaq feed is unreliable** and must not be used
for filtering. An intermediate file built with such a filter dropped 3,570
releases before this was caught, and was discarded.
 
**The registry carries no fiscal-year identifier.** `entryCodes` takes only the
values `TASE` and blank; `recordNumber` is a sequential registry reference of
the form `2025/32056V`. A financial statement notice therefore cannot be
assigned to the fiscal year it reports on, and the outcome variable must be
read as whether a registration event occurred in the observation period.
 
---
 
## Modules added June–August 2026
 
`coconut_new_modules.py` is organised in seven parts.
 
### Part A — Notice type reference
 
The thirteen registration types. Eleven come from the registry's published code
table, retrieved from `/description?code=NRT` rather than inferred from the
data; two more (`END`, `TASE`) appear in the data but not in the published
table and are historical. The grouping drives every outcome variable in the
paper: `TA` is the mandatory disclosure outcome, and the distress group
(`JH`, `FUU`, `DIF`, `END`) serves as a check that shows no treatment effect.
 
### Part B — Full-history notice retrieval
 
`fetch_full_history()` replaces the event-window retrieval in
`prh_pipeline.py`. Production timings: 196 listed firms and 22,572 records in
3.8 minutes; 6,708 cooperatives and 88,473 records in 122 minutes; 169,301
limited companies and 3,512,187 records in 29.2 hours. Results are flushed to
disk every `batch_size` firms and dropped from memory, because holding 3.5
million records in one list exhausts RAM.
 
### Part C — Extensive-margin outcomes and entry/exit truncation
 
`add_extensive_margin()` produces the binary outcomes the paper uses.
`apply_entry_exit_truncation()` keeps firms through the month of exit and from
the month of entry, so that structural zeros are not read as non-compliance.
`restrict_control_group()` drops control firms registered on or after the start
of the sample period, since firms established after the reform may represent
strategic entry.
 
### Part D — Firm-window panel
 
`build_firm_window_panel()` aggregates to four twelve-month windows anchored on
the treatment date. Within a window the question is only whether the firm filed
at all, which is invariant to the forwarding delay between the tax authority
and the registry — 7 days for statements submitted with a tax return, up to 15
months for those submitted through the dividend function.
`compliance_gradient()` and `decompose_2x2()` produce the descriptive table and
the hand-checked decomposition of the estimate.
 
### Part E — Nasdaq category classification
 
`classify_nasdaq()` collapses 27 exchange category labels into six buckets.
`check_label_migration()` quantifies category share shifts between pre and post
periods; run it before choosing outcome definitions on any exchange feed. In
this sample, buyback announcements migrated from a dedicated category into a
residual one (83 to 602 releases) while the count of underlying transactions
barely moved (4,213 to 4,275) — the same behaviour was relabelled, so the
discretionary bucket is kept combined rather than split.
 
### Part F — Tax register cross-match diagnostics
 
`diagnose_vero_match()` matches on Business ID and breaks coverage down by
registration cohort; `crosscheck_missing_against_filing()` compares registry
filing rates inside and outside the tax data. 145,746 of 169,294 control firms
match (86.1 per cent). Coverage runs 98.5 / 99.3 / 99.7 / 99.2 per cent for
firms registered up to 2010, 2011–15, 2016–20 and 2021–23, and 18.4 per cent
for firms registered from 2024; firms outside the tax data file with the
registry at 34.4 per cent against 97.5 per cent for those inside. The shortfall
is mechanical rather than a selection on profitability.
 
### Part G — Estimation
 
`estimate_baseline()`, `estimate_placebo()`, `estimate_event_study()`,
`estimate_nasdaq()` and `segment_means()`. `pyfixest` is used rather than
`statsmodels` or `linearmodels`: on 6.1 million rows with 169,490 firm fixed
effects a dense dummy design matrix is not feasible. For reference, Stata's
`encode()` fails outright on this panel because its value-label limit is 65,536
against 169,490 firms, and `reghdfe` exhausts memory on the production machine.
 
---

## Requirements
Python 3.10+, requests, pandas. Optional for the municipality map: geopandas, matplotlib, and a municipality boundary file from Statistics Finland open geodata.

## Drawing the municipality map 
The map step is skipped by default so the core pipeline runs without GIS dependencies. To draw it after a demo run (e.g. on Google Colab), install geopandas and matplotlib, then run in a notebook cell:

```python
from prh_pipeline import plot_municipality_map
import pandas as pd

firms = pd.read_csv("output/prh_oyj_clean.csv", dtype=str)
plot_municipality_map(firms)
```

dtype=str keeps the zero-padded three-digit municipality codes intact. **Boundaries are fetched directly from Statistics Finland's open WFS (layer tilastointialueet:kunta4500k)**. The example output below shows the geographic concentration of active Finnish public limited companies: most are registered in the Helsinki capital region.

**fetching municipality boundaries (tilastointialueet:kunta4500k) from geo.stat.fi**

<img width="564" height="820" alt="image" src="https://github.com/user-attachments/assets/dffb961d-373f-4e4a-9b6f-e48b1bc9292d" />

---
## Using the new modules
 
The modules are independent. A typical sequence:
 
```python
import pandas as pd
import coconut_new_modules as cnm
 
# 1. retrieve full notice histories
cnm.fetch_full_history(
    business_ids=firms["business_id"].tolist(),
    out_dir="output/notices",
    progress_file="output/notice_progress.json",
)
notices = cnm.load_notice_batches("output/notices")
 
# 2. firm-window panel and descriptive gradient
fw = cnm.build_firm_window_panel(notices, firms)
cnm.compliance_gradient(fw)
cnm.decompose_2x2(fw)
 
# 3. Nasdaq layer
news = cnm.classify_nasdaq(pd.read_csv("all_nasdaq_news_final3.csv"))
cnm.check_label_migration(news)
pa = cnm.build_nasdaq_panel(news, listed_firms)
 
# 4. tax register diagnostics
cnm.diagnose_vero_match(vero, registry, panel_ids)
cnm.crosscheck_missing_against_filing(vero, notices, panel_ids)
 
# 5. estimation
cnm.estimate_event_study(fw)
cnm.estimate_nasdaq(pa)
cnm.segment_means(pa)
```
 
---
 
## Notes on scope
 
This folder is a replication of the data pipeline, not the production code. The
production analysis runs in R (`fixest`, `data.table`) with Stata 17 MP used
for cross-checks. Where the two diverge, the R scripts in `01_data_collection/`
through `03_sample_analysis/` are authoritative.
 
Two functions are included but have not yet been used in a production run, and
are marked as such in their docstrings: `restrict_control_group()` implements a
sample restriction specified in the research design but not yet applied to the
estimation panel, and the cooperative arm of `fetch_full_history()` has been
run for data collection but not for a completed replacement test.
 


