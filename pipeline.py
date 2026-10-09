#!/usr/bin/env python3
"""
CredResolve collections analysis -- reproducible pipeline.

Runs Raw -> Staging -> Golden -> Metrics -> Forensics -> DQ checks and
writes the golden dataset plus every metric and forensic table to disk.
Exits non-zero if any BLOCKING data-quality check fails.

Usage:
    python pipeline.py --data-dir ./raw/ --out ./data/

The whole thing is deterministic: same inputs, same outputs, no seeds,
no sampling. Runtime is about 20 seconds on a laptop.
"""

import argparse
import glob
import os
import re
import sys
import shutil
import duckdb


SQL_FILES = [
    "sql/01_staging.sql",
    "sql/02_golden.sql",
    "sql/03_metrics.sql",
    "sql/04_forensics.sql",
    "sql/05_drivers.sql",
    "sql/06_dq_checks.sql",
]

# Source files arrive with a millisecond-epoch prefix (1788218010160_accounts.csv).
# Normalise to bare table names so the SQL never has to know about it.
PREFIX = re.compile(r"^\d+_")


def stage_inputs(data_dir, raw_dir="raw"):
    """Copy source CSVs to ./raw/ under clean names.

    The SQL refers to plain relative paths ('raw/payments.csv') so that every
    .sql file can be opened and run directly in DuckDB, DBeaver, VS Code or
    any other client without this script. Copies rather than symlinks, because
    symlinks fail on Windows and on some mounted volumes.
    """
    os.makedirs(raw_dir, exist_ok=True)
    found = {}
    for path in sorted(glob.glob(os.path.join(data_dir, "*.csv"))):
        base = PREFIX.sub("", os.path.basename(path))
        dest = os.path.join(raw_dir, base)
        if os.path.abspath(path) != os.path.abspath(dest):
            shutil.copyfile(path, dest)
        found[base] = dest
    if not found:
        sys.exit(f"ERROR: no CSV files found in {data_dir!r}. "
                 f"Pass the folder holding the raw CSVs via --data-dir.")
    return found


def check_env():
    major, minor = (int(x) for x in duckdb.__version__.split(".")[:2])
    if (major, minor) < (0, 10):
        sys.exit(f"ERROR: duckdb {duckdb.__version__} is too old. "
                 f"Run: pip install --upgrade 'duckdb>=0.10'")


def run(db_path, data_dir, out_dir):
    check_env()
    files = stage_inputs(data_dir, "raw")
    print(f"[stage] {len(files)} source CSVs copied to ./raw/")

    if os.path.exists(db_path):
        os.remove(db_path)
    con = duckdb.connect(db_path)

    for f in SQL_FILES:
        if not os.path.exists(f):
            sys.exit(f"ERROR: {f} not found. Run this script from the repo root.")
        print(f"[run  ] {f}")
        con.execute(open(f).read())

    # ---- exports -----------------------------------------------------
    os.makedirs(out_dir, exist_ok=True)

    exports = {
        "golden_account_month":   "SELECT * FROM gold.account_month",
        "golden_fct_payment":     "SELECT * FROM gold.fct_payment",
        "golden_fct_call":        "SELECT * FROM gold.fct_call",
        "golden_dim_account":     "SELECT * FROM gold.dim_account",
        "golden_dim_agent":       "SELECT * FROM gold.dim_agent",
        "metrics_monthly":        "SELECT * FROM metrics.monthly_recovery",
        "metrics_productivity":   "SELECT * FROM metrics.productivity",
        "metrics_channel":        "SELECT * FROM metrics.channel_month",
        "metrics_segment":        "SELECT * FROM metrics.segment_month",
        "metrics_unit_economics": "SELECT * FROM metrics.unit_economics",
        "metrics_hour_profile":   "SELECT * FROM metrics.hour_profile",
        "drivers_attempt_frequency": "SELECT * FROM drivers.attempt_frequency",
        "drivers_vendor_month":      "SELECT * FROM drivers.vendor_month",
        "drivers_calling_time":      "SELECT * FROM drivers.calling_time",
        "drivers_cohort_vintage":    "SELECT * FROM drivers.cohort_vintage",
    }
    for name, q in exports.items():
        # ORDER BY ALL so the files are byte-stable across runs; without it
        # a parallel engine writes rows in whatever order threads finish.
        q = f"SELECT * FROM ({q}) ORDER BY ALL"
        con.execute(f"COPY ({q}) TO '{out_dir}/{name}.parquet' (FORMAT PARQUET)")
        con.execute(f"COPY ({q}) TO '{out_dir}/{name}.csv' (HEADER, DELIMITER ',')")
    print(f"[out  ] {len(exports)} tables written to {out_dir}")

    # ---- reconciliation ledger --------------------------------------
    # Raw -> Rejected/Corrected -> Golden, quantified.
    ledger = con.execute("""
        WITH raw AS (SELECT count(*) n, sum(amount) amt FROM stg.payments),
             dedup AS (SELECT count(*) n, sum(amount) amt FROM gold.fct_payment),
             good AS (SELECT count(*) n, sum(recovered_amount) amt FROM gold.fct_payment WHERE is_recovered)
        SELECT 'raw_payment_rows' AS step, raw.n AS n_rows, raw.amt AS rupees FROM raw
        UNION ALL SELECT 'after_row_hash_dedup', dedup.n, dedup.amt FROM dedup
        UNION ALL SELECT 'after_status_filter_SUCCESS', good.n, good.amt FROM good
    """).df()
    print("\n--- Raw -> Golden reconciliation ---")
    print(ledger.to_string(index=False))
    ledger.to_csv(f"{out_dir}/reconciliation_ledger.csv", index=False)

    # ---- headline result --------------------------------------------
    head = con.execute("""
        SELECT month, calendar_days,
               round(recovered_amount/1e7, 2)  AS recovery_cr,
               round(recovery_per_day/1e5, 2)  AS recovery_per_day_lakh,
               round(mom_pct_naive, 1)         AS mom_naive_pct,
               round(mom_pct_per_day, 1)       AS mom_per_day_pct
        FROM metrics.monthly_recovery ORDER BY month
    """).df()
    print("\n--- Headline: naive MoM vs day-normalised MoM ---")
    print(head.to_string(index=False))
    head.to_csv(f"{out_dir}/headline_monthly.csv", index=False)

    # ---- data-quality gate ------------------------------------------
    dq = con.execute("SELECT * FROM dq.results ORDER BY check_id").df()
    dq.to_csv(f"{out_dir}/dq_results.csv", index=False)
    print("\n--- Data-quality checks ---")
    print(dq.to_string(index=False))
    failed = dq[dq.status == "FAIL"]
    n_block = (dq.tier == "BLOCKING").sum()
    print(f"\n{n_block - len(failed)}/{n_block} blocking checks passed, "
          f"{(dq.status == 'WARN').sum()} known source defects measured")

    con.close()
    if len(failed):
        sys.exit(f"ERROR: {len(failed)} blocking data-quality check(s) failed: "
                 + ", ".join(failed.check_id))
    return head


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-dir", default="/mnt/user-data/uploads")
    ap.add_argument("--out", default="data")
    ap.add_argument("--db", default="data/collections.duckdb")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    run(a.db, a.data_dir, a.out)
