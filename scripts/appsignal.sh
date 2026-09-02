#!/bin/bash
# appsignal.sh — read AppSignal (apps, logs, errors, performance) through the
# hosted AppSignal MCP server via headless Claude Code. Read-only by design.
#
# Connection: `claude mcp add -s user --transport http appsignal
# https://appsignal.com/api/mcp` + a one-time browser OAuth (Tom's work-email
# account). No API key ever touches this repo or config.
#
#   appsignal.sh apps                       the applications Tom's account can see
#   appsignal.sh logs "<query>" [--app <name>] [--minutes <n>] [--namespace <ns>]
#   appsignal.sh errors [--app <name>] [--minutes <n>]        recent exception incidents
#   appsignal.sh perf [--app <name>]                          slowest endpoints lately
#   appsignal.sh ask "<question>"                             free-form, read tools only
#
# Field notes inherited from Athena's watches (baked into every prompt):
#   - get_exception_incidents under-reports; corroborate any zero with a
#     get_log_lines matcher over the same window, positively controlled.
#   - hostname!= matchers falsely return zero rows — never negate hostname.
#   - Namespace strings must be exact (WaltUI/live_view, not live_view);
#     Oban emits nothing to logs — use the exception surface, namespace oban.
set -uo pipefail

CLAUDE_BIN="${MARGIE_CLAUDE_BIN:-$(command -v claude || echo "$HOME/.local/bin/claude")}"
CMODEL="${MARGIE_APPSIGNAL_MODEL:-sonnet}"
T="mcp__appsignal__"
# Read-only tool families; wildcards keep this robust across server versions.
ALLOW="${T}get_applications,${T}get_log_lines,${T}get_exception_incidents,${T}get_exception_incident,${T}get_performance_incidents,${T}get_performance_incident,${T}get_anomaly_incidents,${T}get_metrics,${T}search_logs"

CAVEATS="Known backend quirks you MUST respect: get_exception_incidents under-reports, so corroborate any zero result with a get_log_lines matcher over the same window (positively controlled). Never use a negated hostname matcher (hostname!= falsely returns zero rows). Namespace strings must be exact (e.g. WaltUI/live_view, not live_view). Oban emits nothing to the log stream — check the exception surface in namespace oban instead."

ask() { # ask "<prompt>"
  local out
  out="$(cd "$HOME" && "$CLAUDE_BIN" -p "$1" --model "$CMODEL" --output-format json --allowedTools "$ALLOW" 2>&1 | jq -r '.result // empty' 2>/dev/null)"
  if [ -z "$out" ]; then
    echo "AppSignal didn't answer, dear — if this is the first use, the OAuth sign-in hasn't been done yet: run 'claude' in Warp, then /mcp, pick appsignal, and authenticate with your work email." >&2
    return 1
  fi
  printf '%s\n' "$out"
}

cmd="${1:-apps}"; shift || true
APP=""; MIN="60"; NS=""; ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --minutes) MIN="${2:-60}"; shift 2 ;;
    --namespace) NS="${2:-}"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
Q="${ARGS[*]:-}"
APPLINE="${APP:+ Application: $APP.}"

case "$cmd" in
  apps)
    ask "List the AppSignal applications this account can see, one per line as 'name (environment) — id'. Nothing else. If none, say exactly: No applications visible — the account may need to be added to the AppSignal organization." ;;
  logs)
    [ -z "$Q" ] && { echo "usage: appsignal.sh logs \"<query>\" [--app <name>] [--minutes <n>] [--namespace <ns>]" >&2; exit 1; }
    ask "Search AppSignal logs from the last $MIN minutes for: $Q.$APPLINE${NS:+ Namespace (exact): $NS.} $CAVEATS Output at most 15 matching log lines, newest first, each as 'HH:MM:SS [severity] message' trimmed to ~160 chars, then one summary line ('N matches in the window'). No commentary." ;;
  errors)
    ask "List AppSignal exception incidents from the last $MIN minutes.$APPLINE $CAVEATS Output one line per incident: 'name — count, last seen HH:MM, state', then a one-line total. If zero, corroborate with a positively-controlled get_log_lines check for severity error in the same window and report both results." ;;
  perf)
    ask "List the slowest AppSignal performance incidents currently open.$APPLINE Output one line each: 'action — mean ms, throughput' (max 10), then one summary line." ;;
  ask)
    [ -z "$Q" ] && { echo "usage: appsignal.sh ask \"<question>\"" >&2; exit 1; }
    ask "Answer this question using ONLY AppSignal read tools: $Q.$APPLINE $CAVEATS Be terse — the answer is spoken aloud: key numbers and a one-sentence verdict." ;;
  *)
    echo "usage: appsignal.sh apps | logs \"<q>\" [--app|--minutes|--namespace] | errors [--app|--minutes] | perf [--app] | ask \"<q>\"" >&2
    exit 1 ;;
esac
