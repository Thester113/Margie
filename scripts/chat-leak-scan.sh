#!/bin/bash
# chat-leak-scan.sh — the verification core of the chat sim-verification rig.
# Reads RENDERED chat text on stdin (an idb accessibility-tree dump, or OCR text)
# and fails if any raw internal id leaked into what the user sees.
#
# Why "any uuid in the rendered text = a leak": valid (walt-contact-id: <uuid>) /
# (walt-event-id: ...) markers are consumed by the client and rendered as CARDS
# (a contact name, not text), so they never appear in the a11y text. Anything
# uuid-shaped that DOES appear as text — a bare uuid, "(id: <uuid>)",
# "(contact id: ...)", "(task id: ...)" — is by definition a leak the redaction
# and the card renderer both failed to catch.
#
#   idb ui describe-all --udid <sim> | chat-leak-scan.sh
#   chat-leak-scan.sh < rendered.txt
# Exit 0 + "CHAT_LEAK_SCAN clean" when nothing leaked; exit 1 + the offending
# lines when a raw id is present.
set -uo pipefail

IN="$(cat)"
# RFC-4122-shaped uuid anywhere in the rendered text.
UUID='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

LEAKS="$(printf '%s\n' "$IN" | grep -nE "$UUID|\((id|contact[ _-]?id|task[ _-]?id|event[ _-]?id)[[:space:]]*:" 2>/dev/null)"

if [ -n "$LEAKS" ]; then
  echo "CHAT_LEAK_SCAN FAIL — raw internal id(s) visible in the rendered chat:"
  printf '%s\n' "$LEAKS" | sed 's/^/  /' | head -20
  exit 1
fi
echo "CHAT_LEAK_SCAN clean — no raw ids in the rendered chat."
exit 0
