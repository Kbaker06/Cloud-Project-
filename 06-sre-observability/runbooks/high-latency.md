# Runbook: pulse-api latency SLO burn (`PulseLatencyBudgetBurnFast`)

**Severity:** page · **SLO:** 99% of requests < 300 ms

1. **Confirm it's real:** Dashboard → *Latency percentiles*. Is p99 above 300 ms on every route, or only on one?
   ```promql
   histogram_quantile(0.99, sum by (le, route) (rate(http_request_duration_seconds_bucket[5m])))
   ```
2. **Recent change?** Same as [high-error-rate](high-error-rate.md#1-stabilise-first-understand-later-target-5-minutes): roll back first.
3. **Saturation:** latency is often the first sign of running out of something.
   - CPU: is the HPA at max? Are pods CPU-throttled (`container_cpu_cfs_throttled_periods_total`)?
   - Requests in flight growing without bound → queueing → scale out *now* (`kubectl scale`, raise the HPA max).
4. **Injected latency left on?** `GET /admin/chaos`.
5. **Dependency slowness:** if the DB is slow, every route slows together. Check RDS Performance
   Insights for top SQL and the slow query log (`log_min_duration_statement=500` is set in project 01).
6. Latency incidents often turn into error incidents through client timeouts. Watch the availability panel too.
