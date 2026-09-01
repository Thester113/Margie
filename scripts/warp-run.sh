#!/bin/bash
# warp-run.sh — run an arbitrary command in a new, foregrounded Warp tab.
# Use for dev servers, test runs, log tails — anything Tom wants to watch.
#
# Usage: warp-run.sh <dir> <command...>
#   e.g. warp-run.sh ~/repos/backend npm run dev
#
# Same reliable mechanism as kickoff-claude.sh: a Warp Launch Configuration +
# the warp://launch URI, then foreground Warp. The command is routed through a
# file so quoting/pipes/quotes can't corrupt the config.
set -euo pipefail

DIR="${1:-$HOME}"
shift || true
CMD="$*"
if [ -z "$CMD" ]; then
  echo "usage: warp-run.sh <dir> <command...>" >&2
  exit 1
fi

DIR_ABS="$(cd "$DIR" 2>/dev/null && pwd || echo "$HOME")"
CFG_DIR="$HOME/.warp/launch_configurations"
TASK_DIR="$HOME/.margie/tasks"
mkdir -p "$CFG_DIR" "$TASK_DIR"

STAMP="$(date +%s)"
NAME="margie-run-$STAMP"
CMD_FILE="$TASK_DIR/cmd-$STAMP.sh"
printf '%s\n' "$CMD" > "$CMD_FILE"

# Run the command, then drop into an interactive shell so the tab stays open
# (and Tom can keep working in it) even after a short command finishes.
EXEC="bash $CMD_FILE; exec \$SHELL"

CFG="$CFG_DIR/$NAME.yaml"
cat > "$CFG" <<YAML
---
name: $NAME
windows:
  - tabs:
      - title: margie-run
        layout:
          cwd: "$DIR_ABS"
          commands:
            - exec: '$EXEC'
YAML

find "$CFG_DIR" -name 'margie-run-*.yaml' -type f -mtime +1 -delete 2>/dev/null || true

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "--- $CFG ---"; cat "$CFG"; exit 0
fi

open "warp://launch/$NAME"
sleep 1.5
open -a Warp
echo "Running in Warp — dir: $DIR_ABS, cmd: $CMD"
