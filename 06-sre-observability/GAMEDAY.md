# Game Day: pulse-api

A facilitated, 90-minute exercise. You need two people: a **facilitator**, who picks and injects
faults and doesn't help, and an **on-call engineer**, who only gets the pager, Grafana, Prometheus
and the runbooks. Solo? Write the scenarios on cards, shuffle them, and don't look.

## Before you start (10 min)

- [ ] `docker compose up -d --build` and `docker compose run --rm k6 &`. Let the load run for 5 minutes so the SLIs have a baseline.
- [ ] On-call has Grafana open (http://localhost:3000) and `docker compose logs -f pager` in a terminal.
- [ ] Agree a **safe word** that stops the exercise immediately. In real life this matters, because game days run against production.
- [ ] Facilitator records `slo:error_budget_remaining:ratio` and the start time.

## Rounds (15 min each)

For each round the facilitator injects a fault and starts a timer. The on-call engineer works the
page or ticket using the runbook, and says out loud what they're checking and why.

| # | Facilitator runs | On-call should… | Expected signal |
|---|---|---|---|
| 1 | `chaos.sh errors 0.1` | Get paged, open the runbook, check for recent changes, find chaos left on and clear it | Page in ~3 min |
| 2 | `chaos.sh latency 450` | Recognise a latency page vs an error page, use the percentile panel | Latency page in ~3 min |
| 3 | `chaos.sh partial` | Notice the error rate is too *low* for an all-replica fault and isolate the bad instance by label | Page; one instance's error ratio about 50% |
| 4 | `chaos.sh kill` | Get a ticket, not a page. Explain why that's correct | `PulseInstanceDown` ticket |
| 5 | `chaos.sh blackout` | SEV1: page, restore, then explain how long users were down | `PulseAllInstancesDown` page |
| 6 | `chaos.sh slow-burn`, then walk away | Next "morning": find the ticket, quantify the burn, project when the budget runs out | Ticket after hours: run this one last, overnight |

Between rounds: `chaos.sh heal`. After a 15-minute error round, the fast-burn page stays up for
up to ~30 minutes, because the 6h/30m window pair holds it (that's intended; see the alert tests).
To start the next round clean, run `chaos.sh reset-metrics`, which wipes Prometheus' data.
**Never do that in production.**

## Scorecard (fill in for each round)

| Round | Time to detect | Time to mitigate | Runbook useful? (1–5) | What was missing? |
|---|---|---|---|---|
| 1 | | | | |
| 2 | | | | |
| 3 | | | | |
| 4 | | | | |
| 5 | | | | |

## Debrief (15 min)

1. Which alert was the most useful? The noisiest?
2. Where did the runbook send you somewhere wrong or unhelpful? **Fix it now, in this repo.**
3. What would have been harder in production? (Many more replicas, real dependencies, partial deploys, customers watching.)
4. How much error budget did the game day use? Was that a good trade?
5. Write a [postmortem](postmortem-template.md) for round 3 or 5, as practice for the real thing.
