#!/bin/bash
# camera.sh — capture a photo from the webcam so Margie can see Tom / the room,
# and print the path. Her brain (Sonnet, vision-capable) then Reads it.
#
# Usage: camera.sh ["FaceTime HD Camera" | "iPhone Camera" | <device name>]
#   default: the system default camera
#
# Needs macOS Camera permission for the Margie app (System Settings → Privacy &
# Security → Camera). The -w warmup lets exposure/white-balance settle so the
# frame isn't dark.
set -uo pipefail

OUT="$HOME/.margie/camera.jpg"
mkdir -p "$HOME/.margie"
DEV="${1:-}"

if [ -n "$DEV" ]; then
  imagesnap -w 1.5 -d "$DEV" "$OUT" >/dev/null 2>&1 || true
else
  imagesnap -w 1.5 "$OUT" >/dev/null 2>&1 || true
fi

if [ -s "$OUT" ]; then
  echo "$OUT"
else
  echo "Camera capture failed, sir — check Camera permission for Margie (System Settings → Privacy & Security → Camera), and that the panel camera isn't already using it."
  exit 1
fi
