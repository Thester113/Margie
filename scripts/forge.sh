#!/bin/bash
# forge.sh — read-only GitLab/GitHub lookups Margie can run inline and speak.
# Forge-agnostic: `forge` in ~/.margie/config.json picks glab (gitlab) or gh
# (github); `org` is the GitLab group / GitHub org. Output is one item per line,
# compact, so the brain can summarize it aloud.
#
# Usage:
#   forge.sh projects                 live projects in the org (deletion-scheduled/archived skipped)
#   forge.sh mrs [review|mine|assigned|all]   open MRs/PRs org-wide (default: review = awaiting my review)
#   forge.sh mr <n> [repo]            one MR/PR: title, author, state, branch, url (+ approval/CI where cheap)
#   forge.sh pipelines [repo] [n]     recent pipelines / workflow runs for a repo (default 5)
#   forge.sh whoami                   who glab/gh is logged in as
set -uo pipefail

CFG="$HOME/.margie/config.json"
cfg() { jq -r ".$1 // empty" "$CFG" 2>/dev/null; }
FORGE="${MARGIE_FORGE:-$(cfg forge)}"; FORGE="$(printf '%s' "${FORGE:-github}" | tr 'A-Z' 'a-z')"
ORG="${MARGIE_ORG:-$(cfg org)}"
GL_HOST="$(cfg gitlab_host)"; [ -n "$GL_HOST" ] && export GITLAB_HOST="${GITLAB_HOST:-$GL_HOST}"
DIR="$(cd "$(dirname "$0")" && pwd)"

cmd="${1:-mrs}"; shift || true
urlenc() { jq -rn --arg s "$1" '$s|@uri'; }

norm() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d ' _.-'; }

# Live project paths in the org (or that I'm a member of). GitLab hides
# deletion-scheduled projects behind a rename, so filter those too.
list_projects() {
  if [ "$FORGE" = "gitlab" ]; then
    local q
    if [ -n "$ORG" ]; then q="groups/$(urlenc "$ORG")/projects?include_subgroups=true&simple=true&per_page=100&archived=false"
    else q="projects?membership=true&simple=true&per_page=100&archived=false"; fi
    glab api "$q" 2>/dev/null | jq -r '.[]? | select(.marked_for_deletion_on == null) | .path_with_namespace' | grep -v -- '-deletion_scheduled-'
  else
    gh repo list ${ORG:+"$ORG"} --limit 200 --no-archived --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null
  fi
}

# <repo> arg → "group/project" (gitlab) or "owner/repo" (github), WITHOUT cloning.
# Accepts an "a/b" spec, a local path (→ its origin remote), or a bare/spoken
# name ("walt ui") matched against the org's projects ignoring case/separators.
repo_spec() {
  local r="${1:-}"
  [ -z "$r" ] && r="$PWD"
  if [ -d "$r" ]; then
    git -C "$r" remote get-url origin 2>/dev/null | sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##'; return
  fi
  case "$r" in */*) printf '%s' "$r"; return ;; esac
  local t; t="$(norm "$r")"
  local hit; hit="$(list_projects | awk -F/ -v t="$t" '{ n = tolower($NF); gsub(/[-_. ]/, "", n) } index(n, t) { print; exit }')"
  [ -n "$hit" ] && { printf '%s' "$hit"; return; }
  local dir; dir="$("$DIR/resolve-repo.sh" "$r" 2>/dev/null)" || return 1
  git -C "$dir" remote get-url origin 2>/dev/null | sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##'
}

if [ "$FORGE" = "gitlab" ]; then
  case "$cmd" in
    whoami) glab api user | jq -r '"\(.username) (\(.name)) on \(env.GITLAB_HOST // "gitlab.com")"' ;;
    projects)
      OUT="$(list_projects)"; [ -n "$OUT" ] && echo "$OUT" || echo "No projects found${ORG:+ in $ORG}, dearie." ;;
    mrs)
      which="${1:-review}"
      ME="$(glab api user 2>/dev/null | jq -r .username)"
      case "$which" in
        review|reviews) F="&reviewer_username=$ME" ;;
        mine|authored)  F="&author_username=$ME" ;;
        assigned)       F="&assignee_username=$ME" ;;
        all|*)          F="" ;;
      esac
      if [ -n "$ORG" ]; then Q="groups/$(urlenc "$ORG")/merge_requests?state=opened&scope=all&per_page=50&order_by=updated_at$F"
      else Q="merge_requests?state=opened&scope=all&per_page=50&order_by=updated_at$F"; fi
      OUT="$(glab api "$Q" 2>/dev/null | jq -r '.[]? | "!\(.iid) \(.title) — \(.references.full | split("!")[0]), by \(.author.username)\(if .draft then " (draft)" else "" end)"')"
      [ -n "$OUT" ] && echo "$OUT" || echo "No open merge requests ($which)${ORG:+ in $ORG}, dearie." ;;
    mr)
      n="${1:-}"; [ -z "$n" ] && { echo "usage: forge.sh mr <n> [repo]" >&2; exit 1; }
      spec="$(repo_spec "${2:-}")" || { echo "Couldn't resolve repo '${2:-}', dearie." >&2; exit 1; }
      glab api "projects/$(urlenc "$spec")/merge_requests/$n" | jq -r '
        "!\(.iid) \(.title) — by \(.author.username), \(.state)\(if .draft then " (draft)" else "" end), \(.source_branch) → \(.target_branch), \(.user_notes_count) comments, \(.merge_status // .detailed_merge_status // "?"), \(.web_url)"' \
        || echo "Couldn't find MR !$n in $spec, dearie." ;;
    pipelines|ci)
      spec="$(repo_spec "${1:-}")" || { echo "Couldn't resolve repo '${1:-}', dearie." >&2; exit 1; }
      glab api "projects/$(urlenc "$spec")/pipelines?per_page=${2:-5}" | jq -r '.[]? | "#\(.id) \(.status) on \(.ref) (\(.updated_at))"' \
        || echo "No pipelines for $spec, dearie." ;;
    *) echo "usage: forge.sh projects | mrs [review|mine|assigned|all] | mr <n> [repo] | pipelines [repo] [n] | whoami" >&2; exit 1 ;;
  esac
else
  case "$cmd" in
    whoami) gh api user --jq '"\(.login) (\(.name // ""))"' ;;
    projects) OUT="$(list_projects)"; [ -n "$OUT" ] && echo "$OUT" || echo "No repos found${ORG:+ in $ORG}, dearie." ;;
    mrs)
      which="${1:-review}"
      case "$which" in
        review|reviews) F=(--review-requested=@me) ;;
        mine|authored)  F=(--author=@me) ;;
        assigned)       F=(--assignee=@me) ;;
        all|*)          F=() ;;
      esac
      OUT="$(gh search prs --state=open ${ORG:+--owner "$ORG"} ${F[@]+"${F[@]}"} -L 50 --json number,title,repository,author --jq '.[] | "#\(.number) \(.title) — \(.repository.nameWithOwner), by \(.author.login)"' 2>/dev/null)"
      [ -n "$OUT" ] && echo "$OUT" || echo "No open pull requests ($which)${ORG:+ in $ORG}, dearie." ;;
    mr|pr)
      n="${1:-}"; [ -z "$n" ] && { echo "usage: forge.sh mr <n> [repo]" >&2; exit 1; }
      spec="$(repo_spec "${2:-}")" || { echo "Couldn't resolve repo '${2:-}', dearie." >&2; exit 1; }
      gh pr view "$n" -R "$spec" --json number,title,author,state,isDraft,headRefName,baseRefName,reviewDecision,url \
        --jq '"#\(.number) \(.title) — by \(.author.login), \(.state)\(if .isDraft then " (draft)" else "" end), \(.headRefName) → \(.baseRefName), review: \(.reviewDecision // "none"), \(.url)"' \
        || echo "Couldn't find PR #$n in $spec, dearie." ;;
    pipelines|ci)
      spec="$(repo_spec "${1:-}")" || { echo "Couldn't resolve repo '${1:-}', dearie." >&2; exit 1; }
      gh run list -R "$spec" -L "${2:-5}" --json databaseId,status,conclusion,headBranch,updatedAt --jq '.[] | "#\(.databaseId) \(.conclusion // .status) on \(.headBranch) (\(.updatedAt))"' \
        || echo "No runs for $spec, dearie." ;;
    *) echo "usage: forge.sh projects | mrs [review|mine|assigned|all] | mr <n> [repo] | pipelines [repo] [n] | whoami" >&2; exit 1 ;;
  esac
fi
