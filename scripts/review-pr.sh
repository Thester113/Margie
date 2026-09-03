#!/bin/bash
# review-pr.sh — review a GitHub PR or GitLab MR in a watchable Warp session.
# The forge comes from `forge` in ~/.margie/config.json (gitlab | github).
#
# Runs the reviewer (Claude Code by default, or grok) IN the repo — exactly like
# reviewing manually — so any repo-local review skill is discovered. Set
# review_skill in ~/.margie/config.json to name a skill the prompt should
# trigger; otherwise a generic thorough-review prompt is used. No pre-baked
# diff (that bypasses repo skills).
#
# Usage: review-pr.sh <pr-or-mr-number> [repo-dir] [claude|grok]
set -euo pipefail

CFG="$HOME/.margie/config.json"
cfg() { jq -r ".$1 // empty" "$CFG" 2>/dev/null; }
FORGE="${MARGIE_FORGE:-$(cfg forge)}"; FORGE="$(printf '%s' "${FORGE:-github}" | tr 'A-Z' 'a-z')"
GL_HOST="$(cfg gitlab_host)"; [ -n "$GL_HOST" ] && export GITLAB_HOST="${GITLAB_HOST:-$GL_HOST}"
if [ "$FORGE" = "gitlab" ]; then NOUN="MR"; REF="!"; LONG="merge request"; SITE="GitLab"; else NOUN="PR"; REF="#"; LONG="pull request"; SITE="GitHub"; fi

PR="${1:-}"
DIR="${2:-$PWD}"
REVIEWER="${3:-${MARGIE_ENGINE:-$(jq -r '.engine // empty' "$HOME/.margie/config.json" 2>/dev/null)}}"
REVIEWER="${REVIEWER:-claude}"
if [ -z "$PR" ]; then
  echo "usage: review-pr.sh <pr-or-mr-number> [repo-dir] [claude|grok]" >&2
  exit 1
fi

# Resolve the repo. $DIR may be a full path OR a bare name ("backend"): a local
# clone under repos_dir/$HOME, or a GitHub repo cloned on first use (see
# resolve-repo.sh; configure repos_dir / github_org in ~/.margie/config.json).
DIR_ABS="$("$(dirname "$0")/resolve-repo.sh" "$DIR")" || exit 1

# Validate the PR/MR exists before launching anything (fail fast on a bad number).
set +e
if [ "$FORGE" = "gitlab" ]; then
  PRCHECK="$(cd "$DIR_ABS" && glab mr view "$PR" 2>&1)"
else
  PRCHECK="$(cd "$DIR_ABS" && gh pr view "$PR" --json number 2>&1)"
fi
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
  # One line, no ANSI/box-drawing noise: the brain speaks the LAST line of our output.
  PRCHECK="$(printf '%s' "$PRCHECK" | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | tr '\n' ' ' | tr -s ' ' | sed 's/^ *//;s/ *$//')"
  echo "Couldn't find $NOUN $REF$PR in $(basename "$DIR_ABS"), dearie: ${PRCHECK:0:160}"
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

# Only refuse a duplicate if a review of THIS MR is actively RUNNING (esc to interrupt).
# A finished/idle review session does NOT block a fresh review — an MR gets re-reviewed
# whenever it has new commits, and "re review" is always allowed. FORCE_REVIEW=1 skips this.
if [ "${FORCE_REVIEW:-0}" != 1 ]; then
  for E in $("$TMUX_BIN" list-sessions -F '#{session_name}' 2>/dev/null | grep '^margie-review-'); do
    T="$("$TMUX_BIN" display -t "$E" -p '#{pane_title}' 2>/dev/null)"
    printf '%s' "$T" | grep -qE "(request|MR|PR|#) *0*${PR}( |$|[^0-9])" || continue
    if "$TMUX_BIN" capture-pane -t "$E" -p 2>/dev/null | grep -q 'esc to interrupt'; then
      echo "A review of $NOUN $REF$PR is already running in session '$E', dearie — watch it with /watch $E. Not starting a second."
      exit 0
    else
      # a finished review session for this MR is lingering — retire it and review afresh
      "$TMUX_BIN" kill-session -t "$E" 2>/dev/null || true
    fi
  done
fi

REVIEW_SKILL="$(cfg review_skill)"
if [ -n "$REVIEW_SKILL" ]; then
  PROMPT="Use the $REVIEW_SKILL skill to review $LONG $REF$PR, then submit the $SITE review per the skill."
elif [ "$FORGE" = "gitlab" ]; then
  PROMPT="Review merge request !$PR in this repo: check out its branch (glab mr checkout $PR), read the full diff (glab mr diff $PR) and the surrounding code, run the relevant tests if practical, then submit a GitLab review — leave specific, actionable comments with glab mr note, and glab mr approve only if it's genuinely ready."
else
  PROMPT="Review PR #$PR in this repo: check out the branch, read the full diff and the surrounding code, run the relevant tests if practical, then submit a GitHub review (approve or request changes) with specific, actionable comments."
fi
# Interactive, watchable session: Tom supervises in Warp, so the reviewer runs
# unprompted (skip-permissions) and can post the review itself.
if [ "$REVIEWER" = "grok" ]; then
  REV_CMD="grok --always-approve \"$PROMPT\""
else
  REVIEWER="claude"
  DM="$(cfg claude_model)"
  REV_CMD="claude${DM:+ --model '$DM'} --dangerously-skip-permissions \"$PROMPT\""
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

# warp_mode (config): window = a new Warp window per session (the original behaviour);
# quiet = the session runs in tmux with no window at all — watch any session from one
# place with `margie` → /watch <name>, or `session.sh attach <name>` in any terminal.
if [ "$(jq -r '.warp_mode // "window"' "$HOME/.margie/config.json" 2>/dev/null)" = "quiet" ]; then
  "$TMUX_BIN" new-session -d -s "$SESSION" "bash $INNER"
  echo "(quiet mode: session '$SESSION' is running in tmux — watch it with /watch $SESSION in the margie CLI)"
else
  open "warp://launch/$NAME"
  sleep 1.5
  open -a Warp
fi
if [ "$(jq -r '.warp_mode // "window"' "$HOME/.margie/config.json" 2>/dev/null)" = "quiet" ]; then
  echo "$REVIEWER is reviewing $NOUN $REF$PR in $(basename "$DIR_ABS") — session '$SESSION' (watch it with /watch $SESSION), dearie."
else
  echo "$REVIEWER is reviewing $NOUN $REF$PR in $(basename "$DIR_ABS") — up in Warp (session '$SESSION'), dearie."
fi
