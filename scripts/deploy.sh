#!/bin/bash
# deploy.sh — Margie watches production deploys (she never triggers one). She detects a
# deploy Tom/Cody starts, launches the repo's deploy-watcher agent to watch health, and
# relays its verdict (healthy / rolled back / escalated). Watch-only by default: she does
# NOT auto-roll-back unless deploy_autorollback is true in config.
#
#   deploy.sh status                  latest production deploy: sha, status, when + release:deploy job
#   deploy.sh watch [<sha>]           launch the deploy-watcher agent on the running/last deploy
#   deploy.sh check                   poller: announce + watch a newly-started prod deploy (silent otherwise)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$HOME/.margie/config.json"; ST="$HOME/.margie/deploy"; mkdir -p "$ST"
cfg() { jq -r ".$1 // empty" "$CFG" 2>/dev/null; }
cfgd() { local v; v="$(cfg "$1")"; printf '%s' "${v:-$2}"; }
REPO="$("$DIR/resolve-repo.sh" "$(cfgd default_repo walt_ui)" 2>/dev/null || echo "$HOME/margie/walt_ui")"
SUBDIR="$(jq -r --arg r "$(basename "$REPO")" '.repo_subdirs[$r] // empty' "$CFG" 2>/dev/null)"
ENVN="$(cfgd deploy_environment production)"; APP="$(cfgd deploy_app WaltUI/prod)"
gl() { (cd "$REPO" && glab api "$@" 2>/dev/null); }
latest_deploy() { gl "projects/:id/deployments?environment=$ENVN&sort=desc&order_by=id&per_page=1" | jq -c '.[0] // {}'; }

cmd="${1:-status}"; shift || true
case "$cmd" in
  status)
    D="$(latest_deploy)"; [ "$D" = "{}" ] || [ -z "$D" ] && { echo "No production deploys on record, dearie."; exit 0; }
    printf '%s' "$D" | jq -r '"Latest production deploy: \(.sha[0:8]) — \(.status) — \(.created_at[0:16]) (deployment \(.id))\("\n"+"app: "+"'"$APP"'")"'
    PID="$(gl "projects/:id/pipelines?ref=main&per_page=1" | jq -r '.[0].id')"
    [ -n "$PID" ] && gl "projects/:id/pipelines/$PID/jobs?per_page=100" | jq -r '.[] | select(.name=="release:deploy") | "release:deploy job on latest main pipeline: \(.status)"' | head -1 ;;
  watch)
    SHA="${1:-$(latest_deploy | jq -r '.sha // empty')}"; [ -z "$SHA" ] && { echo "No deploy to watch, dearie." >&2; exit 1; }
    RB="$(cfgd deploy_autorollback false)"; MINS="$(cfgd deploy_watch_minutes 30)"
    SESS="margie-deploy-$(printf '%s' "$SHA" | cut -c1-8)"
    "${MARGIE_TMUX:-$(command -v tmux)}" has-session -t "$SESS" 2>/dev/null && { echo "Already watching $SHA (session $SESS), dearie."; exit 0; }
    P="Use the deploy-watcher agent to watch the CURRENT production deploy of this repository.
Deploy identity: commit ${SHA} deploying now to the '${ENVN}' environment (app.heywalt.com). AppSignal application: ${APP} (confirm with get_applications; it is production, NOT any preview/porter-test/local app).
Watch for up to ${MINS} minutes past cut-over. Authorization: $([ "$RB" = true ] && echo "auto-rollback IS authorized for a migration-additive deploy per your procedure." || echo "WATCH ONLY — do NOT roll back. If it looks unhealthy, ESCALATE to Tom, do not act.")
Follow your full procedure (MIG cut-over vs healthy, the ~1-minute health-check lag, AppSignal error rate). End with a single clear line: DEPLOY VERDICT: healthy | rolled back | escalated — <one sentence>."
    KP="$("$DIR/kickoff-claude.sh" "$REPO" ${SUBDIR:+--subdir "$SUBDIR"} --session "$SESS" "$P" 2>&1 | tail -1)"
    echo "Watching the production deploy of ${SHA:0:8} in session $SESS, dearie — I'll report the verdict. $KP" ;;
  check)
    [ "$(cfgd deploy_watch on)" = off ] && exit 0
    D="$(latest_deploy)"; [ "$D" = "{}" ] || [ -z "$D" ] && exit 0
    DID="$(printf '%s' "$D" | jq -r '.id')"; DSTATUS="$(printf '%s' "$D" | jq -r '.status')"; DSHA="$(printf '%s' "$D" | jq -r '.sha')"
    [ "$(cat "$ST/last-deploy" 2>/dev/null)" = "$DID" ] && exit 0     # already handled this deploy
    case "$DSTATUS" in
      running|created)
        echo "$DID" > "$ST/last-deploy"
        echo "A production deploy just started (commit ${DSHA:0:8}) — I'm watching its health and will report the verdict, dearie."
        "$0" watch "$DSHA" >/dev/null 2>&1 ;;
      *) echo "$DID" > "$ST/last-deploy" ;;   # a finished deploy we hadn't seen: record, don't re-announce
    esac ;;
  *) echo "usage: deploy.sh status | watch [<sha>] | check" >&2; exit 1 ;;
esac
