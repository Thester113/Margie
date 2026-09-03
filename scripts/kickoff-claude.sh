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
# --engine claude|grok (which CLI to run). Claude Code is the default; `engine`
# in ~/.margie/config.json or MARGIE_ENGINE overrides.
CLAUDE_FLAG=""
USE_WT=0
WT_BRANCH=""
ENGINE="${MARGIE_ENGINE:-$(jq -r '.engine // empty' "$HOME/.margie/config.json" 2>/dev/null)}"
ENGINE="${ENGINE:-claude}"

# Pre-scan ALL args for --engine anywhere. The brain often appends it AFTER the
# prompt ("... 'fix the bug' --engine claude"); without this it gets swallowed
# into PROMPT and silently falls back to grok — the reason Claude sessions
# "didn't work".
PRE=()
SUBDIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --engine | -e) ENGINE="${2:-claude}"; shift 2 ;;
    --engine=*) ENGINE="${1#*=}"; shift ;;
    --subdir) SUBDIR="${2:-}"; shift 2 ;;    # monorepo: run the session in <dir>/<subdir>
    *) PRE+=("$1"); shift ;;
  esac
done
set -- ${PRE[@]+"${PRE[@]}"}

# Remaining leading flags: --continue / --worktree [branch].
while true; do
  case "${1:-}" in
    --continue | -c | --resume | -r) CLAUDE_FLAG="--continue"; shift ;;
    --worktree | -w)
      USE_WT=1; shift
      case "${1:-}" in "" | --*) ;; *) WT_BRANCH="$1"; shift ;; esac
      ;;
    *) break ;;
  esac
done

PROMPT="$*"
# Brief every ad-hoc session properly (dispatch prompts are already complete and skip this).
if [ -n "$PROMPT" ] && [ "${MARGIE_NO_PREAMBLE:-0}" != 1 ] && ! printf '%s' "$PROMPT" | grep -q "MARGIE_READY_FOR_QA\|You are the product manager\|You are reviewing merge request"; then
  PRE="$(cat "$(dirname "$0")/prompts/session-preamble.md" 2>/dev/null)"
  NOTES=""
  for f in "$HOME"/.margie/projects/*.md; do [ -f "$f" ] || continue
    for w in $(printf '%s' "$PROMPT" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n' ' ' | tr ' ' '\n' | awk 'length>4' | sort -u | head -12); do
      grep -qi -- "$w" "$f" 2>/dev/null && { NOTES="$NOTES
--- project note: $(basename "$f" .md) ---
$(cat "$f")"; break; }; done; done
  for f in "$HOME"/.margie/process/*.md; do [ -f "$f" ] && NOTES="$NOTES
--- team process: $(basename "$f" .md) ---
$(cat "$f")"; done
  PROMPT="$PRE

THE TASK FROM TOM (via Margie):
$PROMPT
${NOTES:+
CONTEXT AND CONVENTIONS (use these to decide without asking):$NOTES}"
fi

CFG_DIR="$HOME/.warp/launch_configurations"
TASK_DIR="$HOME/.margie/tasks"
mkdir -p "$CFG_DIR" "$TASK_DIR"

STAMP="$(date +%s)"
# Unique tmux session per launch, so starting a new session NEVER kills a
# running one. Worktree launches key off the branch (a repeat targets the same
# one); plain launches get a timestamped name.
SESSION="margie-$STAMP"
if [ "$USE_WT" = "1" ]; then
  [ -z "$WT_BRANCH" ] && WT_BRANCH="margie/$STAMP"
  # Create/reuse the worktree (worktree.sh resolves the repo + clones if needed).
  DIR_ABS="$(bash "$(dirname "$0")/worktree.sh" add "$DIR" "$WT_BRANCH" 2>/dev/null | tail -1)"
  [ -z "$DIR_ABS" ] && { echo "Couldn't create worktree for '$DIR', dearie."; exit 1; }
  SESSION="margie-$(printf '%s' "$WT_BRANCH" | tr '/ ' '--')"
else
  DIR_ABS="$(cd "$DIR" 2>/dev/null && pwd || echo "$HOME")"
fi

NAME="margie-claude-$STAMP"
TMUX_BIN="$(command -v tmux || echo /opt/homebrew/bin/tmux)"

# Guarantee the session name is FREE, so a new launch never collides with (and
# the kick script never clobbers) a running one — even two launches in the same
# second, or a repeat of the same worktree branch.
base="$SESSION"; n=2
while "$TMUX_BIN" has-session -t "$SESSION" 2>/dev/null; do
  SESSION="${base}-${n}"; n=$((n + 1))
done
# Record as the current session so a follow-up targets the newest one by default.
printf '%s' "$SESSION" > "$HOME/.margie/last-session"

# Inner script: cd + run claude (or a test command). Written as plain bash so
# quoting is clean; the prompt is read from a file to avoid all escaping.
INNER="$TASK_DIR/inner-$STAMP.sh"
# Pick the CLI binary. Claude Code unless grok was explicitly requested.
case "$(printf '%s' "$ENGINE" | tr 'A-Z' 'a-z')" in
  grok*) ENGINE_BIN="grok" ;;
  *) ENGINE_BIN="claude"
     # Default model for dispatched sessions (claude_model in ~/.margie/config.json).
     DM="$(jq -r '.claude_model // empty' "$HOME/.margie/config.json" 2>/dev/null)"
     [ -n "$DM" ] && ENGINE_BIN="claude --model '$DM'" ;;
esac
if [ -n "${MARGIE_TEST_CMD:-}" ]; then
  CLAUDE_LINE="$MARGIE_TEST_CMD"
elif [ -n "$PROMPT" ]; then
  PROMPT_FILE="$TASK_DIR/prompt-$STAMP.txt"
  printf '%s' "$PROMPT" > "$PROMPT_FILE"
  CLAUDE_LINE="$ENGINE_BIN ${CLAUDE_FLAG:+$CLAUDE_FLAG }\"\$(cat '$PROMPT_FILE')\""
else
  CLAUDE_LINE="$ENGINE_BIN ${CLAUDE_FLAG}"
fi
# Pre-trust the session folder for Claude Code (its per-folder "Quick safety
# check" otherwise stops every fresh worktree until a human presses Enter).
trust_dir() { # trust_dir <abs path>
  local f="$HOME/.claude.json" d="$1"
  [ -f "$f" ] || return 0
  jq --arg d "$d" '.projects = ((.projects // {}) | .[$d] = ((.[$d] // {}) + {hasTrustDialogAccepted: true, hasClaudeMdExternalIncludesApproved: true, hasClaudeMdExternalIncludesWarningShown: true}))' "$f" > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"
}
trust_dir "$DIR_ABS"; [ -n "$SUBDIR" ] && trust_dir "$DIR_ABS/$SUBDIR"

cat > "$INNER" <<INNEREOF
#!/bin/bash
cd "$DIR_ABS${SUBDIR:+/$SUBDIR}" || cd "\$HOME"
$CLAUDE_LINE
INNEREOF
chmod +x "$INNER"

# Run script: (re)create the tmux session running the inner script, and attach
# to it in this tab so Tom watches it live.
RUN="$TASK_DIR/kick-$STAMP.sh"
cat > "$RUN" <<RUNEOF
#!/bin/bash
# -A: attach if it somehow already exists, create otherwise — NEVER kill.
exec "$TMUX_BIN" new-session -A -s $SESSION 'bash $INNER'
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
