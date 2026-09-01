#!/bin/bash
# poll-loop.sh — stopgap background poller until the brain daemon hosts these.
# Every 60s: dispatch.sh tick + claude-task.sh notify; every 5th cycle:
# agent-messages.sh check. Anything they print becomes a spoken announcement
# (announce drop-box) AND a line in ~/.margie/poll.log. Silent when idle.
# Start: nohup scripts/poll-loop.sh >/dev/null 2>&1 &     Stop: pkill -f poll-loop
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$HOME/.margie/poll.log"
mkdir -p "$HOME/.margie/announce"
say() { while IFS= read -r l; do [ -z "$l" ] && continue; echo "$(date -u +%FT%TZ) $l" >> "$LOG"; printf '%s' "$l" > "$HOME/.margie/announce/$(date +%s%N).txt"; done; }
echo "$(date -u +%FT%TZ) poll loop start" >> "$LOG"
trap 'echo "$(date -u +%FT%TZ) poll loop stop" >> "$LOG"; exit 0' TERM INT
n=0
while true; do
  "$DIR/dispatch.sh" tick 2>>"$LOG" | say
  "$DIR/claude-task.sh" notify 2>>"$LOG" | say
  MARGIE_POLLER=1 "$DIR/slack-watch.sh" 2>>"$LOG" | say
  if [ $((n % 5)) = 0 ]; then "$DIR/agent-messages.sh" check 2>>"$LOG" | say; fi
  n=$((n + 1))
  sleep 60
done
