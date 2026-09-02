#!/bin/bash
# jira.sh — Jira via the Atlassian REST API directly (no Claude, no connector).
#
# Reads credentials from ~/.margie/config.json:
#   atlassian_email        e.g. you@example.com
#   atlassian_api_token    from id.atlassian.com/manage-profile/security/api-tokens
#   jira_base_url          e.g. https://yourorg.atlassian.net
#   jira_default_project   (optional) project key for `create`, e.g. PROJ
#
# Usage:
#   jira.sh read <KEY>
#   jira.sh mine
#   jira.sh search "<jql or free text>"
#   jira.sh create "<summary>"           (uses jira_default_project, type Task)
#   jira.sh create <PROJECT> "<summary>"
#   jira.sh comment <KEY> "<text>"
set -uo pipefail

CFG="$HOME/.margie/config.json"
cfg() { jq -r ".$1 // empty" "$CFG" 2>/dev/null; }
EMAIL="$(cfg atlassian_email)"
TOKEN="$(cfg atlassian_api_token)"
BASE="$(cfg jira_base_url)"
DEFPROJ="$(cfg jira_default_project)"
BASE="${BASE%/}"

if [ -z "$EMAIL" ] || [ -z "$TOKEN" ] || [ -z "$BASE" ]; then
  echo "Jira isn't configured yet, dear — add atlassian_email, atlassian_api_token and jira_base_url to ~/.margie/config.json." >&2
  exit 1
fi

api() { # api <METHOD> <path> [json-body]
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sS -u "$EMAIL:$TOKEN" -X "$method" -H "Content-Type: application/json" \
      --data "$body" "$BASE$path"
  else
    curl -sS -u "$EMAIL:$TOKEN" -X "$method" -H "Accept: application/json" "$BASE$path"
  fi
}

# Build an Atlassian Document Format (ADF) doc from plain text (v3 needs ADF).
adf() { jq -n --arg t "$1" '{type:"doc",version:1,content:[{type:"paragraph",content:[{type:"text",text:$t}]}]}'; }

cmd="${1:-mine}"; shift || true

case "$cmd" in
  read)
    KEY="$1"
    [ -z "$KEY" ] && { echo "usage: jira.sh read <KEY>" >&2; exit 1; }
    api GET "/rest/api/3/issue/$KEY?fields=summary,status,assignee,priority,description&expand=renderedFields" \
      | jq -r '"["+.key+"] "+.fields.summary,
               "Status: "+(.fields.status.name // "?"),
               "Assignee: "+(.fields.assignee.displayName // "Unassigned"),
               "Priority: "+(.fields.priority.name // "?"),
               "URL: '"$BASE"'/browse/"+.key' 2>/dev/null \
      || echo "Couldn't read $KEY, dear."
    ;;
  mine)
    JQL='assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC'
    api GET "/rest/api/3/search/jql?maxResults=20&fields=summary,status&jql=$(jq -rn --arg j "$JQL" '$j|@uri')" \
      | jq -r '.issues[]? | "["+.key+"] "+.fields.summary+" — "+(.fields.status.name // "?")' \
      || echo "Couldn't list your issues, dear."
    ;;
  search)
    Q="$*"
    [ -z "$Q" ] && { echo "usage: jira.sh search \"<jql or text>\"" >&2; exit 1; }
    # Heuristic: if it looks like JQL (has = or ~ or ORDER BY) use as-is, else text search.
    case "$Q" in
      *=*|*~*|*"ORDER BY"*) JQL="$Q" ;;
      *) JQL="text ~ \"$Q\" ORDER BY updated DESC" ;;
    esac
    api GET "/rest/api/3/search/jql?maxResults=20&fields=summary,status&jql=$(jq -rn --arg j "$JQL" '$j|@uri')" \
      | jq -r '.issues[]? | "["+.key+"] "+.fields.summary+" — "+(.fields.status.name // "?")' \
      || echo "Search failed, dear."
    ;;
  create)
    # create <PROJECT> "<summary>"  OR  create "<summary>" (uses default project)
    if [ $# -ge 2 ]; then PROJ="$1"; shift; SUMMARY="$*"; else PROJ="$DEFPROJ"; SUMMARY="$*"; fi
    [ -z "$PROJ" ] && { echo "No project, dear — pass one (jira.sh create PROJ \"...\") or set jira_default_project." >&2; exit 1; }
    [ -z "$SUMMARY" ] && { echo "usage: jira.sh create [PROJECT] \"<summary>\"" >&2; exit 1; }
    BODY="$(jq -n --arg p "$PROJ" --arg s "$SUMMARY" \
      '{fields:{project:{key:$p},summary:$s,issuetype:{name:"Task"}}}')"
    RESP="$(api POST "/rest/api/3/issue" "$BODY")"
    NEWKEY="$(echo "$RESP" | jq -r '.key // empty')"
    if [ -n "$NEWKEY" ]; then echo "Created $NEWKEY, dear: $BASE/browse/$NEWKEY";
    else echo "Create failed, dear: $(echo "$RESP" | jq -rc '.errors // .errorMessages // .' 2>/dev/null | head -c 200)"; fi
    ;;
  comment)
    KEY="$1"; shift || true; TEXT="$*"
    [ -z "$KEY" ] || [ -z "$TEXT" ] && { echo "usage: jira.sh comment <KEY> \"<text>\"" >&2; exit 1; }
    BODY="$(jq -n --argjson b "$(adf "$TEXT")" '{body:$b}')"
    RESP="$(api POST "/rest/api/3/issue/$KEY/comment" "$BODY")"
    if echo "$RESP" | jq -e '.id' >/dev/null 2>&1; then echo "Commented on $KEY, dear.";
    else echo "Comment failed, dear: $(echo "$RESP" | jq -rc '.errors // .errorMessages // .' 2>/dev/null | head -c 200)"; fi
    ;;
  *)
    echo "usage: jira.sh read <KEY>|mine|search <q>|create [PROJECT] <summary>|comment <KEY> <text>" >&2
    exit 1
    ;;
esac
