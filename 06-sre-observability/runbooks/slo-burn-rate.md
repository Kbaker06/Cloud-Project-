# Runbook: slow error-budget burn (`PulseErrorBudgetBurnSlow`)

**Severity:** ticket (business hours) · **SLO:** availability 99.9%

A slow burn means we're failing slightly more than we can afford, and will run out of budget
within days to weeks. Nobody needs waking up, but somebody needs to own it this week.

1. **Quantify:** what's the current burn rate and the projected exhaustion date?
   ```promql
   slo:sli_error:ratio_rate1d / 0.001                    # burn rate
   slo:error_budget_remaining:ratio                      # budget left
   ```
   At burn rate *B* with *R* budget remaining, exhaustion is in roughly `R × 30 / B` days.
2. **Find the shape:** is it a steady trickle (bug in an edge-case path) or periodic spikes (cron
   job, GC, a noisy neighbour)? Zoom the *Error ratio by window* panel out to 3 days.
3. **Find the source:** group the 5xx rate by `route` and by `instance`. Look for a correlation with a
   deploy annotation.
4. **Decide:** fix this sprint, or accept and document it. If the budget is projected to drop below
   25%, the [error budget policy](../SLO.md#error-budget-policy) freezes features.
