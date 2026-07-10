"""
PRH Data Pipeline - Python Replication
======================================
Coconut Water Working Paper: VAT Reform, Financial Disclosure and Fiscal Stress

Python replication of the R data pipeline in 01_data_collection/ and
02_data_cleaning/ (see repository root README). The original pipeline was
built and run in R (httr / jsonlite / tidyverse); this script reproduces
the same logic with requests / pandas, step by step:

  Step 1  Fetch company registrations from the PRH YTJ open data API
          (paginated requests; the API caps each response at 100 rows
          and pages are 1-based -- verified empirically, see
          fetch_companies)
  Step 2  Parse the nested JSON records (Finnish/English company names,
          street, post code, city and municipality code inside the
          postOffices sub-object) with safe missing-value protection
  Step 3  Fetch registered notices per Business ID with checkpointing,
          polite rate limiting and retry logic
  Step 4  Merge notices with registrations and filter to the event window
          (1 March 2023 - 28 February 2026; treatment: 1 September 2024)
  Step 5  Aggregate to a firm x month panel of financial statement (TA)
          filings with DiD indicator variables (treat, post, treat_post)
  Step 6  (Optional) Municipality-level choropleth map with geopandas

Data sources (all free, public, CC BY 4.0):
  - PRH YTJ companies API:
      https://avoindata.prh.fi/opendata-ytj-api/v3/companies
  - PRH registered notices API:
      https://avoindata.prh.fi/opendata-registerednotices-api/v3
  - Municipality boundaries (for Step 6): Statistics Finland open
      geodata (geo.stat.fi); download the municipality GeoJSON manually
      and pass its path to plot_municipality_map().

DEMO_MODE (default True) keeps every network step small enough to run
in a few minutes on Google Colab. The full production run in R covered
169,301 OY companies and took 29.2 hours with the same checkpoint
logic; this script is a faithful, scaled-down replication, not a toy.

Notes for readers coming from the R pipeline:
  - safe() below mirrors the R helper of the same name (NULL / length-0
    / all-NA protection when indexing nested API structures).
  - Comments marked "R equivalent:" map each pandas operation back to
    the dplyr / base-R line it replicates.
"""

import json
import time
from pathlib import Path

import pandas as pd
import requests

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

YTJ_BASE = "https://avoindata.prh.fi/opendata-ytj-api/v3/companies"
NOTICE_BASE = "https://avoindata.prh.fi/opendata-registerednotices-api/v3"

EVENT_START = "2023-03-01"   # event window: 18 months pre-treatment
EVENT_END = "2026-02-28"     # 18 months post-treatment
TREATMENT_DATE = "2024-09-01"  # VAT standard rate 24% -> 25.5%

OUTPUT_DIR = Path("output")
CHECKPOINT_CSV = OUTPUT_DIR / "notices_checkpoint.csv"
DONE_IDS_TXT = OUTPUT_DIR / "notices_done_ids.txt"

DEMO_MODE = True
# Demo scope: full OYJ register (428 firms at verification time,
# 2026-07-10; the register fluctuates daily) but only a small notice
# sample. The full production run covered 169,301 OY firms.
DEMO_MAX_NOTICE_FIRMS = 25

REQUEST_SLEEP = 0.5   # polite delay between API calls (seconds)
MAX_RETRY = 3         # retries per request
RETRY_BACKOFF = 60    # wait after a failed request (the PRH API
                      # intermittently returns 504 under load; observed
                      # repeatedly in the R production run)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def safe(value):
    """Return the first element of a possibly missing/empty value as str.

    Mirrors the R helper:
        safe <- function(x) {
          if (is.null(x) || length(x) == 0 || all(is.na(x))) NA_character_
          else as.character(x[1])
        }
    The PRH API returns irregular nested structures: fields may be
    absent, None, empty lists or empty strings depending on the company.
    Every nested access in Step 2 goes through this guard.
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


def get_with_retry(url, params=None):
    """GET with retry/backoff. Returns parsed JSON or None."""
    for attempt in range(1, MAX_RETRY + 1):
        try:
            resp = requests.get(url, params=params, timeout=60)
            if resp.status_code == 200:
                return resp.json()
            if resp.status_code == 429:
                # Documented rate limit in the official API schema:
                # back off for longer before retrying.
                print(f"  HTTP 429 rate limited, backing off "
                      f"{RETRY_BACKOFF}s (attempt {attempt}/{MAX_RETRY})")
            else:
                print(f"  HTTP {resp.status_code} "
                      f"(attempt {attempt}/{MAX_RETRY})")
        except requests.RequestException as exc:
            print(f"  network error: {exc} (attempt {attempt}/{MAX_RETRY})")
        if attempt < MAX_RETRY:
            time.sleep(RETRY_BACKOFF)
    return None


# ---------------------------------------------------------------------------
# Step 1 - Fetch company registrations (YTJ API)
# ---------------------------------------------------------------------------

def fetch_companies(company_form, location=None, max_pages=None):
    """Fetch company registration records with page-based pagination.

    The API caps every response at 100 rows, and pagination is
    1-BASED. Verified empirically (2026-07-10): page=0 and page=1
    return identical content -- the API silently treats 0 as 1.
    Iterating from page 0 therefore double-fetches the first page
    and, worse, trips the `len(records) >= total` stop condition one
    page early, silently dropping the final partial page (28 of 428
    OYJ firms in the verification run). The original R pipeline
    batched requests by city (location parameter) and never paged, so
    it never hit this; `location` remains available to reproduce that
    behaviour or to narrow a query.
    """
    records = []
    page = 1               # 1-based pagination (see docstring)
    prev_first_id = None
    pages_fetched = 0
    while True:
        params = {"companyForm": company_form, "page": page}
        if location:
            params["location"] = location
        data = get_with_retry(YTJ_BASE, params=params)
        time.sleep(REQUEST_SLEEP)
        if data is None:
            print(f"  page {page}: request failed, stopping")
            break
        batch = data.get("companies", [])
        total = data.get("totalResults", 0)
        if not batch:
            break
        # Defensive check: if the API ever changes its pagination
        # semantics again, a repeated page would silently duplicate
        # rows. Detect it by the first Business ID and stop instead.
        first_id = safe((batch[0].get("businessId") or {}).get("value"))
        if first_id is not None and first_id == prev_first_id:
            print(f"  page {page}: identical to previous page, "
                  f"stopping (pagination semantics may have changed)")
            break
        prev_first_id = first_id
        records.extend(batch)
        pages_fetched += 1
        print(f"  page {page}: {len(batch)} rows "
              f"({len(records)}/{total} fetched)")
        if len(records) >= total:
            break
        if max_pages is not None and pages_fetched >= max_pages:
            print(f"  stopping at max_pages={max_pages} (demo limit)")
            break
        page += 1
    return records


# ---------------------------------------------------------------------------
# Step 2 - Parse nested JSON (replicates parse_oyj in R)
# ---------------------------------------------------------------------------

def parse_company(rec):
    """Flatten one nested company record into a flat dict.

    Field logic replicated from the R function parse_oyj():
      - business_id:   businessId.value (nested dict in the raw JSON)
      - company_name:  names[] entry with type "1" (Finnish) and no
                       endDate (i.e. the current name); fallback: first
                       name on record
      - company_name_en: names[] entry with type "2" (English), current
      - street / post_code: addresses[] entry with type 1 (visiting
                       address); fallback: first address on record
      - city / municipality_code: nested inside addresses[].postOffices,
                       preferring languageCode "1" (Finnish)
    Every access is guarded because the API returns irregular
    structures (the R version crashed on 'replacement has length zero'
    before these guards were added).
    """
    business_id = safe((rec.get("businessId") or {}).get("value"))

    # --- company names -----------------------------------------------------
    names = rec.get("names") or []
    company_name = None
    company_name_en = None
    current_fi = [n for n in names
                  if str(n.get("type")) == "1" and not n.get("endDate")]
    current_en = [n for n in names
                  if str(n.get("type")) == "2" and not n.get("endDate")]
    if current_fi:
        company_name = safe(current_fi[0].get("name"))
    elif names:
        company_name = safe(names[0].get("name"))
    if current_en:
        company_name_en = safe(current_en[0].get("name"))

    # --- address ------------------------------------------------------------
    # NOTE: street / city / municipality_code may be missing for some
    # firms in the raw data. Verified against the raw JSON in the
    # 2026-07-10 run: roughly 30% of registered OYJ firms carry an
    # EMPTY `addresses` list in the register itself (mostly old or
    # dormant companies), so the missingness is a property of the
    # source data, not a parsing failure. The guards below keep the
    # parser from crashing on it.
    street = post_code = city = municipality_code = None
    addresses = rec.get("addresses") or []
    if addresses:
        visiting = [a for a in addresses if str(a.get("type")) == "1"]
        addr = visiting[0] if visiting else addresses[0]
        street = safe(addr.get("street"))
        post_code = safe(addr.get("postCode"))
        post_offices = addr.get("postOffices") or []
        if post_offices:
            fi_po = [p for p in post_offices
                     if str(p.get("languageCode")) == "1"]
            po = fi_po[0] if fi_po else post_offices[0]
            city = safe(po.get("city"))
            municipality_code = safe(po.get("municipalityCode"))

    main_line = rec.get("mainBusinessLine") or {}

    # Company situation: SANE (restructuring), SELTILA (liquidation),
    # KONK (bankruptcy) - distress markers used in the working paper's
    # Layer 2 analysis (cf. status codes appendix in the repo README).
    situations = rec.get("companySituations") or []
    active_situations = [str(s.get("type")) for s in situations
                         if s.get("type") and not s.get("endDate")]
    company_situation = ";".join(active_situations) or None

    return {
        "business_id": business_id,
        "company_name": company_name,
        "company_name_en": company_name_en,
        "status": safe(rec.get("status")),
        "registration_date": safe(rec.get("registrationDate")),
        "street": street,
        "post_code": post_code,
        "city": city,
        "municipality_code": municipality_code,
        "business_line": safe(main_line.get("type")),
        "company_situation": company_situation,
    }


def parse_companies(records, company_form):
    """Parse a list of raw records into a clean DataFrame."""
    rows = [parse_company(r) for r in records]
    df = pd.DataFrame(rows)
    df["firm_type"] = company_form
    df = df.dropna(subset=["business_id"]).drop_duplicates("business_id")
    # R equivalent: filter(status == "2") - keep active firms only.
    # The raw register mixes active and historical statuses (statuses
    # 1 and 5 were found mixed into the OYJ pull in the R run).
    df = df[df["status"] == "2"].reset_index(drop=True)
    return df


# ---------------------------------------------------------------------------
# Step 3 - Fetch registered notices per Business ID (with checkpointing)
# ---------------------------------------------------------------------------

def normalise_entry_codes(entry_codes):
    """entryCodes arrives as a list of strings or a list of dicts."""
    if not entry_codes:
        return None
    parts = []
    for item in entry_codes:
        if isinstance(item, dict):
            parts.append(str(item.get("code") or item.get("value") or item))
        else:
            parts.append(str(item))
    return ";".join(parts) if parts else None


def fetch_notices(business_ids, checkpoint_csv=CHECKPOINT_CSV,
                  done_ids_txt=DONE_IDS_TXT):
    """Fetch all registered notices for each Business ID.

    Replicates the production R loop (oy_notification_pull.R /
    oy_notification_retry.R) that covered 169,301 firms in 29.2 hours:
      - one GET per Business ID against /{businessId}
      - polite sleep between requests
      - checkpoint after every firm so an interrupted run resumes
        where it stopped (R version: progress .rds + batched csv)

    Two checkpoint files are kept:
      - checkpoint_csv: the notice rows fetched so far
      - done_ids_txt:   every Business ID successfully processed,
        INCLUDING firms with zero notices. Verified in the demo run:
        6 of 25 OYJ firms return HTTP 200 with no `publicNotices` key
        at all. Tracking completion separately from the data mirrors
        the R progress file and stops resumed runs from re-requesting
        zero-notice firms (in the R production run, 94 such firms
        were misread as missing and re-pulled).
    """
    OUTPUT_DIR.mkdir(exist_ok=True)

    done_ids = set()
    if done_ids_txt.exists():
        done_ids = set(done_ids_txt.read_text(encoding="utf-8").split())
    rows = []
    if checkpoint_csv.exists():
        prev = pd.read_csv(checkpoint_csv, dtype=str)
        rows = prev.to_dict("records")
        # Backwards-compatible with checkpoints written before the
        # done-ids file existed.
        done_ids |= set(prev["business_id"].unique())
        print(f"  checkpoint found: {len(done_ids)} firms already fetched")

    todo = [b for b in business_ids if b not in done_ids]
    print(f"  fetching notices for {len(todo)} firms "
          f"({len(done_ids)} restored from checkpoint)")

    missing_key_diagnosed = False
    for i, bid in enumerate(todo, 1):
        data = get_with_retry(f"{NOTICE_BASE}/{bid}")
        time.sleep(REQUEST_SLEEP)
        if data is None:
            # Not marked done, so the next run retries this firm.
            print(f"  {bid}: failed after {MAX_RETRY} retries, skipped")
            continue
        notices = data.get("publicNotices") or []
        if "publicNotices" not in data and not missing_key_diagnosed:
            # Diagnostic, printed once per run: zero-notice firms omit
            # the key entirely rather than returning an empty list
            # (verified 2026-07-10). If the API ever renames the key,
            # every firm would land here and this line reveals the
            # actual top-level keys to look at.
            print(f"  {bid}: no 'publicNotices' key in response; "
                  f"top-level keys: {sorted(data.keys())}")
            missing_key_diagnosed = True
        for n in notices:
            rows.append({
                "business_id": bid,
                "notice_date": safe(n.get("registrationDate")),
                "notice_type": safe(n.get("typeOfRegistration")),
                "entry_codes": normalise_entry_codes(n.get("entryCodes")),
            })
        # checkpoint: rewrite csv after each firm (cheap at demo scale;
        # the R production run checkpointed every 1,000 firms instead)
        pd.DataFrame(rows).to_csv(checkpoint_csv, index=False)
        # Mark the firm as processed even when it has zero notices.
        with open(done_ids_txt, "a", encoding="utf-8") as fh:
            fh.write(bid + "\n")
        if i % 5 == 0 or i == len(todo):
            print(f"  progress: {i}/{len(todo)} firms")

    # Fixed column order also protects downstream steps when the
    # notice sample happens to be empty.
    return pd.DataFrame(
        rows, columns=["business_id", "notice_date",
                       "notice_type", "entry_codes"])


# ---------------------------------------------------------------------------
# Step 4 - Merge and filter to the event window
# ---------------------------------------------------------------------------

def filter_event_window(notices, firms):
    """Attach firm attributes and keep notices inside the event window.

    R equivalent:
        notices %>%
          left_join(firms, by = "business_id") %>%
          filter(notice_date >= EVENT_START, notice_date <= EVENT_END)
    """
    df = notices.merge(
        firms[["business_id", "firm_type", "city", "municipality_code"]],
        on="business_id", how="left",
    )
    df["notice_date"] = pd.to_datetime(df["notice_date"], errors="coerce")
    mask = (df["notice_date"] >= EVENT_START) & (df["notice_date"] <= EVENT_END)
    out = df.loc[mask].reset_index(drop=True)
    print(f"  {len(notices)} notices total -> {len(out)} inside event window")
    return out


# ---------------------------------------------------------------------------
# Step 5 - Firm x month panel with DiD indicators
# ---------------------------------------------------------------------------

def build_firm_month_panel(notices_ew, firms, notice_type="TA"):
    """Aggregate notices to a balanced firm x month panel.

    Replicates the Stata panel construction (03_build_firm_month_panel):
        use firm_list, clear
        cross using months            <- full firm x month skeleton
        merge m:1 business_id ym_date using ta_fm
        replace ta_count = 0 if _merge == 1
    The dependent variables mirror the sample DiD analysis:
        ta_count  - number of financial statement (TA) filings per month
        ta_dummy  - 1 if at least one TA filing in the month
    """
    months = pd.period_range(EVENT_START, EVENT_END, freq="M")
    firm_ids = firms["business_id"].unique()

    # Full skeleton: every firm observed in every month (balanced panel)
    skeleton = pd.MultiIndex.from_product(
        [firm_ids, months], names=["business_id", "month"]
    ).to_frame(index=False)

    # Monthly counts of the chosen notice type
    sel = notices_ew[notices_ew["notice_type"] == notice_type].copy()
    sel["month"] = sel["notice_date"].dt.to_period("M")
    counts = (sel.groupby(["business_id", "month"])
                 .size()
                 .rename("ta_count")
                 .reset_index())
    # R equivalent: group_by(business_id, month) %>% summarise(n())

    panel = skeleton.merge(counts, on=["business_id", "month"], how="left")
    panel["ta_count"] = panel["ta_count"].fillna(0).astype(int)
    panel["ta_dummy"] = (panel["ta_count"] > 0).astype(int)

    # DiD indicators
    firm_type = firms.set_index("business_id")["firm_type"]
    panel["treat"] = (panel["business_id"].map(firm_type) == "OYJ").astype(int)
    treatment_month = pd.Period(TREATMENT_DATE, freq="M")
    panel["post"] = (panel["month"] >= treatment_month).astype(int)
    panel["treat_post"] = panel["treat"] * panel["post"]

    n_firms = panel["business_id"].nunique()
    print(f"  panel: {len(panel)} rows = {n_firms} firms x {len(months)} months")
    return panel


# ---------------------------------------------------------------------------
# Step 6 (optional) - Municipality choropleth with geopandas
# ---------------------------------------------------------------------------

def plot_municipality_map(firms, geojson_path, out_png="firms_by_municipality.png"):
    """Plot firm counts by municipality on a Finland map.

    Requires a municipality boundary GeoJSON from Statistics Finland
    open geodata (geo.stat.fi; layer 'kunta'). Download it once and
    pass the local path. The join key is the 3-digit municipality code
    (zero-padded), matching municipality_code parsed in Step 2.
    """
    try:
        import geopandas as gpd
        import matplotlib.pyplot as plt
    except ImportError:
        print("  geopandas/matplotlib not installed; skipping map "
              "(pip install geopandas matplotlib)")
        return

    geo = gpd.read_file(geojson_path)
    counts = (firms.groupby("municipality_code")
                   .size()
                   .rename("n_firms")
                   .reset_index())
    counts["municipality_code"] = counts["municipality_code"].str.zfill(3)
    # Adjust 'kunta' below if the layer names its code column differently
    geo["kunta"] = geo["kunta"].astype(str).str.zfill(3)
    merged = geo.merge(counts, left_on="kunta",
                       right_on="municipality_code", how="left")
    merged["n_firms"] = merged["n_firms"].fillna(0)

    ax = merged.plot(column="n_firms", legend=True, figsize=(8, 10),
                     cmap="viridis", edgecolor="white", linewidth=0.2)
    ax.set_axis_off()
    ax.set_title("Sample firms by municipality")
    out = OUTPUT_DIR / out_png
    plt.savefig(out, dpi=200, bbox_inches="tight")
    print(f"  map saved to {out}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    OUTPUT_DIR.mkdir(exist_ok=True)

    print("Step 1: fetching OYJ registrations (paginated)")
    # OYJ is small enough (428 firms / 5 pages at verification time;
    # the register fluctuates daily) to fetch in full even in demo
    # mode. max_pages=6 is a safety net, not the expected page count:
    # it leaves headroom for the register to grow past 500 firms
    # without silently truncating the pull.
    raw_oyj = fetch_companies("OYJ", max_pages=6 if DEMO_MODE else None)

    print("Step 2: parsing nested JSON")
    firms = parse_companies(raw_oyj, "OYJ")
    firms.to_csv(OUTPUT_DIR / "prh_oyj_clean.csv", index=False)
    print(f"  {len(firms)} active firms parsed -> prh_oyj_clean.csv")

    print("Step 3: fetching registered notices (checkpointed)")
    sample_ids = firms["business_id"].head(DEMO_MAX_NOTICE_FIRMS).tolist()
    notices = fetch_notices(sample_ids)

    print("Step 4: filtering to the event window")
    notices_ew = filter_event_window(notices, firms)
    notices_ew.to_csv(OUTPUT_DIR / "notices_event_window.csv", index=False)

    print("Step 5: building the firm x month panel")
    sample_firms = firms[firms["business_id"].isin(sample_ids)]
    panel = build_firm_month_panel(notices_ew, sample_firms)
    panel.to_csv(OUTPUT_DIR / "firm_month_panel.csv", index=False)

    print("Step 6: municipality map (optional)")
    print("  skipped by default; call plot_municipality_map(firms, "
          "'<path-to-municipality-geojson>') after downloading the "
          "boundary file from Statistics Finland open geodata")

    print("Done.")


if __name__ == "__main__":
    main()
