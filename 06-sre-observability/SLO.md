# pulse-api — Service Level Objectives

| | |
|---|---|
| **Service** | pulse-api (notes API) |
| **Owner** | Platform team |
| **Review cadence** | Monthly, and after every SEV1/SEV2 |
| **Status** | Adopted |

## Why these SLOs

Users notice two things: requests failing and requests being slow. Uptime percentages, CPU and
queue depth are causes, not what users experience, so they are not SLOs. We alert on the
experience and diagnose with the causes.

## SLIs

| SLI | Good event | Valid event | Source |
|---|---|---|---|
| **Availability** | response status is not 5xx | every request to an instrumented API route | `http_requests_total` |
| **Latency** | served in < 300 ms | every API request except `/api/v1/work` | `http_request_duration_seconds_bucket{le="0.3"}` |

Notes:

- Measured **server-side** at the application. Load balancer errors and client network failures
  aren't counted, which is a known gap. Stretch goal: add a synthetic probe (blackbox exporter) so
  "the process is up but unreachable" is also measured.
- 4xx responses count as **good**: the service did its job by rejecting a bad request. A spike in
  4xx after a deploy is still worth a dashboard panel, because it can mean we broke a client.
- `/healthz`, `/readyz` and `/metrics` aren't instrumented, so probe traffic can't make the SLI look better.
- `/api/v1/work` is excluded from latency because its *purpose* is to be slow (CPU burn for autoscaling labs).

## SLOs

| SLO | Target | Window | Error budget |
|---|---|---|---|
| Availability | **99.9%** | rolling 30 days | 0.1% ≈ 43 minutes of total outage, or ~4,300 failed requests per 4.3M |
| Latency | **99%** under 300 ms | rolling 30 days | 1% of requests may be slower |

## Alerting: multi-window, multi-burn-rate

From the [Google SRE Workbook, ch. 5](https://sre.google/workbook/alerting-on-slos/). *Burn rate* is
how fast we're spending budget relative to "exactly on schedule".

| Alert | Condition (both windows must exceed) | Budget spent when it fires | Severity |
|---|---|---|---|
| `PulseErrorBudgetBurnFast` | 14.4× over 1h **and** 5m | 2% in 1 hour | **page** |
| | 6× over 6h **and** 30m | 5% in 6 hours | **page** |
| `PulseErrorBudgetBurnSlow` | 3× over 1d **and** 2h | 10% in 1 day | ticket |
| | 1× over 3d **and** 6h | 10% in 3 days | ticket |
| `PulseLatencyBudgetBurnFast` | same as fast burn, against the 1% latency budget | | **page** |

Why two windows? The long window means we only page for significant budget loss, not a 30-second
blip. The short window means the alert **resolves** soon after the problem stops, instead of firing
for an hour after recovery. Both behaviors have unit tests in `prometheus/tests/slo_test.yml`.

Measured in this lab: at 20% injected errors, the page fired about **2.5 minutes** after the fault
started (pending at 40 s, plus the 2-minute `for`).

## Error budget policy

The point of the budget is that it settles "ship features or fix reliability?" in advance, so the
argument doesn't happen in the middle of an incident.

| Budget remaining (30d) | What happens |
|---|---|
| > 50% | Ship freely. Risky experiments and chaos game days are encouraged; that's what the budget is for. |
| 25–50% | Releases continue, but every change needs a tested rollback. |
| 0–25% | Feature freeze for this service, except changes that improve reliability. On-call reviews every deploy. |
| < 0 (SLO breached) | Freeze stays until the budget recovers. A postmortem is required. The next sprint's top priority is the action items. |

Exceptions (e.g. a legal deadline) need sign-off from the engineering manager **and** the
product owner, recorded in the decision log.

## Not SLOs (on purpose)

- **CPU/memory**: these are capacity signals and live on dashboards. The HPA handles them.
- **Instance down**: one replica down is a ticket. If it actually hurts users, the SLO alerts page anyway.
- **100%**: an availability target of 100% means you can never deploy. Our dependencies don't offer it either.
