#!/bin/bash
# kickoff-claude.sh — open an interactive Claude Code session in a new Warp tab.
#
# Usage: kickoff-claude.sh <project_dir> [prompt words...]
#   <project_dir>  directory to start the session in (defaults to $HOME)
#   [prompt]       optional; everything after the dir is the seed prompt.
#                  `claude "<prompt>"` starts an interactive session with the
#                  prompt already submitted, so Tom can watch and take over.
#
# Uses a Warp Launch Configuration + the warp:// URI — deterministic, no
# keystroke automation and no Accessibility permission required.
#
# Set DRY_RUN=1 to write the config and print it without launching Warp.
set -euo pipefail

DIR="${1:-$HOME}"
shift || true

# Optional first flag: --continue (resume most recent session in this dir) or
# --resume (same). Anything else is treated as the start of the prompt.
CLAUDE_FLAG=""
case "${1:-}" in
  --continue | -c | --resume | -r)
    CLAUDE_FLAG="--continue"
    shift
    ;;
esac

PROMPT="$*"

# Resolve to an absolute directory, falling back to $HOME.
DIR_ABS="$(cd "$DIR" 2>/dev/null && pwd || echo "$HOME")"

CFG_DIR="$HOME/.warp/launch_configurations"
TASK_DIR="$HOME/.margie/tasks"
mkdir -p "$CFG_DIR" "$TASK_DIR"

STAMP="$(date +%s)"
NAME="margie-claude-$STAMP"

# Prompt goes in a file so it never has to be escaped through YAML or shell
# quoting — the exec just cats it back as a single argument to claude.
if [ -n "$PROMPT" ]; then
  PROMPT_FILE="$TASK_DIR/prompt-$STAMP.txt"
  printf '%s' "$PROMPT" > "$PROMPT_FILE"
  EXEC="claude${CLAUDE_FLAG:+ $CLAUDE_FLAG} \"\$(cat $PROMPT_FILE)\""
else
  EXEC="claude${CLAUDE_FLAG:+ $CLAUDE_FLAG}"
fi

# MARGIE_TEST_CMD lets tests substitute a harmless command for `claude`.
if [ -n "${MARGIE_TEST_CMD:-}" ]; then
  EXEC="$MARGIE_TEST_CMD"
fi

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
            - exec: '$EXEC'
YAML

# Prune old Margie launch configs (older than 1 day) to avoid clutter.
find "$CFG_DIR" -name 'margie-claude-*.yaml' -type f -mtime +1 -delete 2>/dev/null || true

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "--- $CFG ---"
  cat "$CFG"
  exit 0
fi

# 1. Launch the configuration. This opens a new Warp tab and runs the command,
#    cold-starting Warp if it isn't running. (Tested reliable on its own.)
open "warp://launch/$NAME"

# 2. Bring Warp and the new window to the foreground so Tom actually SEES it —
#    without this the tab opens in the background / on another Space, which was
#    the "she says it's up but I see nothing" bug. The delay lets the launch
#    settle before we activate.
sleep 1.5
open -a Warp

echo "Launched Claude in Warp — dir: $DIR_ABS, prompt: ${PROMPT:-<none>}"
