# Tillster Take Home Assignment - Kiosk session analysis

This project reads a kiosk event log and answers one chain of questions: what is in the file, whether a session stays in one place, whether a session is a visit or a customer, where sessions drop before purchase, and whether store revenue and store conversion tell the same story.

The analysis of record is `notebooks/discovery_session_identity.ipynb`. The SQL files under `sql/` are the discovery queries that notebook runs. Read the notebook from top to bottom. Each section answers the question the section above leaves open.

## What you need

- Python 3.11 or newer
- The event file at `data/dataset.csv.gz` (gzip of the source CSV; DuckDB reads it directly)
- Optional: the [DuckDB CLI](https://duckdb.org/docs/installation/), if you want to run the SQL outside the notebook

The file is about 1.8 million rows. The first notebook run reads the whole file. Expect about a minute.

## Layout

| Path | What it is |
| --- | --- |
| `data/dataset.csv.gz` | Source events. The view in `sql/init_ddl.sql` reads this path. |
| `sql/init_ddl.sql` | Creates the `events` view. Every other query assumes this has already run. |
| `sql/discovery_query.sql` | File inventory, then the same counts by tenant. |
| `sql/discovery_grain.sql` | Duplicate `session_id` + `event_index` pairs, and whether one session crosses a tenant, store, kiosk, or date. |
| `sql/discovery_session_identity.sql` | How many sessions span more than one date, and the daily session and revenue table. |
| `sql/discovery_kiosk_stores.sql` | Kiosk list, store revenue, and a check that no kiosk sits in two stores. |
| `sql/discovery_events.sql` | One row per event. About 1.8 million rows. The notebook does not run this file. |
| `notebooks/discovery_session_identity.ipynb` | Discovery tables, then the charts. |
| `sql/metric_layer.sql` | Metric tables the question app is allowed to query. |
| `app.py` | Question box. One question, one SELECT, the SQL on the page. |
| `requirements.txt` | Python deps for the notebook and the question app. |

`events` has nine columns: `tenant`, `session_id`, `event_date`, `event_index`, `event_name`, `store_id_unified`, `kiosk_id_up`, `item_id_masked`, `item_revenue`. The event names used in the charts are `view_item_list`, `select_item`, `add_to_cart`, and `purchase`.

## Install

From the repo root in PowerShell:

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
```

On macOS or Linux, activate with `source .venv/bin/activate` instead.

`requirements.txt` installs DuckDB, pandas, matplotlib, and ipykernel. DuckDB runs the SQL. pandas holds the result tables. matplotlib draws the charts. ipykernel is the Jupyter kernel.

In Cursor or VS Code, choose the `.venv` interpreter for the notebook. The kernel name in the notebook metadata is `.venv`.

## Run the notebook

Open `notebooks/discovery_session_identity.ipynb` and run all cells from the top.

The setup cell finds the repo root by looking for `sql/init_ddl.sql` in the current directory, then in the parent. It changes the working directory to that root, opens an in-memory DuckDB connection, and runs `sql/init_ddl.sql`. After that, `events` points at `data/dataset.csv.gz`.

That cell also defines the helpers later cells call:

- `sql_file(path)` reads a `.sql` file, drops `--` line comments and `/* */` blocks, splits on semicolons, and returns one formatted table per statement.
- `load_daily()` builds sessions and item revenue by date and tenant.
- `load_session_flags()` builds one row per tenant and session, with a flag for each funnel step.

Restart the kernel if you change a SQL file or the setup cell. A later cell run on its own fails until the setup cell has run in that kernel. Saved outputs in the file were produced from the repo root. Run All replaces them.

## How to read the notebook

The sections follow the question, not the file order on disk.

1. **What is in the file.** Runs `sql/discovery_query.sql`. The first table is the whole file. The second is the same counts by tenant. The revenue sum mixes price units, so it is an inventory figure. Later charts do not rank tenants by that sum.
2. **Whether a session stays in one place.** Runs `sql/discovery_grain.sql`. A row is one event. The first result counts duplicate `session_id` and `event_index` pairs. The second checks whether one session crosses a tenant, a store, a kiosk, or a date.
3. **A session is one visit.** Runs `sql/discovery_session_identity.sql`. The date span is the reason a session is treated as one visit. There is no guest id in the file. The daily table under that result feeds the next chart. Its revenue column is still not a cross-tenant ranking.
4. **Stores, kiosks, and raw revenue.** Runs `sql/discovery_kiosk_stores.sql`. Three results: one row per kiosk, one row per store, then kiosks that appear in more than one store. An empty third table means that count is zero. The cell prints that sentence when the table is empty. Store revenue here is raw `item_revenue`. Tenant 2 sorts high because the price unit differs.
5. **The gap holds on every day.** Bar chart of sessions by day for both tenants. This is the check that Tenant 1 is larger on every date, not only on a few busy days.
6. **Most visits reach a purchase.** One funnel per tenant. A session counts at a step when it has that event at least once. The label is the session count and the share of all sessions for that tenant. The drawing uses an even taper while `PROPORTIONAL` is `False`, so the band widths are not the shares. Set `PROPORTIONAL = True` in that cell to draw the widths from the session counts.
7. **Where the sessions are lost.** Step rates. Each bar is sessions that reached the step, divided by sessions that reached the step before it: view to select, select to cart, cart to purchase.
8. **The basket is the same. The price unit is not.** Items per session that purchased, next to the median `item_revenue` on a purchase row. The median is why the discovery revenue sums are not a ranking.
9. **Inside a tenant, busier days carry that tenant's revenue.** One chart per tenant. Bars are sessions. The line is that tenant's item revenue. Read each chart on its own revenue axis.
10. **Stores differ more than the tenants do.** Purchase rate by store: sessions with a purchase, divided by all sessions at the store. The label is the rate and the kiosk count. Both tenants share the percent axis.

## Run the SQL in DuckDB

Start the CLI from the repo root. `sql/init_ddl.sql` loads `data/dataset.csv.gz` with a relative path, so another working directory will not find the file.

```powershell
cd /path/to/tillster-takehome-assignment
duckdb
```

Inside the prompt:

```sql
.read sql/init_ddl.sql
.read sql/discovery_query.sql
.read sql/discovery_grain.sql
.read sql/discovery_session_identity.sql
.read sql/discovery_kiosk_stores.sql
.quit
```

Run `init_ddl.sql` once per CLI session, before the discovery files. Each `.read` runs every statement in that file.

Leave `sql/discovery_events.sql` out of a normal pass. It returns one row per event, about 1.8 million rows, and the notebook does not use it. If you do run it, write the result to a file instead of printing it:

```sql
COPY (
    -- paste the query
) TO 'outputs/discovery_events.csv' (HEADER, DELIMITER ',');
```

Useful CLI commands while you are looking at a small result: `.maxrows 100` sets how many rows print, and `.last` reprints the previous result.

## Definitions the charts use

These live in the notebook helpers, not in a separate metric file.

- A session is one `session_id` inside one tenant. The grain checks are what make that safe to treat as one visit: no session crosses a tenant, a store, or a kiosk.
- A session reaches a funnel step when that `event_name` appears at least once. The steps are `view_item_list`, `select_item`, `add_to_cart`, and `purchase`. The check is presence, not `event_index` order.
- Purchase rate for a store is sessions with a purchase, divided by all sessions at that store.
- Items per buying session are purchase rows in sessions that purchased.
- Revenue in the daily charts is `SUM(item_revenue)` for that tenant and date. Revenue per buying session in the basket section uses `item_revenue` on `purchase` rows only. Tenant 1 and Tenant 2 stay on separate axes because the price units differ.

## Question app

`app.py` is a question box over the metric tables. It builds those tables from `sql/metric_layer.sql` after `sql/init_ddl.sql`, then drops the raw `events` view. A question becomes one `SELECT` against those tables. The page shows the SQL under the result.

The definitions match the notebook. A session is one visit. A funnel step is presence of that event name. Item revenue stays inside one tenant. Questions about churn, repeat visits, or lifetime value are refused, because the file has no guest id.

From the repo root, with the virtualenv active:

```powershell
copy .streamlit\secrets.toml.example .streamlit\secrets.toml
streamlit run app.py
```

Put your Deepseek key in `.streamlit/secrets.toml`. That file is gitignored. The first launch reads `data/dataset.csv.gz` and builds the tables. Later questions reuse them until the app process restarts.

To host it on Streamlit Community Cloud:

1. Push this repo to GitHub, including `data/dataset.csv.gz`. Do not push the secrets file.
2. Sign in at [share.streamlit.io](https://share.streamlit.io) and create an app from that repo.
3. Set the main file to `app.py`.
4. In the app settings, open Secrets and paste the same TOML as the example file, with the real key.
5. Deploy. The first boot reads the event file, so give it a minute.

Anyone with the app link can ask questions. The answers come from this dataset.

## Local notes

If you keep a raw `data/dataset.csv` for CLI experiments, leave it untracked. The committed source is `data/dataset.csv.gz`.
