#!/bin/bash
# simulate.sh — spin up a watchable session that BUILDS and RUNS a simulation or
# experiment to test one of Tom's theories, then reports whether it holds.
#
# Usage: simulate.sh "<hypothesis / what to model>" [--engine grok|claude]
#
# It creates a sandbox under ~/.margie/sims/, seeds a strong "model it, run it,
# report the numbers" prompt, and launches it via kickoff-claude.sh (grok by
# default) — so it gets its own Warp tab + tmux session and never disturbs a
# running session. Tom watches it work.
set -uo pipefail

ENGINE=""
DESC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --engine | -e) ENGINE="${2:-claude}"; shift 2 ;;
    *) DESC="${DESC:+$DESC }$1"; shift ;;
  esac
done
if [ -z "$DESC" ]; then
  echo "usage: simulate.sh \"<hypothesis or thing to simulate>\" [--engine claude|grok]" >&2
  exit 1
fi

STAMP="$(date +%s)"
SIM_DIR="$HOME/.margie/sims/sim-$STAMP"
mkdir -p "$SIM_DIR"
printf '%s\n' "$DESC" > "$SIM_DIR/hypothesis.txt"

PROMPT="You are running a simulation/experiment to test a hypothesis for Tom, in this folder ($SIM_DIR).

HYPOTHESIS / WHAT TO MODEL:
$DESC

Do this:
1. State your assumptions and the model in a sentence or two (note any you had to pick).
2. Write a self-contained simulation or experiment — Python is usually best (pip install numpy/pandas/matplotlib here if useful); use a Monte Carlo, numerical model, benchmark, or quick data analysis as fits the question.
3. RUN it here and iterate if the first cut is wrong.
4. Report the KEY NUMBERS clearly and say plainly whether they support the hypothesis (and by how much). Save code and any plots in this folder.
If the hypothesis is ambiguous, pick the most reasonable interpretation and say so."

KICKOFF="$(dirname "$0")/kickoff-claude.sh"
if [ -n "$ENGINE" ]; then
  exec bash "$KICKOFF" "$SIM_DIR" --engine "$ENGINE" "$PROMPT"
else
  exec bash "$KICKOFF" "$SIM_DIR" "$PROMPT"
fi
