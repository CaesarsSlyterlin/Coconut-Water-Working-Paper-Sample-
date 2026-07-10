# Python Replication of the PRH Data Pipeline
This folder contains a self-contained Python replication (prh_pipeline.py) of the R data pipeline in **01_data_collection/** and **02_data_cleaning/**. 

It reproduces the same logic with requests and pandas: paginated retrieval from the PRH YTJ companies API, parsing of nested JSON records with missing-value protection, checkpointed retrieval of registered notices per Business ID, event-window filtering, and aggregation to a firm-month panel with DiD indicator variables.
The script runs in *DEMO_MODE* by default (full OYJ register, a 25-firm notice sample) and completes in a few minutes on Google Colab. Set DEMO_MODE = False only if you intend a full-scale pull; the equivalent R production run over 169,301 firms took 29.2 hours.
Two implementation notes came out of empirical verification against the live API (July 2026): pagination on the YTJ companies endpoint is 1-based (page=0 silently duplicates page 1), and firms with no registered notices omit the publicNotices key entirely rather than returning an empty list. Both behaviours are handled and documented in the code.

## Requirements
Python 3.10+, requests, pandas. Optional for the municipality map: geopandas, matplotlib, and a municipality boundary file from Statistics Finland open geodata.
