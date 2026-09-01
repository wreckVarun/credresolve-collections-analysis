# Metric definitions

Question 3 asks us to build an independent definition of recovery performance
and to challenge nine existing metrics. This document is that challenge: for
each metric, what the business appears to measure, what we measure instead,
and why ours is the more honest choice.

Implementations are in [`sql/03_metrics.sql`](../sql/03_metrics.sql).

**The organising principle:** every rate is computed over a *fixed*
denominator. A denominator that can shrink is a denominator that can be
gamed — deliberately or accidentally. Where we could not construct an honest
denominator, we refuse to publish the metric rather than publish a
convenient one.

---

## 0. Recovery per operating day — the metric that changes the answer

Not on the brief's list of nine. It should have been, because it is the one
that matters.

| | |
|---|---|
| **Definition** | Recovered rupees ÷ days in the period |
| **Denominator** | Calendar days (operating days in production, netting holidays) |
| **Replaces** | Raw monthly totals |

**Why:** monthly totals are not comparable to each other. February has 28 days
and March has 31 — a 10.7% difference in operating days before anyone makes a
call. Comparing raw totals means the calendar generates a ±11% swing
indistinguishable from performance.

**Impact:** this single change turns the reported +11.0% into +0.3% and drops
series volatility from a standard deviation of 8.4% to 2.6%. Month length
explains 82% of the variance in monthly totals (r² = 0.82, p = 0.005).

**Production rule:** any metric compared across periods must be
day-normalised. `recovery_monthly_total` should carry
`comparable_across_periods: false` in the semantic layer.

---

## 1. Contact rate → split into connect rate and RPC rate

| | Business definition (inferred) | Ours |
|---|---|---|
| Numerator | Any call that reached the network | Answered calls (connect); engaged dispositions (RPC) |
| Denominator | Calls attempted | Calls attempted |

**Challenge:** "contact" conflates two different things. A call that connects
to a wrong number is a connection, not a contact. We split them:

- **Connect rate** = `call_status = 'ANSWERED'` ÷ all calls. Measures whether
  telephony worked.
- **RPC rate** = dispositions indicating the borrower actually engaged ÷ all
  calls. Excludes `WRONG_NUMBER` and `NO_CONTACT`.

**Why it matters:** including wrong numbers inflates apparent contact by
roughly a third and makes a deteriorating phone-number database look like
stable performance.

**Caveat:** `duration_sec` is excluded from both. 60% of call rows carry a
non-zero duration alongside NO_ANSWER, BUSY or FAILED (DQ-03), so any
duration-based contact definition is built on a broken column.

## 2. RPC (right-party contact)

**Definition:** dispositions in {PROMISE_TO_PAY, PROMISE_BROKEN, PAID,
DISPUTE, REFUSED, CALLBACK} ÷ all calls.

**Challenge:** the disposition vocabulary spans three schema generations, and
the legacy vocabulary contains **both `PTP` and `PROMISE_TO_PAY`** as separate
codes for one outcome. Any RPC or PTP figure computed without harmonising
undercounts by roughly half in the legacy period. Harmonisation is in
`gold.fct_disposition`, with `disposition_code_raw` preserved for audit.

Note that DISPUTE and REFUSED count as right-party contact. The borrower was
reached; a refusal is a contact with a bad outcome, not a failure to contact.
Excluding them would let a team improve its contact rate by annoying people.

## 3. PTP rate — denominator is RPC, not calls

| | Business definition (inferred) | Ours |
|---|---|---|
| Denominator | All calls | Right-party contacts |

**Challenge:** a promise can only be obtained from someone you actually spoke
to. Dividing by all calls makes PTP rate move whenever dialling volume moves,
which measures the dialler, not the agent.

## 4. PTP kept rate

**Definition:** promises with `status = 'KEPT'` ÷ all promises made in the
period.

**Challenge:** the honest version cohorts by *promise date*, not by settlement
date — otherwise promises still within their window are counted as broken.
Our implementation groups by the month the promise was made.

**Limitation, stated:** we could not link kept promises to the specific
payments that fulfilled them, because `payment_reference` is not unique
(DQ-05) and there is no `ptp_id` on the payments table. So PTP kept rate is
taken from the PTP status field and cannot be independently verified against
cash. That is a real weakness and it should be fixed at source.

## 5. Recovery rate — fixed denominator

| | Business definition (inferred) | Ours |
|---|---|---|
| Denominator | Targeted or contacted accounts | **All 30,000 accounts** |

**Challenge:** this is the denominator-manipulation surface. If unsuccessful
accounts drop out of the base, the rate rises without anything improving. The
gap is not small: on the contacted base the rate reads 22.6–23.2%; on the full
population it is 7.2–8.1%. A 3× difference driven purely by denominator
choice.

We fixed the denominator at all 30,000 accounts in `gold.account_month` — every
account appears in every month whether or not it was targeted, contacted or
paid. The metric is immune to this failure mode by construction rather than by
vigilance.

**Test result:** no manipulation was found (targeting coverage is 77–78%
across ACTIVE, PAID, CLOSED and WRITEOFF alike). We fixed the denominator
anyway.

## 6. Recovery per account

**Definition:** recovered rupees ÷ accounts in the full population.

**Challenge:** the tempting version divides by *recovering* accounts, which
rises whenever you contact fewer people. That metric rewards doing less work
on fewer accounts.

## 7. Recovery per agent-hour

**Definition:** recovered rupees ÷ logged session hours from
`agent_sessions`.

**Challenge on the numerator:** must use net recovery (SUCCESS only), not
payment rows.

**Challenge on the denominator:** headcount ignores shift length, so we use
logged hours. We deliberately do *not* use `duration_sec` — see DQ-03.

**Limitation:** per-agent productivity cannot be computed at all, because
agent identity is unrecoverable (DQ-02: 1,000 agent IDs, 1,099 employee codes,
10 distinct names). This metric works only in aggregate.

**Result:** ₹16,117–17,008 per agent-hour, flat across all seven months.

## 8. Cost per rupee recovered — reported as a range, never a point

**Definition:** (agent cost + telephony + digital + field) ÷ recovered rupees.

**Challenge:** there is **no cost table anywhere in the seventeen datasets** —
no salary, no per-minute telephony rate, no per-message price, no field-visit
cost. Any single number here would be invented.

`metrics.unit_economics` therefore exposes the four cost drivers as **named
parameters** with explicit ASSUMPTION comments, rather than burying invented
inputs inside a result. Replace them with finance data and the view produces a
real number.

This is why the memo gives no ROI figure for the six investment options.

## 9. Channel conversion — deliberately not published

**Challenge:** we cannot define this honestly, so we do not define it.

Of ₹126.9 Cr recovered, **₹46.0 Cr (36%) comes from accounts with zero calls,
zero messages and zero field visits in the month they paid.** A further
₹23.1 Cr (18%) comes from accounts touched on two or three channels
simultaneously. Only 45% is single-channel.

Last-touch attribution on this data credits whichever channel fires most
often — a measure of channel *volume*, not channel *effect*. First-touch has
the same problem in reverse. Neither explains the 36% nobody touched, and no
attribution window rescues it.

`metrics.channel_month` reports volumes and single-channel isolation only.
Publishing a conversion rate would put a precise-looking number on something
unmeasurable, which is the exact failure mode this whole assignment is about.

---

## Metrics we added

| Metric | Why |
|---|---|
| Recovery per operating day | Removes the calendar artefact — the finding |
| Untouched recovery share | Quantifies how much of the book self-cures; bounds what any channel investment can address |
| Reference-collision flag | Distinguishes duplicate money from duplicate identifiers |
| Duration-contradiction flag | Marks the 60% of call rows that cannot be trusted for productivity |
| Geography-reliability flag | Prevents a state-level finding being read off a broken borrower dimension |

## Summary of what is and is not measurable

| Metric | Status |
|---|---|
| Recovery per operating day | **Reliable** |
| Recovery rate, recovery per account | **Reliable** (fixed denominator) |
| Connect rate, RPC rate, PTP rate | **Reliable** after disposition harmonisation |
| PTP kept rate | **Reliable with caveat** — cannot be tied to cash |
| Recovery per agent-hour | **Aggregate only** — no per-agent view |
| Cost per rupee recovered | **Parameterised** — no cost data exists |
| Channel conversion | **Not published** — structurally unmeasurable |
| Any geography metric | **Not published** — borrower identity broken |
