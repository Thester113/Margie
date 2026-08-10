#!/bin/bash
# kickoff-claude.sh — start an interactive Claude Code session in a new Warp
# tab, running inside a tmux session named "margie" so Margie can inject
# follow-ups into the SAME running session later (via claude-followup.sh).
#
# Usage: kickoff-claude.sh <dir> [--continue] [prompt words...]
#   --continue  resume the most recent Claude session in <dir>
#
# Set DRY_RUN=1 to write the files and print them without launching Warp.
set -euo pipefail

DIR="${1:-$HOME}"
shift || true

CLAUDE_FLAG=""
case "${1:-}" in
  --continue | -c | --resume | -r)
    CLAUDE_FLAG="--continue"
    shift
    ;;
esac

PROMPT="$*"
DIR_ABS="$(cd "$DIR" 2>/dev/null && pwd || echo "$HOME")"

CFG_DIR="$HOME/.warp/launch_configurations"
TASK_DIR="$HOME/.margie/tasks"
mkdir -p "$CFG_DIR" "$TASK_DIR"

STAMP="$(date +%s)"
NAME="margie-claude-$STAMP"
SESSION="margie" # canonical tmux session name Margie sends follow-ups to
TMUX_BIN="$(command -v tmux || echo /opt/homebrew/bin/tmux)"

# Inner script: cd + run claude (or a test command). Written as plain bash so
# quoting is clean; the prompt is read from a file to avoid all escaping.
INNER="$TASK_DIR/inner-$STAMP.sh"
if [ -n "${MARGIE_TEST_CMD:-}" ]; then
  CLAUDE_LINE="$MARGIE_TEST_CMD"
elif [ -n "$PROMPT" ]; then
  PROMPT_FILE="$TASK_DIR/prompt-$STAMP.txt"
  printf '%s' "$PROMPT" > "$PROMPT_FILE"
  CLAUDE_LINE="claude ${CLAUDE_FLAG:+$CLAUDE_FLAG }\"\$(cat '$PROMPT_FILE')\""
else
  CLAUDE_LINE="claude ${CLAUDE_FLAG}"
fi
cat > "$INNER" <<INNEREOF
#!/bin/bash
cd "$DIR_ABS" || cd "\$HOME"
$CLAUDE_LINE
INNEREOF
chmod +x "$INNER"

# Run script: (re)create the tmux session running the inner script, and attach
# to it in this tab so Tom watches it live.
RUN="$TASK_DIR/kick-$STAMP.sh"
cat > "$RUN" <<RUNEOF
#!/bin/bash
"$TMUX_BIN" kill-session -t $SESSION 2>/dev/null
exec "$TMUX_BIN" new-session -s $SESSION 'bash $INNER'
RUNEOF
chmod +x "$RUN"

CFG="$CFG_DIR/$NAME.yaml"
cat > "$CFG" <<YAML
---
name: $NAME
windows:
  - tabs:
      - title: claude
        layout:
          cwd: "$DIR_ABS"
          commands:
            - exec: 'bash $RUN'
YAML

find "$CFG_DIR" -name 'margie-claude-*.yaml' -type f -mtime +1 -delete 2>/dev/null || true

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "--- $CFG ---"; cat "$CFG"
  echo "--- $RUN ---"; cat "$RUN"
  echo "--- $INNER ---"; cat "$INNER"
  exit 0
fi

open "warp://launch/$NAME"
sleep 1.5
open -a Warp
echo "Launched Claude in Warp (tmux session '$SESSION') — dir: $DIR_ABS, prompt: ${PROMPT:-<none>}"
