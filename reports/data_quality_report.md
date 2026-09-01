# Data Quality Report

Twelve defects were found across seventeen source tables. Four of them are
severe enough to invalidate an entire class of analysis. Every issue below
lists how it was detected, what we did about it, and what it costs the
business if left alone.

All detection queries are in `sql/04_forensics.sql` and are reproducible
against the golden layer.

## Part 1 documentation index

The brief lists ten items the golden-dataset build must document. Each is
below, with where the decision is implemented.

| Required item | Decision | Where |
|---|---|---|
| **Source-of-truth decisions** | `payments` is the sole source of recovery — `account_status_history` status changes are *not* treated as payment evidence, because half its rows have inverted clocks (DQ-10). `accounts` is the account master; `daily_targeting` defines exposure, never the population. Where `agents` and `borrowers` conflict with themselves, the latest row by `updated_at` wins. | `sql/02_golden.sql` D2, D3, D8, D8a |
| **Entity resolution** | `agent_id` is the agent key (not `employee_code`, not name); `borrower_id` collapsed to latest version; `account_id` is already unique. | D2, D8a |
| **Deduplication logic** | Two-stage: full-row MD5 hash (486 replays), then `payment_id` preferring the enriched copy (14 ingestion races). Exactly 500 rows. | D3 |
| **Missing-data treatment** | Retained, never imputed. Rows excluded only from the specific metric they break: 1,827 NULL `agent_id` calls drop out of agent attribution but stay in call volume. | DQ-12 |
| **Timestamp treatment** | Each row localised to its stated timezone, converted to Asia/Kolkata. Tables with no timezone column assumed IST — an assumption, flagged as such. | D1, DQ-07 |
| **Payment attribution** | Payments attributed to the **account**, on the payment's own timestamp, and to nothing else. No channel, campaign or agent attribution is applied, because 36% of recovery has no interaction to attribute to (DQ-04). Attribution is refused, not guessed. | D3, DQ-04 |
| **Historical changes** | `agents` and `borrowers` arrive as overwritten-style history with no version key. We take the latest version and carry `n_versions` so the churn is visible. No SCD is built on `account_status_history.recorded_at`, because that column is inverted in 50.3% of rows and cannot order events. | D2, D7, D8a, DQ-10 |
| **Exclusion rules** | Only two things are excluded outright: 500 duplicate rows, and non-SUCCESS payment statuses from the recovery measure. August 2026 is excluded from *trend* analysis but retained in the golden layer. Nothing else is dropped — defects are flagged and travel with the data. | D3, D4, D9 |
| **Data-quality issues** | Twelve defects, catalogued below. | this document |
| **Assumptions** | (1) Tables without a timezone column are IST. (2) `payment_status = 'SUCCESS'` means settled cash. (3) REVERSED rows are excluded rather than netted, as they cannot be linked to originals. (4) Cost parameters in `metrics.unit_economics` are invented placeholders, marked ASSUMPTION. (5) Calendar days stand in for operating days — no holiday calendar exists in the data. | D1, D4, `03_metrics.sql` |

---

## Reconciliation: raw → golden

| Stage | Rows | Value | Δ |
|---|---:|---:|---:|
| Raw payment rows | 25,500 | ₹191.73 Cr | — |
| After deduplication | 25,000 | ₹187.89 Cr | −500 rows, −₹3.84 Cr |
| After status filter (SUCCESS only) | 17,534 | ₹131.56 Cr | −7,466 rows, −₹56.33 Cr |
| **Golden (Jan–Jul, Aug excluded as partial)** | **—** | **₹126.85 Cr** | **−₹64.88 Cr vs raw (−33.8%)** |

A third of the value in the payments table is not recovered money.

---

## Severity 1 — invalidates an analysis

### DQ-01 Borrower identity is not unique or consistent

**Detected:** `count(*)` 30,600 vs `count(distinct borrower_id)` 11,015. Then
a per-ID count of distinct names, states and phones.

**What it is:** 8,566 borrower IDs carry multiple rows, and 8,468 of those
carry *conflicting* identities — not replays. `BRW0001072` appears as Aarav
Sharma (Chennai, Tamil Nadu), Pooja Nair (Pune), Ananya Rao (Pune) and Rahul
Verma (Bhubaneswar, Odisha), each with a different phone and email. Up to 11
versions exist for a single ID.

**Treatment:** collapsed to one row per `borrower_id` by latest `updated_at`
into `gold.dim_borrower`, carrying `has_conflicting_identity`,
`n_versions`, `n_names` and `n_states` so the flag travels with the data.

**Business impact:** two, and the second is worse than the first.

1. A naive join from accounts to borrowers fans 30,000 accounts to 75,601
   rows and inflates every downstream sum by ~2.5×. We hit this during
   development: monthly recovery briefly read ₹166 Cr instead of ₹18 Cr.
2. **Geography analysis is not trustworthy and has been excluded.** City and
   state are borrower attributes. The assignment asks for a geography
   breakdown; it can be produced, but a state-level finding from this column
   would be the most plausible-looking wrong answer available in this dataset.

### DQ-02 Agent identity is unrecoverable

**Detected:** cardinality comparison across `agent_id`, `employee_code` and
`agent_name`, then cross-tabulation.

**What it is:** 30,000 rows, 1,000 distinct `agent_id`, 1,099 distinct
`employee_code`, **10** distinct `agent_name`. All 1,099 employee codes map to
more than one name. All 1,000 agent IDs map to more than one employee code.
One `agent_id` carries up to 48 versions.

**Treatment:** `agent_id` treated as the entity key; latest row by
`updated_at` retained in `gold.dim_agent`. Resolution on `employee_code` or
`agent_name` was considered and **rejected** — merging on name would collapse
1,000 agents into 10 and manufacture per-agent recovery figures roughly 100×
too large.

**Business impact:** per-agent performance, agent tenure effects and agent
ranking cannot be computed. Both are on the assignment's required
investigation list; neither is answerable. This is also why the "hire more
agents" investment option cannot be sized.

### DQ-03 Call status contradicts call duration in 60% of rows

**Detected:** cross-tab of `call_status` against `duration_sec > 0`.

**What it is:** 54,902 of 91,350 calls report NO_ANSWER, BUSY or FAILED while
carrying a mean duration of ~450 seconds. Answered and unanswered calls have
statistically identical duration distributions (449–453s), which is not
possible if `duration_sec` measures talk time.

**Treatment:** `duration_sec` excluded from every productivity metric.
Connect rate computed from `call_status` alone. Contradiction surfaced as
`has_duration_contradiction` rather than silently resolved — deciding whether
the status or the duration is wrong requires the telephony vendor, not a
`CASE` statement.

**Business impact:** any average-handle-time, occupancy or talk-time
productivity metric currently in use is meaningless. Recovery per agent-hour
had to be built on session logins instead.

### DQ-04 Channel attribution is structurally impossible

**Detected:** channel-touch count per paying account-month.

**What it is:** of ₹126.85 Cr recovered, **₹46.0 Cr (36%) comes from accounts
with zero calls, zero digital messages and zero field visits in the month
they paid.** A further ₹23.1 Cr comes from accounts touched on two or three
channels simultaneously. Only ₹57.7 Cr (45%) is single-channel.

**Treatment:** channel conversion rate is **not reported**. `metrics.channel_month`
reports volumes and single-channel isolation only, and explicitly refuses a
conversion metric.

**Business impact:** three of the six ₹10 Cr investment options (telephony, AI
voice, WhatsApp/digital) are channel bets that cannot be evaluated. Any
last-touch model applied here credits whichever channel fires most often,
which measures volume, not effect.

---

## Severity 2 — corrupts a metric

### DQ-05 Duplicate payments, via two different mechanisms

**Detected:** full-row MD5 hash, then a second pass on `payment_id`.

**What it is:** 500 duplicate rows, arriving two ways. 486 are byte-identical
ingestion replays. **14 are ingestion races**: same `payment_id`, account,
amount and timestamp, but one copy landed before the provider reference was
attached and carries a NULL `payment_reference`, so the row hashes differ and
a single-pass hash dedup misses them.

**The trap:** the intuitive test — repeated `payment_reference` — flags 8,042
rows. It is wrong. `TXN0000000032` appears against three unrelated borrowers
for three different amounts; the provider's reference is not globally unique.
**Deduplicating on `payment_reference` would delete ₹60.8 Cr of genuine
recovery**, an error 16× larger than the problem being fixed.

**Treatment:** two-stage dedup on row hash, then on `payment_id` preferring
the enriched copy. Exactly 500 rows removed, reconciling with the count of
repeated payment IDs. `payment_reference` demoted from key to attribute and
flagged with `is_reference_collision`.

**Business impact:** −₹3.84 Cr of phantom recovery, and a fact table with a
genuine primary key.

### DQ-06 Non-SUCCESS payments counted as recovery

**Detected:** `payment_status` distribution.

**What it is:** 7,466 of 25,000 deduplicated rows (29.9%) are FAILED, PENDING
or REVERSED. Including them inflates recovery by **₹56.33 Cr (+42.8%)**.

**Treatment:** `is_recovered` and `recovered_amount` defined on SUCCESS only.

**Note on reversals:** 1,284 REVERSED rows cannot be netted against their
original payments, because `payment_reference` is not unique and provides no
reliable link. They are excluded rather than netted, which is conservative.

### DQ-07 Three timezones, naive timestamps

**Detected:** distinct `timezone` values per table, then hour and date
comparison before and after localisation.

**What it is:** `accounts`, `calls`, `agent_sessions` and `vendor_telephony`
carry a mix of UTC, Asia/Kolkata and Asia/Dubai. The timestamps themselves
encode no offset.

**Treatment:** each row localised to its stated zone, then converted to
Asia/Kolkata. Tables with no timezone column (payments, WhatsApp, SMS, field
visits, PTPs, complaints, status history) are **assumed** IST — an assumption,
not a finding, and one that should be confirmed with the source systems.

**Business impact:** 60,865 of 91,350 calls (67%) sit in the wrong hour bucket
uncorrected, and **8,924 fall on the wrong calendar day**. Every "best time to
call" analysis and every daily series is wrong without this correction.

### DQ-08 Disposition codes span three schema generations

**Detected:** `disposition_version` distribution and per-version code
vocabulary.

**What it is:** legacy / v1 / v2 in roughly equal thirds, and the legacy
vocabulary contains **both `PTP` and `PROMISE_TO_PAY`** as separate codes for
the same outcome. The versions are interleaved across months rather than
sequential, so this is not a migration — the codes were never consistent.

**Treatment:** harmonised to a canonical vocabulary in
`gold.fct_disposition`, preserving `disposition_code_raw` for audit.

**Business impact:** PTP rate is understated by roughly half wherever the two
codes are counted separately.

### DQ-09 August 2026 is a partial month

**Detected:** min/max event timestamp per table.

**What it is:** every event table stops between 8 and 12 August 2026. August
holds ~26% of a normal month's volume.

**Treatment:** excluded from all trend analysis; retained in the golden layer;
rendered hatched on the dashboard.

**Business impact:** any month-on-month calculation including August reports a
~74% collapse that did not occur.

---

## Severity 3 — flagged, not corrected

### DQ-10 Half of status-history rows have inverted clocks

30,191 of 60,000 rows (50.3%) have `recorded_at` **earlier** than `event_at`.
This is not late-arriving data, which would be the reverse — it is a broken
clock or a column swap at source. Rows retained, `event_at` used as effective
time, `is_clock_inverted` flagged. No slowly-changing dimension is built on
`recorded_at`, because it cannot be trusted for ordering.

### DQ-11 Payments on closed and written-off accounts

12,775 payments land on accounts whose *current* status is CLOSED or WRITEOFF.
`accounts` carries only a current status with no effective dating, so we
cannot tell whether the payment preceded the write-off (normal) or followed it
(an accounting problem). Flagged, not excluded. Resolving this needs
effective-dated account status from the source system.

### DQ-12 Missing values

`calls.agent_id` NULL in 1,827 rows (2.0%) — these calls cannot be attributed
to an agent. `borrowers.phone` NULL in 614 rows, `borrowers.email` in 895.
Retained; excluded from the specific metrics they break.

---

## What we did not find

Negative results, stated because they narrow where the real problem can hide.

| Hypothesis | Verdict | Evidence |
|---|---|---|
| Portfolio mix changed | **Refuted** | χ² risk segment p = 0.215, loan type p = 0.997 |
| Denominator manipulation | **Refuted** | Targeting coverage 77.2–78.1% across all four account statuses |
| Vendor telephony change drove performance | **Refuted** | All 15 vendors live every month; connect rate 19.3-20.5%, no switch to find |
| Cohort / vintage effects | **Refuted** | 2024 vs 2025 vintages recover at ₹6,030 vs ₹6,052; mix stable, p = 0.13 |
| Attempt frequency drove recovery | **Refuted** (with caveat) | No dose-response; but attempt count is endogenous, so dose and selection cannot be separated here |
| Selection or survivorship bias in the paying population | **Refuted** | Fixed 30,000-account denominator; recovery rate flat at 7.2–8.1% |
| Simpson's paradox across segments | **Refuted** | Every segment flat individually and in aggregate |

---

## Monitoring: what should have caught this

None of these defects are subtle. All twelve would be caught by cheap
assertions running on every load:

| Check | Would have caught |
|---|---|
| Primary-key uniqueness on every dimension and fact | DQ-01, DQ-02, DQ-05 |
| Row-count and value delta vs prior load, ±3σ alert | DQ-05, DQ-09 |
| Referential integrity: every FK resolves to exactly one parent | DQ-01 |
| Cross-column logic assertions (`status='NO_ANSWER' ⇒ duration=0`) | DQ-03 |
| Timestamp ordering assertions (`recorded_at ≥ event_at`) | DQ-10 |
| Enum drift alert on every coded column | DQ-08 |
| Freshness check: max event date within 24h of load | DQ-09 |
| Status-distribution monitor on payments | DQ-06 |

Adding these is the first thing we would do in production. See
`reports/architecture.md`.
