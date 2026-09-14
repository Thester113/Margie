#!/bin/bash
# avatar.sh — the character Margie shows on a Looking Glass display.
# The model is kept OUTSIDE the repo (identity stays configurable):
# ~/.margie/avatar/margie.vrm (or .glb), or `hologram_avatar` in ~/.margie/config.json.
#
#   avatar.sh show               where the avatar is expected and whether it exists
#   avatar.sh set <file>         install a model as Margie: .vrm (VRoid etc.) or a .glb
#                                with ARKit-52 face blendshapes (Avaturn, MetaPerson,
#                                ChatAvatar, Character Creator…) — realistic, not anime
#   avatar.sh sample             fetch a CC0 VRoid sample model as a placeholder (anime)
#
# Margie.app picks the new model up on next launch. To try one without
# installing it: MARGIE_AVATAR=/path/to/model.glb npm run tauri dev
#
# Nothing here is OUTWARD; it only writes under ~/.margie/avatar.
set -uo pipefail
CFG="$HOME/.margie/config.json"
cfg() { jq -r ".$1 // empty" "$CFG" 2>/dev/null; }
DEST="$(cfg hologram_avatar)"
case "$DEST" in "~/"*) DEST="$HOME/${DEST#\~/}";; esac
AVDIR="$HOME/.margie/avatar"
# Default location: whichever of margie.glb / margie.vrm exists (.glb wins),
# mirroring the app's lookup; `set` picks the extension of the file given.
if [ -z "$DEST" ]; then
  if [ -s "$AVDIR/margie.glb" ]; then DEST="$AVDIR/margie.glb"
  elif [ -s "$AVDIR/margie.vrm" ]; then DEST="$AVDIR/margie.vrm"
  else DEST="$AVDIR/margie.glb"; fi
fi

# VRoid Studio's beta-era sample models are CC0 (see
# https://vroid.pixiv.help/hc/en-us/articles/4402614652569); this mirror keeps
# them alongside the licence note.
SAMPLE_URL="https://raw.githubusercontent.com/madjin/vrm-samples/master/vroid/beta/Sendagaya_Shino.vrm"

case "${1:-show}" in
  show)
    echo "avatar: $DEST"
    if [ -s "$DEST" ]; then
      echo "status: present ($(du -h "$DEST" | cut -f1))"
    else
      echo "status: missing — run: avatar.sh set <file.glb|file.vrm>   or   avatar.sh sample (anime placeholder)"
    fi
    ;;
  set)
    src="${2:-}"
    [ -f "$src" ] || { echo "usage: avatar.sh set <file.glb|file.vrm>" >&2; exit 2; }
    case "$src" in *.vrm|*.glb) ;; *) echo "expected a .vrm or .glb file" >&2; exit 2;; esac
    if [ -z "$(cfg hologram_avatar)" ]; then
      # Default path: name by format and retire the other one so the app's
      # lookup (.glb first) can't pick a stale model.
      DEST="$AVDIR/margie.${src##*.}"
      for other in "$AVDIR"/margie.glb "$AVDIR"/margie.vrm; do
        [ "$other" != "$DEST" ] && [ -f "$other" ] && mv "$other" "$other.previous"
      done
    fi
    mkdir -p "$(dirname "$DEST")"
    cp "$src" "$DEST" && echo "installed $DEST ($(du -h "$DEST" | cut -f1)); restart Margie.app to load it"
    ;;
  sample)
    mkdir -p "$(dirname "$DEST")"
    tmp="$(mktemp "${TMPDIR:-/tmp}/margie-avatar.XXXXXX")"
    echo "downloading placeholder (CC0 VRoid sample) …"
    if curl -fsSL --retry 2 -o "$tmp" "$SAMPLE_URL" && [ -s "$tmp" ]; then
      mv "$tmp" "$DEST" && echo "installed $DEST ($(du -h "$DEST" | cut -f1)); restart Margie.app to load it"
    else
      rm -f "$tmp"; echo "download failed: $SAMPLE_URL" >&2; exit 1
    fi
    ;;
  *)
    sed -n '2,14p' "$0"; exit 2;;
esac
