#!/bin/bash
# lessons.sh — what Margie learned from Tom's corrections (Tom, 2026-09-22).
# Lessons live in ~/.margie/process/lessons.md, which processNotes() injects into every
# turn, so a correction changes how she answers from the next message on. Written by her
# brain only on Tom's own turns (the colleague allowlist has no lessons.sh), when Jev
# (jev.sh correction) says his message corrects what she just said.
#
#   lessons.sh add "<what went wrong> → <the rule that prevents it>"
#   lessons.sh list            numbered
#   lessons.sh drop <n>        remove one (Tom prunes)
# Capped at the newest 40 so the prompt stays small. Internal file — nothing is sent.
set -uo pipefail
F="$HOME/.margie/process/lessons.md"; mkdir -p "$(dirname "$F")"
[ -f "$F" ] || printf 'Lessons from Tom'"'"'s corrections (newest last). Each one is a rule — follow it.\n' > "$F"
case "${1:-list}" in
  add)
    T="${2:-}"; [ -z "$T" ] && { echo "usage: lessons.sh add \"<what went wrong> → <rule>\"" >&2; exit 1; }
    T="$(printf '%s' "$T" | tr '\n' ' ' | cut -c1-300)"
    grep -qF -- "$T" "$F" && { echo "Already have that lesson."; exit 0; }
    printf -- '- %s: %s\n' "$(date +%F)" "$T" >> "$F"
    { head -1 "$F"; tail -n +2 "$F" | tail -40; } > "$F.tmp" && mv "$F.tmp" "$F"
    echo "Noted — I'll do it that way from now on." ;;
  list) tail -n +2 "$F" | nl -w2 -s'. ' ;;
  drop)
    N="${2:-}"; [ -z "$N" ] && { echo "usage: lessons.sh drop <n>" >&2; exit 1; }
    L="$(tail -n +2 "$F" | sed -n "${N}p")"; [ -z "$L" ] && { echo "No lesson $N." >&2; exit 1; }
    { head -1 "$F"; tail -n +2 "$F" | sed "${N}d"; } > "$F.tmp" && mv "$F.tmp" "$F"
    echo "Dropped: ${L#- }" ;;
  *) echo "usage: lessons.sh add \"<text>\" | list | drop <n>" >&2; exit 64 ;;
esac
