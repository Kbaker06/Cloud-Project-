#!/usr/bin/env bash
# Game-day fault injection against the docker compose stack.
#   ./chaos/chaos.sh <scenario>
# Scenarios:
#   errors [rate]    inject 5xx on both replicas (default 0.1 = 10%)     → PulseErrorBudgetBurnFast
#   slow-burn        0.5% errors: a ticket after hours, never a page     → PulseErrorBudgetBurnSlow
#   latency [ms]     add latency on both replicas (default 400ms)        → PulseLatencyBudgetBurnFast
#   partial          50% errors on ONE replica (find which one!)
#   kill             stop api-2                                          → PulseInstanceDown (ticket)
#   blackout         stop both                                           → PulseAllInstancesDown (page)
#   heal             clear all faults and start everything
#   reset-metrics    wipe Prometheus TSDB so the next game-day round starts with clean windows (lab only!)
#   status           show current chaos config per replica
set -euo pipefail
cd "$(dirname "$0")/.."
TOKEN="${ADMIN_TOKEN:-gameday-token}"

set_chaos() { # replica error_rate latency_ms
  curl -fsS -X PUT "http://localhost:$(port "$1")/admin/chaos" -H "Authorization: Bearer $TOKEN" \
    -d "{\"error_rate\": $2, \"latency_ms\": $3}" && echo "  ← $1"
}
port() { [[ "$1" == api-1 ]] && echo 8081 || echo 8082; }

case "${1:-}" in
  errors)    for r in api-1 api-2; do set_chaos $r "${2:-0.1}" 0; done ;;
  slow-burn) for r in api-1 api-2; do set_chaos $r 0.005 0; done ;;
  latency)   for r in api-1 api-2; do set_chaos $r 0 "${2:-400}"; done ;;
  partial)   set_chaos "api-$(( RANDOM % 2 + 1 ))" 0.5 0 >/dev/null; echo "one replica is now failing half its requests. Which one? Use Grafana." ;;
  kill)      docker compose stop api-2 ;;
  blackout)  docker compose stop api-1 api-2 ;;
  heal)      docker compose start api-1 api-2; sleep 2; for r in api-1 api-2; do set_chaos $r 0 0; done ;;
  reset-metrics)
             docker compose rm -sf prometheus && docker volume rm -f gameday_prometheus-data >/dev/null \
               && docker compose up -d prometheus && echo "Prometheus reset: SLI windows are empty again" ;;
  status)    for r in api-1 api-2; do printf '%s: ' $r; curl -fsS "http://localhost:$(port $r)/admin/chaos" -H "Authorization: Bearer $TOKEN" || echo down; echo; done ;;
  *)         sed -n '2,14p' "$0"; exit 64 ;;
esac
