# Runbook: instance down (`PulseInstanceDown`, `PulseAllInstancesDown`)

**One instance down — ticket.** The other replicas absorb traffic. If they can't, the SLO alerts page.
**All instances down — page.** Full outage, so treat it as SEV1.

1. **Is the process dead, or just not scrapeable?** `up == 0` means Prometheus couldn't scrape it.
   That covers a crash, but also network policy changes, DNS, or the wrong port.
   - k8s: `kubectl -n pulse get pods -o wide`, `kubectl -n pulse describe pod <pod>` (Events!)
   - compose: `docker compose ps`, `docker compose logs api-2`
2. **CrashLoopBackOff?** `kubectl logs <pod> --previous` shows the crash from the *last* run.
3. **OOMKilled?** Raise the memory limit as a stop-gap and open a ticket to find the leak (heap profile).
4. **Pending pods?** Not enough capacity, an affinity/topology constraint that can't be met, or a PDB
   blocking a drain. `kubectl describe pod` explains it.
5. **All down after a deploy?** Roll back. Readiness probes should have stopped a bad rollout, so
   if they didn't, that's a postmortem action item.
