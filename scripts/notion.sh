#!/bin/bash
# notion.sh — Notion for Margie via the REST API (direct integration token).
#
# Config in ~/.margie/config.json:
#   notion_token         ntn_… (internal integration; name it "Margie"). Pages are
#                        invisible until connected: page → ··· → Connections → Margie.
#   notion_parent_page   (optional) page id/url new pages go under when no --parent given
#
# Usage:
#   notion.sh whoami                           the integration + workspace
#   notion.sh search "<query>"                 pages/databases matching (title + id)
#   notion.sh recent [n]                       last-edited pages the integration can see
#   notion.sh read <id|url> [n]                a page's title + first n text blocks (default 40)
#   notion.sh dbs                              databases the integration can see
#   notion.sh query <db id|url> ["<text>"]     rows of a database (optionally title-filtered)
#   notion.sh create "<title>: <body>" [--parent <id|url>]   new page (body = paragraphs)
#   notion.sh append <id|url> "<text>"         add a paragraph to a page
# Writes (create/append) are held for Tom's confirmation by the brain.
set -uo pipefail

CFG="$HOME/.margie/config.json"
cfg() { jq -r ".$1 // empty" "$CFG" 2>/dev/null; }
TOKEN="${NOTION_TOKEN:-$(cfg notion_token)}"
[ -z "$TOKEN" ] && { echo "Notion isn't configured yet, dearie — add notion_token to ~/.margie/config.json." >&2; exit 1; }
PARENT_DEFAULT="$(cfg notion_parent_page)"
API="https://api.notion.com/v1"

api() { # api <METHOD> <path> [json]
  local m="$1" p="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sS -X "$m" -H "Authorization: Bearer $TOKEN" -H "Notion-Version: 2022-06-28" -H "Content-Type: application/json" --data "$body" "$API$p"
  else
    curl -sS -X "$m" -H "Authorization: Bearer $TOKEN" -H "Notion-Version: 2022-06-28" "$API$p"
  fi
}
# Accept a raw id, a dashed uuid, or a Notion URL; return the 32-hex id.
nid() { printf '%s' "$1" | grep -oE '[0-9a-fA-F]{32}|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' | tail -1 | tr -d '-'; }
fail_if_error() { # fail_if_error <json>
  if printf '%s' "$1" | jq -e '.object == "error"' >/dev/null 2>&1; then
    echo "Notion says: $(printf '%s' "$1" | jq -r '.message')" >&2; exit 1
  fi
}
# title of a page/database object
TITLE_JQ='(.title[0]?.plain_text // (.properties | to_entries | map(select(.value.type=="title")) | .[0].value.title[0]?.plain_text) // "(untitled)")'
# plain text of rich_text blocks
text_of_blocks() { jq -r '.results[]? | select(.type != "child_page" and .type != "child_database") | .[.type].rich_text? // [] | map(.plain_text) | join("")' | grep -v '^$'; }
paragraphs_json() { # stdin: body text → children array of paragraph blocks
  jq -Rs 'split("\n") | map(select(length>0)) | map({object:"block", type:"paragraph", paragraph:{rich_text:[{type:"text", text:{content:.}}]}})'
}


LIBDIR="$(cd "$(dirname "$0")" && pwd)"

# ── Data-source layer (Notion-Version 2025-09-03) ────────────────────────────
# The DB-aware subcommands below (schema/find/ticket/testcase/page) talk to
# data sources — same API walt_ui's agent-messages hook uses. Legacy
# search/recent/read/dbs/query/create/append stay on 2022-06-28 above.
api2() { # api2 <METHOD> <path> [json-body]
  local m="$1" p="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sS --max-time 15 -X "$m" -H "Authorization: Bearer $TOKEN" -H "Notion-Version: 2025-09-03" -H "Content-Type: application/json" --data "$body" "$API$p"
  else
    curl -sS --max-time 15 -X "$m" -H "Authorization: Bearer $TOKEN" -H "Notion-Version: 2025-09-03" "$API$p"
  fi
}
# Alias -> data source id from config; raw ids / collection:// URLs pass through.
ds_of() {
  local a="$1" v=""
  case "$a" in
    tickets) v="$(cfg notion_tickets_ds)" ;;
    epics) v="$(cfg notion_epics_ds)" ;;
    testcases) v="$(cfg notion_testcases_ds)" ;;
    usecases) v="$(cfg notion_usecases_ds)" ;;
    requirements) v="$(cfg notion_requirements_ds)" ;;
    agent_messages|messages) v="$(cfg agent_messages_ds)" ;;
    *) v="$a" ;;
  esac
  [ -z "$v" ] && { echo "No data source configured for '$a', dearie — add notion_${a}_ds to ~/.margie/config.json." >&2; return 1; }
  printf '%s' "$v" | sed 's|^collection://||'
}
# Confirm-gate dry description: print one line and exit without touching Notion.
desc() { if [ "${MARGIE_DESCRIBE:-0}" = "1" ]; then echo "$*"; exit 0; fi; }
md_blocks() { jq -Rs -f "$LIBDIR/lib/md2blocks.jq" < "${1:-/dev/null}"; }
append_blocks() { # append_blocks <block/page id> <children-json-array>
  local id="$1" ch="$2" n i R
  n="$(printf '%s' "$ch" | jq 'length')"
  i=0
  while [ "$i" -lt "$n" ]; do
    R="$(api2 PATCH "/blocks/$id/children" "$(printf '%s' "$ch" | jq -c --argjson i "$i" '{children: .[$i:$i+100]}')")"
    fail_if_error "$R"
    i=$((i + 100))
  done
}
# Resolve "PT-296" / "296" (ticket unique id) or a page id/url -> "id<TAB>url<TAB>PT-n"
pt_page() {
  local x="$1" num ds R
  if printf '%s' "$x" | grep -qE '^[A-Za-z]+-[0-9]+$|^[0-9]+$'; then
    num="${x##*-}"
    ds="$(ds_of tickets)" || return 1
    R="$(api2 POST "/data_sources/$ds/query" "$(jq -n --argjson n "$num" '{filter:{property:"ID", unique_id:{equals:$n}}, page_size:1}')")"
    fail_if_error "$R"
    printf '%s' "$R" | jq -re '.results[0] | [.id, .url, ((.properties.ID.unique_id.prefix // "") + "-" + (.properties.ID.unique_id.number|tostring))] | @tsv' \
      || { echo "Couldn't find ticket $x, dearie." >&2; return 1; }
  else
    local id; id="$(nid "$x")"
    [ -z "$id" ] && { echo "Not a ticket id: $x" >&2; return 1; }
    R="$(api GET "/pages/$id")"
    fail_if_error "$R"
    printf '%s' "$R" | jq -re '[.id, .url, ((.properties.ID.unique_id.prefix // "T") + "-" + ((.properties.ID.unique_id.number // 0)|tostring))] | @tsv'
  fi
}
now_iso() { date -u +%FT%TZ; }

cmd="${1:-recent}"; shift || true

case "$cmd" in
  whoami)
    R="$(api GET /users/me)"; fail_if_error "$R"
    printf '%s' "$R" | jq -r '"\(.name) (integration) in workspace \(.bot.workspace_name // "?")"' ;;
  search)
    q="$*"; [ -z "$q" ] && { echo "usage: notion.sh search \"<query>\"" >&2; exit 1; }
    R="$(api POST /search "$(jq -n --arg q "$q" '{query:$q, page_size:15}')")"; fail_if_error "$R"
    OUT="$(printf '%s' "$R" | jq -r ".results[]? | \"\(.object): \($TITLE_JQ)  [\(.id | gsub(\"-\";\"\"))]\"")"
    [ -n "$OUT" ] && echo "$OUT" || echo "No Notion pages match '$q', dearie — has that page been connected to the Margie integration?" ;;
  recent)
    R="$(api POST /search "$(jq -n --argjson n "${1:-10}" '{page_size:$n, sort:{direction:"descending", timestamp:"last_edited_time"}}')")"; fail_if_error "$R"
    OUT="$(printf '%s' "$R" | jq -r ".results[]? | \"\(.object): \($TITLE_JQ)  (\(.last_edited_time[:10]))  [\(.id | gsub(\"-\";\"\"))]\"")"
    [ -n "$OUT" ] && echo "$OUT" || echo "The Margie integration can't see any pages yet, dearie — connect a page to it (page → ··· → Connections → Margie)." ;;
  read)
    id="$(nid "${1:-}")"; [ -z "$id" ] && { echo "usage: notion.sh read <id|url> [n]" >&2; exit 1; }
    P="$(api GET "/pages/$id")"; fail_if_error "$P"
    echo "# $(printf '%s' "$P" | jq -r "$TITLE_JQ")"
    B="$(api GET "/blocks/$id/children?page_size=${2:-40}")"; fail_if_error "$B"
    printf '%s' "$B" | text_of_blocks ;;
  dbs)
    R="$(api POST /search '{"filter":{"property":"object","value":"database"},"page_size":30}')"; fail_if_error "$R"
    OUT="$(printf '%s' "$R" | jq -r ".results[]? | \"\($TITLE_JQ)  [\(.id | gsub(\"-\";\"\"))]\"")"
    [ -n "$OUT" ] && echo "$OUT" || echo "No databases visible to the Margie integration, dearie." ;;
  query)
    case "$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')" in tickets|testcases|usecases|requirements|epics|"test cases"|"use cases")
      A="$(printf '%s' "$1" | tr 'A-Z ' 'a-z' | tr -d ' ')"; shift || true
      "$0" rows "$A" 100 | { if [ -n "$*" ]; then grep -i -- "$*"; else cat; fi; }; exit 0 ;;
    esac
    id="$(nid "${1:-}")"; [ -z "$id" ] && { echo "usage: notion.sh query <db id|url|tickets|testcases|usecases|requirements|epics> [\"<text>\"]" >&2; exit 1; }; shift || true
    R="$(api POST "/databases/$id/query" '{"page_size":50}')"; fail_if_error "$R"
    OUT="$(printf '%s' "$R" | jq -r ".results[]? | \"\($TITLE_JQ)  (\(.last_edited_time[:10]))  [\(.id | gsub(\"-\";\"\"))]\"")"
    [ -n "$*" ] && OUT="$(printf '%s\n' "$OUT" | grep -i -- "$*")"
    [ -n "$OUT" ] && echo "$OUT" || echo "No rows${*:+ matching '$*'}, dearie." ;;
  create)
    PARENT=""; ARGS=()
    while [ $# -gt 0 ]; do case "$1" in --parent) PARENT="${2:-}"; shift 2 ;; *) ARGS+=("$1"); shift ;; esac; done
    spec="${ARGS[*]:-}"; title="${spec%%:*}"; body="${spec#*:}"; [ "$title" = "$spec" ] && body=""
    title="$(printf '%s' "$title" | sed 's/^ *//;s/ *$//')"; body="$(printf '%s' "$body" | sed 's/^ *//')"
    [ -z "$title" ] && { echo "usage: notion.sh create \"<title>: <body>\" [--parent <id|url>]" >&2; exit 1; }
    desc "would create a Notion page \"$title\" under ${PARENT:-the default parent page}"
    pid="$(nid "${PARENT:-$PARENT_DEFAULT}")"
    [ -z "$pid" ] && { echo "No parent page, dearie — pass --parent <id|url> or set notion_parent_page in config (and connect that page to the Margie integration)." >&2; exit 1; }
    children="$(printf '%s' "$body" | paragraphs_json)"
    R="$(api POST /pages "$(jq -n --arg p "$pid" --arg t "$title" --argjson c "$children" \
      '{parent:{page_id:$p}, properties:{title:{title:[{type:"text", text:{content:$t}}]}}, children:$c}')")"; fail_if_error "$R"
    echo "Created Notion page \"$title\": $(printf '%s' "$R" | jq -r .url)" ;;
  append)
    id="$(nid "${1:-}")"; shift || true; text="$*"
    [ -z "$id" ] || [ -z "$text" ] && { echo "usage: notion.sh append <id|url> \"<text>\"" >&2; exit 1; }
    desc "would append a paragraph to Notion page $(printf '%.24s' "$1")…"
    children="$(printf '%s' "$text" | paragraphs_json)"
    R="$(api PATCH "/blocks/$id/children" "$(jq -n --argjson c "$children" '{children:$c}')")"; fail_if_error "$R"
    echo "Appended to the page, dearie." ;;
  rows)
    # rows <alias|ds|db> [n] — compact row list (title + status/date) for planner context.
    # Aliases resolve to a data source; decisions|questions resolve their DB's first source.
    a="${1:-tickets}"; n="${2:-30}"
    case "$a" in
      decisions) DB="$(cfg notion_decisions_db)" ;;
      questions|open_questions) DB="$(cfg notion_open_questions_db)" ;;
      *) DB="" ;;
    esac
    if [ -n "$DB" ]; then
      R="$(api2 GET "/databases/$DB")"; fail_if_error "$R"
      ds="$(printf '%s' "$R" | jq -r '.data_sources[0].id // empty')"
      [ -z "$ds" ] && { echo "No data source on database $DB, dearie." >&2; exit 1; }
    else
      ds="$(ds_of "$a")" || exit 1
    fi
    R="$(api2 POST "/data_sources/$ds/query" "$(jq -n --argjson n "$n" '{page_size:$n, sorts:[{timestamp:"last_edited_time", direction:"descending"}]}')")"
    fail_if_error "$R"
    printf '%s' "$R" | jq -r '.results[]? |
      ((.properties | to_entries | map(select(.value.type=="title")) | .[0].value.title[0].plain_text) // "(untitled)")
      + (if .properties.ID.unique_id then "  [" + (.properties.ID.unique_id.prefix // "") + "-" + (.properties.ID.unique_id.number|tostring) + "]" else "" end)
      + (if .properties.Status.status then "  (" + .properties.Status.status.name + ")"
         elif .properties.Status.select then "  (" + .properties.Status.select.name + ")"
         elif .properties.Maturity.select then "  (" + .properties.Maturity.select.name + ")"
         elif .properties.Ref then "  ref " + ((.properties.Ref.rich_text // [{plain_text:"?"}])[0].plain_text) else "" end)' ;;
  schema)
    ds="$(ds_of "${1:-tickets}")" || exit 1
    R="$(api2 GET "/data_sources/$ds")"; fail_if_error "$R"
    printf '%s' "$R" | jq -r '(.schema // .properties) | to_entries[] |
      [.key, .value.type,
       ((.value.select.options // .value.multi_select.options // .value.status.options //
         (.value | to_entries | map(select(.value|type=="object")) | map(.value.options // empty) | add) // [])
        | map(.name) | join("|")),
       (.value.unique_id.prefix // "")]
      | map(select(. != "")) | join("  ")' ;;
  find)
    [ -z "${1:-}" ] && { echo "usage: notion.sh find <PT-###>" >&2; exit 1; }
    IFS="$(printf '\t')" read -r pid purl ppt <<EOF2
$(pt_page "$1")
EOF2
    [ -z "$pid" ] && exit 1
    echo "$ppt  $purl  [$(printf '%s' "$pid" | tr -d '-')]" ;;
  epic)
    # epic create "<title>" [--md f] [--status S] [--tickets PT,PT] | status <id> <S> | relate <id> --tickets PT,PT
    sub="${1:-}"; shift || true
    ds="$(ds_of epics)" || exit 1
    ticket_ids() { local out="[]" b bid; for b in $(printf '%s' "$1" | tr ',' ' '); do bid="$(pt_page "$b" | cut -f1)"; [ -n "$bid" ] && out="$(printf '%s' "$out" | jq -c --arg i "$bid" '. + [{id:$i}]')"; done; printf '%s' "$out"; }
    case "$sub" in
      create)
        TITLE=""; MD=""; STATUS=""; TICKETS=""
        while [ $# -gt 0 ]; do case "$1" in --md) MD="${2:-}"; shift 2 ;; --status) STATUS="${2:-}"; shift 2 ;; --tickets) TICKETS="${2:-}"; shift 2 ;; *) [ -z "$TITLE" ] && TITLE="$1" || TITLE="$TITLE $1"; shift ;; esac; done
        [ -z "$TITLE" ] && { echo "usage: notion.sh epic create \"<title>\" [--md f] [--status S] [--tickets PT,PT]" >&2; exit 1; }
        desc "would create Epic \"$TITLE\" (status ${STATUS:-default}) linking tickets ${TICKETS:-none}"
        PROPS="$(jq -n --arg t "$TITLE" --arg st "$STATUS" --argjson tk "$(ticket_ids "$TICKETS")" '{Name:{title:[{type:"text",text:{content:$t}}]}} + (if $st != "" then {Status:{select:{name:$st}}} else {} end) + (if ($tk|length) > 0 then {Tickets:{relation:$tk}} else {} end)')"
        CH="$(md_blocks "$MD")"
        R="$(api2 POST /pages "$(jq -n --arg ds "$ds" --argjson p "$PROPS" --argjson c "$CH" '{parent:{type:"data_source_id", data_source_id:$ds}, properties:$p, children: $c[0:100]}')")"; fail_if_error "$R"
        echo "Created Epic \"$TITLE\": $(printf '%s' "$R" | jq -r .url)"
        jq -cn --arg id "$(printf '%s' "$R" | jq -r .id)" --arg url "$(printf '%s' "$R" | jq -r .url)" '{id:$id, url:$url}' ;;
      status)
        [ -z "${1:-}" ] || [ -z "${2:-}" ] && { echo "usage: notion.sh epic status <id> <Status>" >&2; exit 1; }
        desc "would set Epic $(printf '%.24s' "$1")… to \"$2\""
        R="$(api2 PATCH "/pages/$(nid "$1")" "$(jq -nc --arg s "$2" '{properties:{Status:{select:{name:$s}}}}')")"; fail_if_error "$R"; echo "Epic is now $2, dearie." ;;
      relate)
        E="${1:-}"; shift || true; TICKETS=""; while [ $# -gt 0 ]; do case "$1" in --tickets) TICKETS="${2:-}"; shift 2 ;; *) shift ;; esac; done
        { [ -z "$E" ] || [ -z "$TICKETS" ]; } && { echo "usage: notion.sh epic relate <id> --tickets PT,PT" >&2; exit 1; }
        desc "would link tickets $TICKETS to Epic $(printf '%.24s' "$E")…"
        R="$(api2 PATCH "/pages/$(nid "$E")" "$(jq -nc --argjson tk "$(ticket_ids "$TICKETS")" '{properties:{Tickets:{relation:$tk}}}')")"; fail_if_error "$R"; echo "Linked $TICKETS to the Epic, dearie." ;;
      *) echo "usage: notion.sh epic create \"<title>\" [--md f] [--status S] [--tickets PT,PT] | status <id> <S> | relate <id> --tickets PT,PT" >&2; exit 1 ;;
    esac ;;
  ticket)
    sub="${1:-read}"; shift || true
    case "$sub" in
      read)
        IFS="$(printf '\t')" read -r pid purl ppt <<EOF2
$(pt_page "${1:-}")
EOF2
        [ -z "$pid" ] && exit 1
        P="$(api GET "/pages/$pid")"; fail_if_error "$P"
        printf '%s' "$P" | jq -r '"\(.properties.ID.unique_id.prefix // "")-\(.properties.ID.unique_id.number // "?") \(.properties.Title.title[0].plain_text // "(untitled)") — \(.properties.Status.status.name // "?"), \(.properties.Priority.select.name // "no priority"), labels: \((.properties.Labels.multi_select // []) | map(.name) | join(",") | if . == "" then "none" else . end)\n\(.url)"'
        B="$(api GET "/blocks/$pid/children?page_size=${2:-60}")"; fail_if_error "$B"
        printf '%s' "$B" | text_of_blocks ;;
      create)
        TITLE=""; MD=""; DESCR=""; STATUS=""; PRIO=""; LABELS=""; USECASE=""; ASSIGNEE=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --md) MD="${2:-}"; shift 2 ;;
            --description) DESCR="${2:-}"; shift 2 ;;
            --status) STATUS="${2:-}"; shift 2 ;;
            --priority) PRIO="${2:-}"; shift 2 ;;
            --labels) LABELS="${2:-}"; shift 2 ;;
            --usecase) USECASE="${2:-}"; shift 2 ;;
            --assignee) ASSIGNEE="${2:-}"; shift 2 ;;
            --epic) EPIC="${2:-}"; shift 2 ;;
            *) [ -z "$TITLE" ] && TITLE="$1" || TITLE="$TITLE $1"; shift ;;
          esac
        done
        [ -z "$TITLE" ] && { echo "usage: notion.sh ticket create \"<title>\" --md <file> [--status|--priority|--labels|--usecase|--assignee|--description]" >&2; exit 1; }
        ds="$(ds_of tickets)" || exit 1
        desc "would create a ticket \"$TITLE\" (status ${STATUS:-default}, labels ${LABELS:-default}) with the spec body from ${MD:-<none>} in the Tickets database"
        DEFS="$(jq -c '.notion_ticket_defaults // {}' "$CFG" 2>/dev/null || echo '{}')"
        [ -z "$ASSIGNEE" ] && ASSIGNEE="$(cfg notion_assignee)"
        PROPS="$(jq -n --arg t "$TITLE" --argjson defs "$DEFS" --arg descr "$DESCR" --arg status "$STATUS" \
                       --arg prio "$PRIO" --arg labels "$LABELS" --arg usecase "$(nid "${USECASE:-}" || true)" --arg assignee "$ASSIGNEE" --arg epic "$(nid "${EPIC:-}" || true)" '
          def opt(f): if . == "" then empty else f end;
          {Title: {title: [{type:"text", text:{content:$t}}]}}
          + (($status  | opt({name:.}) ) // ($defs.Status  // "" | opt({name:.})) | if . then {Status:{status:.}} else {} end)
          + (($prio    | opt({name:.}) ) // ($defs.Priority // "" | opt({name:.})) | if . then {Priority:{select:.}} else {} end)
          + (($defs.Team // "" | opt({name:.})) | if . then {Team:{select:.}} else {} end)
          + ((if $labels != "" then ($labels | split(",")) else ($defs.Labels // []) end)
             | if length > 0 then {Labels:{multi_select: map({name:.})}} else {} end)
          + ($descr | opt({Description:{rich_text:[{type:"text",text:{content:.}}]}}) // {})
          + ($usecase | opt({"Use Cases":{relation:[{id:.}]}}) // {})
          + ($assignee | opt({Assignee:{people:[{id:.}]}}) // {})
          + ($epic | opt({Epic:{relation:[{id:.}]}}) // {})')"
        CH="$(md_blocks "$MD")"
        R="$(api2 POST /pages "$(jq -n --arg ds "$ds" --argjson p "$PROPS" --argjson c "$CH" \
              '{parent:{type:"data_source_id", data_source_id:$ds}, properties:$p, children: $c[0:100]}')")"
        fail_if_error "$R"
        PID="$(printf '%s' "$R" | jq -r .id)"; PURL="$(printf '%s' "$R" | jq -r .url)"
        PT="$(printf '%s' "$R" | jq -r '(.properties.ID.unique_id.prefix // "T") + "-" + ((.properties.ID.unique_id.number // 0)|tostring)')"
        REST="$(printf '%s' "$CH" | jq -c '.[100:]')"
        [ "$(printf '%s' "$REST" | jq 'length')" -gt 0 ] && append_blocks "$PID" "$REST"
        echo "Created $PT \"$TITLE\": $PURL"
        jq -cn --arg pt "$PT" --arg id "$PID" --arg url "$PURL" '{pt:$pt, id:$id, url:$url}' ;;
      relate)
        # ticket relate <PT> --blocked-by <PT[,PT…]>   sets the Blocked By relation
        T="${1:-}"; shift || true; BB=""
        while [ $# -gt 0 ]; do case "$1" in --blocked-by) BB="${2:-}"; shift 2 ;; *) shift ;; esac; done
        { [ -z "$T" ] || [ -z "$BB" ]; } && { echo "usage: notion.sh ticket relate <PT> --blocked-by <PT[,PT]>" >&2; exit 1; }
        desc "would mark ticket $T as blocked by $BB"
        IFS="$(printf '\t')" read -r pid purl ppt <<EOF2
$(pt_page "$T")
EOF2
        [ -z "$pid" ] && { echo "Couldn't find $T, dearie." >&2; exit 1; }
        IDS="[]"; for b in $(printf '%s' "$BB" | tr ',' ' '); do
          bid="$(pt_page "$b" | cut -f1)"; [ -n "$bid" ] && IDS="$(printf '%s' "$IDS" | jq -c --arg i "$bid" '. + [{id:$i}]')"
        done
        R="$(api2 PATCH "/pages/$pid" "$(jq -nc --argjson r "$IDS" '{properties:{"Blocked By":{relation:$r}}}')")"; fail_if_error "$R"
        echo "$T is now blocked by $BB, dearie." ;;
      status)
        [ -z "${1:-}" ] || [ -z "${2:-}" ] && { echo "usage: notion.sh ticket status <PT> \"<Status>\"" >&2; exit 1; }
        desc "would set ticket $1 to status \"$2\""
        IFS="$(printf '\t')" read -r pid purl ppt <<EOF2
$(pt_page "$1")
EOF2
        [ -z "$pid" ] && exit 1
        EXTRA='{}'
        case "$2" in
          "In Progress") EXTRA="$(jq -cn --arg d "$(now_iso)" '{"Started At":{date:{start:$d}}}')" ;;
          Done)          EXTRA="$(jq -cn --arg d "$(now_iso)" '{"Completed At":{date:{start:$d}}}')" ;;
          Canceled)      EXTRA="$(jq -cn --arg d "$(now_iso)" '{"Canceled At":{date:{start:$d}}}')" ;;
        esac
        R="$(api2 PATCH "/pages/$pid" "$(jq -cn --arg st "$2" --argjson x "$EXTRA" '{properties: ({Status:{status:{name:$st}}} + $x)}')")"
        fail_if_error "$R"
        echo "$ppt is now $2, dearie." ;;
      append)
        MD=""; TARGET=""
        while [ $# -gt 0 ]; do case "$1" in --md) MD="${2:-}"; shift 2 ;; *) TARGET="$1"; shift ;; esac; done
        [ -z "$TARGET" ] || [ -z "$MD" ] && { echo "usage: notion.sh ticket append <PT> --md <file>" >&2; exit 1; }
        desc "would append $(wc -l < "$MD" | tr -d ' ') lines of notes to ticket $TARGET"
        IFS="$(printf '\t')" read -r pid purl ppt <<EOF2
$(pt_page "$TARGET")
EOF2
        [ -z "$pid" ] && exit 1
        append_blocks "$pid" "$(md_blocks "$MD")"
        echo "Appended to $ppt, dearie." ;;
      comment)
        [ -z "${1:-}" ] || [ -z "${2:-}" ] && { echo "usage: notion.sh ticket comment <PT> \"<text>\"" >&2; exit 1; }
        desc "would comment on ticket $1: \"$2\""
        IFS="$(printf '\t')" read -r pid purl ppt <<EOF2
$(pt_page "$1")
EOF2
        [ -z "$pid" ] && exit 1
        R="$(api2 POST /comments "$(jq -cn --arg id "$pid" --arg t "$2" '{parent:{page_id:$id}, rich_text:[{type:"text",text:{content:$t}}]}')")"
        fail_if_error "$R"
        echo "Commented on $ppt, dearie." ;;
      *) echo "usage: notion.sh ticket read|create|status|append|comment ..." >&2; exit 1 ;;
    esac ;;
  testcase)
    sub="${1:-}"; shift || true
    case "$sub" in
      add)
        TARGET=""; JSONF=""
        while [ $# -gt 0 ]; do case "$1" in --json) JSONF="${2:-}"; shift 2 ;; *) TARGET="$1"; shift ;; esac; done
        [ -z "$TARGET" ] || [ -z "$JSONF" ] && { echo "usage: notion.sh testcase add <PT> --json <file>" >&2; exit 1; }
        N="$(jq 'length' "$JSONF")"
        desc "would add $N test cases to ticket $TARGET in the Test Cases database"
        ds="$(ds_of testcases)" || exit 1
        IFS="$(printf '\t')" read -r pid purl ppt <<EOF2
$(pt_page "$TARGET")
EOF2
        [ -z "$pid" ] && exit 1
        MAP='{}'
        i=0
        while [ "$i" -lt "$N" ]; do
          TC="$(jq -c --argjson i "$i" '.[$i]' "$JSONF")"
          R="$(api2 POST /pages "$(printf '%s' "$TC" | jq -c --arg ds "$ds" --arg tid "$pid" '
            def rtp(v): if (v // "") == "" then empty else {rich_text:[{type:"text",text:{content:(v|tostring)[0:1900]}}]} end;
            {parent:{type:"data_source_id", data_source_id:$ds},
             properties: ({"Test Case": {title:[{type:"text",text:{content:(.title // "untitled")}}]},
                           "Ticket": {relation:[{id:$tid}]},
                           "Status": {select:{name:"Planned"}}}
              + (if (.case_type // "") != "" then {"Case Type":{select:{name:.case_type}}} else {} end)
              + (if .cannot_run_async == true then {"Cannot run async":{checkbox:true}} else {} end)
              + (rtp(.setup)      | if . then {"Setup": .} else {} end)
              + (rtp(.exercise)   | if . then {"Exercise (Call Under Test)": .} else {} end)
              + (rtp(.assertions) | if . then {"Assertions": .} else {} end)
              + (rtp(.cleanup)    | if . then {"Cleanup": .} else {} end)
              + (rtp(.test_file)  | if . then {"Test File / Module": .} else {} end)
              + (rtp(.sabotage // .notes) | if . then {"Notes": .} else {} end))}')")"
          fail_if_error "$R"
          MAP="$(printf '%s' "$MAP" | jq -c --arg k "$(printf '%s' "$TC" | jq -r '.title // "untitled"')" --arg v "$(printf '%s' "$R" | jq -r .id)" '. + {($k): $v}')"
          i=$((i + 1))
        done
        echo "Added $N test cases to $ppt, dearie."
        printf '%s\n' "$MAP" ;;
      status)
        [ -z "${1:-}" ] || [ -z "${2:-}" ] && { echo "usage: notion.sh testcase status <id> <Planned|Written|Passing|Failing|Skipped> [--file <path>]" >&2; exit 1; }
        TCID="$(nid "$1")"; ST="$2"; FILEP="${4:-}"
        desc "would mark test case $1 as $ST"
        R="$(api2 PATCH "/pages/$TCID" "$(jq -cn --arg st "$ST" --arg f "$FILEP" \
          '{properties: ({Status:{select:{name:$st}}} + (if $f != "" then {"Test File / Module":{rich_text:[{type:"text",text:{content:$f}}]}} else {} end))}')")"
        fail_if_error "$R"
        echo "Test case marked $ST." ;;
      *) echo "usage: notion.sh testcase add <PT> --json <file> | status <id> <Status> [--file <path>]" >&2; exit 1 ;;
    esac ;;
  page)
    sub="${1:-}"; shift || true
    case "$sub" in
      create)
        TITLE=""; MD=""; PARENT=""
        while [ $# -gt 0 ]; do case "$1" in --md) MD="${2:-}"; shift 2 ;; --parent) PARENT="${2:-}"; shift 2 ;; *) [ -z "$TITLE" ] && TITLE="$1" || TITLE="$TITLE $1"; shift ;; esac; done
        [ -z "$TITLE" ] || [ -z "$PARENT" ] && { echo "usage: notion.sh page create \"<title>\" --md <file> --parent <id|url>" >&2; exit 1; }
        desc "would create a page \"$TITLE\" under $(printf '%.24s' "$PARENT")…"
        PARENT_ID="$(nid "$PARENT")"
        CH="$(md_blocks "$MD")"
        R="$(api2 POST /pages "$(jq -n --arg p "$PARENT_ID" --arg t "$TITLE" --argjson c "$CH" \
              '{parent:{page_id:$p}, properties:{title:{title:[{type:"text",text:{content:$t}}]}}, children: $c[0:100]}')")"
        fail_if_error "$R"
        PID="$(printf '%s' "$R" | jq -r .id)"
        REST="$(printf '%s' "$CH" | jq -c '.[100:]')"
        [ "$(printf '%s' "$REST" | jq 'length')" -gt 0 ] && append_blocks "$PID" "$REST"
        echo "Created page \"$TITLE\": $(printf '%s' "$R" | jq -r .url)" ;;
      append)
        TARGET="${1:-}"; MD=""
        shift || true
        while [ $# -gt 0 ]; do case "$1" in --md) MD="${2:-}"; shift 2 ;; *) shift ;; esac; done
        [ -z "$TARGET" ] || [ -z "$MD" ] && { echo "usage: notion.sh page append <id|url> --md <file>" >&2; exit 1; }
        desc "would append notes to page $(printf '%.24s' "$TARGET")…"
        append_blocks "$(nid "$TARGET")" "$(md_blocks "$MD")"
        echo "Appended, dearie." ;;
      archive)
        [ -z "${1:-}" ] && { echo "usage: notion.sh page archive <id|url>" >&2; exit 1; }
        desc "would archive Notion page $(printf '%.24s' "$1")…"
        R="$(api2 PATCH "/pages/$(nid "$1")" '{"archived": true}')"; fail_if_error "$R"
        echo "Archived, dearie." ;;
      replace)
        # Replace a page's body with fresh markdown (delete existing top-level blocks, append new).
        TARGET="${1:-}"; MD=""; shift || true
        while [ $# -gt 0 ]; do case "$1" in --md) MD="${2:-}"; shift 2 ;; *) shift ;; esac; done
        [ -z "$TARGET" ] || [ -z "$MD" ] && { echo "usage: notion.sh page replace <id|url> --md <file>" >&2; exit 1; }
        desc "would replace the body of Notion page $(printf '%.24s' "$TARGET")… with $MD"
        PID="$(nid "$TARGET")"
        for b in $(api2 GET "/blocks/$PID/children?page_size=100" | jq -r '.results[]?.id'); do api2 DELETE "/blocks/$b" >/dev/null 2>&1; done
        append_blocks "$PID" "$(md_blocks "$MD")"
        echo "Refreshed, dearie." ;;
      restore)
        [ -z "${1:-}" ] && { echo "usage: notion.sh page restore <id|url>" >&2; exit 1; }
        desc "would restore Notion page $(printf '%.24s' "$1")… from the trash"
        R="$(api2 PATCH "/pages/$(nid "$1")" '{"archived": false}')"; fail_if_error "$R"
        echo "Restored: $(printf '%s' "$R" | jq -r .url)" ;;
      rename)
        TARGET="${1:-}"; NEWT="${2:-}"
        { [ -z "$TARGET" ] || [ -z "$NEWT" ]; } && { echo "usage: notion.sh page rename <id|url> \"<new title>\"" >&2; exit 1; }
        desc "would rename Notion page $(printf '%.24s' "$TARGET")… to \"$NEWT\""
        R="$(api2 PATCH "/pages/$(nid "$TARGET")" "$(jq -n --arg t "$NEWT" '{properties:{title:{title:[{type:"text",text:{content:$t}}]}}}')")"; fail_if_error "$R"
        echo "Renamed to \"$NEWT\", dearie." ;;
      *) echo "usage: notion.sh page create \"<title>\" --md <file> --parent <id|url> | append <id|url> --md <file> | archive <id|url> | restore <id|url> | replace <id|url> --md <file> | rename <id|url> \"<title>\"" >&2; exit 1 ;;
    esac ;;
  *) echo "usage: notion.sh whoami | search \"<q>\" | recent [n] | read <id|url> | dbs | query <db> [\"<text>\"] | create \"<title>: <body>\" [--parent <id>] | append <id|url> \"<text>\"" >&2; exit 1 ;;
esac
