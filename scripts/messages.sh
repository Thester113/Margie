#!/bin/bash
# messages.sh — send iMessage/SMS reliably and list chats, so Margie never has
# to improvise AppleScript (which sent to the wrong person).
#
# Contact aliases live in ~/.margie/config.json under "contacts", mapping a
# spoken name to a phone/email handle (most reliable) or exact contact name:
#   "contacts": { "wife": "+15551234567", "mom": "jane@icloud.com" }
#
# Usage:
#   messages.sh send "<who>: <message>"   who = alias | phone/email | contact name
#   messages.sh read "<who>" [count]      read recent iMessages with someone
#                                         (needs Full Disk Access for the app)
#   messages.sh list                      list recent chat handles
#   messages.sh resolve "<who>"           show what an alias/name resolves to
set -uo pipefail

CFG="$HOME/.margie/config.json"
cmd="${1:-}"; shift || true

resolve() {
  local who="$1" key val
  key="$(printf '%s' "$who" | tr 'A-Z' 'a-z' | sed 's/^ *//;s/ *$//')"
  # 1) alias in config.contacts (case-insensitive)
  val="$(jq -r --arg k "$key" '(.contacts // {}) | to_entries[] | select((.key|ascii_downcase)==$k) | .value' "$CFG" 2>/dev/null | head -1)"
  [ -n "$val" ] && { printf '%s' "$val"; return; }
  # 2) otherwise use it as given (a phone/email handle or contact name)
  printf '%s' "$who"
}

case "$cmd" in
  send)
    args="$*"
    who="${args%%:*}"; msg="${args#*:}"
    who="$(printf '%s' "$who" | sed 's/^ *//;s/ *$//')"
    msg="$(printf '%s' "$msg" | sed 's/^ *//;s/ *$//')"
    if [ -z "$who" ] || [ -z "$msg" ] || [ "$who" = "$args" ]; then
      echo "usage: messages.sh send \"<who>: <message>\"" >&2; exit 1
    fi
    target="$(resolve "$who")"
    # Escape double quotes and backslashes for AppleScript string literals.
    esc_msg="$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    esc_tgt="$(printf '%s' "$target" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    out="$(osascript <<OSA 2>&1
tell application "Messages"
  set svc to 1st account whose service type = iMessage
  try
    set b to participant "$esc_tgt" of svc
  on error
    set b to buddy "$esc_tgt" of svc
  end try
  send "$esc_msg" to b
end tell
OSA
)"
    if [ $? -eq 0 ]; then
      echo "Sent to $who ($target), sir: \"$msg\""
    else
      echo "Couldn't send to $who ($target), sir: ${out:0:160}. Is the handle a phone/email? Set an alias in config.contacts." >&2
      exit 1
    fi
    ;;
  read)
    # Read recent iMessages with someone from the Messages database. Requires
    # Full Disk Access for whatever app is running this (Margie, or Warp/Terminal
    # when testing) — System Settings → Privacy & Security → Full Disk Access.
    who="$1"; shift || true; N="${1:-12}"
    [ -z "$who" ] && { echo "usage: messages.sh read \"<who>\" [count]" >&2; exit 1; }
    target="$(resolve "$who")"
    DB="$HOME/Library/Messages/chat.db"
    if [ ! -r "$DB" ]; then
      echo "I can't read Messages, sir — grant Full Disk Access to Margie (System Settings → Privacy & Security → Full Disk Access), then try again." >&2
      exit 1
    fi
    MG_DB="$DB" MG_TARGET="$target" MG_N="$N" python3 <<'PY'
import os, re, sqlite3, sys, subprocess, tempfile, shutil
db = os.environ["MG_DB"]; target = os.environ["MG_TARGET"]; n = int(os.environ["MG_N"])
digits = re.sub(r"\D", "", target)
OBJ = "￼"  # object-replacement char = an attachment placeholder

MODELS = os.path.expanduser("~/.margie/models")
MODEL = next((os.path.join(MODELS, m) for m in
              ("ggml-small.en.bin", "ggml-base.en.bin", "ggml-tiny.en.bin")
              if os.path.exists(os.path.join(MODELS, m))), None)
WHISPER = shutil.which("whisper-cli") or "/opt/homebrew/bin/whisper-cli"

def decode_attr(data):
    if not data:
        return ""
    try:
        seg = data.split(b"NSString", 1)[1][5:]
        length = int.from_bytes(seg[1:3], "little") if seg[0] == 0x81 else seg[0]
        start = 3 if seg[0] == 0x81 else 1
        return seg[start:start + length].decode("utf-8", "ignore")
    except Exception:
        return ""

def is_audio(mime, blob):
    return (mime or "").lower().startswith("audio") or b"imaudio" in (blob or b"").lower()

def label_media(mime, blob):
    m = (mime or "").lower()
    if m.startswith("image") or any(x in (blob or b"").lower() for x in (b"public.jpeg", b"public.png", b"public.heic")):
        return "[image]"
    if m.startswith("video"):
        return "[video]"
    return "[attachment]"

def transcribe(fn):
    """Voice memo -> text via afconvert (built-in) + whisper-cli."""
    p = os.path.expanduser(fn) if fn else ""
    if not p or not os.path.exists(p) or not MODEL or not os.path.exists(WHISPER):
        return ""
    wav = tempfile.mktemp(suffix=".wav")
    try:
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", p, wav],
                       capture_output=True, timeout=30, check=True)
        r = subprocess.run([WHISPER, "-m", MODEL, "-f", wav, "-nt", "-np"],
                           capture_output=True, text=True, timeout=120)
        return " ".join(l.strip() for l in r.stdout.splitlines() if l.strip())
    except Exception:
        return ""
    finally:
        try:
            os.unlink(wav)
        except Exception:
            pass

try:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    q = """
      SELECT m.is_from_me, m.text, m.attributedBody, a.mime_type, a.filename
      FROM message m JOIN handle h ON m.handle_id = h.ROWID
      LEFT JOIN message_attachment_join maj ON maj.message_id = m.ROWID
      LEFT JOIN attachment a ON a.ROWID = maj.attachment_id
      WHERE h.id = ? OR replace(replace(replace(h.id,'+',''),'-',''),' ','') = ?
      ORDER BY m.date DESC LIMIT ?
    """
    rows = con.execute(q, (target, digits, n)).fetchall()
except Exception as e:
    print(f"Couldn't read Messages, sir: {e}", file=sys.stderr); sys.exit(1)

out = []
for is_me, text, blob, mime, fname in reversed(rows):
    t = (text or "").strip()
    if not t or t == OBJ:
        t = decode_attr(blob).strip()
    if (not t or t == OBJ or mime) and is_audio(mime, blob):
        tx = transcribe(fname)
        t = f"(voice memo) {tx}" if tx else "[audio message]"
    elif not t or t == OBJ or mime:
        t = label_media(mime, blob)
    who = "Me" if is_me else "Them"
    out.append(f"{who}: {t.replace(chr(10), ' ')}")
print("\n".join(out) if out else "No messages found with that contact, sir.")
PY
    ;;
  list)
    # Chat ids embed the handle (e.g. "iMessage;-;+15551234567"); pull out the
    # phone numbers / emails so Tom can pick one to set as an alias.
    {
      osascript -e 'tell application "Messages" to get id of every chat' 2>/dev/null
      osascript -e 'tell application "Messages" to get name of every chat' 2>/dev/null
    } | tr ',' '\n' \
      | grep -oE '[+][0-9]{7,}|[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}|[A-Z][a-zA-Z ]{2,30}' \
      | grep -v 'missing value' | sed 's/^ *//;s/ *$//' | sort -u | head -40
    ;;
  resolve)
    echo "$(resolve "$*")"
    ;;
  *)
    echo "usage: messages.sh send \"<who>: <msg>\" | list | resolve \"<who>\"" >&2
    exit 1
    ;;
esac
