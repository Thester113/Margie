#!/bin/bash
# resolve-repo.sh — turn a repo path OR bare name ("backend") into a local git
# directory, and print it. Shared by review-pr.sh, worktree.sh, kickoff.
#
# Order: already a git dir → a local clone whose folder name contains the token
# (under repos_dir, then $HOME) → a project on the forge (GitLab or GitHub; in
# `org` if set, else the projects you're a member of) cloned into repos_dir on
# first use.
#
# Config (~/.margie/config.json), each overridable by env:
#   forge        MARGIE_FORGE      gitlab | github (default github)
#   org          MARGIE_ORG        GitLab group / GitHub org to search; unset = your own
#   repos_dir    MARGIE_REPOS_DIR  where your repos live / clones go (default ~/repos)
#   gitlab_host  GITLAB_HOST       self-hosted GitLab host (default gitlab.com)
set -uo pipefail

CFG="$HOME/.margie/config.json"
cfg() { jq -r ".$1 // empty" "$CFG" 2>/dev/null; }
FORGE="${MARGIE_FORGE:-$(cfg forge)}"; FORGE="$(printf '%s' "${FORGE:-github}" | tr 'A-Z' 'a-z')"
ORG="${MARGIE_ORG:-$(cfg org)}"
REPOS_DIR="${MARGIE_REPOS_DIR:-$(cfg repos_dir)}"
REPOS_DIR="${REPOS_DIR:-$HOME/repos}"
REPOS_DIR="${REPOS_DIR/#\~/$HOME}"
GL_HOST="$(cfg gitlab_host)"; [ -n "$GL_HOST" ] && export GITLAB_HOST="${GITLAB_HOST:-$GL_HOST}"

d="${1:-$PWD}"
if git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  (cd "$d" && pwd); exit 0
fi

# Match ignoring case and separators, so spoken "walt ui" / "walt-ui" find walt_ui.
norm() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d ' _.-'; }
token="$(norm "$(basename "$d")")"
[ -z "$token" ] && exit 1

for c in "$REPOS_DIR"/*/ "$HOME"/*/; do
  [ -d "$c" ] || continue
  git -C "$c" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
  case "$(norm "$(basename "$c")")" in *"$token"*) echo "${c%/}"; exit 0 ;; esac
done

# Not local — look on the forge. Match on the project name (last path segment).
urlenc() { jq -rn --arg s "$1" '$s|@uri'; }
case "$FORGE" in
  gitlab)
    if [ -n "$ORG" ]; then
      LIST="$(glab api "groups/$(urlenc "$ORG")/projects?per_page=100&include_subgroups=true&simple=true" 2>/dev/null)"
    else
      LIST="$(glab api "projects?membership=true&per_page=100&simple=true&order_by=last_activity_at" 2>/dev/null)"
    fi
    # Skip projects GitLab has queued for deletion (renamed "<name>-deletion_scheduled-<id>").
    full="$(printf '%s' "$LIST" | jq -r '.[]? | select(.marked_for_deletion_on == null) | .path_with_namespace' 2>/dev/null \
      | grep -v -- '-deletion_scheduled-' \
      | awk -F/ -v t="$token" '{ n = tolower($NF); gsub(/[-_. ]/, "", n) } index(n, t) { print; exit }')"
    CLONE=(glab repo clone "$full")
    WHERE="${ORG:+ or in the $ORG GitLab group}"
    ;;
  *)
    full="$(gh repo list ${ORG:+"$ORG"} --limit 200 --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null \
      | awk -F/ -v t="$token" '{ n = tolower($2); gsub(/[-_. ]/, "", n) } index(n, t) { print; exit }')"
    CLONE=(gh repo clone "$full")
    WHERE="${ORG:+ or in the $ORG GitHub org}"
    ;;
esac
if [ -z "$full" ]; then
  echo "Couldn't find a repo matching '$token' locally$WHERE, sir." >&2
  exit 1
fi
dst="$REPOS_DIR/${full##*/}"
if ! git -C "$dst" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  mkdir -p "$REPOS_DIR"
  echo "Cloning $full (first time), sir…" >&2
  "${CLONE[@]}" "$dst" >/dev/null 2>&1 || { echo "Couldn't clone $full, sir." >&2; exit 1; }
fi
echo "$dst"
