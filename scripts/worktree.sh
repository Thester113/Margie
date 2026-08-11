#!/bin/bash
# worktree.sh — manage git worktrees for isolated parallel work.
# Usage:
#   worktree.sh list <repo>
#   worktree.sh add <repo> <branch>      create a worktree on a new/existing branch
#   worktree.sh remove <repo> <branch>   remove the worktree (branch is kept)
#   worktree.sh path <repo> <branch>     print the worktree directory
#   worktree.sh prune <repo>             clean up stale worktree records
# <repo> may be a path or a name ("backend" → xerpa_ai_backend, cloned if needed).
set -uo pipefail

WT_ROOT="$HOME/.margie/worktrees"; mkdir -p "$WT_ROOT"
cmd="${1:-list}"; repo_arg="${2:-$PWD}"; branch="${3:-}"

# Resolve <repo> to a git dir (local match, else xerpaai org clone on demand).
resolve() {
  local d="$1"
  if git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1; then (cd "$d" && pwd); return; fi
  local token; token="$(basename "$d" | tr 'A-Z' 'a-z')"
  for c in "$HOME/Xerpa Repos"/*/ "$HOME"/*/; do
    git -C "$c" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
    case "$(basename "$c" | tr 'A-Z' 'a-z')" in *"$token"*) echo "${c%/}"; return;; esac
  done
  local org; org="$(gh repo list xerpaai --limit 200 --json name --jq '.[].name' 2>/dev/null | grep -iF "$token" | head -1 || true)"
  if [ -n "$org" ]; then
    local dst="$HOME/Xerpa Repos/$org"
    git -C "$dst" rev-parse --is-inside-work-tree >/dev/null 2>&1 || gh repo clone "xerpaai/$org" "$dst" >/dev/null 2>&1
    echo "$dst"
  fi
}
REPO="$(resolve "$repo_arg")"
[ -z "$REPO" ] && { echo "Couldn't find repo '$repo_arg', sir." >&2; exit 1; }

slug() { printf '%s' "$1" | tr '/ ' '--'; }
wtdir() { echo "$WT_ROOT/$(basename "$REPO")__$(slug "$branch")"; }

case "$cmd" in
  list)  git -C "$REPO" worktree list ;;
  path)  [ -z "$branch" ] && { echo "need <branch>" >&2; exit 1; }; echo "$(wtdir)" ;;
  add)
    [ -z "$branch" ] && { echo "need <branch>" >&2; exit 1; }
    d="$(wtdir)"
    if git -C "$REPO" worktree list --porcelain | grep -qF "$d"; then echo "$d"; exit 0; fi
    if git -C "$REPO" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$REPO" worktree add "$d" "$branch" >&2
    else
      git -C "$REPO" worktree add -b "$branch" "$d" >&2
    fi
    echo "$d" ;;
  remove)
    [ -z "$branch" ] && { echo "need <branch>" >&2; exit 1; }
    git -C "$REPO" worktree remove --force "$(wtdir)" && echo "removed $(wtdir)" ;;
  prune) git -C "$REPO" worktree prune && echo "pruned" ;;
  *) echo "usage: worktree.sh list|add|remove|path|prune <repo> [branch]" >&2; exit 1 ;;
esac
