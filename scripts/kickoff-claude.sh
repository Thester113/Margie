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

# Flags: --continue (resume), --worktree [branch] (isolated git worktree),
# --engine grok|claude (which CLI to run; grok is the default so sessions stay
# off Tom's Claude subscription).
CLAUDE_FLAG=""
USE_WT=0
WT_BRANCH=""
ENGINE="${MARGIE_ENGINE:-grok}"
while true; do
  case "${1:-}" in
    --continue | -c | --resume | -r) CLAUDE_FLAG="--continue"; shift ;;
    --engine | -e) shift; ENGINE="${1:-grok}"; shift || true ;;
    --worktree | -w)
      USE_WT=1; shift
      case "${1:-}" in "" | --*) ;; *) WT_BRANCH="$1"; shift ;; esac
      ;;
    *) break ;;
  esac
done

PROMPT="$*"

CFG_DIR="$HOME/.warp/launch_configurations"
TASK_DIR="$HOME/.margie/tasks"
mkdir -p "$CFG_DIR" "$TASK_DIR"

SESSION="margie" # tmux session name Margie sends follow-ups to
if [ "$USE_WT" = "1" ]; then
  [ -z "$WT_BRANCH" ] && WT_BRANCH="margie/$(date +%s)"
  # Create/reuse the worktree (worktree.sh resolves the repo + clones if needed).
  DIR_ABS="$(bash "$(dirname "$0")/worktree.sh" add "$DIR" "$WT_BRANCH" 2>/dev/null | tail -1)"
  [ -z "$DIR_ABS" ] && { echo "Couldn't create worktree for '$DIR', sir."; exit 1; }
  # Distinct tmux session per branch so worktree sessions can run in parallel.
  SESSION="margie-$(printf '%s' "$WT_BRANCH" | tr '/ ' '--')"
else
  DIR_ABS="$(cd "$DIR" 2>/dev/null && pwd || echo "$HOME")"
fi

STAMP="$(date +%s)"
NAME="margie-claude-$STAMP"
TMUX_BIN="$(command -v tmux || echo /opt/homebrew/bin/tmux)"

# Inner script: cd + run claude (or a test command). Written as plain bash so
# quoting is clean; the prompt is read from a file to avoid all escaping.
INNER="$TASK_DIR/inner-$STAMP.sh"
# Pick the CLI binary. grok is the default (keeps sessions off the Claude sub).
if [ "$ENGINE" = "claude" ]; then
  ENGINE_BIN="claude"
else
  ENGINE_BIN="grok"
fi
if [ -n "${MARGIE_TEST_CMD:-}" ]; then
  CLAUDE_LINE="$MARGIE_TEST_CMD"
elif [ -n "$PROMPT" ]; then
  PROMPT_FILE="$TASK_DIR/prompt-$STAMP.txt"
  printf '%s' "$PROMPT" > "$PROMPT_FILE"
  CLAUDE_LINE="$ENGINE_BIN ${CLAUDE_FLAG:+$CLAUDE_FLAG }\"\$(cat '$PROMPT_FILE')\""
else
  CLAUDE_LINE="$ENGINE_BIN ${CLAUDE_FLAG}"
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
if [ "$USE_WT" = "1" ]; then
  echo "Launched $ENGINE_BIN in Warp on an isolated worktree (branch '$WT_BRANCH', tmux session '$SESSION') — dir: $DIR_ABS, prompt: ${PROMPT:-<none>}. Follow up with: claude-followup.sh \"<text>\" --branch $WT_BRANCH"
else
  echo "Launched $ENGINE_BIN in Warp (tmux session '$SESSION') — dir: $DIR_ABS, prompt: ${PROMPT:-<none>}"
fi
