#!/bin/bash
# calendar.sh — show Tom's Google Calendar and let Margie READ it visually.
# Google Calendar has no connector/CLI here, so this opens it in Chrome,
# screenshots it, and prints the image path for the brain to Read.
# Usage: calendar.sh [week|day]
set -uo pipefail
OUT="$HOME/.margie/calendar.png"
mkdir -p "$HOME/.margie"
case "${1:-week}" in
  day|today) URL="https://calendar.google.com/calendar/u/0/r/day" ;;
  *)         URL="https://calendar.google.com/calendar/u/0/r/week" ;;
esac
# Open (or focus) the calendar in Chrome, give it a moment to render, capture it.
open -a "Google Chrome" "$URL" 2>/dev/null || open "$URL"
sleep 3
screencapture -x "$OUT"
if [ -s "$OUT" ]; then
  echo "$OUT"
else
  echo "Couldn't capture the calendar, dear — grant Margie Screen Recording permission."
  exit 1
fi
