#!/bin/bash
# slack-watch-loop.sh — run slack-watch.sh on an interval until killed.
# Start:  MARGIE_SLACK_MODE=live nohup .../slack-watch-loop.sh >/dev/null 2>&1 &
# Stop:   pkill -f slack-watch-loop
#
# MARGIE_SLACK_MODE   preview (default) | live
# MARGIE_SLACK_INTERVAL   seconds between checks (default 90)
set -uo pipefail

INTERVAL="${MARGIE_SLACK_INTERVAL:-90}"
MODE="${MARGIE_SLACK_MODE:-preview}"
DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$HOME/.margie/slack-watch.log"
mkdir -p "$HOME/.margie"

echo "$(date -u +%FT%TZ) loop start mode=$MODE interval=${INTERVAL}s" >> "$LOG"
trap 'echo "$(date -u +%FT%TZ) loop stop" >> "$LOG"; exit 0' TERM INT

while true; do
  MARGIE_SLACK_MODE="$MODE" "$DIR/slack-watch.sh" || true
  sleep "$INTERVAL"
done
