#!/bin/bash
# evals.sh — nightly answer evals for Margie. See evals.py.
#   evals.sh run | auto | last
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/evals.py" "$@"
