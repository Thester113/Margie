#!/bin/bash
# prodread.sh — read-only answers from the production app's database, so Margie reports
# what a run actually did instead of inferring it from a ticket's status (2026-09-25: she
# said "no lists were created" while list #23 held 9,616 contacts).
#
#   prodread.sh list                      the named queries this install knows
#   prodread.sh <query> [arg]             run one (arg fills $1 when the query takes one)
#
# Company-agnostic: where production lives and what the queries are both come from
# ~/.margie/config.json:
#   "prod_read": { "gcloud_project": "…", "zone": "…", "instance_filter": "name~app AND -name~gke",
#                  "container_cmd": "bin/app rpc" },
#   "prod_queries": { "runs": {"sql": "select … where ($1 = '' or tenant_id = $1) …", "about": "…"} }
# Guard: only a single SELECT/WITH statement, run inside a READ ONLY transaction, output
# capped. Never writes.
set -uo pipefail
CFG="$HOME/.margie/config.json"
cfgj() { jq -r "$1 // empty" "$CFG" 2>/dev/null; }

cmd="${1:-list}"
if [ "$cmd" = list ]; then
  jq -r '.prod_queries // {} | to_entries[] | "\(.key)\t\(.value.about // "")"' "$CFG"; exit 0
fi
SQL="$(cfgj ".prod_queries[\"$cmd\"].sql")"
[ -n "$SQL" ] || { echo "No such query '$cmd'. Try: prodread.sh list" >&2; exit 64; }
ARG="${2:-}"
# One read statement only.
if ! printf '%s' "$SQL" | tr 'A-Z' 'a-z' | grep -qE '^[[:space:]]*(select|with)[[:space:]]' \
   || printf '%s' "$SQL" | grep -q ';'; then
  echo "Refusing: query '$cmd' is not a single SELECT." >&2; exit 65
fi
printf '%s' "$ARG" | grep -qE "^[A-Za-z0-9_.:@+-]{0,80}$" || { echo "Refusing: argument has characters a query id never needs." >&2; exit 65; }

PROJ="$(cfgj '.prod_read.gcloud_project')"; ZONE="$(cfgj '.prod_read.zone')"
FILT="$(cfgj '.prod_read.instance_filter')"; RPC="$(cfgj '.prod_read.container_cmd')"
[ -n "$PROJ" ] && [ -n "$ZONE" ] && [ -n "$FILT" ] && [ -n "$RPC" ] || { echo "prod_read is not configured in $CFG." >&2; exit 66; }
I="$(gcloud compute instances list --project "$PROJ" --filter="$FILT" --sort-by=~creationTimestamp --format='value(name)' 2>/dev/null | head -1)"
[ -n "$I" ] || { echo "Couldn't find the production instance (gcloud login expired?)." >&2; exit 69; }

# The Elixir runs the SQL in a read-only transaction and prints one tab-separated row per line.
SQLB64="$(printf '%s' "$SQL" | base64 | tr -d '\n')"
EX="{:ok, r} = Repo.transaction(fn -> Repo.query!(\"SET TRANSACTION READ ONLY\"); Repo.query!(Base.decode64!(\"$SQLB64\"), [\"$ARG\"] |> Enum.take(if String.contains?(Base.decode64!(\"$SQLB64\"), \"\$1\"), do: 1, else: 0)) end); IO.puts(Enum.join(r.columns, \"\\t\")); Enum.each(Enum.take(r.rows, 50), fn row -> IO.puts(Enum.map_join(row, \"\\t\", &to_string/1)) end)"
gcloud compute ssh "$I" --zone="$ZONE" --tunnel-through-iap --project "$PROJ" \
  --command="sudo docker exec \$(sudo docker ps -q) $RPC '$EX'" 2>/dev/null
