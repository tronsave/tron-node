#!/bin/bash
# Container healthcheck: the HTTP API answers and the head block is recent.
# HEALTH_MAX_LAG_SEC=0 only checks that the API answers.
set -uo pipefail

max_lag="${HEALTH_MAX_LAG_SEC:-300}"
body=$(curl -sf -m 8 -X POST "http://127.0.0.1:${HTTP_PORT:-8090}/wallet/getnowblock") || exit 1
[ "$max_lag" -gt 0 ] 2> /dev/null || exit 0

# The first "timestamp" in the response is the block header's (milliseconds).
ts=$(printf '%s' "$body" | grep -o '"timestamp":[0-9]*' | head -1 | cut -d: -f2)
[ -n "$ts" ] || exit 1
lag=$(( $(date +%s) - ts / 1000 ))
[ "$lag" -le "$max_lag" ] || { echo "head block is ${lag}s old (limit ${max_lag}s)"; exit 1; }
