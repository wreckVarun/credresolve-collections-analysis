-- =====================================================================
-- 05_drivers.sql   Question 2: "Why did it happen?"
--
-- The brief lists thirteen dimensions to investigate at minimum. This file
-- works through the ones that exist in the data, and states plainly which
-- ones do not exist and which are unanswerable because of a data defect.
--
-- Since the answer to "what happened" is "nothing", the purpose of these
-- queries is inverted: they exist to rule out the possibility that a real
-- movement is hiding inside a flat aggregate. Every one of them comes back
-- flat, which is the finding.
--
--   Portfolio mix ....... tested, stable          (04_forensics.sql, F)
--   DPD ................. tested, stable          (metrics.segment_month)
--   Client .............. NO SUCH COLUMN in any of the 17 tables
--   Geography ........... UNRELIABLE - borrower identity broken (DQ-01)
--   Language ............ NO SUCH COLUMN in any of the 17 tables
--   Agent ............... UNANSWERABLE - identity unrecoverable (DQ-02)
--   Agent tenure ........ UNANSWERABLE - same defect
--   Campaign ............ tested below
--   Channel ............. tested, unmeasurable   (04_forensics.sql, B)
--   Telephony vendor .... tested below
--   Calling time ........ tested below
--   Attempt frequency ... tested below
--   Borrower segment .... tested, stable          (metrics.segment_month)
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS drivers;

-- ---------------------------------------------------------------------
-- D1. ATTEMPT FREQUENCY
--
-- The operational question behind this: is there a dose-response? Does
-- calling an account more times recover more money? If dialling intensity
-- had risen, that could explain a performance change.
--
-- Result: NO dose-response, and the sign is mildly negative. Accounts
-- reaching 6-9 attempts pay at 7.7%, accounts capped at 1-2 attempts pay
-- at 7.9%. Mean recovery per account-month is flat (₹5,973-6,074) across
-- every band.
--
-- Read carefully: this does NOT mean calling does not work. Attempt count
-- is endogenous -- accounts get called more BECAUSE they have not paid, so
-- high-attempt accounts are selected for being hard to collect. The honest
-- statement is that this data cannot separate dose from selection, and a
-- randomised contact-intensity test would be needed to.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW drivers.attempt_frequency AS
WITH att AS (
    SELECT account_id, date_trunc('month', event_at_naive) AS month,
           max(attempt_no) AS max_attempt, count(*) AS n_attempts
    FROM stg.call_attempts GROUP BY 1,2
)
SELECT
    CASE WHEN a.max_attempt <= 2 THEN '1-2'
         WHEN a.max_attempt <= 5 THEN '3-5'
         WHEN a.max_attempt <= 9 THEN '6-9'
         ELSE '10+' END                                      AS attempt_band,
    count(*)                                                 AS account_months,
    round(avg(am.recovered_amount))                          AS avg_recovery,
    round(100 * avg(CASE WHEN am.recovered_amount > 0 THEN 1.0 ELSE 0 END), 2) AS pct_paying
FROM att a
JOIN gold.account_month am ON a.account_id = am.account_id AND a.month = am.month
GROUP BY 1 ORDER BY 1;


-- ---------------------------------------------------------------------
-- D2. TELEPHONY VENDOR
--
-- Hypothesis: a vendor switch changed connect rates and therefore recovery.
--
-- Result: REFUTED. All 15 vendors are live in every month from January
-- onward -- there is no switch to find. Connect rate by vendor spans
-- 19.45% to 20.71%, a range of 1.3 percentage points across five vendor
-- brands. Monthly aggregate connect rate holds between 19.31% and 20.47%.
--
-- Caveat on the vendor dimension itself: vendor_telephony carries three
-- schema_versions and an ACTIVE/INACTIVE flag with no effective dates, so
-- "which vendors were live when" is not actually recorded. We infer it from
-- call traffic instead, which is the more reliable signal.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW drivers.vendor_performance AS
SELECT
    v.vendor_name,
    count(*)                                                          AS n_calls,
    count(DISTINCT c.vendor_id)                                       AS n_vendor_ids,
    round(100.0 * count(*) FILTER (WHERE c.is_connected) / count(*), 2) AS connect_pct
FROM gold.fct_call c
JOIN stg.vendor_telephony v USING (vendor_id)
GROUP BY 1 ORDER BY 2 DESC;

CREATE OR REPLACE VIEW drivers.vendor_month AS
SELECT date_trunc('month', called_at_ist) AS month,
       count(DISTINCT vendor_id)                                       AS active_vendors,
       count(*)                                                        AS n_calls,
       round(100.0 * count(*) FILTER (WHERE is_connected) / count(*), 2) AS connect_pct
FROM gold.fct_call
WHERE called_at_ist >= DATE '2026-01-01' AND called_at_ist < DATE '2026-08-01'
GROUP BY 1 ORDER BY 1;


-- ---------------------------------------------------------------------
-- D3. CALLING TIME
--
-- Uses the TIMEZONE-CORRECTED hour. Without the correction (DQ-07), 67% of
-- calls sit in the wrong hour bucket and this analysis would be fiction.
--
-- Result: connect rate is 19-21% at EVERY hour of the day, including 03:00
-- and 04:00 IST. That is not a plausible collections floor -- a real
-- operation shows a pronounced daytime peak and a night-time collapse. The
-- flatness is itself evidence that call timestamps are close to uniformly
-- random, which is a caution about the dataset rather than a finding about
-- the business.
--
-- Consequence: no "best time to call" recommendation can be made. Doing so
-- would dress up noise as an operational insight.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW drivers.calling_time AS
SELECT call_hour_ist                                                    AS hour_ist,
       count(*)                                                         AS n_calls,
       round(100.0 * count(*) FILTER (WHERE is_connected) / count(*), 2) AS connect_pct
FROM gold.fct_call GROUP BY 1 ORDER BY 1;


-- ---------------------------------------------------------------------
-- D4. COHORT / VINTAGE EFFECTS  (Part 3 requirement)
--
-- Hypothesis: newer account vintages behave differently from older ones,
-- and a change in the vintage mix could move aggregate recovery without any
-- operational change. This is the classic cohort confound.
--
-- Result: REFUTED on both legs.
--   * 2024 and 2025 vintages recover at ₹6,030 and ₹6,052 per account-month
--     and pay at 7.70% and 7.77%. Indistinguishable.
--   * The vintage mix among paying accounts is stable across months
--     (chi-square p = 0.126, computed in the notebook).
--
-- Note the accounts table spans opening dates from Jan 2024 to Nov 2025,
-- while all events fall in 2026. So every account is seasoned before the
-- observation window opens, and there are no true new-origination cohorts
-- entering mid-period.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW drivers.cohort_vintage AS
WITH coh AS (
    SELECT account_id,
           date_part('year', opened_at_ist)   AS vintage_year,
           date_trunc('month', opened_at_ist) AS vintage_month
    FROM gold.dim_account
)
SELECT c.vintage_year,
       count(DISTINCT am.account_id)                                            AS accounts,
       round(avg(am.recovered_amount))                                          AS avg_recovery,
       round(100 * avg(CASE WHEN am.recovered_amount > 0 THEN 1.0 ELSE 0 END), 2) AS pct_paying
FROM gold.account_month am JOIN coh c USING (account_id)
GROUP BY 1 ORDER BY 1;

CREATE OR REPLACE VIEW drivers.cohort_mix_month AS
WITH coh AS (SELECT account_id, date_part('year', opened_at_ist) AS vintage_year
             FROM gold.dim_account)
SELECT am.month, c.vintage_year, count(*) AS paying_accounts
FROM gold.account_month am JOIN coh c USING (account_id)
WHERE am.recovered_amount > 0
GROUP BY 1,2 ORDER BY 1,2;


-- ---------------------------------------------------------------------
-- D5. CAMPAIGN
--
-- Result: campaign definitions are internally inconsistent. The same
-- strategy_version carries different target_definition rules, and
-- campaign_name does not match channel -- 'DIGITAL_FOLLOWUP' is recorded
-- against channel FIELD. Campaigns also stop starting in May while calling
-- continues at full volume through July.
--
-- Consequence: campaign is not usable as an explanatory dimension, and this
-- is the same defect that prevents the Part 4 counterfactual from being
-- identified.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW drivers.campaign_consistency AS
SELECT strategy_version,
       count(*)                             AS n_campaigns,
       count(DISTINCT target_definition)    AS distinct_target_rules,
       count(DISTINCT channel)              AS distinct_channels,
       min(start_at)                        AS first_start,
       max(start_at)                        AS last_start
FROM stg.campaigns GROUP BY 1 ORDER BY 1;

CREATE OR REPLACE VIEW drivers.campaign_name_channel_mismatch AS
SELECT campaign_name, channel, count(*) AS n
FROM stg.campaigns GROUP BY 1,2 ORDER BY 1,2;
