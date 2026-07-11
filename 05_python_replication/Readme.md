# Python Replication of the PRH Data Pipeline
This folder contains a self-contained Python replication (prh_pipeline.py) of the R data pipeline in **01_data_collection/** and **02_data_cleaning/**. 

It reproduces the same logic with requests and pandas: paginated retrieval from the PRH YTJ companies API, parsing of nested JSON records with missing-value protection, checkpointed retrieval of registered notices per Business ID, event-window filtering, and aggregation to a firm-month panel with DiD indicator variables.
The script runs in *DEMO_MODE* by default (full OYJ register, a 25-firm notice sample) and completes in a few minutes on Google Colab. Set DEMO_MODE = False only if you intend a full-scale pull; the equivalent R production run over 169,301 firms took 29.2 hours.
Two implementation notes came out of empirical verification against the live API (July 2026): pagination on the YTJ companies endpoint is 1-based (page=0 silently duplicates page 1), and firms with no registered notices omit the publicNotices key entirely rather than returning an empty list. Both behaviours are handled and documented in the code.status filtering keeps registered non-deregistered firms (420 at verification time); the paper's treatment group further restricts to firms with FY2024 tax records (294, cross-validated against PRH's official statistics)

## Requirements
Python 3.10+, requests, pandas. Optional for the municipality map: geopandas, matplotlib, and a municipality boundary file from Statistics Finland open geodata.

## Drawing the municipality map (optional)
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

