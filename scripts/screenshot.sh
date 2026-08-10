#!/bin/bash
# screenshot.sh — capture ALL displays so Margie can see every screen, and
# print one PNG path per display (one per line). Her brain (Sonnet, vision-
# capable) then uses the Read tool on each path to actually "see" the screens.
#
# Requires macOS Screen Recording permission for the Margie app (granted once
# in System Settings → Privacy & Security → Screen Recording).
set -uo pipefail

OUT_DIR="$HOME/.margie"
mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/screen-*.png

# Pass more candidate paths than any realistic monitor count; screencapture
# writes one file per actual display, in order, and ignores the extras.
screencapture -x \
  "$OUT_DIR/screen-1.png" \
  "$OUT_DIR/screen-2.png" \
  "$OUT_DIR/screen-3.png" \
  "$OUT_DIR/screen-4.png" \
  "$OUT_DIR/screen-5.png" \
  "$OUT_DIR/screen-6.png" 2>/dev/null || true

# List only the files that were actually created (one per real display).
ls "$OUT_DIR"/screen-*.png 2>/dev/null
