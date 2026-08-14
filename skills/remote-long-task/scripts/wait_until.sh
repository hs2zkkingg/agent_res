#!/usr/bin/env bash
set -u

COND_CMD="${1:?usage: wait_until.sh <COND_CMD> [TIMEOUT_SEC] [HEALTH_CMD] [POLL_SEC]}"
TIMEOUT="${2:-3600}"
HEALTH_CMD="${3:-}"
POLL_SEC="${4:-5}"
started="$(date +%s)"
last_heartbeat=0

while true; do
  if eval "$COND_CMD" >/dev/null 2>&1; then
    echo "COMPLETE: condition met"
    exit 0
  fi
  if [ -n "$HEALTH_CMD" ] && ! eval "$HEALTH_CMD" >/dev/null 2>&1; then
    echo "CRASH: health check failed" >&2
    exit 3
  fi

  now="$(date +%s)"
  elapsed=$((now - started))
  if [ "$elapsed" -ge "$TIMEOUT" ]; then
    echo "WAIT-TIMEOUT: condition unmet after ${TIMEOUT}s" >&2
    exit 1
  fi
  if [ $((elapsed - last_heartbeat)) -ge 60 ]; then
    echo "[wait ${elapsed}s] condition not met"
    last_heartbeat="$elapsed"
  fi
  sleep "$POLL_SEC"
done

