#!/bin/bash
# status-sync.sh — Margie's memory of record in Notion. Mirrors her local project state
# (~/.margie/projects/*.md) to a "Margie — Status" area in Notion so it's backed up and
# the team can read it; and pulls it back to reground her after a restart or data loss.
#
#   status-sync.sh push          write every project note to its Notion status page
#   status-sync.sh pull          restore local notes from Notion (if a local note is missing)
#   status-sync.sh link          print the Notion status pages
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$HOME/.margie/config.json"; PROJ="$HOME/.margie/projects"; mkdir -p "$PROJ"
cfg() { jq -r ".$1 // empty" "$CFG" 2>/dev/null; }
setcfg() { jq --arg k "$1" --arg v "$2" '.[$k]=$v' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG" && chmod 600 "$CFG"; }

ensure_parent() {
  local pp; pp="$(cfg notion_status_parent)"
  if [ -z "$pp" ]; then
    local under; under="$(cfg notion_parent_page)"; [ -z "$under" ] && under="$(cfg notion_drafts_parent)"
    [ -z "$under" ] && { echo "No Notion parent to create the status area under, dearie (set notion_parent_page)." >&2; return 1; }
    printf '# Margie — Status\nLive project state, kept current by Margie. Newest facts are at the top of each page.\n' > /tmp/margie-status-root.md
    local url; url="$("$DIR/notion.sh" page create "Margie — Status" --md /tmp/margie-status-root.md --parent "$under" 2>/dev/null | grep -oE '[0-9a-f]{32}' | tail -1)"
    [ -z "$url" ] && { echo "Couldn't create the status area, dearie." >&2; return 1; }
    setcfg notion_status_parent "$url"; pp="$url"
  fi
  echo "$pp"
}

case "${1:-push}" in
  push)
    PP="$(ensure_parent)" || exit 1
    for f in "$PROJ"/*.md; do
      [ -f "$f" ] || continue; name="$(basename "$f" .md)"; pfile="$PROJ/.$name.page"
      pid="$(cat "$pfile" 2>/dev/null || true)"
      if [ -z "$pid" ]; then
        pid="$("$DIR/notion.sh" page create "Status — $name" --md "$f" --parent "$PP" 2>/dev/null | grep -oE '[0-9a-f]{32}' | tail -1)"
        [ -n "$pid" ] && echo "$pid" > "$pfile" && echo "Created status page for $name."
      else
        "$DIR/notion.sh" page replace "$pid" --md "$f" >/dev/null 2>&1 >/dev/null 2>&1   # routine sync: silent
      fi
    done ;;
  pull)
    for pfile in "$PROJ"/.*.page; do
      [ -f "$pfile" ] || continue; name="$(basename "$pfile" .page)"; name="${name#.}"
      [ -s "$PROJ/$name.md" ] && continue   # local note exists — don't clobber
      pid="$(cat "$pfile")"; "$DIR/notion.sh" read "$pid" 200 2>/dev/null | tail -n +2 > "$PROJ/$name.md" && echo "Restored $name from Notion."
    done ;;
  link)
    for pfile in "$PROJ"/.*.page; do [ -f "$pfile" ] || continue; name="$(basename "$pfile" .page)"; echo "${name#.}: https://notion.so/$(cat "$pfile")"; done
    pp="$(cfg notion_status_parent)"; [ -n "$pp" ] && echo "Status area: https://notion.so/$pp" ;;
  *) echo "usage: status-sync.sh push | pull | link" >&2; exit 1 ;;
esac
