# Production Analytics Design

The analysis in this repository runs as a batch script. This document
describes what it looks like as a system leadership opens every morning.

The design constraint that shapes everything below: **the failure this
analysis uncovered was not an analytical failure, it was a missing
assertion.** A duplicate-payment check and a calendar-normalised metric
definition would have prevented a ₹10 Cr decision from being made against an
artefact. So the architecture prioritises contracts and monitoring over
sophistication.

## Layers

```
  SOURCE            RAW              STAGING           CLEAN
┌──────────┐   ┌────────────┐   ┌────────────┐   ┌────────────┐
│ LMS      │──►│ immutable  │──►│ typed      │──►│ deduped    │
│ dialler  │   │ append-only│   │ lineage    │   │ entity-    │
│ WhatsApp │   │ partitioned│   │ row hash   │   │ resolved   │
│ SMS      │   │ by ingest  │   │ no logic   │   │ tz-normal  │
│ field app│   │ date       │   │            │   │ flagged    │
│ payments │   └────────────┘   └────────────┘   └─────┬──────┘
│ CRM      │         │                                 │
└──────────┘         │ replay source of truth          ▼
                     │                          ┌────────────┐
                     │                          │  GOLDEN    │
                     │                          │ account_   │
                     │                          │ month      │
                     │                          │ (the spine)│
                     │                          └─────┬──────┘
                     │                                │
                     │                    ┌───────────┴──────────┐
                     │                    ▼                      ▼
                     │             ┌────────────┐         ┌────────────┐
                     │             │  FEATURE   │         │  METRICS   │
                     │             │ per-account│         │ semantic   │
                     │             │ rolling    │         │ layer, one │
                     │             │ windows    │         │ definition │
                     │             └─────┬──────┘         └─────┬──────┘
                     │                   │                      │
                     │                   ▼                      ▼
                     │             ┌────────────┐         ┌────────────┐
                     │             │ TARGETING  │         │ DASHBOARD  │
                     │             │ model      │         │ + alerts   │
                     │             └────────────┘         └────────────┘
                     │
                     └──────────► DATA QUALITY GATE (blocks promotion) ◄─┘
```

Full diagram: `figures/architecture.svg`.

## Data contracts

Each source publishes a contract; a load that violates it is quarantined
rather than promoted. Contract violations page the owning team, not the
analytics team — the fix belongs at source.

| Source | Primary key | Contract | On violation |
|---|---|---|---|
| `payments` | `payment_id` | unique; `amount > 0`; `payment_status ∈ enum`; `event_at ≤ now` | quarantine batch |
| `accounts` | `account_id` | unique; `borrower_id` resolves to exactly one borrower | quarantine |
| `borrowers` | `borrower_id` | unique; one name/phone/state per ID per version | **currently failing** — see DQ-01 |
| `agents` | `agent_id + effective_at` | unique; `employee_code` stable per `agent_id` | **currently failing** — see DQ-02 |
| `calls` | `call_id` | unique; `status='ANSWERED' ⇔ duration_sec > 0`; timezone non-null | **currently failing** — see DQ-03 |
| `call_dispositions` | `disposition_id` | unique; code in the *current* enum version | alert on enum drift |
| `account_status_history` | `history_id` | unique; `recorded_at ≥ event_at` | **currently failing** — see DQ-10 |

Three of seven contracts fail today. Publishing the contracts is the point:
it moves the argument from "the dashboard looks wrong" to "the dialler feed
is violating clause 3", which is a conversation that gets fixed.

## Metric definitions live in one place

Every metric is defined once, in the semantic layer (dbt metrics, Cube, or
LookML — the choice matters less than the singularity). No metric is redefined
in a dashboard, a notebook or a spreadsheet.

The specific rule that would have prevented this incident:

> **Any metric compared across time periods must be normalised by operating
> days.** Monthly totals are not a permitted comparison basis. The semantic
> layer exposes `recovery_per_operating_day`; `recovery_monthly_total` exists
> but is marked `comparable_across_periods: false` and the BI tool refuses to
> render it as a trend.

Operating days, not calendar days, in production: the pipeline should net out
public holidays and any planned floor closures, which this dataset does not
capture.

## Lineage

Column-level lineage from source column to dashboard tile, emitted by the
transformation framework (dbt exposures + OpenLineage), so that "where does
this number come from" is answerable in one click. This matters most for the
flags: when a dashboard shows geography greyed out, the lineage should lead a
user to DQ-01 rather than to a support ticket.

## Incremental processing

Facts are incremental on `event_at`, partitioned by month, with a **7-day
reprocessing window** on every run to absorb late arrivals. Dimensions are
snapshot-based (SCD Type 2) keyed on the natural key plus effective date.

Merge strategy is `insert_overwrite` by partition rather than `merge` on key,
because the sources have demonstrated that keys are not reliable and an
overwrite of a bounded window is recoverable where a bad merge is not.

## Late-arriving data

Two distinct problems, handled differently:

- **Late-arriving facts** (payment settles days after the attempt): absorbed
  by the 7-day reprocessing window. Anything older than 7 days triggers a
  targeted backfill rather than silently restating a closed month.
- **Late-arriving dimensions** (a payment for an account not yet in the
  dimension): the fact loads with a placeholder key and is reconciled on the
  next run. Facts are never dropped for a missing dimension row — the
  unmatched count is a monitored metric.

Restatement policy: closed months are immutable in the reporting layer. A
correction to a closed month is published as a dated restatement with a visible
note, not a silent overwrite. Leadership should never see a number change
without being told it changed.

## Backfills

Backfills run against the raw layer, which is immutable and append-only, so
any historical state can be reconstructed. Every run stamps
`_pipeline_version`; a backfill under a new version writes to a shadow table
and is diffed against production before promotion. A backfill that changes
headline recovery by more than 1% requires sign-off.

## Data quality checks

Run as a gate between clean and golden. Failures block promotion; the previous
golden snapshot stays live rather than a bad one replacing it.

| Tier | Check | Action |
|---|---|---|
| **Blocking** | PK uniqueness on every dimension and fact | halt, page owner |
| **Blocking** | Row count vs 28-day rolling median, ±3σ | halt, page owner |
| **Blocking** | Referential integrity on all FKs | halt |
| **Blocking** | `sum(recovered_amount)` vs finance ledger, ±0.5% | halt |
| Warning | Enum drift on any coded column | alert, auto-map to `UNMAPPED` |
| Warning | NULL rate change > 5pp vs prior load | alert |
| Warning | Cross-column logic assertions | alert, set flag column |
| Warning | Freshness: max `event_at` within 24h | alert |

The finance reconciliation is the most important line in that table. A
recovery number that does not tie to the ledger to within half a percent is
not a recovery number, and no amount of pipeline elegance substitutes for that
check.

## Monitoring and anomaly detection

Deliberately simple, because an anomaly detector nobody can explain is an
anomaly detector nobody acts on.

- **Volume and value**: per source, per day, vs 28-day rolling median with a
  seasonal (day-of-week) adjustment. Robust z-score, flag at |z| > 3.
- **Metric drift**: every published metric monitored on its *normalised* form.
  Had this existed, recovery-per-day would have shown a flat line for seven
  months and nobody would have reported an 11% improvement.
- **Distribution drift**: population stability index on risk segment, DPD
  bucket, loan type. PSI > 0.2 alerts on portfolio mix change — the check that
  would confirm or refute a book acquisition automatically.
- **Duplicate-rate monitor**: dedup removal rate per load. A sudden rise means
  an upstream retry loop, which is exactly how the 500 duplicate payments got
  in.

Alerts route to an on-call analytics rota with a runbook per alert type. An
alert without a runbook gets muted within a fortnight; that is not a
hypothetical.

## What runs when

| Job | Cadence | SLA |
|---|---|---|
| Raw ingestion | every 15 min (streams), hourly (batch) | — |
| Staging + clean + golden | hourly | golden fresh within 90 min |
| Metrics + dashboard refresh | hourly, 06:00 full rebuild | dashboard by 07:00 IST |
| DQ gate | every golden run | blocking |
| Finance reconciliation | daily 02:00 | blocking |
| Backfill window (7-day) | nightly | — |

## Deliberate omissions

Things a production design is often expected to include, left out on purpose:

- **No ML in the critical path.** The targeting model is downstream of the
  golden layer and its outputs are never inputs to a reported metric.
- **No real-time recovery metrics.** Payments settle over days; a real-time
  recovery number would be less accurate, not more, and would invite exactly
  the kind of short-window comparison that caused this problem.
- **No channel attribution model** until the holdout experiment reads out.
  Shipping an attribution model on this data would put a precise-looking
  number on something we have shown is not measurable.
