#!/bin/bash
# sync-decoders.sh — copy three.js's glTF decoders (Draco, Basis/KTX2) from
# node_modules into public/decoders so the hologram can load compressed avatar
# models. Run by npm's predev/prebuild hooks; public/decoders is git-ignored.
set -euo pipefail
cd "$(dirname "$0")/.."
LIBS=node_modules/three/examples/jsm/libs
[ -d "$LIBS" ] || { echo "three.js not installed (npm install first)" >&2; exit 1; }
mkdir -p public/decoders/draco public/decoders/basis
cp "$LIBS"/draco/gltf/draco_decoder.js "$LIBS"/draco/gltf/draco_decoder.wasm "$LIBS"/draco/gltf/draco_wasm_wrapper.js public/decoders/draco/
cp "$LIBS"/basis/basis_transcoder.js "$LIBS"/basis/basis_transcoder.wasm public/decoders/basis/
