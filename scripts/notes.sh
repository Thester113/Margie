#!/bin/bash
# notes.sh — per-project state notes Margie keeps in ~/.margie/projects/<name>.md
# (what exists, what's missing, decisions, blockers). Team PROCESS notes live in
# ~/.margie/process/ and are injected into every turn; project notes are read on demand.
#
#   notes.sh list                      project notes, newest first
#   notes.sh show <name|word>          print one (fuzzy on the name)
#   notes.sh add <name> "<line…>"      append a dated line (creates the note)
set -uo pipefail
P="$HOME/.margie/projects"; mkdir -p "$P"
cmd="${1:-list}"; shift || true
case "$cmd" in
  list) ls -t "$P" 2>/dev/null | sed 's/\.md$//' | while read -r n; do printf '%s  (%s)\n' "$n" "$(head -1 "$P/$n.md" | cut -c1-80)"; done; [ -z "$(ls -A "$P" 2>/dev/null)" ] && echo "No project notes yet, dearie." ;;
  show) x="${1:?name}"; f="$P/$x.md"; [ -f "$f" ] || f="$(ls "$P"/*.md 2>/dev/null | grep -i -- "$x" | head -1)"; [ -f "${f:-}" ] && cat "$f" || { echo "No project note matching '$x', dearie." >&2; exit 1; } ;;
  add) n="${1:?name}"; shift; t="$*"; [ -z "$t" ] && { echo "usage: notes.sh add <name> \"<text>\"" >&2; exit 1; }; f="$P/$(printf '%s' "$n" | tr 'A-Z /' 'a-z--').md"
    [ -f "$f" ] || printf '# %s\n\n## STATE\n\n## BLOCKERS / ON TOM\n\n## DECISIONS\n' "$n" > "$f"
    # newest facts go at the TOP of STATE so a truncated read still sees them
    awk -v line="- $(date +%F): $t" 'BEGIN{done=0} {print} /^## STATE/ && !done {print line; done=1} END{if(!done) print line}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    echo "Noted under $(basename "$f" .md) (top of STATE), dearie." ;;
  *) echo "usage: notes.sh list | show <name> | add <name> \"<text>\"" >&2; exit 1 ;;
esac
