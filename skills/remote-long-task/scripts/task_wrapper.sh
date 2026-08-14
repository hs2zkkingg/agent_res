#!/usr/bin/env bash
set -u

TASK_NAME="${1:?usage: task_wrapper.sh <TASK_NAME> <TASK_TIMEOUT_SEC> <REAL_CMD...>}"
TASK_TIMEOUT="${2:?task timeout in seconds is required}"
shift 2

WORK_DIR="${WORK_DIR:?set WORK_DIR to an explicit remote task directory}"
STATE_FILE="$WORK_DIR/$TASK_NAME.STATE"
LOG_FILE="$WORK_DIR/$TASK_NAME.log"
mkdir -p "$WORK_DIR"

if [ -f "$STATE_FILE" ]; then
  previous="$(cat "$STATE_FILE")"
  case "$previous" in
    DONE) echo "SKIP: $TASK_NAME is DONE"; exit 0 ;;
    RUNNING) echo "SKIP: $TASK_NAME is RUNNING"; exit 0 ;;
  esac
fi

echo "RUNNING" > "$STATE_FILE"
echo "=== [$(date '+%F %T')][$(hostname)] $TASK_NAME started ===" >> "$LOG_FILE"
started="$(date +%s)"
timeout "$TASK_TIMEOUT" "$@" >> "$LOG_FILE" 2>&1
rc=$?
finished="$(date +%s)"
echo "=== [$(date '+%F %T')] $TASK_NAME rc=$rc elapsed=$((finished-started))s ===" >> "$LOG_FILE"

if [ "$rc" -eq 124 ]; then
  echo "TIMEOUT" > "$STATE_FILE"
  exit 2
elif [ "$rc" -eq 0 ]; then
  echo "DONE" > "$STATE_FILE"
  exit 0
else
  echo "FAIL" > "$STATE_FILE"
  exit 1
fi

