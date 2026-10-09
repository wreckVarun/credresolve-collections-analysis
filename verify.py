"""Cross-check every number asserted in the reports against the rebuilt DB."""
#
# Run after pipeline.py. Cross-checks every numeric claim made in the
# reports against the rebuilt database. Any FAIL means a document and the
# data disagree.
#   python pipeline.py --data-dir <raw> --out data && python verify.py
import sys
import duckdb, numpy as np
from scipy import stats
c=duckdb.connect('data/collections.duckdb', read_only=True); v=lambda s: float(c.sql(s).fetchone()[0])
results=[]
def ok(cond,label,got):
    results.append(bool(cond))
    print(f"{'PASS' if cond else '*** FAIL ***':12s} {label:52s} {got}")

m=c.sql("select * from metrics.monthly_recovery order by month").df()

# headline claims
ok(abs(m.mom_pct_naive[2]-11.0)<0.15, "+11.0% naive MoM Feb->Mar", round(m.mom_pct_naive[2],2))
ok(abs(m.mom_pct_per_day[2]-0.3)<0.15, "+0.3% day-normalised MoM", round(m.mom_pct_per_day[2],2))
a,b=m.mom_pct_naive.dropna(),m.mom_pct_per_day.dropna()
ok(abs(a.std()-8.4)<0.15 and abs(b.std()-2.6)<0.15, "sd 8.4% -> 2.6%", f"{a.std():.2f} -> {b.std():.2f}")
lo,hi=(m.recovery_per_day/1e5).min(),(m.recovery_per_day/1e5).max()
ok(abs(lo-58.4)<0.2 and abs(hi-60.9)<0.2, "Rs 58.4-60.9 lakh/day range", f"{lo:.2f}-{hi:.2f}")
ok(abs(100*(hi/lo-1)-4.3)<0.3, "spread 4.3%", f"{100*(hi/lo-1):.2f}%")

sl,ic,r,p,se=stats.linregress(np.arange(len(m)),m.recovery_per_day)
ok(abs(p-0.33)<0.03, "recovery/day trend p=0.33", round(p,3))
sl2,_,r2,p2,_=stats.linregress(m.calendar_days,m.recovered_amount)
ok(abs(r2**2-0.82)<0.02 and p2<0.01, "month length r2=0.82, p=0.005", f"r2={r2**2:.3f} p={p2:.4f}")
ok(abs(100*(31/28-1)-10.7)<0.05, "31/28-1 = 10.7%", f"{100*(31/28-1):.2f}%")

# reconciliation
raw=v("select sum(amount)/1e7 from stg.payments"); ded=v("select sum(amount)/1e7 from gold.fct_payment")
suc=v("select sum(recovered_amount)/1e7 from gold.fct_payment"); gold=v("select sum(recovered_amount)/1e7 from gold.account_month")
ok(abs(raw-191.7)<0.1,"raw Rs 191.7 Cr",round(raw,2))
ok(abs(raw-ded-3.8)<0.1,"dupes Rs 3.8 Cr",round(raw-ded,2))
ok(abs(ded-suc-56.3)<0.1,"non-SUCCESS Rs 56.3 Cr",round(ded-suc,2))
ok(abs(gold-126.9)<0.1,"golden Jan-Jul Rs 126.9 Cr",round(gold,2))
ok(abs(100*(raw-suc)/raw-31.4)<0.1 and abs(raw-suc-60.2)<0.1,"Rs 60.2 Cr / 31.4% not recovered money",f"{raw-suc:.2f} / {100*(raw-suc)/raw:.2f}%")
ok(abs(suc-gold-4.71)<0.01,"Rs 4.71 Cr August held out of trend",round(suc-gold,2))
ok(abs(100*(ded-suc)/suc-43)<1.5,"+43% level inflation",f"{100*(ded-suc)/suc:.1f}%")
ok(v("select count(*) from stg.payments")-v("select count(*) from gold.fct_payment")==500,"exactly 500 dupes removed",
   v("select count(*) from stg.payments")-v("select count(*) from gold.fct_payment"))
ok(v("select count(*) from gold.fct_payment where is_recovered")==17534,"17,534 SUCCESS rows",v("select count(*) from gold.fct_payment where is_recovered"))
fx=lambda m: v(f"select value from forensics.a_duplicate_payments where measure='{m}'")
ok(abs(fx('rupees_sharing_a_reference')/1e7-60.8)<0.2 and fx('rows_sharing_a_reference')==8042,
   "8,042 rows / Rs 60.8 Cr share a reference", f"{fx('rows_sharing_a_reference'):.0f} / {fx('rupees_sharing_a_reference')/1e7:.2f}")
ok(fx('genuine_payments_naive_dedup_would_delete')==3808 and abs(fx('rupees_naive_dedup_would_delete')/1e7-28.9)<0.1,
   "naive ref-dedup deletes 3,808 genuine / Rs 28.9 Cr", f"{fx('genuine_payments_naive_dedup_would_delete'):.0f} / {fx('rupees_naive_dedup_would_delete')/1e7:.2f}")
ok(abs(fx('recovered_rupees_naive_dedup_would_delete')/1e7-19.8)<0.1,
   "... of which Rs 19.8 Cr SUCCESS recovery", round(fx('recovered_rupees_naive_dedup_would_delete')/1e7,2))

# attribution
o=c.sql("select * from forensics.b_attribution_overlap order by channels_touching").df()
tot=o.recovered_amount.sum()
ok(abs(o.recovered_amount[0]/1e7-46.0)<0.2,"untouched Rs 46.0 Cr",round(o.recovered_amount[0]/1e7,2))
ok(abs(100*o.recovered_amount[0]/tot-36)<1,"untouched 36%",f"{100*o.recovered_amount[0]/tot:.1f}%")
multi=o.recovered_amount[2:].sum()
ok(abs(multi/1e7-23.1)<0.2,"multi-channel Rs 23.1 Cr",round(multi/1e7,2))
ok(abs(100*multi/tot-18)<1,"multi-channel 18%",f"{100*multi/tot:.1f}%")
ok(abs(100*o.recovered_amount[1]/tot-45)<1.5,"single-channel 45%",f"{100*o.recovered_amount[1]/tot:.1f}%")

# identity defects
ok(v("select count(*) from stg.borrowers")==30600 and v("select count(distinct borrower_id) from stg.borrowers")==11015,"borrowers 30,600 -> 11,015","ok")
ok(v("select count(*) from gold.dim_borrower where has_conflicting_identity")==8468,"8,468 conflicting borrowers",v("select count(*) from gold.dim_borrower where has_conflicting_identity"))
ok(v("select count(distinct agent_id) from stg.agents")==1000 and v("select count(distinct employee_code) from stg.agents")==1099 and v("select count(distinct agent_name) from stg.agents")==10,"agents 1000/1099/10","ok")
ok(v("select count(*) from gold.dim_account")==30000,"dim_account 30,000 (no fan-out)",v("select count(*) from gold.dim_account"))
ok(v("select count(*) from gold.account_month")==210000,"account_month 210,000 rows",v("select count(*) from gold.account_month"))

# other defects
dc=v("select count(*) from gold.fct_call where has_duration_contradiction")
ok(abs(100*dc/91350-60)<1.5,"60% duration contradiction",f"{100*dc/91350:.1f}%")
ci=v("select count(*) from gold.fct_status_history where is_clock_inverted")
ok(ci==30191,"30,191 clock inversions",ci)
tz=c.sql("select sum(hour_bucket_changed) h, sum(calendar_day_changed) d from forensics.c_timezone_impact").df()
ok(abs(100*tz.h[0]/91350-67)<1.5,"67% wrong hour bucket",f"{100*tz.h[0]/91350:.1f}%")
ok(tz.d[0]==8924,"8,924 calendar-day shifts",int(tz.d[0]))

# drivers
af=c.sql("select * from drivers.attempt_frequency order by attempt_band").df()
ok(abs(af.pct_paying[0]-7.89)<0.05 and abs(af.pct_paying[2]-7.74)<0.05,"attempts 7.9% vs 7.7%",f"{af.pct_paying[0]}/{af.pct_paying[2]}")
vm=c.sql("select * from drivers.vendor_month").df()
ok(vm.active_vendors.min()==15 and abs(vm.connect_pct.min()-19.31)<0.05 and abs(vm.connect_pct.max()-20.47)<0.05,"vendors 15, connect 19.3-20.5%",f"{vm.connect_pct.min()}-{vm.connect_pct.max()}")
cv=c.sql("select * from drivers.cohort_vintage order by vintage_year").df()
ok(abs(cv.avg_recovery[0]-6030)<2 and abs(cv.avg_recovery[1]-6052)<2,"vintages 6030 vs 6052",f"{cv.avg_recovery.tolist()}")
pr=c.sql("select * from metrics.productivity order by month").df(); pr=pr[pr.month<'2026-08-01']
ok(abs(pr.recovery_per_agent_hour.min()-16117)<20 and abs(pr.recovery_per_agent_hour.max()-17008)<20,"agent-hour 16.1-17.0K",f"{pr.recovery_per_agent_hour.min():.0f}-{pr.recovery_per_agent_hour.max():.0f}")
gt=c.sql("select * from forensics.g_targeting_by_status").df()
ok(abs(100*gt.coverage.min()-77.2)<0.2 and abs(100*gt.coverage.max()-78.1)<0.2,"targeting coverage 77-78%",f"{100*gt.coverage.min():.1f}-{100*gt.coverage.max():.1f}")
gd=c.sql("select * from forensics.g_denominator").df()
ok(abs(100*gd.rate_fixed_denominator.min()-7.24)<0.05 and abs(100*gd.rate_fixed_denominator.max()-8.06)<0.05,"recovery rate 7.2-8.1%",f"{100*gd.rate_fixed_denominator.min():.2f}-{100*gd.rate_fixed_denominator.max():.2f}")

dq=c.sql("select count(*) from dq.results where status='FAIL'").fetchone()[0]
ok(dq==0,"all blocking data-quality checks pass",f"{dq} failing")

n_fail=results.count(False)
print(f"\n{len(results)-n_fail}/{len(results)} checks passed")
sys.exit(1 if n_fail else 0)
