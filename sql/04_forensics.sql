-- =====================================================================
-- 04_forensics.sql   Part 2: Data Forensics
--
-- Seven hypotheses were posed. Each is tested here with a query that
-- returns evidence, and each is answered CONFIRMED, REFUTED, or
-- INDETERMINATE. A refuted hypothesis is a finding too: it narrows where
-- the real problem can be hiding.
--
-- Every query below is reproducible against the golden layer.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS forensics;

-- ---------------------------------------------------------------------
-- A. DUPLICATE PAYMENTS -- CONFIRMED, but smaller than it first appears
--
-- The naive test (repeated payment_reference) flags 8,042 rows worth
-- ₹60.8 Cr. The correct test (row hash, then payment_id) finds 500. The
-- gap is the trap: payment_reference is not unique in the source system.
-- Deduplicating on it would delete 3,808 genuine payments worth ₹28.9 Cr,
-- 7.5x the ₹3.84 Cr of real duplicates.
-- ---------------------------------------------------------------------
-- payment_ids a naive dedup would drop (every row after the first per
-- reference), minus those whose payment_id is also kept under another row.
CREATE OR REPLACE VIEW forensics.naive_ref_dedup_dropped AS
WITH ranked AS (
    SELECT payment_id, row_number() OVER (
               PARTITION BY payment_reference ORDER BY event_at_naive, payment_id) AS rn
    FROM stg.payments WHERE payment_reference IS NOT NULL
),
kept AS (
    SELECT payment_id FROM ranked WHERE rn = 1
    UNION SELECT payment_id FROM stg.payments WHERE payment_reference IS NULL
)
SELECT DISTINCT payment_id FROM ranked
WHERE rn > 1 AND payment_id NOT IN (SELECT payment_id FROM kept);

CREATE OR REPLACE VIEW forensics.a_duplicate_payments AS
SELECT 'total_rows'                AS measure, count(*)::DOUBLE AS value FROM stg.payments
UNION ALL SELECT 'distinct_payment_id',        count(DISTINCT payment_id)        FROM stg.payments
UNION ALL SELECT 'distinct_payment_reference', count(DISTINCT payment_reference) FROM stg.payments
UNION ALL SELECT 'true_duplicates_by_row_hash',
    (SELECT count(*) - count(DISTINCT _row_hash) FROM stg.payments)
UNION ALL SELECT 'rows_sharing_a_reference',
    (SELECT count(*) FROM stg.payments WHERE payment_reference IN
        (SELECT payment_reference FROM stg.payments GROUP BY 1 HAVING count(*) > 1))
UNION ALL SELECT 'reference_collisions_not_duplicates',
    (SELECT count(*) FROM stg.payments WHERE payment_reference IN
        (SELECT payment_reference FROM stg.payments GROUP BY 1 HAVING count(*) > 1))
    - (SELECT count(*) - count(DISTINCT _row_hash) FROM stg.payments)
UNION ALL SELECT 'rupees_removed_by_correct_dedup',
    (SELECT sum(amount) FROM stg.payments) - (SELECT sum(amount) FROM gold.fct_payment)
UNION ALL SELECT 'rupees_sharing_a_reference',
    (SELECT sum(amount) FROM stg.payments WHERE payment_reference IN
        (SELECT payment_reference FROM stg.payments GROUP BY 1 HAVING count(*) > 1))
-- What a naive dedup actually does: keep one row per payment_reference and
-- drop the rest. Any dropped row whose payment_id survives correct dedup is
-- a genuine payment lost.
UNION ALL SELECT 'genuine_payments_naive_dedup_would_delete',
    (SELECT count(*) FROM gold.fct_payment WHERE payment_id IN (SELECT payment_id FROM forensics.naive_ref_dedup_dropped))
UNION ALL SELECT 'rupees_naive_dedup_would_delete',
    (SELECT sum(amount) FROM gold.fct_payment WHERE payment_id IN (SELECT payment_id FROM forensics.naive_ref_dedup_dropped))
UNION ALL SELECT 'recovered_rupees_naive_dedup_would_delete',
    (SELECT sum(recovered_amount) FROM gold.fct_payment WHERE payment_id IN (SELECT payment_id FROM forensics.naive_ref_dedup_dropped));

-- Evidence: one reference, three unrelated borrowers, three amounts.
CREATE OR REPLACE VIEW forensics.a_collision_example AS
SELECT payment_id, account_id, borrower_id, amount, payment_status, event_at_naive
FROM stg.payments
WHERE payment_reference = (
    SELECT payment_reference FROM stg.payments
    GROUP BY 1 HAVING count(DISTINCT account_id) >= 3 LIMIT 1)
ORDER BY event_at_naive;


-- ---------------------------------------------------------------------
-- B. ATTRIBUTION ERRORS -- CONFIRMED as unmeasurable, which is the finding
--
-- The question is whether payments are being credited to the most recent
-- campaign or interaction. The structural answer: with essentially every
-- targeted account touched on voice, digital and field within the same
-- month, last-touch attribution assigns recovery to whichever channel
-- fires most often. That measures channel VOLUME, not channel EFFECT.
--
-- The query below counts, for each paying account-month, how many
-- distinct channels touched it. If most payers are multi-touch, no
-- single-touch attribution rule is defensible.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW forensics.b_attribution_overlap AS
SELECT
    (CASE WHEN n_calls > 0 THEN 1 ELSE 0 END
     + CASE WHEN n_digital > 0 THEN 1 ELSE 0 END
     + CASE WHEN n_field_visits > 0 THEN 1 ELSE 0 END) AS channels_touching,
    count(*)                                            AS paying_account_months,
    sum(recovered_amount)                               AS recovered_amount
FROM gold.account_month
WHERE recovered_amount > 0
GROUP BY 1 ORDER BY 1;

-- Payments with no preceding interaction at all in the same month.
-- These cannot be attributed to any channel, yet last-touch logic will
-- silently assign them to one.
CREATE OR REPLACE VIEW forensics.b_unattributable_recovery AS
SELECT month,
       sum(recovered_amount) FILTER (WHERE n_calls=0 AND n_digital=0 AND n_field_visits=0) AS untouched_recovery,
       sum(recovered_amount)                                                                AS total_recovery,
       sum(recovered_amount) FILTER (WHERE n_calls=0 AND n_digital=0 AND n_field_visits=0)
         / nullif(sum(recovered_amount), 0)                                                 AS untouched_share
FROM gold.account_month GROUP BY 1 ORDER BY 1;


-- ---------------------------------------------------------------------
-- C. TIMEZONE PROBLEMS -- CONFIRMED
--
-- Three zones are present in the source and the timestamps are naive.
-- The query quantifies how many calls change HOUR bucket and how many
-- change CALENDAR DAY once localised correctly.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW forensics.c_timezone_impact AS
SELECT
    src_timezone,
    count(*)                                                                     AS n_calls,
    count(*) FILTER (WHERE call_hour_ist <> call_hour_uncorrected)                AS hour_bucket_changed,
    count(*) FILTER (WHERE CAST(called_at_ist AS DATE) <> CAST(called_at_raw AS DATE)) AS calendar_day_changed
FROM gold.fct_call GROUP BY 1 ORDER BY 1;


-- ---------------------------------------------------------------------
-- D. VENDOR / DISPOSITION CODE CHANGES -- CONFIRMED
--
-- Three disposition schema versions coexist, and the legacy vocabulary
-- contains two distinct codes ('PTP', 'PROMISE_TO_PAY') for one outcome.
-- Additionally, vendor_telephony carries three schema_versions and a mix
-- of ACTIVE/INACTIVE status with no effective dates.
--
-- Critically: the query also tests WHEN each version appears. If the
-- versions are interleaved rather than sequential, the codes did not
-- "change during the period" -- they were never consistent in the first
-- place, which is a different and worse problem.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW forensics.d_disposition_versions AS
SELECT date_trunc('month', disposed_at_ist) AS month, disposition_version,
       count(*) AS n
FROM gold.fct_disposition GROUP BY 1,2 ORDER BY 1,2;

CREATE OR REPLACE VIEW forensics.d_synonym_codes AS
SELECT disposition_version, disposition_code_raw, disposition_code AS mapped_to, count(*) AS n
FROM gold.fct_disposition
WHERE disposition_code_raw IN ('PTP','PROMISE_TO_PAY')
GROUP BY 1,2,3 ORDER BY 1,2;

CREATE OR REPLACE VIEW forensics.d_vendor_schema AS
SELECT schema_version, status, count(*) AS n_vendors,
       string_agg(DISTINCT vendor_name, ', ') AS vendors
FROM stg.vendor_telephony GROUP BY 1,2 ORDER BY 1,2;


-- ---------------------------------------------------------------------
-- E. AGENT IDENTITY -- CONFIRMED, and the naive fix is worse than the bug
--
-- 30,000 rows, 1,000 agent_id, 1,099 employee_code, 10 agent_name.
-- Resolving on employee_code merges different people (same code, two
-- names). Resolving on name collapses 1,000 agents into 10.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW forensics.e_agent_identity AS
SELECT 'agent_rows'                     AS measure, count(*)::DOUBLE AS value FROM stg.agents
UNION ALL SELECT 'distinct_agent_id',       count(DISTINCT agent_id)      FROM stg.agents
UNION ALL SELECT 'distinct_employee_code',  count(DISTINCT employee_code) FROM stg.agents
UNION ALL SELECT 'distinct_agent_name',     count(DISTINCT agent_name)    FROM stg.agents
UNION ALL SELECT 'employee_codes_with_multiple_names',
    (SELECT count(*) FROM (SELECT employee_code FROM stg.agents
      GROUP BY 1 HAVING count(DISTINCT agent_name) > 1))
UNION ALL SELECT 'agent_ids_with_multiple_employee_codes',
    (SELECT count(*) FROM (SELECT agent_id FROM stg.agents
      GROUP BY 1 HAVING count(DISTINCT employee_code) > 1))
UNION ALL SELECT 'max_versions_per_agent_id',
    (SELECT max(n) FROM (SELECT count(*) n FROM stg.agents GROUP BY agent_id));


-- ---------------------------------------------------------------------
-- F. PORTFOLIO MIX CHANGE -- REFUTED
--
-- If the business had acquired a structurally different book, the mix of
-- loan_type / risk_segment / DPD across paying accounts would shift over
-- time. The query produces the monthly share of each segment; a chi-square
-- test on this table is run in the notebook (risk_segment p=0.215,
-- loan_type p=0.997 -- no detectable shift).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW forensics.f_portfolio_mix AS
SELECT month, dimension, segment, accounts,
       accounts::DOUBLE / sum(accounts) OVER (PARTITION BY month, dimension) AS share
FROM metrics.segment_month
WHERE dimension IN ('risk_segment','loan_type','dpd_bucket')
ORDER BY dimension, segment, month;


-- ---------------------------------------------------------------------
-- G. DENOMINATOR MANIPULATION -- REFUTED (and pre-empted by design)
--
-- Test: are unsuccessful accounts disappearing from the population used
-- to compute conversion? If so, the count of accounts in the targeting
-- base would fall over time while recovery rate rose.
--
-- Result: the targeted base is stable at ~5,500-5,800 accounts/month and
-- tracks calendar days, not performance. Targeting coverage is also
-- near-identical across ACTIVE / PAID / CLOSED / WRITEOFF statuses
-- (~78% each), which is what you would NOT see if bad accounts were
-- being culled.
--
-- Note the golden layer fixes the denominator at all 30,000 accounts, so
-- the published metrics are immune to this failure mode regardless.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW forensics.g_denominator AS
SELECT month,
       count(DISTINCT account_id)                                    AS population,
       count(DISTINCT account_id) FILTER (WHERE n_targeted > 0)      AS targeted,
       count(DISTINCT account_id) FILTER (WHERE n_calls > 0)         AS contacted,
       count(DISTINCT account_id) FILTER (WHERE is_recovering)       AS recovering,
       count(DISTINCT account_id) FILTER (WHERE is_recovering)::DOUBLE
         / count(DISTINCT account_id)                                AS rate_fixed_denominator,
       count(DISTINCT account_id) FILTER (WHERE is_recovering)::DOUBLE
         / nullif(count(DISTINCT account_id) FILTER (WHERE n_calls > 0), 0) AS rate_contacted_denominator
FROM gold.account_month GROUP BY 1 ORDER BY 1;

CREATE OR REPLACE VIEW forensics.g_targeting_by_status AS
SELECT status,
       count(*)                                        AS accounts,
       count(*) FILTER (WHERE was_ever_targeted)       AS targeted,
       count(*) FILTER (WHERE was_ever_targeted)::DOUBLE / count(*) AS coverage
FROM gold.dim_account GROUP BY 1 ORDER BY 1;


-- ---------------------------------------------------------------------
-- H. ADDITIONAL FINDINGS (not on the assignment's list, found anyway)
-- ---------------------------------------------------------------------

-- H1. Call status contradicts call duration in 60% of rows.
CREATE OR REPLACE VIEW forensics.h1_duration_contradiction AS
SELECT call_status, count(*) AS n,
       count(*) FILTER (WHERE duration_sec > 0)  AS with_duration,
       round(avg(duration_sec))                  AS avg_duration_sec
FROM gold.fct_call GROUP BY 1 ORDER BY 2 DESC;

-- H2. Half of status-history rows were "recorded" before the event happened.
CREATE OR REPLACE VIEW forensics.h2_clock_inversion AS
SELECT count(*) AS total_rows,
       count(*) FILTER (WHERE is_clock_inverted) AS recorded_before_event,
       count(*) FILTER (WHERE is_clock_inverted)::DOUBLE / count(*) AS share
FROM gold.fct_status_history;

-- H3. Payments landing on accounts currently flagged CLOSED or WRITEOFF.
CREATE OR REPLACE VIEW forensics.h3_payments_on_dead_accounts AS
SELECT a.status, count(*) AS n_payments, sum(p.recovered_amount) AS recovered_amount
FROM gold.fct_payment p JOIN gold.dim_account a USING (account_id)
GROUP BY 1 ORDER BY 3 DESC;

-- H4. Truncated final month -- the second artefact that corrupts MoM.
CREATE OR REPLACE VIEW forensics.h4_coverage AS
SELECT 'payments' AS tbl, min(event_at_naive) AS first_event, max(event_at_naive) AS last_event, count(*) AS n FROM stg.payments
UNION ALL SELECT 'calls',            min(event_at_naive), max(event_at_naive), count(*) FROM stg.calls
UNION ALL SELECT 'whatsapp_events',  min(event_at_naive), max(event_at_naive), count(*) FROM stg.whatsapp_events
UNION ALL SELECT 'sms_events',       min(event_at_naive), max(event_at_naive), count(*) FROM stg.sms_events
UNION ALL SELECT 'field_visits',     min(event_at_naive), max(event_at_naive), count(*) FROM stg.field_visits
UNION ALL SELECT 'promises_to_pay',  min(event_at_naive), max(event_at_naive), count(*) FROM stg.promises_to_pay
UNION ALL SELECT 'complaints',       min(event_at_naive), max(event_at_naive), count(*) FROM stg.complaints
ORDER BY 1;

-- H5. Missing values that matter operationally.
CREATE OR REPLACE VIEW forensics.h5_nulls AS
SELECT 'calls.agent_id'   AS column_name, count(*) FILTER (WHERE agent_id IS NULL)::DOUBLE AS n_null, count(*) AS n_rows FROM stg.calls
UNION ALL SELECT 'borrowers.phone', count(*) FILTER (WHERE phone IS NULL), count(*) FROM stg.borrowers
UNION ALL SELECT 'borrowers.email', count(*) FILTER (WHERE email IS NULL), count(*) FROM stg.borrowers;

-- H6. Borrower dimension integrity -- the largest single defect found.
-- 30,600 rows, 11,015 ids, 8,468 ids with conflicting identity.
CREATE OR REPLACE VIEW forensics.h6_borrower_identity AS
SELECT 'borrower_rows'        AS measure, count(*)::DOUBLE AS value FROM stg.borrowers
UNION ALL SELECT 'distinct_borrower_id', count(DISTINCT borrower_id) FROM stg.borrowers
UNION ALL SELECT 'ids_with_multiple_rows',
    (SELECT count(*) FROM (SELECT borrower_id FROM stg.borrowers GROUP BY 1 HAVING count(*)>1))
UNION ALL SELECT 'ids_with_conflicting_identity',
    (SELECT count(*) FROM gold.dim_borrower WHERE has_conflicting_identity)
UNION ALL SELECT 'max_versions_per_borrower_id',
    (SELECT max(n_versions) FROM gold.dim_borrower)
UNION ALL SELECT 'account_rows_if_joined_naively',
    (SELECT count(*) FROM stg.accounts a JOIN stg.borrowers b USING (borrower_id))
UNION ALL SELECT 'account_rows_after_resolution',
    (SELECT count(*) FROM gold.dim_account);
