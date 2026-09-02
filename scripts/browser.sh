#!/bin/bash
# browser.sh — active browser. Usage: browser.sh [current|open <url>|search <query>]
set -uo pipefail
cmd="${1:-current}"; shift || true; arg="$*"
case "$cmd" in
  current)
    url="$(osascript -e 'tell application "Google Chrome" to get URL of active tab of front window' 2>/dev/null)"
    [ -z "$url" ] && url="$(osascript -e 'tell application "Safari" to get URL of front document' 2>/dev/null)"
    ttl="$(osascript -e 'tell application "Google Chrome" to get title of active tab of front window' 2>/dev/null)"
    [ -z "$ttl" ] && ttl="$(osascript -e 'tell application "Safari" to get name of front document' 2>/dev/null)"
    [ -n "$url" ] && echo "${ttl:-page}: $url" || echo "No open browser tab, dear." ;;
  open)   open "$arg"; echo "Opened $arg" ;;
  search) open "https://www.google.com/search?q=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$arg")"; echo "Searching: $arg" ;;
  *) echo "usage: browser.sh current|open <url>|search <query>" >&2; exit 1 ;;
esac
