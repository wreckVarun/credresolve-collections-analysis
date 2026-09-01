#!/usr/bin/env python3
"""Generate the figures used in the notebook, memo and dashboard."""
import duckdb, numpy as np, matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from scipy import stats

INK, MUTE, ALERT, OK = "#1a1a1a", "#8a8a8a", "#b23a2f", "#2f6b4f"
plt.rcParams.update({
    "font.family": "DejaVu Sans", "font.size": 9,
    "axes.spines.top": False, "axes.spines.right": False,
    "axes.edgecolor": "#cccccc", "axes.labelcolor": INK,
    "xtick.color": MUTE, "ytick.color": MUTE, "figure.dpi": 140,
})

con = duckdb.connect("data/collections.duckdb")
m = con.sql("SELECT * FROM metrics.monthly_recovery ORDER BY month").df()
lbl = m.month.dt.strftime("%b")

# --- Fig 1: the whole finding in one chart -----------------------------
fig, ax = plt.subplots(1, 2, figsize=(9, 3.4))
ax[0].bar(lbl, m.recovered_amount / 1e7, color=MUTE, width=.62)
ax[0].bar(lbl[2:3], m.recovered_amount[2:3] / 1e7, color=ALERT, width=.62)
ax[0].set_title("Reported: monthly recovery total", loc="left", color=INK, fontsize=10)
ax[0].set_ylabel("₹ crore")
ax[0].annotate("+11.0%\nreported as\nimprovement", xy=(2, 18.9), xytext=(3.1, 20.4),
               color=ALERT, fontsize=8, ha="left",
               arrowprops=dict(arrowstyle="->", color=ALERT, lw=1))
ax[0].set_ylim(0, 23)

ax[1].bar(lbl, m.recovery_per_day / 1e5, color=MUTE, width=.62)
ax[1].bar(lbl[2:3], m.recovery_per_day[2:3] / 1e5, color=OK, width=.62)
ax[1].set_title("Corrected: recovery per calendar day", loc="left", color=INK, fontsize=10)
ax[1].set_ylabel("₹ lakh / day")
ax[1].annotate("+0.3%\nno change", xy=(2, 60.9), xytext=(3.1, 66),
               color=OK, fontsize=8, ha="left",
               arrowprops=dict(arrowstyle="->", color=OK, lw=1))
ax[1].set_ylim(0, 75)
fig.tight_layout(); fig.savefig("figures/fig1_headline.png", bbox_inches="tight"); plt.close()

# --- Fig 2: volatility collapse ---------------------------------------
a, b = m.mom_pct_naive.dropna(), m.mom_pct_per_day.dropna()
fig, ax = plt.subplots(figsize=(6.4, 3.2))
x = np.arange(len(a))
ax.axhline(0, color="#dddddd", lw=1)
ax.plot(x, a.values, "o-", color=ALERT, lw=1.6, ms=5, label=f"Monthly total  (sd {a.std():.1f}%)")
ax.plot(x, b.values, "o-", color=OK, lw=1.6, ms=5, label=f"Per calendar day  (sd {b.std():.1f}%)")
ax.axhspan(-2 * b.std(), 2 * b.std(), color=OK, alpha=.07)
ax.set_xticks(x); ax.set_xticklabels(lbl[1:])
ax.set_ylabel("month-on-month %")
ax.set_title("Month-on-month volatility is a calendar artefact", loc="left", color=INK, fontsize=10)
ax.legend(frameon=False, fontsize=8)
fig.tight_layout(); fig.savefig("figures/fig2_volatility.png", bbox_inches="tight"); plt.close()

# --- Fig 3: days vs recovery -------------------------------------------
fig, ax = plt.subplots(figsize=(4.6, 3.4))
ax.scatter(m.calendar_days, m.recovered_amount / 1e7, s=52, color=INK, zorder=3)
sl, ic, r, p, se = stats.linregress(m.calendar_days, m.recovered_amount / 1e7)
xs = np.array([27.6, 31.4])
ax.plot(xs, ic + sl * xs, color=ALERT, lw=1.4)
for _, row in m.iterrows():
    ax.annotate(row.month.strftime("%b"), (row.calendar_days, row.recovered_amount / 1e7),
                textcoords="offset points", xytext=(6, -3), fontsize=7, color=MUTE)
ax.set_xlabel("days in month"); ax.set_ylabel("₹ crore recovered")
ax.set_title(f"Recovery tracks the calendar\nr² = {r**2:.2f},  p = {p:.4f}", loc="left", color=INK, fontsize=10)
fig.tight_layout(); fig.savefig("figures/fig3_calendar.png", bbox_inches="tight"); plt.close()

# --- Fig 4: reconciliation waterfall -----------------------------------
led = con.sql("""
  SELECT (SELECT sum(amount) FROM stg.payments)/1e7 AS raw,
         (SELECT sum(amount) FROM gold.fct_payment)/1e7 AS deduped,
         (SELECT sum(recovered_amount) FROM gold.fct_payment)/1e7 AS success
""").df().iloc[0]
steps = ["Raw payment\nrows", "− duplicate\nrows", "− failed / pending /\nreversed", "Golden:\nrecovered"]
vals = [led.raw, -(led.raw - led.deduped), -(led.deduped - led.success), led.success]
fig, ax = plt.subplots(figsize=(6.2, 3.4))
run = 0
for i, (s, v) in enumerate(zip(steps, vals)):
    if i in (0, 3):
        ax.bar(i, v, color=INK if i == 3 else MUTE, width=.6); run = v
    else:
        ax.bar(i, v, bottom=run, color=ALERT, width=.6); run += v
    ax.text(i, max(run, run - v) + 4, f"₹{abs(v):.0f} Cr", ha="center", fontsize=8, color=INK)
ax.set_xticks(range(4)); ax.set_xticklabels(steps, fontsize=8)
ax.set_ylabel("₹ crore"); ax.set_ylim(0, 220)
ax.set_title("Raw → Golden: 31% of reported payment value is not recovery",
             loc="left", color=INK, fontsize=10)
fig.tight_layout(); fig.savefig("figures/fig4_reconciliation.png", bbox_inches="tight"); plt.close()

# --- Fig 5: untouched recovery ----------------------------------------
ov = con.sql("SELECT * FROM forensics.b_attribution_overlap ORDER BY channels_touching").df()
fig, ax = plt.subplots(figsize=(5.4, 3.2))
cols = [ALERT, MUTE, MUTE, MUTE]
ax.bar(ov.channels_touching.astype(str), ov.recovered_amount / 1e7, color=cols, width=.6)
tot = ov.recovered_amount.sum()
for i, r in ov.iterrows():
    ax.text(i, r.recovered_amount / 1e7 + 1.5, f"{100*r.recovered_amount/tot:.0f}%",
            ha="center", fontsize=8, color=INK)
ax.set_xlabel("channels that touched the account that month")
ax.set_ylabel("₹ crore recovered")
ax.set_title("36% of recovery arrives with no interaction at all", loc="left", color=INK, fontsize=10)
fig.tight_layout(); fig.savefig("figures/fig5_attribution.png", bbox_inches="tight"); plt.close()

# --- Fig 6: segment stability ------------------------------------------
seg = con.sql("""SELECT month, segment, recovery_per_day FROM metrics.segment_month
                 WHERE dimension='risk_segment' ORDER BY 1,2""").df()
fig, ax = plt.subplots(figsize=(6.2, 3.2))
for s, g in seg.groupby("segment"):
    ax.plot(g.month.dt.strftime("%b"), g.recovery_per_day / 1e5, "o-", ms=4, lw=1.4, label=s)
ax.set_ylabel("₹ lakh / day"); ax.set_ylim(0, None)
ax.set_title("No segment is moving: risk-segment recovery per day", loc="left", color=INK, fontsize=10)
ax.legend(frameon=False, fontsize=8, ncol=3)
fig.tight_layout(); fig.savefig("figures/fig6_segments.png", bbox_inches="tight"); plt.close()

print("figures written")
