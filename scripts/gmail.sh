#!/bin/bash
# gmail.sh — Gmail via IMAP/SMTP directly (no Claude, no connector).
#
# Reads credentials from ~/.margie/config.json:
#   gmail_address        e.g. you@example.com
#   gmail_app_password   a 16-char app password from
#                        myaccount.google.com/apppasswords (needs 2FA on).
#   gmail_imap_host      (optional, default imap.gmail.com)
#   gmail_smtp_host      (optional, default smtp.gmail.com)
#
# Usage:
#   gmail.sh unread                         (recent unread: from, subject, gist)
#   gmail.sh read "<query>"                 (search subject/from/body)
#   gmail.sh send "<to>: <subject>: <body>"
set -uo pipefail

CFG="$HOME/.margie/config.json"
cfg() { jq -r ".$1 // empty" "$CFG" 2>/dev/null; }
ADDR="$(cfg gmail_address)"
PASS="$(cfg gmail_app_password)"
IMAP_HOST="$(cfg gmail_imap_host)"; IMAP_HOST="${IMAP_HOST:-imap.gmail.com}"
SMTP_HOST="$(cfg gmail_smtp_host)"; SMTP_HOST="${SMTP_HOST:-smtp.gmail.com}"

if [ -z "$ADDR" ] || [ -z "$PASS" ]; then
  echo "Gmail isn't configured yet, sir — add gmail_address and gmail_app_password to ~/.margie/config.json (create an app password at myaccount.google.com/apppasswords)." >&2
  exit 1
fi

cmd="${1:-unread}"; shift || true; args="$*"

export MG_ADDR="$ADDR" MG_PASS="$PASS" MG_IMAP="$IMAP_HOST" MG_SMTP="$SMTP_HOST" MG_ARGS="$args"

case "$cmd" in
  unread|read)
    export MG_MODE="$cmd"
    python3 <<'PY'
import imaplib, email, os, sys
from email.header import decode_header
def dec(v):
    if not v: return ""
    out=[]
    for s,enc in decode_header(v):
        out.append(s.decode(enc or "utf-8","replace") if isinstance(s,bytes) else s)
    return "".join(out)
try:
    M=imaplib.IMAP4_SSL(os.environ["MG_IMAP"])
    M.login(os.environ["MG_ADDR"], os.environ["MG_PASS"])
    M.select("INBOX")
    mode=os.environ["MG_MODE"]; q=os.environ["MG_ARGS"].strip()
    if mode=="unread":
        typ,data=M.search(None,"UNSEEN")
    else:
        # simple text search across common fields
        if q:
            typ,data=M.search(None,"TEXT",q.encode("utf-8"))
        else:
            typ,data=M.search(None,"ALL")
    ids=data[0].split()[-12:][::-1]  # most recent up to 12
    if not ids:
        print("No matching messages, sir."); M.logout(); sys.exit(0)
    for i in ids:
        # PEEK so we don't mark unread mail as read
        typ,md=M.fetch(i,"(BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)])")
        hdr=email.message_from_bytes(md[0][1])
        frm=dec(hdr.get("From")); subj=dec(hdr.get("Subject")); date=dec(hdr.get("Date"))
        print(f"• {frm} — {subj}  ({date})")
    M.logout()
except imaplib.IMAP4.error as e:
    print(f"Gmail login/read failed, sir: {e}. If your Workspace blocks app passwords/IMAP, that's the cause.", file=sys.stderr); sys.exit(1)
except Exception as e:
    print(f"Gmail error, sir: {e}", file=sys.stderr); sys.exit(1)
PY
    ;;
  send)
    # args form: "<to>: <subject>: <body>"
    python3 <<'PY'
import smtplib, os, sys
from email.message import EmailMessage
raw=os.environ["MG_ARGS"]
parts=raw.split(":",2)
if len(parts)<3:
    print('usage: gmail.sh send "<to>: <subject>: <body>"', file=sys.stderr); sys.exit(1)
to,subj,body=[p.strip() for p in parts]
msg=EmailMessage(); msg["From"]=os.environ["MG_ADDR"]; msg["To"]=to; msg["Subject"]=subj; msg.set_content(body)
try:
    s=smtplib.SMTP(os.environ["MG_SMTP"],587); s.starttls()
    s.login(os.environ["MG_ADDR"], os.environ["MG_PASS"]); s.send_message(msg); s.quit()
    print(f"Sent to {to}, sir: “{subj}”.")
except Exception as e:
    print(f"Send failed, sir: {e}", file=sys.stderr); sys.exit(1)
PY
    ;;
  *)
    echo "usage: gmail.sh unread | read \"<query>\" | send \"<to>: <subject>: <body>\"" >&2
    exit 1
    ;;
esac
