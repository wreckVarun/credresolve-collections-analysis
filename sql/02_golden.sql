-- =====================================================================
-- 02_golden.sql   Staging -> Clean -> Golden
--
-- This file contains every judgement call in the pipeline. Each block
-- states the decision, the evidence for it, and what would change if the
-- decision were wrong. Read the comments; they are the deliverable as
-- much as the SQL is.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS gold;

-- ---------------------------------------------------------------------
-- DECISION 1: Timezone normalisation -> Asia/Kolkata
--
-- accounts, calls, agent_sessions and vendor_telephony each carry a
-- `timezone` column with a mix of UTC, Asia/Kolkata and Asia/Dubai. The
-- timestamps themselves are naive: no offset is encoded. The only
-- coherent reading is that each row's clock was recorded *in* the stated
-- zone. So we localise to the stated zone, then convert to Asia/Kolkata,
-- which is where the collections floor operates and the only zone in
-- which "calling hour" means anything to the business.
--
-- Impact: a row stamped 04:00 UTC is 09:30 IST. Left uncorrected, ~1/3
-- of calls land in the wrong hour bucket and roughly 1 in 25 lands on
-- the wrong calendar day. Every "best time to call" and every daily
-- series is wrong without this step.
--
-- Event tables with no timezone column (payments, whatsapp, sms, field
-- visits, PTPs, complaints, status history) are ASSUMED Asia/Kolkata.
-- This is an assumption, not a finding -- see the data quality report.
-- ---------------------------------------------------------------------
CREATE OR REPLACE MACRO to_ist(ts, tz) AS
    CAST(ts AT TIME ZONE COALESCE(tz, 'Asia/Kolkata') AT TIME ZONE 'Asia/Kolkata' AS TIMESTAMP);


-- ---------------------------------------------------------------------
-- DECISION 2: Agent entity resolution -> agent_id is the key
--
-- The agents table has 30,000 rows, 1,000 distinct agent_id, 1,099
-- distinct employee_code and only 10 distinct agent_name. It is a
-- slowly-changing dimension delivered without a version flag: each
-- agent_id appears up to 35 times with different updated_at values.
--
-- The obvious move -- resolve identity on employee_code, or on name --
-- is wrong here, and provably so:
--   * the same employee_code maps to multiple different agent_names
--     (EMP00900 covers both "Amit Kumar" and "Ananya Rao"), so the code
--     is not a stable person key;
--   * there are only 10 distinct names across 1,000 agents, so merging
--     on name would collapse the workforce ~100:1 and manufacture
--     enormous fake per-agent recovery numbers.
--
-- We therefore treat agent_id as the entity and take the latest row per
-- agent_id by updated_at as the current dimension record. employee_code
-- is retained as an attribute, explicitly flagged unreliable.
--
-- If this is wrong: per-agent metrics are the affected surface. Portfolio
-- level recovery is unchanged, because payments never join through agents.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE gold.dim_agent AS
WITH ranked AS (
    SELECT *,
           row_number() OVER (PARTITION BY agent_id ORDER BY updated_at DESC, joined_at DESC) AS rn,
           count(*)     OVER (PARTITION BY agent_id) AS n_versions,
           count(DISTINCT employee_code) OVER (PARTITION BY agent_id) AS n_emp_codes
    FROM stg.agents
)
SELECT agent_id, employee_code, agent_name, vendor_id, team, status,
       joined_at, updated_at AS effective_at,
       n_versions, n_emp_codes,
       (n_emp_codes > 1) AS has_ambiguous_employee_code
FROM ranked
WHERE rn = 1;


-- ---------------------------------------------------------------------
-- DECISION 3: Payment deduplication -> hash-identical rows only
--
-- This is the single most consequential decision in the analysis, and
-- the one most likely to be got wrong.
--
-- payments has 25,500 rows but only 25,000 distinct payment_id and only
-- 20,821 distinct payment_reference. It is tempting to treat every
-- repeated payment_reference as a duplicate and drop 3,746 rows. That
-- would be a serious error.
--
-- Inspection shows two structurally different phenomena:
--   (a) 500 rows that are byte-identical across every column, including
--       payment_id. These are genuine ingestion replays. Drop them.
--   (b) ~3,250 rows that share a payment_reference but differ in
--       payment_id, account_id, amount and timestamp. TXN0000000032
--       appears against three different borrowers for three different
--       amounts. These are reference-space collisions from a provider
--       whose reference is not globally unique -- not duplicate money.
--       Dropping them would erase ~₹4 Cr of real recovery.
--
-- Rule: deduplicate on the full row hash. Retain reference collisions
-- and flag them. Payment_reference is demoted from key to attribute.
--
-- Quantified impact: -500 rows, -₹0.36 Cr gross.
-- ---------------------------------------------------------------------
-- Deduplication runs in TWO stages, because there are two distinct
-- duplication mechanisms and stage 1 alone catches only 486 of 500:
--
--   Stage 1 -- byte-identical replays (486 rows). Same everything.
--   Stage 2 -- ingestion races (14 rows). Same payment_id, same account,
--              same amount, same timestamp, but one copy landed BEFORE
--              the provider reference was attached and carries a NULL
--              payment_reference. The row hashes differ, so stage 1 lets
--              both through. Keep the enriched copy.
--
-- Together: exactly 500 rows removed, reconciling with the 500 repeated
-- payment_ids. Getting stage 2 wrong leaves ₹0.01 Cr of phantom recovery
-- and, more importantly, leaves a duplicate primary key in the fact table.
CREATE OR REPLACE TABLE gold.fct_payment AS
WITH stage1 AS (   -- byte-identical replays
    SELECT *, row_number() OVER (PARTITION BY _row_hash ORDER BY _ingested_at) AS rn
    FROM stg.payments
),
stage2 AS (        -- ingestion races on the same payment_id
    SELECT *, row_number() OVER (
                 PARTITION BY payment_id
                 ORDER BY CASE WHEN payment_reference IS NULL THEN 1 ELSE 0 END,
                          payment_reference
             ) AS rn2
    FROM stage1 WHERE rn = 1
),
flagged AS (
    SELECT d.* EXCLUDE (rn, rn2),
           count(*) OVER (PARTITION BY d.payment_reference) AS ref_multiplicity
    FROM stage2 d
    WHERE rn2 = 1
)
SELECT
    payment_id,
    account_id,
    borrower_id,
    event_at_naive                       AS paid_at_ist,   -- no tz column; assumed IST
    date_trunc('month', event_at_naive)  AS paid_month,
    CAST(event_at_naive AS DATE)         AS paid_date,
    payment_reference,
    amount,
    payment_status,
    payment_method,
    provider_id,
    ref_multiplicity,
    (ref_multiplicity > 1)               AS is_reference_collision,
    -- DECISION 4: what counts as recovered money.
    -- Only SUCCESS is money in the bank. FAILED, PENDING and REVERSED are
    -- not recovery. The business's headline appears to count payment rows
    -- irrespective of status: 7,620 of 25,000 rows (30.5%) are non-SUCCESS,
    -- and including them inflates monthly recovery by ~45%.
    (payment_status = 'SUCCESS')         AS is_recovered,
    CASE WHEN payment_status = 'SUCCESS' THEN amount ELSE 0 END AS recovered_amount
FROM flagged;


-- ---------------------------------------------------------------------
-- DECISION 5: Disposition code harmonisation
--
-- call_dispositions carries three schema generations (legacy / v1 / v2)
-- in roughly equal thirds, and the legacy vocabulary contains BOTH
-- 'PTP' and 'PROMISE_TO_PAY' as separate codes for the same outcome.
-- Any contact-rate or PTP-rate computed without harmonising will
-- undercount PTPs by roughly half in the legacy period.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE gold.fct_disposition AS
SELECT
    disposition_id, account_id, borrower_id, call_id, agent_id,
    event_at_naive AS disposed_at_ist,
    disposition_version,
    disposition_code_raw,
    CASE disposition_code_raw
        WHEN 'PTP'            THEN 'PROMISE_TO_PAY'
        WHEN 'PROMISE_TO_PAY' THEN 'PROMISE_TO_PAY'
        WHEN 'PTP_BROKEN'     THEN 'PROMISE_BROKEN'
        WHEN 'NO_CONTACT'     THEN 'NO_CONTACT'
        WHEN 'WRONG_NUMBER'   THEN 'WRONG_NUMBER'
        WHEN 'CALLBACK'       THEN 'CALLBACK'
        WHEN 'DISPUTE'        THEN 'DISPUTE'
        WHEN 'REFUSED'        THEN 'REFUSED'
        WHEN 'PAID'           THEN 'PAID'
        ELSE 'UNMAPPED'
    END AS disposition_code,
    -- Right-party contact: the borrower was actually reached and engaged.
    -- WRONG_NUMBER and NO_CONTACT are connections, not contacts.
    (CASE disposition_code_raw
        WHEN 'PTP' THEN 1 WHEN 'PROMISE_TO_PAY' THEN 1 WHEN 'PTP_BROKEN' THEN 1
        WHEN 'DISPUTE' THEN 1 WHEN 'REFUSED' THEN 1 WHEN 'PAID' THEN 1
        WHEN 'CALLBACK' THEN 1 ELSE 0 END) = 1 AS is_rpc
FROM stg.call_dispositions;


-- ---------------------------------------------------------------------
-- DECISION 6: Calls -- timezone corrected, contradictions flagged
--
-- 54,902 of 91,350 call rows (60%) carry a non-zero duration while
-- reporting a status of NO_ANSWER, BUSY or FAILED. A call that was never
-- answered cannot have 450 seconds of talk time. Either the status is
-- wrong or the duration is telco-side ring/session time rather than talk
-- time.
--
-- VOICEMAIL is deliberately EXCLUDED from the contradiction flag. A
-- voicemail that was left legitimately has a recording length, so a
-- non-zero duration on a VOICEMAIL row is expected behaviour, not a
-- defect. Including it would overstate the contradiction rate as 80%
-- rather than the true 60% and would flag 18,217 correct rows as broken.
--
-- We do not silently pick a side on the genuine contradiction.
-- duration_sec is excluded from any productivity metric and the conflict
-- is surfaced as a flag, because resolving it requires a conversation
-- with the telephony vendor, not a CASE statement. Connect rate is
-- computed from call_status alone.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE gold.fct_call AS
SELECT
    c.call_id, c.account_id, c.borrower_id, c.agent_id, c.campaign_id,
    c.vendor_id, c.direction, c.call_status,
    to_ist(c.event_at_naive, c.src_timezone) AS called_at_ist,
    c.event_at_naive                          AS called_at_raw,
    c.src_timezone,
    extract(hour FROM to_ist(c.event_at_naive, c.src_timezone))  AS call_hour_ist,
    extract(hour FROM c.event_at_naive)                          AS call_hour_uncorrected,
    c.duration_sec,
    (c.call_status = 'ANSWERED')                                 AS is_connected,
    (c.call_status IN ('NO_ANSWER','BUSY','FAILED')
      AND c.duration_sec > 0)                                    AS has_duration_contradiction,
    (c.agent_id IS NULL)                                         AS is_unattributed_agent
FROM stg.calls c;


-- ---------------------------------------------------------------------
-- DECISION 7: Account status history -- late-arriving vs impossible
--
-- 30,191 of 60,000 rows (50.3%) have recorded_at EARLIER than event_at:
-- the system claims to have written the record before the event occurred.
-- These are not late-arriving events (which would be the reverse). They
-- are a broken clock or a column swap at source.
--
-- We keep the rows -- the status transitions themselves look plausible --
-- but we use event_at as the effective time and flag the inversion. No
-- SCD is built on recorded_at, because recorded_at cannot be trusted for
-- ordering.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE gold.fct_status_history AS
SELECT
    history_id, account_id, borrower_id,
    event_at_naive AS status_at_ist,
    status, changed_by, source, recorded_at,
    (recorded_at < event_at_naive) AS is_clock_inverted,
    row_number() OVER (PARTITION BY account_id ORDER BY event_at_naive) AS status_seq
FROM stg.account_status_history;


-- ---------------------------------------------------------------------
-- DECISION 8: The account population (the denominator)
--
-- Denominator manipulation is the classic way to manufacture a conversion
-- improvement: drop non-performing accounts from the base. We therefore
-- fix the denominator to ALL 30,000 accounts and carry a targeting flag
-- rather than filtering. 23,344 accounts (77.8%) appear in daily_targeting;
-- the untargeted 6,656 remain in the population.
--
-- Note: 12,775 payments land on accounts whose current status is CLOSED or
-- WRITEOFF. Because accounts carries only a current status and no
-- effective-dating, we cannot tell whether the payment preceded the
-- write-off (normal) or followed it (an accounting problem). Flagged, not
-- excluded.
-- ---------------------------------------------------------------------
-- ---------------------------------------------------------------------
-- DECISION 8a: Borrower identity is NOT reliable. Geography is suppressed.
--
-- borrowers.csv has 30,600 rows but only 11,015 distinct borrower_id.
-- 8,518 of those ids carry CONFLICTING rows -- not replays, genuinely
-- different people. BRW0001072 appears as "Aarav Sharma" in Chennai and
-- as "Rahul Verma" in Bhubaneswar, with different phones and emails,
-- across four records. Up to 11 versions exist for a single id.
--
-- Two consequences, and the second is the important one:
--
--   1. Joining accounts to borrowers naively fans the 30,000-row account
--      dimension out to 78,514 rows and inflates every downstream sum by
--      ~2.6x. Any analysis that joins borrower attributes without
--      collapsing first is silently wrong by a factor of three.
--
--   2. The assignment asks for a geography breakdown. We can produce one,
--      but we should not trust it. City and state are borrower attributes,
--      and borrower identity is broken, so geography is carried into the
--      golden layer FLAGGED as low-confidence and is excluded from the
--      investment recommendation. Reporting a state-level finding from
--      this column would be the most plausible-looking wrong answer
--      available in this dataset.
--
-- We collapse to one row per borrower_id (latest updated_at) so the join
-- is safe, and carry n_conflicting_versions so the flag travels with the
-- data rather than living in a footnote.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE gold.dim_borrower AS
WITH ranked AS (
    SELECT *,
           row_number() OVER (PARTITION BY borrower_id ORDER BY updated_at DESC) AS rn,
           count(*) OVER (PARTITION BY borrower_id) AS n_versions,
           count(DISTINCT name) OVER (PARTITION BY borrower_id) AS n_names,
           count(DISTINCT state) OVER (PARTITION BY borrower_id) AS n_states
    FROM stg.borrowers
)
SELECT borrower_id, name, phone, email, city, state, created_at, updated_at,
       n_versions, n_names, n_states,
       (n_names > 1 OR n_states > 1) AS has_conflicting_identity
FROM ranked WHERE rn = 1;

CREATE OR REPLACE TABLE gold.dim_account AS
SELECT
    a.account_id, a.borrower_id, a.loan_type, a.principal_amount,
    a.outstanding_amount, a.dpd, a.risk_segment, a.status,
    to_ist(a.opened_at_naive, a.src_timezone) AS opened_at_ist,
    a.src_timezone, a.schema_version,
    CASE
        WHEN a.dpd <  30 THEN '0-29'
        WHEN a.dpd <  60 THEN '30-59'
        WHEN a.dpd <  90 THEN '60-89'
        WHEN a.dpd < 120 THEN '90-119'
        ELSE '120+'
    END AS dpd_bucket,
    (t.account_id IS NOT NULL) AS was_ever_targeted,
    b.city, b.state,
    COALESCE(b.has_conflicting_identity, TRUE) AS geography_is_unreliable
FROM stg.accounts a
LEFT JOIN (SELECT DISTINCT account_id FROM stg.daily_targeting) t USING (account_id)
LEFT JOIN gold.dim_borrower b USING (borrower_id);


-- ---------------------------------------------------------------------
-- GOLDEN: account-month grain
--
-- One row per account per month. This is the analytical spine: it fixes
-- the denominator, so every rate computed from it is immune to accounts
-- silently leaving the population.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE gold.account_month AS
WITH months AS (
    SELECT DISTINCT paid_month AS month FROM gold.fct_payment
    WHERE paid_month < DATE '2026-08-01'          -- August is a partial month; see DECISION 9
),
spine AS (
    SELECT a.account_id, m.month FROM gold.dim_account a CROSS JOIN months m
),
pay AS (
    SELECT account_id, paid_month AS month,
           sum(recovered_amount)                        AS recovered_amount,
           count(*) FILTER (WHERE is_recovered)         AS n_success,
           count(*)                                     AS n_payment_rows
    FROM gold.fct_payment GROUP BY 1,2
),
cal AS (
    SELECT account_id, date_trunc('month', called_at_ist) AS month,
           count(*)                              AS n_calls,
           count(*) FILTER (WHERE is_connected)  AS n_connected
    FROM gold.fct_call GROUP BY 1,2
),
disp AS (
    SELECT account_id, date_trunc('month', disposed_at_ist) AS month,
           count(*) FILTER (WHERE is_rpc)                             AS n_rpc,
           count(*) FILTER (WHERE disposition_code='PROMISE_TO_PAY')  AS n_ptp_disp
    FROM gold.fct_disposition GROUP BY 1,2
),
ptp AS (
    SELECT account_id, date_trunc('month', event_at_naive) AS month,
           count(*)                                   AS n_ptp,
           count(*) FILTER (WHERE status='KEPT')      AS n_ptp_kept,
           sum(promised_amount)                       AS promised_amount
    FROM stg.promises_to_pay GROUP BY 1,2
),
tgt AS (
    SELECT account_id, date_trunc('month', target_date) AS month,
           count(*) AS n_targeted, avg(priority) AS avg_priority
    FROM stg.daily_targeting GROUP BY 1,2
),
dig AS (
    SELECT account_id, month, sum(n) AS n_digital FROM (
        SELECT account_id, date_trunc('month', event_at_naive) AS month, count(*) n
        FROM stg.whatsapp_events GROUP BY 1,2
        UNION ALL
        SELECT account_id, date_trunc('month', event_at_naive), count(*)
        FROM stg.sms_events GROUP BY 1,2
    ) GROUP BY 1,2
),
fld AS (
    SELECT account_id, date_trunc('month', event_at_naive) AS month, count(*) AS n_field_visits
    FROM stg.field_visits GROUP BY 1,2
)
SELECT
    s.account_id, s.month,
    a.loan_type, a.risk_segment, a.dpd_bucket, a.status AS account_status,
    a.outstanding_amount, a.state, a.was_ever_targeted,
    day(last_day(s.month))                        AS calendar_days,   -- DECISION 9
    COALESCE(p.recovered_amount, 0)               AS recovered_amount,
    COALESCE(p.n_success, 0)                      AS n_success,
    COALESCE(p.n_payment_rows, 0)                 AS n_payment_rows,
    COALESCE(c.n_calls, 0)                        AS n_calls,
    COALESCE(c.n_connected, 0)                    AS n_connected,
    COALESCE(d.n_rpc, 0)                          AS n_rpc,
    COALESCE(pp.n_ptp, 0)                         AS n_ptp,
    COALESCE(pp.n_ptp_kept, 0)                    AS n_ptp_kept,
    COALESCE(pp.promised_amount, 0)               AS promised_amount,
    COALESCE(t.n_targeted, 0)                     AS n_targeted,
    t.avg_priority,
    COALESCE(g.n_digital, 0)                      AS n_digital,
    COALESCE(f.n_field_visits, 0)                 AS n_field_visits,
    (COALESCE(p.recovered_amount,0) > 0)          AS is_recovering
FROM spine s
JOIN gold.dim_account a USING (account_id)
LEFT JOIN pay  p  ON p.account_id  = s.account_id AND p.month  = s.month
LEFT JOIN cal  c  ON c.account_id  = s.account_id AND c.month  = s.month
LEFT JOIN disp d  ON d.account_id  = s.account_id AND d.month  = s.month
LEFT JOIN ptp  pp ON pp.account_id = s.account_id AND pp.month = s.month
LEFT JOIN tgt  t  ON t.account_id  = s.account_id AND t.month  = s.month
LEFT JOIN dig  g  ON g.account_id  = s.account_id AND g.month  = s.month
LEFT JOIN fld  f  ON f.account_id  = s.account_id AND f.month  = s.month;


-- ---------------------------------------------------------------------
-- DECISION 9: August 2026 is excluded from all trend analysis
--
-- Every event table stops between 8 and 12 August 2026. August therefore
-- contains ~26% of a month's volume. Any month-on-month comparison that
-- includes it reports a ~74% collapse that did not happen. It is retained
-- in the golden layer but excluded from the trend series, and the
-- dashboard shows it hatched as partial.
-- ---------------------------------------------------------------------
