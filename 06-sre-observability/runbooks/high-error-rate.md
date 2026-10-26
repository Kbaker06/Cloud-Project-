# Runbook: pulse-api high error rate (`PulseErrorBudgetBurnFast`, `PulseHighErrorRate`)

**Severity:** page · **SLO:** availability 99.9% · **Dashboard:** Grafana → SRE → *pulse-api — SLOs & error budget*

## 1. Stabilise first, understand later (target: 5 minutes)

1. **Acknowledge** the page and say so in the incident channel: *"Investigating pulse-api 5xx, I'm IC."*
2. **Did something just change?** Most incidents are caused by a change.
   - Deploys: `kubectl -n pulse rollout history deploy/pulse-api` / ECS → *Deployments* tab / Argo CD history.
   - Config, feature flags, infra applies (check the `terraform-deploy` workflow runs).
   - **If a change landed in the last ~30 minutes, roll it back now.** Don't debug forward while users are failing.
     - k8s: `kubectl -n pulse rollout undo deploy/pulse-api`
     - ECS: redeploy the previous task definition revision
     - Argo CD: revert the commit in git (Argo will sync), or `argocd app rollback pulse-api`
3. **Is it all replicas or one?** Dashboard → *Requests/s by route and status*, split by `instance`:
   ```promql
   sum by (instance) (rate(http_requests_total{code=~"5.."}[5m])) / sum by (instance) (rate(http_requests_total[5m]))
   ```
   - **One instance**: take it out (`kubectl delete pod <pod>`, or stop that container/task) and let the others serve.
   - **All instances**: it's shared, so think deploy, config or a dependency.
4. **Is it one route?** Group by `route`. A single bad endpoint can sometimes be disabled behind a flag.

## 2. Diagnose

| Check | How |
|---|---|
| Error logs | `kubectl -n pulse logs -l app.kubernetes.io/name=pulse-api --since=15m \| grep '"level":"ERROR"'` or CloudWatch Logs Insights: `fields @timestamp, msg, err \| filter level="ERROR" \| sort @timestamp desc` |
| Fault injection left on? | `GET /admin/chaos` on each replica. **Check this during game days — it has caused real incidents elsewhere.** |
| Restarts / OOM | `kubectl -n pulse get pods` (RESTARTS column) · `kubectl describe pod` → `Last State: OOMKilled` |
| Saturation | in-flight requests climbing? CPU at limit? HPA at max (`PulseHPAMaxedOut`)? |
| Dependencies | DB connections, downstream 5xx/timeouts in logs |

## 3. Resolve and follow up

- Watch the 5m error ratio return to baseline. The page clears once the short window (5m/30m) is clean.
- Post the impact in the incident channel: start and end time, error rate, budget consumed
  (`slo:error_budget_remaining:ratio` before and after).
- **Postmortem required if:** more than 10% of the monthly budget was consumed, or any customer-reported impact.
  Use [`../postmortem-template.md`](../postmortem-template.md).
