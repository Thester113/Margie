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
[ -z "$TOKEN" ] && { echo "Notion isn't configured yet, sir — add notion_token to ~/.margie/config.json." >&2; exit 1; }
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

cmd="${1:-recent}"; shift || true

case "$cmd" in
  whoami)
    R="$(api GET /users/me)"; fail_if_error "$R"
    printf '%s' "$R" | jq -r '"\(.name) (integration) in workspace \(.bot.workspace_name // "?")"' ;;
  search)
    q="$*"; [ -z "$q" ] && { echo "usage: notion.sh search \"<query>\"" >&2; exit 1; }
    R="$(api POST /search "$(jq -n --arg q "$q" '{query:$q, page_size:15}')")"; fail_if_error "$R"
    OUT="$(printf '%s' "$R" | jq -r ".results[]? | \"\(.object): \($TITLE_JQ)  [\(.id | gsub(\"-\";\"\"))]\"")"
    [ -n "$OUT" ] && echo "$OUT" || echo "No Notion pages match '$q', sir — has that page been connected to the Margie integration?" ;;
  recent)
    R="$(api POST /search "$(jq -n --argjson n "${1:-10}" '{page_size:$n, sort:{direction:"descending", timestamp:"last_edited_time"}}')")"; fail_if_error "$R"
    OUT="$(printf '%s' "$R" | jq -r ".results[]? | \"\(.object): \($TITLE_JQ)  (\(.last_edited_time[:10]))  [\(.id | gsub(\"-\";\"\"))]\"")"
    [ -n "$OUT" ] && echo "$OUT" || echo "The Margie integration can't see any pages yet, sir — connect a page to it (page → ··· → Connections → Margie)." ;;
  read)
    id="$(nid "${1:-}")"; [ -z "$id" ] && { echo "usage: notion.sh read <id|url> [n]" >&2; exit 1; }
    P="$(api GET "/pages/$id")"; fail_if_error "$P"
    echo "# $(printf '%s' "$P" | jq -r "$TITLE_JQ")"
    B="$(api GET "/blocks/$id/children?page_size=${2:-40}")"; fail_if_error "$B"
    printf '%s' "$B" | text_of_blocks ;;
  dbs)
    R="$(api POST /search '{"filter":{"property":"object","value":"database"},"page_size":30}')"; fail_if_error "$R"
    OUT="$(printf '%s' "$R" | jq -r ".results[]? | \"\($TITLE_JQ)  [\(.id | gsub(\"-\";\"\"))]\"")"
    [ -n "$OUT" ] && echo "$OUT" || echo "No databases visible to the Margie integration, sir." ;;
  query)
    id="$(nid "${1:-}")"; [ -z "$id" ] && { echo "usage: notion.sh query <db id|url> [\"<text>\"]" >&2; exit 1; }; shift || true
    R="$(api POST "/databases/$id/query" '{"page_size":50}')"; fail_if_error "$R"
    OUT="$(printf '%s' "$R" | jq -r ".results[]? | \"\($TITLE_JQ)  (\(.last_edited_time[:10]))  [\(.id | gsub(\"-\";\"\"))]\"")"
    [ -n "$*" ] && OUT="$(printf '%s\n' "$OUT" | grep -i -- "$*")"
    [ -n "$OUT" ] && echo "$OUT" || echo "No rows${*:+ matching '$*'}, sir." ;;
  create)
    PARENT=""; ARGS=()
    while [ $# -gt 0 ]; do case "$1" in --parent) PARENT="${2:-}"; shift 2 ;; *) ARGS+=("$1"); shift ;; esac; done
    spec="${ARGS[*]:-}"; title="${spec%%:*}"; body="${spec#*:}"; [ "$title" = "$spec" ] && body=""
    title="$(printf '%s' "$title" | sed 's/^ *//;s/ *$//')"; body="$(printf '%s' "$body" | sed 's/^ *//')"
    [ -z "$title" ] && { echo "usage: notion.sh create \"<title>: <body>\" [--parent <id|url>]" >&2; exit 1; }
    pid="$(nid "${PARENT:-$PARENT_DEFAULT}")"
    [ -z "$pid" ] && { echo "No parent page, sir — pass --parent <id|url> or set notion_parent_page in config (and connect that page to the Margie integration)." >&2; exit 1; }
    children="$(printf '%s' "$body" | paragraphs_json)"
    R="$(api POST /pages "$(jq -n --arg p "$pid" --arg t "$title" --argjson c "$children" \
      '{parent:{page_id:$p}, properties:{title:{title:[{type:"text", text:{content:$t}}]}}, children:$c}')")"; fail_if_error "$R"
    echo "Created Notion page \"$title\": $(printf '%s' "$R" | jq -r .url)" ;;
  append)
    id="$(nid "${1:-}")"; shift || true; text="$*"
    [ -z "$id" ] || [ -z "$text" ] && { echo "usage: notion.sh append <id|url> \"<text>\"" >&2; exit 1; }
    children="$(printf '%s' "$text" | paragraphs_json)"
    R="$(api PATCH "/blocks/$id/children" "$(jq -n --argjson c "$children" '{children:$c}')")"; fail_if_error "$R"
    echo "Appended to the page, sir." ;;
  *) echo "usage: notion.sh whoami | search \"<q>\" | recent [n] | read <id|url> | dbs | query <db> [\"<text>\"] | create \"<title>: <body>\" [--parent <id>] | append <id|url> \"<text>\"" >&2; exit 1 ;;
esac
