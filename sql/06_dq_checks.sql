-- =====================================================================
-- 06_dq_checks.sql   Data-quality checks, one row per check
--
-- Every check returns the number of rows that violate it. Two tiers:
--
--   BLOCKING      Invariants the pipeline itself guarantees: keys unique,
--                 joins don't fan out, money reconciles. Any failure means
--                 the golden layer is wrong; pipeline.py exits non-zero
--                 and nothing downstream should be trusted.
--
--   SOURCE_DEFECT Known defects in the source data, measured on every
--                 run. These are expected to be non-zero; they are handled
--                 by a documented treatment (see data_quality_report.md),
--                 and the count is tracked so a change is visible.
--
-- Results land in dq.results and are exported to data/dq_results.csv.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS dq;

CREATE OR REPLACE TABLE dq.results AS
WITH checks(check_id, tier, check_name, failing_rows) AS (

    -- ---------------- BLOCKING: keys and grain -----------------------
    SELECT 'B01', 'BLOCKING', 'fct_payment.payment_id is unique',
           (SELECT count(*) - count(DISTINCT payment_id) FROM gold.fct_payment)
    UNION ALL SELECT 'B02', 'BLOCKING', 'fct_payment.payment_id is not null',
           (SELECT count(*) FROM gold.fct_payment WHERE payment_id IS NULL)
    UNION ALL SELECT 'B03', 'BLOCKING', 'dedup removed exactly the repeated payment_ids',
           (SELECT abs((SELECT count(*) FROM stg.payments) - (SELECT count(*) FROM gold.fct_payment)
                     - ((SELECT count(*) FROM stg.payments) - (SELECT count(DISTINCT payment_id) FROM stg.payments))))
    UNION ALL SELECT 'B04', 'BLOCKING', 'dim_account.account_id is unique',
           (SELECT count(*) - count(DISTINCT account_id) FROM gold.dim_account)
    UNION ALL SELECT 'B05', 'BLOCKING', 'dim_account has one row per source account (no join fan-out)',
           (SELECT abs((SELECT count(*) FROM gold.dim_account) - (SELECT count(*) FROM stg.accounts)))
    UNION ALL SELECT 'B06', 'BLOCKING', 'dim_borrower.borrower_id is unique',
           (SELECT count(*) - count(DISTINCT borrower_id) FROM gold.dim_borrower)
    UNION ALL SELECT 'B07', 'BLOCKING', 'dim_agent.agent_id is unique',
           (SELECT count(*) - count(DISTINCT agent_id) FROM gold.dim_agent)
    UNION ALL SELECT 'B08', 'BLOCKING', 'fct_disposition.disposition_id is unique',
           (SELECT count(*) - count(DISTINCT disposition_id) FROM gold.fct_disposition)
    UNION ALL SELECT 'B09', 'BLOCKING', 'account_month is unique on (account_id, month)',
           (SELECT count(*) - count(DISTINCT (account_id, month)) FROM gold.account_month)
    UNION ALL SELECT 'B10', 'BLOCKING', 'account_month = every account x every month (fixed denominator)',
           (SELECT abs((SELECT count(*) FROM gold.account_month)
                     - (SELECT count(*) FROM gold.dim_account)
                       * (SELECT count(DISTINCT month) FROM gold.account_month)))

    -- ---------------- BLOCKING: referential integrity ----------------
    UNION ALL SELECT 'B11', 'BLOCKING', 'every payment resolves to an account',
           (SELECT count(*) FROM gold.fct_payment p
            WHERE NOT EXISTS (SELECT 1 FROM gold.dim_account a WHERE a.account_id = p.account_id))
    UNION ALL SELECT 'B12', 'BLOCKING', 'every call resolves to an account',
           (SELECT count(*) FROM gold.fct_call c
            WHERE NOT EXISTS (SELECT 1 FROM gold.dim_account a WHERE a.account_id = c.account_id))
    UNION ALL SELECT 'B13', 'BLOCKING', 'every non-null call agent resolves to dim_agent',
           (SELECT count(*) FROM gold.fct_call c WHERE c.agent_id IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM gold.dim_agent a WHERE a.agent_id = c.agent_id))
    UNION ALL SELECT 'B14', 'BLOCKING', 'every disposition resolves to a call',
           (SELECT count(*) FROM gold.fct_disposition d
            WHERE NOT EXISTS (SELECT 1 FROM gold.fct_call c WHERE c.call_id = d.call_id))

    -- ---------------- BLOCKING: value rules --------------------------
    UNION ALL SELECT 'B15', 'BLOCKING', 'payment amount > 0',
           (SELECT count(*) FROM gold.fct_payment WHERE amount IS NULL OR amount <= 0)
    UNION ALL SELECT 'B16', 'BLOCKING', 'payment_status in {SUCCESS, FAILED, PENDING, REVERSED}',
           (SELECT count(*) FROM gold.fct_payment
            WHERE payment_status IS NULL OR payment_status NOT IN ('SUCCESS','FAILED','PENDING','REVERSED'))
    UNION ALL SELECT 'B17', 'BLOCKING', 'recovered_amount = amount for SUCCESS, 0 otherwise',
           (SELECT count(*) FROM gold.fct_payment
            WHERE recovered_amount <> CASE WHEN payment_status = 'SUCCESS' THEN amount ELSE 0 END)
    UNION ALL SELECT 'B18', 'BLOCKING', 'every call has an IST timestamp after tz conversion',
           (SELECT count(*) FROM gold.fct_call WHERE called_at_ist IS NULL)
    UNION ALL SELECT 'B19', 'BLOCKING', 'call timezone in {UTC, Asia/Kolkata, Asia/Dubai}',
           (SELECT count(*) FROM gold.fct_call
            WHERE src_timezone IS NULL OR src_timezone NOT IN ('UTC','Asia/Kolkata','Asia/Dubai'))
    UNION ALL SELECT 'B20', 'BLOCKING', 'agent session logout >= login',
           (SELECT count(*) FROM stg.agent_sessions WHERE logout_at_naive < login_at_naive)
    UNION ALL SELECT 'B21', 'BLOCKING', 'calendar_days between 28 and 31',
           (SELECT count(*) FROM gold.account_month WHERE calendar_days NOT BETWEEN 28 AND 31)
    UNION ALL SELECT 'B22', 'BLOCKING', 'partial month (Aug 2026) kept out of the trend spine',
           (SELECT count(*) FROM gold.account_month WHERE month >= DATE '2026-08-01')

    -- ---------------- BLOCKING: reconciliation -----------------------
    UNION ALL SELECT 'B23', 'BLOCKING', 'golden recovery = SUCCESS payments Jan-Jul, to the paisa',
           (SELECT CASE WHEN (SELECT sum(recovered_amount) FROM gold.account_month)
                           = (SELECT sum(recovered_amount) FROM gold.fct_payment
                              WHERE paid_month < DATE '2026-08-01')
                        THEN 0 ELSE 1 END)
    UNION ALL SELECT 'B24', 'BLOCKING', 'monthly metric total = golden total',
           (SELECT CASE WHEN (SELECT sum(recovered_amount) FROM metrics.monthly_recovery)
                           = (SELECT sum(recovered_amount) FROM gold.account_month)
                        THEN 0 ELSE 1 END)
    UNION ALL SELECT 'B25', 'BLOCKING', 'every disposition code maps (no UNMAPPED)',
           (SELECT count(*) FROM gold.fct_disposition WHERE disposition_code = 'UNMAPPED')

    -- ---------------- SOURCE_DEFECT: measured, flagged ---------------
    UNION ALL SELECT 'S01', 'SOURCE_DEFECT', 'DQ-01 borrower_ids with conflicting identities',
           (SELECT count(*) FROM gold.dim_borrower WHERE has_conflicting_identity)
    UNION ALL SELECT 'S02', 'SOURCE_DEFECT', 'DQ-02 agent_ids with more than one employee_code',
           (SELECT count(*) FROM gold.dim_agent WHERE has_ambiguous_employee_code)
    UNION ALL SELECT 'S03', 'SOURCE_DEFECT', 'DQ-03 unanswered calls with non-zero duration',
           (SELECT count(*) FROM gold.fct_call WHERE has_duration_contradiction)
    UNION ALL SELECT 'S04', 'SOURCE_DEFECT', 'DQ-04 recovering account-months with no touch',
           (SELECT count(*) FROM gold.account_month
            WHERE is_recovering AND n_calls = 0 AND n_digital = 0 AND n_field_visits = 0)
    UNION ALL SELECT 'S05', 'SOURCE_DEFECT', 'DQ-05 byte-identical payment replays',
           (SELECT count(*) - count(DISTINCT _row_hash) FROM stg.payments)
    UNION ALL SELECT 'S06', 'SOURCE_DEFECT', 'DQ-05 payments sharing a payment_reference',
           (SELECT count(*) FROM gold.fct_payment WHERE is_reference_collision)
    UNION ALL SELECT 'S07', 'SOURCE_DEFECT', 'DQ-06 non-SUCCESS payment rows',
           (SELECT count(*) FROM gold.fct_payment WHERE NOT is_recovered)
    UNION ALL SELECT 'S08', 'SOURCE_DEFECT', 'DQ-07 calls whose hour changes after tz conversion',
           (SELECT count(*) FROM gold.fct_call WHERE call_hour_ist <> call_hour_uncorrected)
    UNION ALL SELECT 'S09', 'SOURCE_DEFECT', 'DQ-08 legacy PTP code needing harmonisation',
           (SELECT count(*) FROM gold.fct_disposition WHERE disposition_code_raw = 'PTP')
    UNION ALL SELECT 'S10', 'SOURCE_DEFECT', 'DQ-09 event tables ending before month end (Aug)',
           (SELECT count(*) FROM gold.fct_payment WHERE paid_month = DATE '2026-08-01')
    UNION ALL SELECT 'S11', 'SOURCE_DEFECT', 'DQ-10 status rows recorded before the event',
           (SELECT count(*) FROM gold.fct_status_history WHERE is_clock_inverted)
    UNION ALL SELECT 'S12', 'SOURCE_DEFECT', 'DQ-11 payments on CLOSED / WRITEOFF accounts',
           (SELECT count(*) FROM gold.fct_payment p JOIN gold.dim_account a USING (account_id)
            WHERE a.status IN ('CLOSED','WRITEOFF'))
    UNION ALL SELECT 'S13', 'SOURCE_DEFECT', 'DQ-12 calls with NULL agent_id',
           (SELECT count(*) FROM gold.fct_call WHERE agent_id IS NULL)
    UNION ALL SELECT 'S14', 'SOURCE_DEFECT', 'DQ-12 borrowers with NULL phone',
           (SELECT count(*) FROM stg.borrowers WHERE phone IS NULL)
    UNION ALL SELECT 'S15', 'SOURCE_DEFECT', 'DQ-13 call rows sharing a call_id',
           (SELECT count(*) FROM gold.fct_call WHERE is_duplicate_call_id)
    UNION ALL SELECT 'S16', 'SOURCE_DEFECT', 'DQ-14 duplicate WhatsApp event_ids',
           (SELECT count(*) - count(DISTINCT event_id) FROM stg.whatsapp_events)
    UNION ALL SELECT 'S17', 'SOURCE_DEFECT', 'DQ-15 accounts whose borrower_id is not in borrowers',
           (SELECT count(*) FROM stg.accounts a
            WHERE NOT EXISTS (SELECT 1 FROM stg.borrowers b WHERE b.borrower_id = a.borrower_id))
)
SELECT check_id, tier, check_name, failing_rows,
       CASE WHEN failing_rows = 0 THEN 'PASS'
            WHEN tier = 'BLOCKING' THEN 'FAIL'
            ELSE 'WARN' END AS status
FROM checks
ORDER BY check_id;
