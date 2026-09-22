#!/bin/bash
# state.sh — Margie's structured picture of work in flight. See state.py for the details.
#   state.sh json | waiting | ticket <PT-n|!n> | summary
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/state.py" "$@"
