#!/bin/bash
# review-pr.sh — review a GitHub PR in a watchable Warp session.
#
# Runs the reviewer (grok by default, or claude) IN the repo with a
# skill-triggering prompt — exactly like reviewing manually — so the repo's
# xerpa-pr-review skill is discovered and used. No pre-baked diff (that was
# what bypassed the skill before).
#
# Usage: review-pr.sh <pr-number> [repo-dir] [grok|claude]
set -euo pipefail

PR="${1:-}"
DIR="${2:-$PWD}"
REVIEWER="${3:-grok}"
if [ -z "$PR" ]; then
  echo "usage: review-pr.sh <pr-number> [repo-dir] [grok|claude]" >&2
  exit 1
fi

# Resolve the repo. $DIR may be a full path OR a bare name ("backend",
# "xerpa_databricks"). Order: use it if it's a git repo; else match a locally
# cloned repo by name; else find it in the xerpaai org and clone on demand.
# This lets her review PRs in ANY org repo, not just cloned ones.
DIR_ABS=""
if git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  DIR_ABS="$(cd "$DIR" && pwd)"
else
  token="$(basename "$DIR" | tr 'A-Z' 'a-z')"
  for d in "$HOME/Xerpa Repos"/*/ "$HOME"/*/; do
    git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
    bn="$(basename "$d" | tr 'A-Z' 'a-z')"
    case "$bn" in *"$token"*) DIR_ABS="${d%/}"; break ;; esac
  done
  if [ -z "$DIR_ABS" ]; then
    # `|| true` so a no-match grep under `set -e`/pipefail doesn't kill us
    # silently — we want the clear "couldn't find" message below.
    orgrepo="$(gh repo list xerpaai --limit 200 --json name --jq '.[].name' 2>/dev/null \
      | grep -iF "$token" | head -1 || true)"
    if [ -n "$orgrepo" ]; then
      DIR_ABS="$HOME/Xerpa Repos/$orgrepo"
      if ! git -C "$DIR_ABS" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "Cloning xerpaai/$orgrepo (first time), sir…"
        gh repo clone "xerpaai/$orgrepo" "$DIR_ABS" >/dev/null 2>&1 || {
          echo "Couldn't clone xerpaai/$orgrepo, sir."; exit 1; }
      fi
    fi
  fi
  if [ -z "$DIR_ABS" ]; then
    echo "Couldn't find a repo matching '$token' in the xerpaai org, sir."
    exit 1
  fi
fi

# Validate the PR exists before launching anything (fail fast on a bad number).
set +e
PRCHECK="$(cd "$DIR_ABS" && gh pr view "$PR" --json number 2>&1)"
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
  echo "Couldn't find PR #$PR in $(basename "$DIR_ABS"), sir: ${PRCHECK:0:200}"
  exit 1
fi

TASK_DIR="$HOME/.margie/tasks"
CFG_DIR="$HOME/.warp/launch_configurations"
mkdir -p "$TASK_DIR" "$CFG_DIR"
STAMP="$(date +%s)"
# Unique session per review so it never kills a running session (finalized +
# recorded to last-session after the uniqueness check below).
SESSION="margie-review-$STAMP"
TMUX_BIN="$(command -v tmux || echo /opt/homebrew/bin/tmux)"

PROMPT="Use the xerpa-pr-review skill to review PR #$PR, then submit the GitHub review per the skill."
if [ "$REVIEWER" = "claude" ]; then
  REV_CMD="claude --dangerously-skip-permissions \"$PROMPT\""
else
  REV_CMD="grok --always-approve \"$PROMPT\""
fi

INNER="$TASK_DIR/inner-$STAMP.sh"
cat > "$INNER" <<INNEREOF
#!/bin/bash
cd "$DIR_ABS" || cd "\$HOME"
$REV_CMD
INNEREOF
chmod +x "$INNER"

# Guarantee the session name is free so this review never clobbers a running one.
base="$SESSION"; n=2
while "$TMUX_BIN" has-session -t "$SESSION" 2>/dev/null; do
  SESSION="${base}-${n}"; n=$((n + 1))
done
printf '%s' "$SESSION" > "$HOME/.margie/last-session"

RUN="$TASK_DIR/kick-$STAMP.sh"
cat > "$RUN" <<RUNEOF
#!/bin/bash
# -A: attach if it somehow exists, create otherwise — NEVER kill.
exec "$TMUX_BIN" new-session -A -s $SESSION 'bash $INNER'
RUNEOF
chmod +x "$RUN"

NAME="margie-review-$STAMP"
cat > "$CFG_DIR/$NAME.yaml" <<YAML
---
name: $NAME
windows:
  - tabs:
      - title: pr-review
        layout:
          cwd: "$DIR_ABS"
          commands:
            - exec: 'bash $RUN'
YAML
find "$CFG_DIR" -name 'margie-review-*.yaml' -type f -mtime +1 -delete 2>/dev/null || true

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "--- inner ($REVIEWER) ---"; cat "$INNER"
  exit 0
fi

open "warp://launch/$NAME"
sleep 1.5
open -a Warp
echo "$REVIEWER is reviewing PR #$PR in $(basename "$DIR_ABS") — up in Warp, sir."
