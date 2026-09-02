#!/bin/bash
# media.sh — control Spotify. Usage: media.sh [current|play|pause|next|prev|volume <0-100>]
set -uo pipefail
cmd="${1:-current}"; arg="${2:-}"
osa() { osascript -e "tell application \"Spotify\" $1" 2>/dev/null; }
case "$cmd" in
  play|resume)     osa "to play"; echo "Playing." ;;
  pause)           osa "to pause"; echo "Paused." ;;
  playpause|toggle) osa "to playpause" ;;
  next)            osa "to next track"; sleep 0.3; media_now ;;
  prev|previous)   osa "to previous track"; sleep 0.3 ;;
  volume)          [ -n "$arg" ] && { osa "to set sound volume to $arg"; echo "Volume $arg."; } ;;
  current|now)
    t="$(osascript -e 'tell application "Spotify" to (name of current track) & " by " & (artist of current track)' 2>/dev/null)"
    [ -n "$t" ] && echo "$t" || echo "Nothing playing, dear." ;;
  *) echo "usage: media.sh current|play|pause|next|prev|volume <0-100>" >&2; exit 1 ;;
esac
