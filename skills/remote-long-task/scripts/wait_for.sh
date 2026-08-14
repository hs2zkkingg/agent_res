#!/usr/bin/env bash
set -u

STATE_FILE="${1:?usage: wait_for.sh <STATE_FILE> [TIMEOUT_SEC] [HEALTH_CMD] [POLL_SEC]}"
TIMEOUT="${2:-3600}"
HEALTH_CMD="${3:-}"
POLL_SEC="${4:-5}"
started="$(date +%s)"
last_heartbeat=0

while true; do
  if [ -f "$STATE_FILE" ]; then
    state="$(cat "$STATE_FILE" 2>/dev/null)"
    case "$state" in
      DONE) echo "COMPLETE: DONE"; exit 0 ;;
      FAIL) echo "COMPLETE: FAIL"; exit 2 ;;
      TIMEOUT) echo "COMPLETE: TIMEOUT"; exit 2 ;;
    esac
  fi

  if [ -n "$HEALTH_CMD" ] && ! eval "$HEALTH_CMD" >/dev/null 2>&1; then
    echo "CRASH: health check failed" >&2
    exit 3
  fi

  now="$(date +%s)"
  elapsed=$((now - started))
  if [ "$elapsed" -ge "$TIMEOUT" ]; then
    echo "WAIT-TIMEOUT: ${TIMEOUT}s state=$(cat "$STATE_FILE" 2>/dev/null || echo N/A)" >&2
    exit 1
  fi
  if [ $((elapsed - last_heartbeat)) -ge 60 ]; then
    echo "[wait ${elapsed}s] state=$(cat "$STATE_FILE" 2>/dev/null || echo N/A)"
    last_heartbeat="$elapsed"
  fi
  sleep "$POLL_SEC"
done

