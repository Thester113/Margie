#!/bin/bash
# deploy.sh — Margie watches production deploys (she never triggers one). She detects a
# deploy Tom/Cody starts, launches the repo's deploy-watcher agent to watch health, and
# relays its verdict (healthy / rolled back / escalated). Watch-only by default: she does
# NOT auto-roll-back unless deploy_autorollback is true in config.
#
#   deploy.sh status                  latest production deploy: sha, status, when + release:deploy job
#   deploy.sh live <PT-n|!n|sha>      is that change in production? (git ancestry vs the last
#                                     SUCCESSFUL production deploy — read-only)
#   deploy.sh watch [<sha>]           launch the deploy-watcher agent on the running/last deploy
#   deploy.sh check                   poller: announce + watch a newly-started prod deploy (silent otherwise)
set -uo pipefail
# Every forge call gets a deadline: after GitLab's 2026-09-24 outage its API accepted
# connections and never answered, and one hung `glab api` stalled every dispatch tick.
_GLAB="$(command -v glab)"; _GH="$(command -v gh)"
glab() { perl -e 'alarm shift; exec @ARGV' "${MARGIE_GLAB_TIMEOUT:-45}" "$_GLAB" "$@"; }
gh() { perl -e 'alarm shift; exec @ARGV' "${MARGIE_GLAB_TIMEOUT:-45}" "$_GH" "$@"; }
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$HOME/.margie/config.json"; ST="$HOME/.margie/deploy"; mkdir -p "$ST"
cfg() { local v; v="$(jq -r ".$1 // empty" "$CFG" 2>/dev/null)"; case "$v" in op://*) v="$(op read "$v" 2>/dev/null || true)";; esac; printf "%s" "$v"; }
cfgd() { local v; v="$(cfg "$1")"; printf '%s' "${v:-$2}"; }
REPO="$("$DIR/resolve-repo.sh" "$(cfgd default_repo walt_ui)" 2>/dev/null || echo "$HOME/margie/walt_ui")"
SUBDIR="$(jq -r --arg r "$(basename "$REPO")" '.repo_subdirs[$r] // empty' "$CFG" 2>/dev/null)"
ENVN="$(cfgd deploy_environment production)"; APP="$(cfgd deploy_app WaltUI/prod)"
gl() { (cd "$REPO" && glab api "$@" 2>/dev/null); }
latest_deploy() { gl "projects/:id/deployments?environment=$ENVN&sort=desc&order_by=id&per_page=1" | jq -c '.[0] // {}'; }

cmd="${1:-status}"; shift || true
case "$cmd" in
  live)
    # "Is X in production?" answered from git, not from the newest pipeline: a commit is live
    # when it is an ancestor of the commit production last deployed SUCCESSFULLY. Looking at
    # the latest main pipeline instead (someone else's undeployed merge) made Margie tell an
    # agent the terraform guard wasn't live when it had shipped twice (2026-09-22).
    #   deploy.sh live <PT-n | !n | sha>
    X="${1:-}"; [ -z "$X" ] && { echo "usage: deploy.sh live <PT-n | !n | sha>" >&2; exit 1; }
    (cd "$REPO" && git fetch -q origin "$(cfgd mr_target_branch main)" 2>/dev/null)
    case "$X" in
      PT-*|pt-*) C="$(cd "$REPO" && git log "origin/$(cfgd mr_target_branch main)" --format=%H --grep "$(printf '%s' "$X" | tr a-z A-Z)" -1)" ;;
      !*|[0-9]*) N="${X#!}"; C="$(cd "$REPO" && glab mr view "$N" -F json 2>/dev/null | jq -r '.merge_commit_sha // .squash_commit_sha // empty')" ;;
      *) C="$X" ;;
    esac
    [ -z "$C" ] && { echo "$X is not on $(cfgd mr_target_branch main) yet — nothing of it is in production."; exit 0; }
    DEP="$(gl "projects/:id/deployments?environment=$ENVN&status=success&order_by=id&sort=desc&per_page=1" | jq -c '.[0] // {}')"
    DSHA="$(printf '%s' "$DEP" | jq -r '.sha // empty')"; DAT="$(printf '%s' "$DEP" | jq -r '(.finished_at // .updated_at // .created_at // "")[:16] | sub("T";" ")')"
    [ -z "$DSHA" ] && { echo "I can't see a successful production deploy to compare against."; exit 1; }
    if (cd "$REPO" && git merge-base --is-ancestor "$C" "$DSHA" 2>/dev/null); then
      echo "$X is live in production — it's included in the deploy of ${DSHA:0:8} (finished $DAT UTC)."
    else
      echo "$X is merged (${C:0:8}) but not in production yet — production is at ${DSHA:0:8}, deployed $DAT UTC."
    fi ;;
  status)
    D="$(latest_deploy)"; [ "$D" = "{}" ] || [ -z "$D" ] && { echo "No production deploys on record."; exit 0; }
    printf '%s' "$D" | jq -r '"Latest production deploy: \(.sha[0:8]) — \(.status) — \(.created_at[0:16]) (deployment \(.id))\("\n"+"app: "+"'"$APP"'")"'
    PID="$(gl "projects/:id/pipelines?ref=main&per_page=1" | jq -r '.[0].id')"
    [ -n "$PID" ] && gl "projects/:id/pipelines/$PID/jobs?per_page=100" | jq -r '.[] | select(.name=="release:deploy") | "release:deploy job on latest main pipeline: \(.status)"' | head -1 ;;
  watch)
    SHA="${1:-$(latest_deploy | jq -r '.sha // empty')}"; [ -z "$SHA" ] && { echo "No deploy to watch." >&2; exit 1; }
    RB="$(cfgd deploy_autorollback false)"; MINS="$(cfgd deploy_watch_minutes 30)"
    SESS="margie-deploy-$(printf '%s' "$SHA" | cut -c1-8)"
    "${MARGIE_TMUX:-$(command -v tmux)}" has-session -t "$SESS" 2>/dev/null && { echo "Already watching $SHA (session $SESS)."; exit 0; }
    P="Use the deploy-watcher agent to watch the CURRENT production deploy of this repository.
Deploy identity: commit ${SHA} deploying now to the '${ENVN}' environment (app.heywalt.com). AppSignal application: ${APP} (confirm with get_applications; it is production, NOT any preview/porter-test/local app).
Watch for up to ${MINS} minutes past cut-over. Authorization: $([ "$RB" = true ] && echo "auto-rollback IS authorized for a migration-additive deploy per your procedure." || echo "WATCH ONLY — do NOT roll back. If it looks unhealthy, ESCALATE to Tom, do not act.")
Follow your full procedure (MIG cut-over vs healthy, the ~1-minute health-check lag, AppSignal error rate). End with a single clear line: DEPLOY VERDICT: healthy | rolled back | escalated — <one sentence>."
    KP="$("$DIR/kickoff-claude.sh" "$REPO" ${SUBDIR:+--subdir "$SUBDIR"} --session "$SESS" "$P" 2>&1 | tail -1)"
    echo "Watching the production deploy of ${SHA:0:8} in session $SESS — I'll report the verdict. $KP" ;;
  check)
    [ "$(cfgd deploy_watch on)" = off ] && exit 0
    # A main pipeline that fails BEFORE its deploy job (build, image push, test stage) is
    # a merge that never shipped, and nothing watched for it: two merges on 2026-09-21
    # (PT-1402, PT-1456) sat undeployed after runner DNS blips (registry.npmjs.org
    # EAI_AGAIN, docker.io unreachable). Same triage as MR pipelines: Jev reads the failed
    # jobs' logs; infrastructure → retry them once; code → say so, main needs a look.
    # Only the NEWEST main pipeline is worth retrying: an older failed one is superseded
    # by whatever merged after it (its deploy would carry the same commits and race the
    # newer rollout — the overlap that opened the false revert !1203).
    for MP in $(gl "projects/:id/pipelines?ref=$(cfgd mr_target_branch main)&per_page=1" | jq -r '.[] | select(.status=="failed") | .id'); do
      [ -f "$ST/mainfail-$MP" ] && continue
      touch "$ST/mainfail-$MP"
      MSHA="$(gl "projects/:id/pipelines/$MP" | jq -r '.sha[0:8]')"
      JOBS="$(gl "projects/:id/pipelines/$MP/jobs?per_page=100")"
      # GitLab's "prevent outdated deployment jobs" fails a deploy whose commit a NEWER deploy
      # already shipped (failure_reason failed_outdated_deployment_job) — GitLab still sends a
      # "Failed pipeline" alert, but nothing is wrong (494177c8, 2026-09-25). Not a failure:
      # say so once, in plain words, instead of "did not deploy" or a retry. Deterministic.
      FJ="$(printf '%s' "$JOBS" | jq -r '.[] | select(.status=="failed" and (.allow_failure|not) and (.failure_reason != "failed_outdated_deployment_job")) | "\(.id)\t\(.name)"')"
      if [ -z "$FJ" ]; then
        if printf '%s' "$JOBS" | jq -e '[.[] | select(.failure_reason == "failed_outdated_deployment_job")] | length > 0' >/dev/null 2>&1; then
          PROD="$(latest_deploy | jq -r '.sha[0:8] // empty' 2>/dev/null)"
          echo "The \"Failed pipeline\" alert for $MSHA is harmless: GitLab skipped its deploy because a newer one${PROD:+ ($PROD)} already shipped those changes. Nothing to do."
        fi
        continue    # only allow_failure or outdated-deploy jobs failed
      fi
      TAILS="$(printf '%s\n' "$FJ" | while IFS=$'\t' read -r jid jname; do [ -n "$jid" ] || continue; echo "=== job $jname"; (cd "$REPO" && glab ci trace "$jid" 2>/dev/null) | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | grep -vE '^\s*$' | tail -60; done | tail -200)"
      JC="$(printf '%s' "$TAILS" | "$DIR/jev.sh" ci_failure 2>/dev/null)" || JC=""
      NAMES="$(printf '%s' "$FJ" | cut -f2 | tr '\n' ' ')"
      if [ "$(printf '%s' "$JC" | cut -f1)" = infrastructure ] && [ "$(printf '%s' "$JC" | cut -f2 | awk '{print ($1>=0.8)}')" = 1 ]; then
        printf '%s\n' "$FJ" | while IFS=$'\t' read -r jid jname; do [ -n "$jid" ] && (cd "$REPO" && glab ci retry "$jid" >/dev/null 2>&1); done
        "$DIR/jev.sh" outcome ci_failure "retry main pipeline=$MP jobs=$NAMES" >/dev/null 2>&1
        echo "The main pipeline for $MSHA failed before deploying ($NAMES) — the runner, not the code — so I've retried those jobs once."
      else
        "$DIR/jev.sh" outcome ci_failure "escalate main pipeline=$MP jev=$(printf '%s' "${JC:-unavailable}" | tr '\t' '@')" >/dev/null 2>&1
        echo "The main pipeline for $MSHA FAILED on $NAMES and did not deploy — that commit is on main but not in production; it needs a look."
      fi
    done
    D="$(latest_deploy)"; [ "$D" = "{}" ] || [ -z "$D" ] && exit 0
    DID="$(printf '%s' "$D" | jq -r '.id')"; DSTATUS="$(printf '%s' "$D" | jq -r '.status')"; DSHA="$(printf '%s' "$D" | jq -r '.sha')"
    [ "$(cat "$ST/last-deploy" 2>/dev/null)" = "$DID" ] && exit 0     # already handled this deploy
    case "$DSTATUS" in
      running|created)
        echo "$DID" > "$ST/last-deploy"
        echo "A production deploy just started (commit ${DSHA:0:8}) — I'm watching its health and will report the verdict."
        "$0" watch "$DSHA" >/dev/null 2>&1 ;;
      *) echo "$DID" > "$ST/last-deploy" ;;   # a finished deploy we hadn't seen: record, don't re-announce
    esac ;;
  *) echo "usage: deploy.sh status | live <PT-n|!n|sha> | watch [<sha>] | check" >&2; exit 1 ;;
esac
