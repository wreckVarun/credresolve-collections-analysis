# Collections analytics — CredResolve Data Analyst assignment

**The reported 11% month-on-month improvement is the difference between a
28-day month and a 31-day month.** 31 ÷ 28 − 1 = 10.7%. Normalised to
recovery per calendar day, that +11.0% becomes +0.3%, and the volatility of
the whole series collapses from a standard deviation of 8.4% to 2.6%.
Recovery has been flat for seven months.

Start with [`reports/executive_memo.md`](reports/executive_memo.md) (2 pages)
or open [`dashboard/index.html`](dashboard/index.html) in a browser.

---

## Findings in brief

| | |
|---|---|
| Reported improvement | +11.0% MoM (February → March) |
| Actual, day-normalised | **+0.3%** |
| Variance in monthly totals explained by month length | **r² = 0.82** (p = 0.005) |
| Trend in recovery per operating day, Jan–Jul | none (p = 0.33) |
| Segments trending (of 14 tested) | **0** |
| Reported payment value that is not recovery | **₹64.9 Cr of ₹191.7 Cr (33.8%)** |
| Recovery arriving with no call, message or visit | **₹46.0 Cr (36%)** |
| ₹10 Cr recommendation | **Hold one quarter.** Spend ₹40–60 L on a randomised holdout |

Two places where the intuitive approach is wrong, and the wrong answer is
larger than the problem it fixes:

- **Deduplicating payments on `payment_reference`** — the obvious key —
  would delete **₹60.8 Cr of genuine recovery**. The reference is not unique
  in the source system; one reference maps to three unrelated borrowers. The
  real duplicate count is 500, found on a full row hash plus a second pass for
  ingestion races.
- **Resolving agent identity on `employee_code` or `agent_name`** would
  collapse 1,000 agents into 10 and inflate per-agent recovery ~100×.

## Repository layout

```
├── pipeline.py                  reproducible Raw → Golden → Metrics run
├── counterfactual.py            Part 4: DiD design, and why it fails here
├── make_figures.py              figures used in the memo and notebook
├── verify.py                    asserts every number in the reports against the data
├── build_notebook.py            assembles the analysis notebook
│
├── sql/
│   ├── 01_staging.sql           raw → staging, lineage + row hashes
│   ├── 02_golden.sql            every judgement call, documented inline
│   ├── 03_metrics.sql           independent metric definitions
│   ├── 04_forensics.sql         the seven investigations, with verdicts
│   └── 05_drivers.sql           Q2 driver dimensions, with verdicts
│
├── notebooks/analysis.ipynb     reasoning, executed with outputs
│
├── reports/
│   ├── executive_memo.md        2 pages — the primary deliverable
│   ├── data_quality_report.md   12 defects: detection, treatment, impact
│   ├── metric_definitions.md    the nine existing definitions, challenged
│   └── architecture.md          production design
│
├── dashboard/index.html         one screen, self-contained, no dependencies
├── figures/                     charts + architecture.svg
└── data/                        golden dataset (parquet + csv) and DuckDB file
```

## Running it

```bash
pip install -r requirements.txt
python pipeline.py --data-dir /path/to/raw/csvs --out data
python verify.py          # asserts all 37 claims in the reports against the data
python make_figures.py
python counterfactual.py
jupyter notebook notebooks/analysis.ipynb
```

`pipeline.py` copies the source CSVs into `./raw/`, stripping the
millisecond-epoch filename prefixes, then runs the five SQL files in order.
Requires `duckdb >= 0.10`; the script checks and tells you if yours is older.

**The SQL runs standalone too.** Every `.sql` file uses plain relative paths
(`raw/payments.csv`), so once `./raw/` exists you can open any of them in the
DuckDB CLI, DBeaver or VS Code and execute directly:

```bash
python pipeline.py --data-dir /path/to/raw/csvs --out data   # populates ./raw/
duckdb analysis.duckdb                                        # then, in the CLI:
#   .read sql/01_staging.sql
#   .read sql/02_golden.sql
#   .read sql/03_metrics.sql
#   .read sql/04_forensics.sql
#   .read sql/05_drivers.sql
#   SELECT * FROM metrics.monthly_recovery ORDER BY month;
```

Run them in numeric order — each layer builds on the previous one. The
notebook expects `data/collections.duckdb`, so run `pipeline.py` before
opening it.

Runtime is about 20 seconds. Deterministic: no sampling, no seeds, no manual
steps. `pipeline.py` handles the millisecond-epoch filename prefixes on the
source CSVs, so the raw directory can be passed unchanged.

The golden dataset is written to `data/golden_account_month.{parquet,csv}` —
one row per account per month, 210,000 rows, with a fixed 30,000-account
denominator so no rate computed from it can be gamed by a shrinking base.

## Where the answers live

| Assignment section | Where |
|---|---|
| Part 1 — Golden dataset | `sql/02_golden.sql`, reconciliation in `pipeline.py` output |
| Part 2 — Data forensics | `sql/04_forensics.sql`, `reports/data_quality_report.md` |
| Part 3 — Statistical investigation | `notebooks/analysis.ipynb` §5–6 (mix, cohort, selection, survivorship, Simpson's, attribution-window, time-series) |
| Q2 driver dimensions | `sql/05_drivers.sql` |
| Part 4 — Counterfactual | `counterfactual.py` |
| Part 5 — Production design | `reports/architecture.md`, `figures/architecture.svg` |
| Q3 — challenge the nine metric definitions | `reports/metric_definitions.md`, `sql/03_metrics.sql` |
| Q1–Q4 (what/why/is it real/where to invest) | `reports/executive_memo.md` |

## What this analysis does not claim

Stated up front, because the constraints shaped the conclusions:

- **Geography is excluded.** City and state are borrower attributes, and
  borrower identity is broken: 30,600 rows resolve to 11,015 IDs, of which
  8,468 carry conflicting names, phones and cities. A state-level finding here
  would be the most plausible-looking wrong answer in the dataset.
- **Per-agent and agent-tenure analysis is impossible.** 1,000 agent IDs,
  1,099 employee codes, 10 distinct names, every code mapping to multiple
  people.
- **Channel effectiveness is not measurable.** 36% of recovery has no
  interaction at all; 18% has two or more simultaneously. No attribution
  window fixes this, so no channel conversion rate is published.
- **Client and language do not exist** as columns in any of the 17 tables,
  despite being on the required investigation list.
- **No ROI figures are given for the six investment options.** The dataset
  contains no cost table. `metrics.unit_economics` exposes cost assumptions as
  named parameters rather than burying invented inputs inside a result.

Four of the assignment's required investigation dimensions cannot be answered
from this data. Saying so, with the evidence, is the answer.
