# Postmortem: <title>

> **Blameless.** We're here to understand how the *system* (code, process, tooling, incentives)
> made this outcome likely, not to find who to blame. People acted reasonably with the information
> they had. If they didn't have the right information, that's a finding.

| | |
|---|---|
| **Date** | YYYY-MM-DD |
| **Authors** | |
| **Status** | Draft / In review / Final |
| **Severity** | SEV1 / SEV2 / SEV3 |
| **Duration** | detection → mitigation → resolution |
| **Error budget consumed** | x% of 30-day availability budget (`slo:error_budget_remaining:ratio` before → after) |

## Summary
Two or three sentences a VP can read: what broke, who was affected, for how long, and what fixed it.

## Impact
- Users affected / requests failed (from `http_requests_total`):
- Revenue, data or SLA impact:
- Support tickets / customer reports:

## Timeline (UTC)
| Time | Event |
|---|---|
| 00:00 | Change X deployed |
| 00:04 | `PulseErrorBudgetBurnFast` pending |
| 00:06 | Page fired, acknowledged by … |
| 00:09 | Rollback started |
| 00:11 | Error rate back to baseline (**mitigated**) |
| 00:45 | Page resolved; root cause confirmed (**resolved**) |

**Time to detect:** · **Time to mitigate:** · **Time to resolve:**

## Root cause and trigger
- **Trigger:** what started it (a deploy, traffic spike, expiry, dependency failure)
- **Root cause(s):** why the system was vulnerable to that trigger. Keep asking "why" until you
  reach something you can change. Usually there are several contributing factors, not one root.

## What went well
## What went wrong
## Where we got lucky

## Action items
| Action | Type (prevent / detect / mitigate) | Owner | Ticket | Due |
|---|---|---|---|---|
| | | | | |

Rules for action items: each one has an owner and a date, and **at least one prevents recurrence**.
"Be more careful" isn't an action item. "Add a pre-deploy check that blocks X" is.
