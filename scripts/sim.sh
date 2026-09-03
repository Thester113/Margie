#!/bin/bash
# sim.sh — iOS Simulator primitives for the visual verification of UI MRs.
# Company-agnostic: it boots a device, builds+runs a Flutter app on a branch,
# and captures screenshots. HOW to make a specific feature visible (seed data,
# feature flags) lives in the repo's process notes, not here — the visual-verify
# Claude Code session reads those and does the forcing/navigation itself.
#
#   sim.sh device                         the sim device this uses (config sim_device, else first booted, else first available iPhone)
#   sim.sh boot [udid]                    boot a simulator device; prints its udid
#   sim.sh run <worktree> [--subdir d] [--device udid] [--log f]   build+run Flutter on the branch in the booted sim (background); waits for launch
#   sim.sh shot [--out png] [--device udid]                        screenshot the booted sim; prints the PNG path
#   sim.sh stop                           kill any `flutter run` this started (leaves the sim booted)
#   sim.sh tap <x> <y> [--device udid]    tap (needs `idb`; prints how to install it if missing)
#
# Nothing here is OUTWARD (no sends, no merges); it only drives a local sim.
set -uo pipefail
# Ensure the iOS/Flutter toolchain is findable no matter who invokes us (the
# daemon poller and the brain run with a thin PATH). Flutter shells out to
# `pod` (CocoaPods) during an iOS build; without asdf shims / Homebrew on PATH
# it dies with "CocoaPods not installed or not in valid state".
export PATH="$HOME/.asdf/shims:/opt/homebrew/bin:/usr/local/bin:$HOME/development/flutter/bin:$PATH"
CFG="$HOME/.margie/config.json"
cfg() { jq -r ".$1 // empty" "$CFG" 2>/dev/null; }
FLUTTER="$(command -v flutter || echo "$HOME/development/flutter/bin/flutter")"
SIMDIR="$HOME/.margie/sims"; mkdir -p "$SIMDIR"

pick_device() {
  local d; d="$(cfg sim_device)"; [ -n "$d" ] && { echo "$d"; return; }
  d="$(xcrun simctl list devices booted 2>/dev/null | grep -oE '\([0-9A-F-]{36}\)' | head -1 | tr -d '()')"; [ -n "$d" ] && { echo "$d"; return; }
  # first available iPhone
  xcrun simctl list devices available 2>/dev/null | grep -iE 'iPhone' | grep -oE '\([0-9A-F-]{36}\)' | head -1 | tr -d '()'
}

cmd="${1:-device}"; shift || true
DEVICE=""; SUBDIR=""; OUT=""; LOG=""
ARGS=(); while [ $# -gt 0 ]; do case "$1" in
  --device) DEVICE="${2:-}"; shift 2 ;;
  --subdir) SUBDIR="${2:-}"; shift 2 ;;
  --out) OUT="${2:-}"; shift 2 ;;
  --log) LOG="${2:-}"; shift 2 ;;
  *) ARGS+=("$1"); shift ;;
esac; done; set -- ${ARGS[@]+"${ARGS[@]}"}
[ -z "$DEVICE" ] && DEVICE="$(pick_device)"

case "$cmd" in
  device) echo "${DEVICE:-<none — no iPhone simulator found>}" ;;
  boot)
    [ -n "${1:-}" ] && DEVICE="$1"
    [ -z "$DEVICE" ] && { echo "No simulator device found, dearie — open Xcode once to install one." >&2; exit 1; }
    xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1 || xcrun simctl boot "$DEVICE" >/dev/null 2>&1 || true
    open -a Simulator >/dev/null 2>&1 || true
    echo "$DEVICE" ;;
  run)
    WT="${1:?usage: sim.sh run <worktree> [--subdir d]}"
    RUNDIR="$WT${SUBDIR:+/$SUBDIR}"
    [ -d "$RUNDIR" ] || { echo "No such dir: $RUNDIR" >&2; exit 1; }
    [ -x "$FLUTTER" ] || { echo "flutter not found, dearie (looked in PATH and ~/development/flutter/bin)." >&2; exit 1; }
    [ -z "$DEVICE" ] && { echo "No simulator device, dearie." >&2; exit 1; }
    xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1 || xcrun simctl boot "$DEVICE" >/dev/null 2>&1 || true
    open -a Simulator >/dev/null 2>&1 || true
    [ -z "$LOG" ] && LOG="$SIMDIR/flutter-run.log"
    # kill a previous run we started, then launch fresh in the background
    pkill -f "flutter run.*$DEVICE" 2>/dev/null || true
    ( cd "$RUNDIR" && nohup "$FLUTTER" run -d "$DEVICE" --debug >"$LOG" 2>&1 & echo $! > "$SIMDIR/run.pid" )
    echo "Building & launching $RUNDIR on $DEVICE (log: $LOG)…"
    for _i in $(seq 1 40); do
      grep -qiE "Dart VM Service on|Flutter DevTools" "$LOG" 2>/dev/null && { echo "Launched."; exit 0; }
      grep -qiE "^Error:|Could not build|BUILD FAILED|error:.*\.dart" "$LOG" 2>/dev/null && { echo "Build error — see $LOG" >&2; tail -5 "$LOG" >&2; exit 1; }
      sleep 6
    done
    echo "Still building after 4 min — check $LOG" >&2; exit 1 ;;
  shot)
    [ -z "$DEVICE" ] && { echo "No simulator device, dearie." >&2; exit 1; }
    [ -z "$OUT" ] && OUT="$SIMDIR/shot-$(date +%s).png"
    xcrun simctl io "$DEVICE" screenshot "$OUT" >/dev/null 2>&1 || xcrun simctl io booted screenshot "$OUT" >/dev/null 2>&1 || { echo "Screenshot failed, dearie." >&2; exit 1; }
    echo "$OUT" ;;
  stop)
    [ -f "$SIMDIR/run.pid" ] && kill "$(cat "$SIMDIR/run.pid")" 2>/dev/null || true
    pkill -f "flutter run.*$DEVICE" 2>/dev/null || true
    echo "Stopped the flutter run (sim stays booted), dearie." ;;
  tap)
    X="${1:?x}"; Y="${2:?y}"
    if command -v idb >/dev/null 2>&1; then idb ui tap --udid "$DEVICE" "$X" "$Y" && echo "tapped $X,$Y"; else
      echo "No tap tool, dearie — install idb for headless taps: brew install idb-companion && pipx install fb-idb (or python3 -m pip install fb-idb)." >&2; exit 1
    fi ;;
  *) echo "usage: sim.sh device | boot [udid] | run <worktree> [--subdir d] [--device udid] [--log f] | shot [--out png] | stop | tap <x> <y>" >&2; exit 1 ;;
esac
