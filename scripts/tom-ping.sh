#!/bin/bash
# tom-ping.sh — Margie's background notices, reaching Tom in Slack while he's away from the
# terminal (Tom, 2026-09-22: Slack should be an extension of the CLI).
#
#   tom-ping.sh consider "<notice>"   Jev (jev.sh notice) decides: act | know | skip.
#                                     act (≥0.6) or know (≥0.75) is queued; nothing else.
#                                     Play-by-play lines ("[label] …") and repeats are dropped
#                                     without asking.
#   tom-ping.sh flush                 poller (every minute): sends the queue as ONE Slack DM —
#                                     things that need him first. At most one DM every 2 minutes
#                                     unless something needs him.
#
# Deterministic around a typed decision: whether a notice is worth a ping is Jev's call
# (fixtures in jev.sh check); dedup, rate-limit and delivery are code. Jev unavailable or
# unsure → no ping (the CLI still shows every notice). Config: slack_ping on|off (default on).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$HOME/.margie/config.json"; ST="$HOME/.margie/tom-ping"; mkdir -p "$ST"
Q="$ST/queue"; SEEN="$ST/seen"; LAST="$ST/last-sent"
cfg() { jq -r ".$1 // empty" "$CFG" 2>/dev/null; }
[ "$(cfg slack_ping)" = off ] && exit 0

case "${1:-}" in
  consider)
    T="${2:-}"; [ -z "$T" ] && exit 0
    case "$T" in "["*) exit 0 ;; esac                      # session play-by-play
    H="$(printf '%s' "$T" | tr -d '0-9' | shasum | cut -c1-12)"   # digits vary (times, counts)
    touch "$SEEN"; grep -qx "$H" "$SEEN" && exit 0
    echo "$H" >> "$SEEN"; tail -500 "$SEEN" > "$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"
    J="$(printf '%s' "$T" | "$DIR/jev.sh" notice 2>/dev/null)" || exit 0
    K="$(printf '%s' "$J" | cut -f1)"; C="$(printf '%s' "$J" | cut -f2)"
    GO=0
    case "$K" in
      act)  awk -v c="$C" 'BEGIN{exit !(c>=0.6)}'  && GO=1 ;;
      know) awk -v c="$C" 'BEGIN{exit !(c>=0.75)}' && GO=1 ;;
    esac
    "$DIR/jev.sh" outcome notice "$([ "$GO" = 1 ] && echo "queue $K" || echo skip)@$C: $(printf '%s' "$T" | cut -c1-60)" >/dev/null 2>&1
    [ "$GO" = 1 ] && printf '%s\t%s\n' "$K" "$(printf '%s' "$T" | tr '\n' ' ' | cut -c1-500)" >> "$Q"
    exit 0 ;;
  flush)
    [ -s "$Q" ] || exit 0
    NOW="$(date +%s)"; L="$(cat "$LAST" 2>/dev/null || echo 0)"
    grep -q '^act' "$Q" || [ $(( NOW - L )) -ge 120 ] || exit 0
    mv "$Q" "$Q.sending"
    N="$(wc -l < "$Q.sending" | tr -d ' ')"
    if [ "$N" = 1 ]; then MSG="$(cut -f2- "$Q.sending")"
    else MSG="$( { grep '^act' "$Q.sending"; grep '^know' "$Q.sending"; } | cut -f2- | sed 's/^/• /')"; fi
    if "$DIR/slack.sh" send "@$(cfg owner_first_name || echo Tom): $MSG" >/dev/null 2>&1; then
      echo "$NOW" > "$LAST"; rm -f "$Q.sending"
    else
      cat "$Q.sending" >> "$Q" 2>/dev/null; rm -f "$Q.sending"   # try again next minute
    fi
    exit 0 ;;   # silent: the notices themselves were already announced in the CLI
  *) echo "usage: tom-ping.sh consider \"<notice>\" | flush" >&2; exit 64 ;;
esac
