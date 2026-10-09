-- =====================================================================
-- 03_metrics.sql   Golden -> Metrics
--
-- Independent definitions of collections performance. Each metric states
-- what it measures, what its denominator is, and why that denominator is
-- the honest one. Where our definition differs from the one the business
-- appears to use, the difference is named.
--
-- The organising principle: every rate is computed over a FIXED
-- denominator (all accounts, or all calendar days), never over a
-- self-selected one. A denominator that can shrink is a denominator that
-- can be gamed.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS metrics;

-- ---------------------------------------------------------------------
-- METRIC 1: Recovery per calendar day  (the headline metric)
--
-- Total recovered rupees divided by the number of days in the month.
--
-- Why: monthly totals are not comparable to each other. February has 28
-- days and March has 31 -- a 10.7% difference in operating days before
-- anyone does any work. Comparing raw monthly totals means the calendar
-- generates a ±11% swing that is indistinguishable from performance.
-- This is precisely the artefact behind the reported improvement.
--
-- This metric is the single most important correction in the analysis.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW metrics.monthly_recovery AS
WITH m AS (
    SELECT
        month,
        max(calendar_days)                          AS calendar_days,
        sum(recovered_amount)                       AS recovered_amount,
        count(DISTINCT account_id)                  AS accounts_in_population,
        count(DISTINCT account_id) FILTER (WHERE is_recovering)  AS accounts_recovering,
        sum(n_calls)      AS n_calls,
        sum(n_connected)  AS n_connected,
        sum(n_rpc)        AS n_rpc,
        sum(n_ptp)        AS n_ptp,
        sum(n_ptp_kept)   AS n_ptp_kept,
        sum(n_targeted)   AS n_targeted
    FROM gold.account_month
    GROUP BY 1
)
SELECT
    month,
    calendar_days,
    recovered_amount,
    recovered_amount / calendar_days                      AS recovery_per_day,
    accounts_in_population,
    accounts_recovering,
    -- METRIC 2: Recovery rate. Denominator is the FULL account population,
    -- not the targeted subset and not the contacted subset. Fixing it here
    -- is what makes the series immune to denominator manipulation.
    accounts_recovering::DOUBLE / accounts_in_population  AS recovery_rate,
    -- METRIC 3: Recovery per account in population (not per recovering
    -- account -- that ratio rises whenever you contact fewer people).
    recovered_amount / accounts_in_population             AS recovery_per_account,
    -- METRIC 4: Connect rate. Answered calls / all call attempts.
    -- Distinguished from contact rate below: connecting is not reaching.
    n_connected::DOUBLE / nullif(n_calls, 0)              AS connect_rate,
    -- METRIC 5: Right-party contact rate. Dispositions indicating the
    -- borrower actually engaged, over all calls. Excludes WRONG_NUMBER
    -- and NO_CONTACT, which the business's "contact rate" appears to
    -- include -- that inflates contact by roughly a third.
    n_rpc::DOUBLE / nullif(n_calls, 0)                    AS rpc_rate,
    -- METRIC 6: PTP rate over RPC, not over calls. A promise can only be
    -- obtained from someone you actually spoke to; dividing by all calls
    -- makes the metric move whenever dialling volume moves.
    n_ptp::DOUBLE / nullif(n_rpc, 0)                      AS ptp_rate,
    -- METRIC 7: PTP kept rate. Kept promises over promises made.
    n_ptp_kept::DOUBLE / nullif(n_ptp, 0)                 AS ptp_kept_rate,
    -- Month-on-month, computed both ways. The gap between these two
    -- columns is the entire finding of this analysis.
    100 * (recovered_amount
           / lag(recovered_amount) OVER (ORDER BY month) - 1) AS mom_pct_naive,
    100 * ((recovered_amount / calendar_days)
           / lag(recovered_amount / calendar_days) OVER (ORDER BY month) - 1) AS mom_pct_per_day
FROM m
ORDER BY month;


-- ---------------------------------------------------------------------
-- METRIC 8: Recovery per agent-hour
--
-- Productivity, normalised for staffing. Uses logged session hours rather
-- than headcount, because headcount does not account for shift length.
-- Deliberately does NOT use call duration_sec: 60% of call rows carry a
-- duration that contradicts their status (see DECISION 6), so any
-- duration-based productivity metric is built on a broken column.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW metrics.productivity AS
WITH hrs AS (
    SELECT date_trunc('month', login_at_naive) AS month,
           sum(date_diff('minute', login_at_naive, logout_at_naive)) / 60.0 AS agent_hours,
           count(DISTINCT agent_id) AS active_agents
    FROM stg.agent_sessions
    GROUP BY 1
)
SELECT r.month, r.recovered_amount, h.agent_hours, h.active_agents,
       r.recovered_amount / nullif(h.agent_hours, 0)   AS recovery_per_agent_hour,
       h.agent_hours / nullif(h.active_agents, 0)      AS hours_per_agent
FROM metrics.monthly_recovery r
JOIN hrs h USING (month)
ORDER BY month;


-- ---------------------------------------------------------------------
-- METRIC 9: Channel view
--
-- Contact volume and associated recovery by channel. Attribution here is
-- deliberately NOT last-touch. See 04_forensics.sql section B for why
-- last-touch attribution on this dataset is meaningless: with every
-- account touched on multiple channels every month, last-touch assigns
-- recovery to whichever channel happens to fire most often, which is a
-- measure of channel volume, not channel effectiveness.
--
-- We report channel volume and account-level co-occurrence, and refuse to
-- report a channel conversion rate, because the data does not support one.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW metrics.channel_month AS
SELECT
    month,
    sum(n_calls)                        AS voice_touches,
    sum(n_digital)                      AS digital_touches,
    sum(n_field_visits)                 AS field_touches,
    sum(recovered_amount)               AS recovered_amount,
    sum(recovered_amount) FILTER (WHERE n_calls > 0        AND n_digital = 0 AND n_field_visits = 0) AS recovery_voice_only,
    sum(recovered_amount) FILTER (WHERE n_calls = 0        AND n_digital > 0 AND n_field_visits = 0) AS recovery_digital_only,
    sum(recovered_amount) FILTER (WHERE n_calls = 0        AND n_digital = 0 AND n_field_visits > 0) AS recovery_field_only,
    sum(recovered_amount) FILTER (WHERE n_calls = 0        AND n_digital = 0 AND n_field_visits = 0) AS recovery_no_touch,
    count(*) FILTER (WHERE n_calls = 0 AND n_digital = 0 AND n_field_visits = 0 AND recovered_amount > 0) AS accounts_paid_untouched
FROM gold.account_month
GROUP BY 1 ORDER BY 1;


-- ---------------------------------------------------------------------
-- METRIC 10: Segment cuts, for the mix-effect investigation.
-- Long format so one view drives every breakdown on the dashboard.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW metrics.segment_month AS
SELECT month, 'risk_segment' AS dimension, risk_segment AS segment,
       sum(recovered_amount) AS recovered_amount,
       max(calendar_days)    AS calendar_days,
       sum(recovered_amount) / max(calendar_days) AS recovery_per_day,
       count(DISTINCT account_id) AS accounts
FROM gold.account_month GROUP BY 1,2,3
UNION ALL
SELECT month, 'dpd_bucket', dpd_bucket, sum(recovered_amount), max(calendar_days),
       sum(recovered_amount)/max(calendar_days), count(DISTINCT account_id)
FROM gold.account_month GROUP BY 1,2,3
UNION ALL
SELECT month, 'loan_type', loan_type, sum(recovered_amount), max(calendar_days),
       sum(recovered_amount)/max(calendar_days), count(DISTINCT account_id)
FROM gold.account_month GROUP BY 1,2,3
UNION ALL
SELECT month, 'state', state, sum(recovered_amount), max(calendar_days),
       sum(recovered_amount)/max(calendar_days), count(DISTINCT account_id)
FROM gold.account_month GROUP BY 1,2,3;


-- ---------------------------------------------------------------------
-- METRIC 11: Calling-hour profile, corrected vs uncorrected.
-- Included to quantify what the timezone fix actually changes, since
-- "best time to call" is a live operational decision.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW metrics.hour_profile AS
SELECT
    call_hour_ist                        AS hour,
    count(*)                             AS calls_corrected,
    count(*) FILTER (WHERE is_connected) AS connected_corrected
FROM gold.fct_call GROUP BY 1
ORDER BY 1;


-- ---------------------------------------------------------------------
-- METRIC 12: Cost per rupee recovered.
--
-- Reported as a RANGE, not a point estimate. The dataset contains no cost
-- table: no agent salary, no per-minute telephony rate, no per-message
-- price, no field-visit cost. Any single number here would be invented.
-- The parameters below are external assumptions, stated so they can be
-- replaced with real finance data.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW metrics.unit_economics AS
WITH assumptions AS (
    SELECT 250.0  AS agent_cost_per_hour,   -- ₹/hr fully loaded; ASSUMPTION
           0.35   AS telephony_cost_per_call, -- ₹/call; ASSUMPTION
           0.15   AS digital_cost_per_msg,  -- ₹/message; ASSUMPTION
           400.0  AS field_visit_cost       -- ₹/visit; ASSUMPTION
)
SELECT
    p.month,
    p.recovered_amount,
    p.agent_hours * a.agent_cost_per_hour                       AS agent_cost,
    c.voice_touches   * a.telephony_cost_per_call               AS telephony_cost,
    c.digital_touches * a.digital_cost_per_msg                  AS digital_cost,
    c.field_touches   * a.field_visit_cost                      AS field_cost,
    (p.agent_hours * a.agent_cost_per_hour
     + c.voice_touches   * a.telephony_cost_per_call
     + c.digital_touches * a.digital_cost_per_msg
     + c.field_touches   * a.field_visit_cost)                  AS total_cost,
    (p.agent_hours * a.agent_cost_per_hour
     + c.voice_touches   * a.telephony_cost_per_call
     + c.digital_touches * a.digital_cost_per_msg
     + c.field_touches   * a.field_visit_cost)
        / nullif(p.recovered_amount, 0)                         AS cost_per_rupee_recovered
FROM metrics.productivity p
JOIN metrics.channel_month c USING (month)
CROSS JOIN assumptions a
ORDER BY p.month;
