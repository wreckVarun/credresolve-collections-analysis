-- =====================================================================
-- 01_staging.sql   Raw -> Staging
--
-- Staging is a faithful mirror of source. No business logic, no filtering,
-- no dedup. Every cleaning decision happens downstream so that it stays
-- auditable and reversible.
--
-- Two things are added: ingestion lineage (_src_file, _ingested_at) and a
-- deterministic row fingerprint (_row_hash) over the full natural payload.
-- The fingerprint is what lets us separate a true replayed row from two
-- genuinely distinct events that happen to share an identifier -- a
-- distinction that turns out to matter a great deal in this dataset.
--
-- Engine: DuckDB. Portable to Snowflake/BigQuery; divergences noted inline.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS stg;

-- sample_size=-1 forces a full-file type scan. Several columns here only
-- reveal their true type, or their NULLs, well beyond the default 20k
-- sample; letting DuckDB guess produced silent VARCHAR casts on amounts.

CREATE OR REPLACE TABLE stg.payments AS
SELECT
    payment_id, account_id, borrower_id,
    CAST(event_at AS TIMESTAMP)      AS event_at_naive,
    payment_reference,
    CAST(amount AS DOUBLE)           AS amount,
    upper(trim(payment_status))      AS payment_status,
    upper(trim(payment_method))      AS payment_method,
    provider_id,
    'payments.csv'                   AS _src_file,
    current_timestamp                AS _ingested_at,
    md5(concat_ws('|', payment_id, account_id, borrower_id,
                  CAST(event_at AS VARCHAR), payment_reference,
                  CAST(amount AS VARCHAR), payment_status,
                  payment_method, provider_id)) AS _row_hash
FROM read_csv_auto('raw/payments.csv', header=true, sample_size=-1);

CREATE OR REPLACE TABLE stg.accounts AS
SELECT
    account_id, borrower_id,
    upper(trim(loan_type))              AS loan_type,
    CAST(principal_amount AS DOUBLE)    AS principal_amount,
    CAST(outstanding_amount AS DOUBLE)  AS outstanding_amount,
    CAST(dpd AS INTEGER)                AS dpd,
    upper(trim(risk_segment))           AS risk_segment,
    upper(trim(status))                 AS status,
    CAST(opened_at AS TIMESTAMP)        AS opened_at_naive,
    timezone                            AS src_timezone,
    schema_version,
    'accounts.csv' AS _src_file, current_timestamp AS _ingested_at
FROM read_csv_auto('raw/accounts.csv', header=true, sample_size=-1);

CREATE OR REPLACE TABLE stg.agents AS
SELECT
    agent_id, employee_code, agent_name, vendor_id, team,
    upper(trim(status))            AS status,
    CAST(joined_at AS TIMESTAMP)   AS joined_at,
    CAST(updated_at AS TIMESTAMP)  AS updated_at,
    'agents.csv' AS _src_file, current_timestamp AS _ingested_at
FROM read_csv_auto('raw/agents.csv', header=true, sample_size=-1);

CREATE OR REPLACE TABLE stg.calls AS
SELECT
    call_id, account_id, borrower_id,
    CAST(event_at AS TIMESTAMP)   AS event_at_naive,
    agent_id, campaign_id,
    upper(trim(direction))        AS direction,
    vendor_id,
    upper(trim(call_status))      AS call_status,
    CAST(duration_sec AS INTEGER) AS duration_sec,
    timezone                      AS src_timezone,
    'calls.csv' AS _src_file, current_timestamp AS _ingested_at
FROM read_csv_auto('raw/calls.csv', header=true, sample_size=-1);

CREATE OR REPLACE TABLE stg.call_attempts AS
SELECT attempt_id, account_id, borrower_id,
       CAST(event_at AS TIMESTAMP) AS event_at_naive,
       call_id, agent_id, CAST(attempt_no AS INTEGER) AS attempt_no,
       vendor_id, upper(trim(attempt_status)) AS attempt_status,
       'call_attempts.csv' AS _src_file, current_timestamp AS _ingested_at
FROM read_csv_auto('raw/call_attempts.csv', header=true, sample_size=-1);

CREATE OR REPLACE TABLE stg.call_dispositions AS
SELECT disposition_id, account_id, borrower_id,
       CAST(event_at AS TIMESTAMP) AS event_at_naive,
       call_id, agent_id,
       upper(trim(disposition_code)) AS disposition_code_raw,
       disposition_version,
       'call_dispositions.csv' AS _src_file, current_timestamp AS _ingested_at
FROM read_csv_auto('raw/call_dispositions.csv', header=true, sample_size=-1);

CREATE OR REPLACE TABLE stg.promises_to_pay AS
SELECT ptp_id, account_id, borrower_id,
       CAST(event_at AS TIMESTAMP) AS event_at_naive,
       agent_id, CAST(promised_amount AS DOUBLE) AS promised_amount,
       CAST(promised_date AS TIMESTAMP) AS promised_date,
       upper(trim(status)) AS status, upper(trim(source)) AS source,
       'promises_to_pay.csv' AS _src_file, current_timestamp AS _ingested_at
FROM read_csv_auto('raw/promises_to_pay.csv', header=true, sample_size=-1);

CREATE OR REPLACE TABLE stg.agent_sessions AS
SELECT session_id, agent_id,
       CAST(login_at AS TIMESTAMP)  AS login_at_naive,
       CAST(logout_at AS TIMESTAMP) AS logout_at_naive,
       upper(trim(channel)) AS channel, device_id,
       timezone AS src_timezone,
       'agent_sessions.csv' AS _src_file, current_timestamp AS _ingested_at
FROM read_csv_auto('raw/agent_sessions.csv', header=true, sample_size=-1);

CREATE OR REPLACE TABLE stg.daily_targeting AS
SELECT target_id, account_id, campaign_id,
       CAST(target_date AS DATE) AS target_date,
       CAST(priority AS INTEGER) AS priority,
       upper(trim(recommended_channel)) AS recommended_channel,
       upper(trim(status)) AS status,
       'daily_targeting.csv' AS _src_file, current_timestamp AS _ingested_at
FROM read_csv_auto('raw/daily_targeting.csv', header=true, sample_size=-1);

CREATE OR REPLACE TABLE stg.campaigns AS
SELECT campaign_id, campaign_name, upper(trim(channel)) AS channel,
       strategy_version,
       CAST(start_at AS TIMESTAMP) AS start_at,
       CAST(end_at AS TIMESTAMP)   AS end_at,
       target_definition,
       'campaigns.csv' AS _src_file, current_timestamp AS _ingested_at
FROM read_csv_auto('raw/campaigns.csv', header=true, sample_size=-1);

CREATE OR REPLACE TABLE stg.field_visits AS
SELECT visit_id, account_id, borrower_id,
       CAST(event_at AS TIMESTAMP) AS event_at_naive,
       agent_id, upper(trim(visit_type)) AS visit_type,
       upper(trim(outcome)) AS outcome,
       CAST(latitude AS DOUBLE) AS latitude, CAST(longitude AS DOUBLE) AS longitude,
       CAST(scheduled_at AS TIMESTAMP) AS scheduled_at,
       'field_visits.csv' AS _src_file, current_timestamp AS _ingested_at
FROM read_csv_auto('raw/field_visits.csv', header=true, sample_size=-1);

CREATE OR REPLACE TABLE stg.whatsapp_events AS
SELECT whatsapp_event_id AS event_id, account_id, borrower_id,
       CAST(event_at AS TIMESTAMP) AS event_at_naive,
       message_id, upper(trim(event_type)) AS event_type,
       template_code, provider_id, 'WHATSAPP' AS channel,
       'whatsapp_events.csv' AS _src_file, current_timestamp AS _ingested_at
FROM read_csv_auto('raw/whatsapp_events.csv', header=true, sample_size=-1);

CREATE OR REPLACE TABLE stg.sms_events AS
SELECT sms_event_id AS event_id, account_id, borrower_id,
       CAST(event_at AS TIMESTAMP) AS event_at_naive,
       message_id, upper(trim(event_type)) AS event_type,
       template_code, provider_id, 'SMS' AS channel,
       'sms_events.csv' AS _src_file, current_timestamp AS _ingested_at
FROM read_csv_auto('raw/sms_events.csv', header=true, sample_size=-1);

CREATE OR REPLACE TABLE stg.complaints AS
SELECT complaint_id, account_id, borrower_id,
       CAST(event_at AS TIMESTAMP) AS event_at_naive,
       upper(trim(complaint_type)) AS complaint_type,
       upper(trim(severity)) AS severity, upper(trim(status)) AS status,
       upper(trim(source)) AS source,
       CAST(resolution_at AS TIMESTAMP) AS resolution_at,
       'complaints.csv' AS _src_file, current_timestamp AS _ingested_at
FROM read_csv_auto('raw/complaints.csv', header=true, sample_size=-1);

CREATE OR REPLACE TABLE stg.account_status_history AS
SELECT history_id, account_id, borrower_id,
       CAST(event_at AS TIMESTAMP)    AS event_at_naive,
       upper(trim(status)) AS status, changed_by, upper(trim(source)) AS source,
       CAST(recorded_at AS TIMESTAMP) AS recorded_at,
       'account_status_history.csv' AS _src_file, current_timestamp AS _ingested_at
FROM read_csv_auto('raw/account_status_history.csv', header=true, sample_size=-1);

CREATE OR REPLACE TABLE stg.borrowers AS
SELECT borrower_id, name, CAST(phone AS VARCHAR) AS phone, email, city, state,
       CAST(created_at AS TIMESTAMP) AS created_at,
       CAST(updated_at AS TIMESTAMP) AS updated_at,
       'borrowers.csv' AS _src_file, current_timestamp AS _ingested_at
FROM read_csv_auto('raw/borrowers.csv', header=true, sample_size=-1);

CREATE OR REPLACE TABLE stg.vendor_telephony AS
SELECT vendor_id, vendor_name, vendor_account_id,
       timezone AS src_timezone, upper(trim(status)) AS status, schema_version,
       'vendor_telephony.csv' AS _src_file, current_timestamp AS _ingested_at
FROM read_csv_auto('raw/vendor_telephony.csv', header=true, sample_size=-1);
