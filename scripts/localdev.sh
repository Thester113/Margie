#!/bin/bash
# localdev.sh — bring up (and check) the local dev web app via DOCKER, the way this app is
# actually meant to run. NEVER run it natively (mix phx.server / asdf / direnv) — the app runs
# in a container that already has the Elixir toolchain; the native path is a rabbit hole
# (compiling Erlang from source, .envrc/.envrc.private, PATH), which is what to avoid.
#
#   localdev.sh up        colima up -> docker compose up -d app -> build assets if needed ->
#                         ecto.migrate -> poll the URL until it serves. Idempotent.
#   localdev.sh status    is the app container up + is the URL serving? (one line)
#   localdev.sh logs      last app-container logs (the cause of a 5xx is named there)
#   localdev.sh restart   recreate the app container, then `up`.
#
# Config (company-agnostic — nothing hardcoded): local_dev_repo (default: regression_repo /
# default_repo), repo_subdirs[<repo>], web_app_url (the URL to poll), local_dev_service
# (default "app"), local_dev_assets_cmd (run in the container if the app crashes on a missing
# JS bundle), local_dev_migrate_cmd (default "mix ecto.migrate").
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$HOME/.margie/config.json"
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
cfg() { jq -r ".$1 // empty" "$CFG" 2>/dev/null; }
cfgd() { local v; v="$(cfg "$1")"; [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"; }
REPO_ARG="$(cfgd local_dev_repo "$(cfgd regression_repo "$(cfgd default_repo walt_ui)")")"
REPO="$("$DIR/resolve-repo.sh" "$REPO_ARG" 2>/dev/null)"; [ -z "$REPO" ] && { echo "Can't resolve repo '$REPO_ARG', dearie." >&2; exit 1; }
SUBDIR="$(jq -r --arg r "$(basename "$REPO")" '.repo_subdirs[$r] // empty' "$CFG" 2>/dev/null)"
BE="$REPO${SUBDIR:+/$SUBDIR}"
URL="$(cfgd web_app_url http://localhost:4000)"
SVC="$(cfgd local_dev_service app)"
ASSETS="$(cfgd local_dev_assets_cmd "")"
MIGRATE="$(cfgd local_dev_migrate_cmd "mix ecto.migrate")"
dc() { ( cd "$BE" && docker compose "$@" ); }
appname() { docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E "walt.?ui.*-${SVC}\$|-${SVC}\$" | grep -vE "\-(db|typesense)" | head -1; }
serving() { curl -s -o /dev/null -m 6 -w "%{http_code}" "$URL/" 2>/dev/null; }

ensure_colima() {
  colima status >/dev/null 2>&1 && return 0
  echo "colima is down — starting it (VM boot ~30s)…"; colima start >/dev/null 2>&1
}
ensure_override() {
  # the port-publishing override is gitignored/local; without it nothing maps to the host.
  [ -f "$BE/docker-compose.override.yml" ] && return 0
  echo "no docker-compose.override.yml (publishes host ports) — writing a minimal one…"
  cat > "$BE/docker-compose.override.yml" <<YAML
services:
  ${SVC}:
    ports:
      - "4000:4000"
  typesense:
    ports:
      - "8108:8108"
YAML
}

case "${1:-up}" in
  status)
    a="$(appname)"; st="$(docker ps --format '{{.Status}}' --filter "name=$a" 2>/dev/null | head -1)"
    echo "app container: ${a:-none} ${st:-(not running)} | $URL -> $(serving)" ;;

  logs) docker logs "$(appname)" --tail "${2:-40}" 2>&1 | tail -"${2:-40}" ;;

  restart) ensure_colima; ensure_override; dc up -d --force-recreate "$SVC" typesense >/dev/null 2>&1; exec "$0" up ;;

  up)
    ensure_colima
    ensure_override
    echo "starting $SVC + typesense (docker) in $BE…"
    dc up -d "$SVC" typesense >/dev/null 2>&1
    # if the app crashed on a missing JS bundle, build assets once (in the container) and retry
    if docker logs "$(appname)" --tail 20 2>&1 | grep -qi "bundle was never built\|BundleError"; then
      if [ -n "$ASSETS" ]; then
        echo "JS bundle missing — building assets in the container: $ASSETS"
        dc run --rm "$SVC" sh -lc "$ASSETS" >/dev/null 2>&1
        dc up -d "$SVC" >/dev/null 2>&1
      else
        echo "app needs its assets built but local_dev_assets_cmd is not set, dearie — set it in config."
      fi
    fi
    # apply any pending migrations (a pull usually adds some — the classic 503 cause)
    echo "running pending migrations…"
    dc exec -T "$SVC" sh -lc "$MIGRATE" >/dev/null 2>&1 || dc run --rm "$SVC" sh -lc "$MIGRATE" >/dev/null 2>&1
    # poll until it serves
    for i in $(seq 1 24); do
      c="$(serving)"
      if [ "$c" = 200 ] || [ "$c" = 302 ]; then echo "✓ $URL is up ($c), dearie."; exit 0; fi
      sleep 5
    done
    echo "still not serving ($URL -> $(serving)). The cause is in the app log:"
    docker logs "$(appname)" --tail 15 2>&1 | grep -iE "error|migration|BundleError|pending|exit|Endpoint" | tail -8
    echo "(full log: localdev.sh logs)"
    exit 1 ;;

  *) echo "usage: localdev.sh up|status|logs|restart" >&2; exit 1 ;;
esac
