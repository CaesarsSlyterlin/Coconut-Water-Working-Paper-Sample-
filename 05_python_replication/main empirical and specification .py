#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Coconut Water Working Paper - Python modules added June-August 2026

This file contains ONLY the modules that did not exist in the original
Python replication pipeline (05_python_replication/prh_pipeline.py). It is
kept separate so the original six-step pipeline stays as it was and the
additions can be reviewed on their own.

What is here, and why each was added:

  Part A  Notice type reference table
          Retrieved from the registry's own /description endpoint rather than
          inferred from the data.

  Part B  Full-history notice retrieval
          Replaces event-window retrieval. Computing compliance from
          event-window extracts understated listed-firm compliance in the
          earliest window as 3.1 per cent against a true 97.3 per cent.

  Part C  Extensive-margin outcomes and entry/exit truncation
          The paper's outcome is binary (whether a firm files), not a count.

  Part D  Firm-window panel
          Twelve-month windows, invariant to the 7-day-to-15-month forwarding
          delay between the tax authority and the registry.

  Part E  Nasdaq category classification
          27 exchange labels collapsed into six buckets, with the buyback
          relabelling artefact handled explicitly.

  Part F  Tax register cross-match diagnostics
          Match rate broken down by registration cohort and cross-checked
          against filing behaviour, to establish that the shortfall is
          mechanical rather than a selection on profitability.

  Part G  Estimation
          Baseline, placebo, event study and the segmented capital market
          specification.

Dependencies beyond the original pipeline: pyfixest.

Author: [Author Name]
Last updated: August 2026
"""

import time
import json
from pathlib import Path

import requests
import numpy as np
import pandas as pd

PRH_BASE = "https://avoindata.prh.fi/opendata-registerednotices-api/v3"

EVENT_START = pd.Timestamp("2023-03-01")
TREATMENT_DATE = pd.Timestamp("2024-09-01")
EVENT_END = pd.Timestamp("2026-02-28")

SESSION = requests.Session()
SESSION.headers.update({"Accept": "application/json"})


def safe(value):
    """Guard for the irregular nested structures the PRH API returns.

    Carried over from the original pipeline; repeated here so this file runs
    standalone.
    """
    if value is None:
        return None
    if isinstance(value, (list, tuple)):
        if len(value) == 0:
            return None
        value = value[0]
    if isinstance(value, float) and pd.isna(value):
        return None
    text = str(value).strip()
    return text if text else None


# =============================================================================
# PART A  Notice type reference
# =============================================================================
# The thirteen registration types. Eleven come from the registry's published
# code table, retrieved from /description?code=NRT rather than inferred from
# the data. Two more (END, TASE) appear in the data but not in the published
# table and are historical.
#
# The grouping below drives every outcome variable in the paper: TA is the
# mandatory disclosure outcome, the distress group is used as a placebo-like
# check (it shows no treatment effect, which is informative - the reform
# changed how firms filed, not the rate at which they entered formal distress
# procedures).

NOTICE_TYPES = pd.DataFrame([
    ("TA",   "Financial statements",            "mandatory"),
    ("M",    "Amendment notification",          "routine"),
    ("U",    "Start-up notification",           "routine"),
    ("OI",   "Rectification",                   "routine"),
    ("JH",   "Public summons to creditors",     "distress"),
    ("FUU",  "Merger application",              "distress"),
    ("DIF",  "Demerger application",            "distress"),
    ("END",  "Termination (historical code)",   "distress"),
    ("H",    "Application",                     "other"),
    ("T",    "Notice",                          "other"),
    ("VA",   "Supervision",                     "other"),
    ("KM",   "Municipal change notification",   "other"),
    ("TASE", "Balance sheet (historical code)", "other"),
], columns=["code", "label", "group"])

TA_CODES = ["TA", "TASE"]
DISTRESS_CODES = ["JH", "FUU", "DIF", "END"]


def fetch_notice_types(lang="EN"):
    """Pull the live code table from the registry."""
    resp = SESSION.get(f"{PRH_BASE}/description",
                       params={"code": "NRT", "lang": lang}, timeout=30)
    resp.raise_for_status()
    return resp.json()


# =============================================================================
# PART B  Full-history notice retrieval
# =============================================================================

def fetch_full_history(business_ids, out_dir, progress_file,
                       batch_size=1000, sleep_sec=0.5, max_retry=3):
    """Retrieve each firm's COMPLETE notice history.

    This replaces the event-window retrieval in the original pipeline. The
    change is not cosmetic. Compliance rates computed from event-window
    extracts understate listed-firm compliance in the earliest comparison
    window as 3.1 per cent, against a true value of 97.3 per cent computed
    from full histories, because a firm's earlier filings simply fall outside
    the extract. Every descriptive rate in the paper depends on this.

    The registry's own boundary is 7 November 2014; responses run to the
    current date, so out-of-window records are filtered downstream rather than
    at retrieval.

    Two design points that matter at scale:

    1. done_ids is tracked independently of the output, so firms that
       legitimately have zero notices are not re-fetched on every restart.
       94 of 169,301 control firms have no notice history at all, and the
       publicNotices key is ABSENT rather than an empty list for those firms.
    2. Results are flushed to disk every batch_size firms and dropped from
       memory. Holding 3.5 million notice records in one list exhausts RAM.

    Timings from the production runs: 196 listed firms and 22,572 records in
    3.8 minutes; 6,708 cooperatives and 88,473 records in 122 minutes; 169,301
    limited companies and 3,512,187 records in 29.2 hours.
    """
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    done_ids = set()
    if Path(progress_file).exists():
        done_ids = set(json.loads(Path(progress_file).read_text()))

    todo = [b for b in business_ids if b not in done_ids]
    print(f"total {len(business_ids):,} | done {len(done_ids):,} | "
          f"remaining {len(todo):,}")

    buffer, errors = [], []
    batch_no = len(list(out_dir.glob("*.csv")))
    t0 = time.time()

    for i, bid in enumerate(todo, start=1):
        ok = False
        for attempt in range(1, max_retry + 1):
            try:
                resp = SESSION.get(f"{PRH_BASE}/{bid}", timeout=60)
                if resp.status_code == 200:
                    for n in (resp.json().get("publicNotices") or []):
                        buffer.append({
                            "business_id": bid,
                            "registrationDate": safe(n.get("registrationDate")),
                            "typeOfRegistration": safe(n.get("typeOfRegistration")),
                            "recordNumber": safe(n.get("recordNumber")),
                            "entryCodes": ";".join(n.get("entryCodes") or []),
                        })
                    ok = True
                    break
            except requests.RequestException:
                pass
            time.sleep(2 ** attempt)

        if not ok:
            errors.append(bid)
        done_ids.add(bid)

        if i % batch_size == 0 or i == len(todo):
            batch_no += 1
            if buffer:
                pd.DataFrame(buffer).to_csv(
                    out_dir / f"batch_{batch_no:04d}.csv", index=False)
                buffer = []
            Path(progress_file).write_text(json.dumps(sorted(done_ids)))
            rate = i / max(time.time() - t0, 1e-9)
            print(f"  [{time.strftime('%H:%M:%S')}] {i:,}/{len(todo):,} "
                  f"({rate:.1f}/s), {len(errors)} errors")

        time.sleep(sleep_sec)

    if errors:
        (out_dir / "failed_ids.txt").write_text("\n".join(errors))
        print(f"failed ids written for a patch run: {len(errors)}")
    return errors


def load_notice_batches(out_dir):
    """Concatenate the batch files into one frame with parsed dates."""
    files = sorted(Path(out_dir).glob("batch_*.csv"))
    df = pd.concat([pd.read_csv(f, dtype=str) for f in files],
                   ignore_index=True)
    df["registrationDate"] = pd.to_datetime(df["registrationDate"],
                                            errors="coerce")
    print(f"{len(df):,} notices, {df['business_id'].nunique():,} firms, "
          f"{df['registrationDate'].min().date()} to "
          f"{df['registrationDate'].max().date()}")
    return df


# =============================================================================
# PART C  Extensive-margin outcomes and entry/exit truncation
# =============================================================================

def add_extensive_margin(panel):
    """Add binary outcomes alongside the existing counts.

    The paper's outcome is whether a firm files, not how often. Three reasons.

    The timing of a count is unreliable: statements submitted with a tax return
    reach the registry within 7 days, but those submitted through the tax
    authority's dividend function can take up to 15 months.

    A count conflates disclosure with administrative correction: roughly four
    in ten firm-years contain more than one filing, and the registry metadata
    carry no fiscal-year identifier (entryCodes takes only the values TASE and
    blank; recordNumber is a sequential reference), so a notice cannot be
    assigned to the year it reports on.

    The choice is testable: on the same panel, same cut-point and same fixed
    effects, the binary TA outcome passes the placebo test (-0.0095, n.s.)
    while the count version under seasonality controls fails.
    """
    panel = panel.copy()
    panel["d_any"] = (panel["y_total"] > 0).astype(int)
    panel["d_ta"] = (panel["y_ta"] > 0).astype(int)
    panel["d_m"] = (panel["y_m"] > 0).astype(int)
    return panel


def apply_entry_exit_truncation(panel, events):
    """Drop firm-months outside a firm's period of existence.

    Firms that leave the register are retained through the month of exit;
    firms that enter are retained from the month of entry. Without this,
    structural zeros are read as non-compliance and both the descriptive rates
    and the fixed effects are contaminated.

    events: columns business_id, event_type in {'exit','entry'}, event_month
            as a monthly Period.

    Sensitivity: on the production panel this removed 465 rows, and dropping
    the single largest affected firm entirely changed the estimated
    coefficients by less than 0.0001, so the firm was retained.
    """
    panel = panel.merge(events, on="business_id", how="left")
    keep = (panel["event_type"].isna() |
            ((panel["event_type"] == "exit") &
             (panel["month"] <= panel["event_month"])) |
            ((panel["event_type"] == "entry") &
             (panel["month"] >= panel["event_month"])))
    dropped = (~keep).sum()
    print(f"truncation removed {dropped:,} firm-months")
    return panel[keep].drop(columns=["event_type", "event_month"])


def restrict_control_group(firms, registry, cutoff="2023-03-01"):
    """Keep only control firms registered before the sample period begins.

    Firms established after the onset of the reform may represent strategic
    entry or reorganisation in response to the policy, which would contaminate
    the counterfactual.
    """
    reg = registry.rename(columns={"businessId.value": "business_id"})
    reg["registrationDate"] = pd.to_datetime(reg["registrationDate"],
                                             errors="coerce")
    eligible = set(reg.loc[reg["registrationDate"] <
                           pd.Timestamp(cutoff), "business_id"])
    out = firms[firms["business_id"].isin(eligible) |
                (firms["firm_type"] != "OY")]
    print(f"control group restricted: {len(firms):,} -> {len(out):,} firms")
    return out


# =============================================================================
# PART D  Firm-window panel
# =============================================================================

WINDOWS = {
    "t-3": ("2021-09-01", "2022-08-31"),
    "t-2": ("2022-09-01", "2023-08-31"),
    "t-1": ("2023-09-01", "2024-08-31"),
    "t+1": ("2024-09-01", "2025-08-31"),
}

FREE_FILING_DAYS = 243   # eight months from fiscal year end


def build_firm_window_panel(notices, firms):
    """Aggregate to four twelve-month windows anchored on the treatment date.

    Within a window the question is only whether the firm filed at all, which
    is invariant to a forwarding delay of up to a year and to repeated
    submissions in the same period. That is the point of this panel.

    A note on what the outcome is NOT. An earlier definition treated a filing
    in months 9-12 of a window as a late filing for the previous fiscal year.
    That was wrong: of the 115 such records in one window, 81 of the 84 firms
    involved (96.4 per cent) had already filed earlier in the same calendar
    year, so those are second filings - amendments and supplements - not late
    ones. The definition was discarded.

    A second trap worth naming: conditioning the sample on firms that filed in
    t-1 produces a large positive estimate (+0.0799), but that is mean
    reversion, not an effect. Selecting on a realised value of the dependent
    variable guarantees it.
    """
    ta = notices[notices["typeOfRegistration"].isin(TA_CODES)]
    firm_ids = firms["business_id"].unique()
    frames = []

    for win, (lo, hi) in WINDOWS.items():
        lo, hi = pd.Timestamp(lo), pd.Timestamp(hi)
        sel = ta[(ta["registrationDate"] >= lo) &
                 (ta["registrationDate"] <= hi)]

        agg = (sel.groupby("business_id")["registrationDate"]
               .agg(d_ta=lambda s: 1,
                    d_ontime=lambda s: int(
                        (s <= lo + pd.Timedelta(days=FREE_FILING_DAYS)).any()))
               .reset_index())

        base = pd.DataFrame({"business_id": firm_ids, "win": win})
        frames.append(base.merge(agg, on="business_id", how="left"))

    out = pd.concat(frames, ignore_index=True)
    out[["d_ta", "d_ontime"]] = out[["d_ta", "d_ontime"]].fillna(0).astype(int)

    firm_type = firms.set_index("business_id")["firm_type"]
    out["firm_type"] = out["business_id"].map(firm_type)
    out["treat"] = out["firm_type"].isin(["OYJ", "OY_listed"]).astype(int)
    out["post"] = (out["win"] == "t+1").astype(int)
    out["did"] = out["treat"] * out["post"]
    return out


def compliance_gradient(fw):
    """Filing compliance by group and window - the paper's descriptive table.

    Production result: the ordering OYJ > OY > OSK holds in every window,
    matching the ordering of statutory obligations.
    """
    tab = (fw.groupby(["firm_type", "win"])
           .agg(n=("business_id", "nunique"), rate=("d_ta", "mean"))
           .reset_index()
           .pivot(index="firm_type", columns="win", values=["n", "rate"]))
    print(tab.round(4).to_string())
    return tab


def decompose_2x2(fw):
    """Hand-calculated DiD on the balanced two-by-two.

    Worth doing: because the specification is saturated, the regression
    coefficient must reproduce the raw cell means exactly, and the
    decomposition shows where the estimate comes from. On the production data,
    control-group compliance rises 2.0 points while the treatment group falls
    2.3 points, so slightly more than half of the estimate is an improvement in
    the control group rather than a deterioration in the treatment group.
    """
    sub = fw[fw["win"].isin(["t-1", "t+1"])]
    counts = sub.groupby("business_id")["win"].nunique()
    balanced = sub[sub["business_id"].isin(counts[counts == 2].index)]

    cells = (balanced.groupby(["treat", "win"])["d_ta"].mean().unstack())
    diff = cells["t+1"] - cells["t-1"]
    did = diff.loc[1] - diff.loc[0]

    print(cells.round(4).to_string())
    print(f"change: control {diff.loc[0]:+.4f}  treated {diff.loc[1]:+.4f}")
    print(f"DiD = {did:.4f}")
    return did


# =============================================================================
# PART E  Nasdaq category classification
# =============================================================================

MECH_CATS = ["Managers' Transactions",
             "Changes in company's own shares",
             "Total number of voting rights and capital",
             "Net Asset Value"]
DISC_CATS = ["Company Announcement", "Inside information", "Investor News"]
PERI_CATS = ["Annual Financial Report", "Annual report",
             "Financial Statement Release", "Half Year financial report",
             "Interim report (Q1 and Q3)", "Interim information"]
SPEC_CATS = ["Tender offer", "Prospectus"]
GOV_PATTERN = r"nomination|remuneration|board|general meeting|articles"
BUYBACK_PATTERN = r"own shares|buy-?back|repurchase"


def classify_nasdaq(df):
    """Collapse 27 exchange category labels into six buckets.

    One measurement problem has to be handled explicitly. Between the pre- and
    post-periods, share buyback announcements migrated out of the dedicated
    'Changes in company's own shares' category into the residual 'Other
    information' category: buyback content in the residual category rose from
    83 to 602 releases (+725 per cent) while the count of the underlying
    transactions barely moved (4,213 to 4,275). The same behaviour was
    relabelled.

    The consequence for the research design: any outcome that separates
    voluntary from ad hoc disclosure inherits this artefact, so the
    discretionary bucket is kept combined. The split version is not reported.

    A related caution: the 'market' field in the raw feed is unreliable and
    must not be used for filtering. An earlier filtered file dropped 3,570
    releases before this was caught, and was discarded.
    """
    df = df.copy()
    head = df["headline"].fillna("")
    is_buyback = head.str.contains(BUYBACK_PATTERN, case=False, regex=True)
    is_gov = head.str.contains(GOV_PATTERN, case=False, regex=True)
    cat = df["cnsCategory"]

    df["bucket3"] = np.select(
        [
            cat.isin(MECH_CATS) | ((cat == "Other information") & is_buyback),
            cat.isin(PERI_CATS),
            cat == "Financial Calendar",
            cat.isin(SPEC_CATS),
            is_gov,
            cat.isin(DISC_CATS) | (cat == "Other information"),
        ],
        ["mech", "periodic", "fincal", "special", "governance",
         "discretionary"],
        default="other",
    )
    print(df["bucket3"].value_counts().to_string())
    return df


def check_label_migration(df):
    """Quantify category share shifts between pre and post.

    Run this before choosing outcome definitions on any exchange feed. A large
    share shift in a category whose underlying transaction count is stable is
    a relabelling, not a behavioural change.
    """
    df = df.copy()
    df["period"] = np.where(
        pd.to_datetime(df["releaseTime"]) < TREATMENT_DATE, "pre", "post")

    tab = (df.pivot_table(index="cnsCategory", columns="period",
                          values="disclosureId", aggfunc="count")
           .fillna(0))
    tab["pre_share"] = 100 * tab["pre"] / tab["pre"].sum()
    tab["post_share"] = 100 * tab["post"] / tab["post"].sum()
    tab["delta_share"] = tab["post_share"] - tab["pre_share"]

    out = tab.reindex(tab["delta_share"].abs().sort_values(
        ascending=False).index)
    print(out.round(2).head(12).to_string())
    return out


def build_nasdaq_panel(news, firms):
    """Firm x month panel of release counts by bucket, with post segments.

    The post period is split because a single post indicator averages an
    initial null against a later decline and reports nothing: discretionary
    disclosure does not fall for seven months, then declines and stabilises
    roughly 30 per cent below the pre-treatment mean.
    """
    news = news.copy()
    news["month"] = pd.to_datetime(news["releaseTime"]).dt.to_period("M")
    months = pd.period_range(EVENT_START, EVENT_END, freq="M")

    agg = (news[news["month"].isin(months)]
           .pivot_table(index=["business_id", "month"], columns="bucket3",
                        values="disclosureId", aggfunc="count")
           .reset_index())

    skeleton = pd.MultiIndex.from_product(
        [firms["business_id"].unique(), months],
        names=["business_id", "month"]).to_frame(index=False)

    panel = skeleton.merge(agg, on=["business_id", "month"], how="left")
    value_cols = [c for c in panel.columns if c not in ("business_id", "month")]
    panel[value_cols] = panel[value_cols].fillna(0).astype(int)

    treat_period = TREATMENT_DATE.to_period("M")
    panel["post"] = (panel["month"] >= treat_period).astype(int)
    panel["event_time"] = panel["month"].apply(
        lambda p: (p.year * 12 + p.month) -
                  (treat_period.year * 12 + treat_period.month))
    panel["seg"] = np.select(
        [panel["post"] == 0,
         panel["event_time"] <= 6,
         panel["event_time"] <= 10],
        ["pre", "post_early", "post_mid"],
        default="post_late",
    )
    return panel


# =============================================================================
# PART F  Tax register cross-match diagnostics
# =============================================================================

def diagnose_vero_match(vero, registry, panel_ids):
    """Match on Business ID and establish whether the shortfall is benign.

    A match rate on its own says nothing. Coverage is broken down by
    registration cohort and cross-checked against filing behaviour.

    Production result: 145,746 of 169,294 control firms match (86.1 per cent).
    Coverage by cohort runs 98.5 / 99.3 / 99.7 / 99.2 per cent for firms
    registered up to 2010, 2011-15, 2016-20 and 2021-23, and 18.4 per cent for
    firms registered from 2024. Firms outside the tax data have a filing rate
    of 34.4 per cent against 97.5 per cent for those inside. The shortfall is
    mechanical - recent registrations have not yet entered the FY2024 tax file
    - and not a selection on profitability.

    This also corrected an earlier record: a 61.2 per cent match rate from an
    intermediate file had been carried forward, when the raw source in fact
    covers 86.1 per cent with no missing values and no duplicates.
    """
    vero_ids = set(vero["business_id"].unique())
    panel_ids = set(panel_ids)
    hit = panel_ids & vero_ids

    print(f"panel     {len(panel_ids):,} firms")
    print(f"tax data  {len(vero_ids):,} firms")
    print(f"matched   {len(hit):,} ({100 * len(hit) / len(panel_ids):.1f}%)")
    print(f"in tax data but not in panel: {len(vero_ids - panel_ids)}")

    reg = registry.rename(columns={"businessId.value": "business_id"}).copy()
    reg["reg_year"] = pd.to_datetime(reg["registrationDate"],
                                     errors="coerce").dt.year
    reg["in_vero"] = reg["business_id"].isin(vero_ids).astype(int)
    reg["cohort"] = pd.cut(reg["reg_year"],
                           [-np.inf, 2010, 2015, 2020, 2023, np.inf],
                           labels=["<=2010", "2011-15", "2016-20",
                                   "2021-23", "2024+"])

    print("\ncoverage by registration cohort:")
    print(reg.groupby("cohort", observed=True)["in_vero"]
          .agg(n="size", covered="sum", rate="mean").round(3).to_string())

    print("\nzero rates in the tax variables:")
    for col in ["taxable_income", "total_tax", "tax_refund", "back_tax"]:
        if col in vero.columns:
            print(f"  {col:<16} NA {100 * vero[col].isna().mean():5.2f}%   "
                  f"zero {100 * (vero[col] == 0).mean():5.2f}%")
    return hit


def crosscheck_missing_against_filing(vero, notices, panel_ids):
    """Do firms absent from the tax data behave differently in the registry?

    If the tax data were selecting on profitability, firms outside it would
    still be filing with the registry at a normal rate. They are not: 34.4 per
    cent against 97.5 per cent. That is the pattern of firms too new to have
    entered the tax file, which is the benign explanation.
    """
    vero_ids = set(vero["business_id"].unique())
    filers = set(notices.loc[notices["typeOfRegistration"].isin(TA_CODES),
                             "business_id"])

    inside = [b for b in panel_ids if b in vero_ids]
    outside = [b for b in panel_ids if b not in vero_ids]

    r_in = np.mean([b in filers for b in inside]) if inside else float("nan")
    r_out = np.mean([b in filers for b in outside]) if outside else float("nan")

    print(f"in tax data      n={len(inside):,}  filing rate {r_in:.3f}")
    print(f"not in tax data  n={len(outside):,}  filing rate {r_out:.3f}")
    return r_in, r_out


# =============================================================================
# PART G  Estimation
# =============================================================================
# pyfixest is used rather than statsmodels or linearmodels. On 6.1 million rows
# with 169,490 firm fixed effects a dense dummy design matrix is not feasible;
# the absorbing estimator handles the same specification in seconds. For
# reference, Stata's encode() fails outright on this panel because its
# value-label limit is 65,536 against 169,490 firms, and reghdfe exhausts
# memory on the production machine.

def estimate_baseline(panel):
    """Two-way fixed effects, binary and count outcomes side by side.

    The Poisson semi-elasticity is three to four times the proportional effect
    implied by the linear model. That is the sensitivity Roth and Sant'Anna
    (2023) describe: with a skewed count outcome and large baseline
    differences between groups, parallel trends cannot hold in levels and in
    logs simultaneously. The extensive-margin specification sidesteps it
    because the outcome is bounded.
    """
    import pyfixest as pf
    vcov = {"CRV1": "business_id"}

    models = {
        "d_any": pf.feols("d_any ~ did | business_id + month", panel, vcov=vcov),
        "d_ta": pf.feols("d_ta ~ did | business_id + month", panel, vcov=vcov),
        "d_m": pf.feols("d_m ~ did | business_id + month", panel, vcov=vcov),
        "count_ols": pf.feols("y_ta ~ did | business_id + month", panel, vcov=vcov),
        "count_pois": pf.fepois("y_ta ~ did | business_id + month", panel, vcov=vcov),
    }
    pf.etable(list(models.values()))
    return models


def estimate_placebo(panel, cut="2023-12"):
    """Pseudo-treatment date inside the pre-treatment window.

    No post-reform observation enters, so a well-specified design should
    return zero.

    A trap worth naming: 2024 cannot be used as a pseudo-treatment year,
    because the reform splits it. It looks like a reasonable choice and is not.

    Result: the binary TA outcome passes (-0.0095, n.s.); the broader
    any-notice outcome fails (-0.0422, p < 0.01), which is why it is not the
    primary outcome despite producing a similar treatment-period estimate.
    """
    import pyfixest as pf
    vcov = {"CRV1": "business_id"}

    cut_p = pd.Period(cut, freq="M")
    pre = panel[panel["month"] < TREATMENT_DATE.to_period("M")].copy()
    pre["fake_post"] = (pre["month"] >= cut_p).astype(int)
    pre["fake_did"] = pre["treat"] * pre["fake_post"]

    models = {
        "d_any": pf.feols("d_any ~ fake_did | business_id + month", pre, vcov=vcov),
        "d_ta": pf.feols("d_ta ~ fake_did | business_id + month", pre, vcov=vcov),
        "count": pf.feols("y_ta ~ fake_did | business_id + month", pre, vcov=vcov),
    }
    pf.etable(list(models.values()))
    return models


def estimate_event_study(fw):
    """Event study on the firm-window panel, reference window t-1.

    The monthly event study is NOT usable for this purpose. At any sub-annual
    frequency the pre-treatment coefficients oscillate with the filing
    calendar, and interacting treatment with month-of-year alongside
    event-time indicators is collinear by construction: within a
    single-cohort design month-of-year is fully determined by event time, so
    interaction terms are dropped whatever package is used. That is a property
    of the data structure, not of the estimator, and switching packages does
    not help.

    Reading the output: the joint test on the two pre-treatment terms is
    marginal (p = 0.069 and 0.044), but the deviations are not monotonic -
    negative at t-3, positive at t-2 - and the reference window coincides with
    the highest treatment-group compliance rate in the sample (99.4 per cent,
    one firm of 180 not filing), so every other window is measured against an
    extreme value. A single firm moves the rate by 0.55 points against a
    treatment estimate of 4.3 points.
    """
    import pyfixest as pf

    fw = fw.copy()
    fw["win"] = pd.Categorical(fw["win"],
                               categories=["t-1", "t-3", "t-2", "t+1"])
    vcov = {"CRV1": "business_id"}

    models = {
        "d_ta": pf.feols("d_ta ~ i(win, treat, ref='t-1') | business_id + win",
                         fw, vcov=vcov),
        "d_ontime": pf.feols(
            "d_ontime ~ i(win, treat, ref='t-1') | business_id + win",
            fw, vcov=vcov),
    }
    pf.etable(list(models.values()))
    return models


def estimate_nasdaq(panel):
    """Capital market layer: firm fixed effects only, single and segmented.

    There is no control group here - unlisted firms do not file with the
    exchange - so these are before-and-after comparisons, not
    difference-in-differences. The pre-period coefficients are descriptive
    dynamics and must not be reported as a parallel-trends test: with no
    comparison group they measure each category's own seasonality against the
    reference month. The ordering of the test statistics (periodic most
    calendar-driven, mechanical least) is what confirms this reading.
    """
    import pyfixest as pf
    vcov = {"CRV1": "business_id"}
    outcomes = ["discretionary", "periodic", "mech"]

    single = [pf.feols(f"{y} ~ post | business_id", panel, vcov=vcov)
              for y in outcomes]
    seg = [pf.feols(f"{y} ~ i(seg, ref='pre') | business_id", panel, vcov=vcov)
           for y in outcomes]

    pf.etable(single + seg)
    return {"post": single, "seg": seg}


def segment_means(panel):
    """Segment means alongside the coefficients.

    Reported because the coefficients alone hide the level: discretionary
    disclosure runs 2.09 releases per firm-month before the reform, rises to
    2.40 in the first seven months, then settles at 1.47.
    """
    tab = panel.groupby("seg")[["discretionary", "periodic", "mech"]].mean()
    order = ["pre", "post_early", "post_mid", "post_late"]
    tab = tab.reindex([s for s in order if s in tab.index])
    print(tab.round(3).to_string())
    return tab
