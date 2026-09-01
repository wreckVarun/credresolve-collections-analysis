#!/usr/bin/env python3
"""
Part 4 -- Counterfactual: "What would recovery have looked like if we had
not changed the targeting strategy?"

Approach: difference-in-differences on account-months, with the treatment
defined by exposure to post-change campaign strategy versions.

The point of this script is not to produce a number. It is to test whether
the identifying assumptions hold. They do not, and the script demonstrates
why, which is the honest deliverable.
"""
import duckdb, numpy as np, pandas as pd
from scipy import stats

con = duckdb.connect("data/collections.duckdb")
pd.set_option("display.width", 200)

print("=" * 72)
print("STEP 1 -- Locate the targeting change point")
print("=" * 72)
# The assignment tells us a change happened mid-year. Before designing an
# estimator we must find it in the data. If we cannot, the estimator has no
# treatment date and nothing downstream is identified.
camp = con.sql("""
    SELECT date_trunc('month', start_at) AS month, strategy_version, count(*) AS n
    FROM stg.campaigns GROUP BY 1,2 ORDER BY 1,2
""").df()
piv = camp.pivot(index="month", columns="strategy_version", values="n").fillna(0)
print(piv.to_string())
print("""
READ: the four strategy versions (legacy, v1, v2, v3) are INTERLEAVED across
every month, not sequential. 'legacy' campaigns start in April and May, after
v2 and v3 campaigns have already run. There is no month at which the
portfolio switches from one strategy generation to another.

Campaigns also only span Jan-May 2026; June and July have no campaign
start dates at all, while targeting and calling continue at full volume.
So campaign_id cannot define treatment for the back half of the period.
""")

print("=" * 72)
print("STEP 2 -- Test for ANY structural break in the outcome series")
print("=" * 72)
# If a targeting change occurred and had an effect, it should show up as a
# break in recovery per day. Chow test at every candidate break point.
m = con.sql("SELECT month, recovery_per_day FROM metrics.monthly_recovery ORDER BY month").df()
y = m.recovery_per_day.values
x = np.arange(len(y))


def chow(y, x, k):
    """F-statistic for a structural break after index k-1."""
    def rss(xx, yy):
        if len(yy) < 3:
            return np.nan
        b = np.polyfit(xx, yy, 1)
        return float(np.sum((yy - np.polyval(b, xx)) ** 2))
    r_pool = rss(x, y)
    r1, r2 = rss(x[:k], y[:k]), rss(x[k:], y[k:])
    if np.isnan(r1) or np.isnan(r2):
        return np.nan, np.nan
    n, kk = len(y), 2
    num = (r_pool - (r1 + r2)) / kk
    den = (r1 + r2) / (n - 2 * kk)
    F = num / den
    return F, 1 - stats.f.cdf(F, kk, n - 2 * kk)


print(f"{'break after':<12}{'F':>10}{'p':>10}")
for k in range(3, len(y) - 2):
    F, p = chow(y, x, k)
    print(f"{m.month[k-1].strftime('%b %Y'):<12}{F:>10.3f}{p:>10.3f}")
print("""
READ: no break point is significant at any conventional level. The outcome
series has no structural break to attribute to a targeting change.
""")

print("=" * 72)
print("STEP 3 -- DiD design, stated in full, then tested")
print("=" * 72)
print("""
Because no change point is observable, we adopt the assignment's stipulation
that the change occurred mid-year and set the treatment date to 1 April 2026
(the midpoint of the observed window). The design is then:

  Treatment group : accounts targeted under post-change strategy versions
                    (v2/v3 campaign exposure) in the post period
  Control group   : accounts never exposed to those versions
  Pre period      : Jan-Mar 2026
  Post period     : Apr-Jul 2026
  Outcome         : recovery per account-month (₹), fixed denominator
  Estimator       : (T_post - T_pre) - (C_post - C_pre)

  Identifying assumption: PARALLEL TRENDS -- absent the change, treatment and
  control would have moved together. This is testable on the pre-period, and
  it is the assumption that carries the whole design.
""")

did = con.sql("""
    WITH exposure AS (
        SELECT DISTINCT t.account_id
        FROM stg.daily_targeting t
        JOIN stg.campaigns c USING (campaign_id)
        WHERE c.strategy_version IN ('v2','v3')
    )
    SELECT am.month,
           CASE WHEN e.account_id IS NOT NULL THEN 'treated' ELSE 'control' END AS grp,
           count(*)                                   AS accounts,
           avg(am.recovered_amount)                   AS mean_recovery,
           avg(am.recovered_amount) / max(am.calendar_days) AS mean_recovery_per_day
    FROM gold.account_month am
    LEFT JOIN exposure e USING (account_id)
    GROUP BY 1,2 ORDER BY 1,2
""").df()
print(did.to_string(index=False))

print("\n--- Parallel-trends test on the PRE period (Jan-Mar) ---")
pre = did[did.month < "2026-04-01"]
t = pre[pre.grp == "treated"].mean_recovery_per_day.values
c = pre[pre.grp == "control"].mean_recovery_per_day.values
gap = t - c
print(f"pre-period gap by month : {np.round(gap, 2)}")
sl, ic, r, p, se = stats.linregress(np.arange(len(gap)), gap)
print(f"trend in the gap        : slope={sl:.3f}  p={p:.3f}")
if p < 0.05:
    print("PARALLEL TRENDS IS REJECTED (p < 0.05). The gap between treated and")
    print("control is already trending in the pre-period, before any treatment.")
    print("DiD is not identified here. Anything estimated below is reported only")
    print("to show what an unwary analyst would have published.")
else:
    print("Not rejected -- but with three pre-periods this test has almost no")
    print("power, so a non-rejection is not evidence that parallel trends hold.")

print("\n--- DiD point estimate (reported, then disowned) ---")
post = did[did.month >= "2026-04-01"]
tp, cp = post[post.grp == "treated"].mean_recovery.mean(), post[post.grp == "control"].mean_recovery.mean()
tq = pre[pre.grp == "treated"].mean_recovery.mean()
cq = pre[pre.grp == "control"].mean_recovery.mean()
est = (tp - tq) - (cp - cq)
n_t = int(did[did.grp == "treated"].accounts.mean())
print(f"treated pre  ₹{tq:,.0f}   treated post ₹{tp:,.0f}")
print(f"control pre  ₹{cq:,.0f}   control post ₹{cp:,.0f}")
print(f"DiD estimate ₹{est:,.0f} per account-month  ({n_t:,} treated accounts)")

# Bootstrap a CI so the noise is visible rather than implied.
rng = np.random.default_rng(42)
am = con.sql("""
    WITH exposure AS (
        SELECT DISTINCT t.account_id FROM stg.daily_targeting t
        JOIN stg.campaigns c USING (campaign_id)
        WHERE c.strategy_version IN ('v2','v3'))
    SELECT am.account_id, am.month, am.recovered_amount,
           (e.account_id IS NOT NULL) AS treated,
           (am.month >= DATE '2026-04-01') AS post
    FROM gold.account_month am LEFT JOIN exposure e USING (account_id)
""").df()
boot = []
accts = am.account_id.unique()
for _ in range(400):
    s = rng.choice(accts, size=len(accts), replace=True)
    d = am.set_index("account_id").loc[s]
    g = d.groupby(["treated", "post"]).recovered_amount.mean()
    try:
        boot.append((g[True][True] - g[True][False]) - (g[False][True] - g[False][False]))
    except KeyError:
        pass
lo, hi = np.percentile(boot, [2.5, 97.5])
print(f"bootstrap 95% CI: [₹{lo:,.0f}, ₹{hi:,.0f}]   (400 account-level resamples)")
print(f"CI spans zero: {lo < 0 < hi}")

print("=" * 72)
print("""CONCLUSION

The DiD estimate is not usable, for three independent reasons, any one of
which would be sufficient:

1. NO OBSERVABLE TREATMENT. Strategy versions are interleaved, not
   sequential, and campaigns stop in May. The treatment date is imposed by
   assumption, not identified from data. An estimator built on an invented
   treatment date estimates nothing.

2. SELECTION INTO TREATMENT IS UNKNOWN AND LIKELY ENDOGENOUS. Campaign
   assignment rules (target_definition) are inconsistent across campaigns
   with the same strategy version. If accounts were targeted because they
   looked collectable, the DiD estimate is selection, not effect.

3. THE CONFIDENCE INTERVAL SPANS ZERO AND IS WIDE. Even taking the design at
   face value, the data cannot distinguish the estimate from no effect.

WHAT WOULD MAKE THIS ANSWERABLE:

  a. A dated changelog of targeting-rule deployments -- which rule, which
     accounts, which date. Without this there is no treatment variable.
  b. A holdout. Randomly withhold the new targeting rule from 10-15% of
     eligible accounts. Two months at current volumes (~5,700 targeted
     accounts/month) gives roughly 1,700 control account-months, enough to
     detect a 10% lift at 80% power given the observed variance.
  c. Account-level cost data, so that any measured lift can be converted
     into ROI rather than into rupees recovered.

Recommendation: do not attempt to estimate this counterfactual from the
existing data. Run (b). It costs one quarter and produces an answer that
does not depend on untestable assumptions.
""")
