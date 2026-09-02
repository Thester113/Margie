#!/usr/bin/env python3
"""Read iMessages (1:1 or group) from chat.db, decoding attributedBody and
transcribing voice memos. Shared by messages.sh (read / readchat).

Usage: imsg_read.py handle "<phone/email>" <n>
       imsg_read.py chat   "<chat_rowid>"  <n>
"""
import os, re, sqlite3, sys, subprocess, tempfile, shutil, json

DB = os.path.expanduser("~/Library/Messages/chat.db")
OBJ = "￼"  # object-replacement char = attachment placeholder
MODELS = os.path.expanduser("~/.margie/models")
MODEL = next((os.path.join(MODELS, m) for m in
              ("ggml-small.en.bin", "ggml-base.en.bin", "ggml-tiny.en.bin")
              if os.path.exists(os.path.join(MODELS, m))), None)
WHISPER = shutil.which("whisper-cli") or "/opt/homebrew/bin/whisper-cli"

# handle -> friendly alias (from config.contacts, which is alias -> handle)
NAMES = {}
try:
    cfg = json.load(open(os.path.expanduser("~/.margie/config.json")))
    for alias, handle in (cfg.get("contacts") or {}).items():
        if isinstance(handle, str):
            NAMES.setdefault(handle, alias)
except Exception:
    pass


def name_for(h):
    return NAMES.get(h, h or "?")


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


def content(text, blob, mime, fname):
    t = (text or "").strip()
    if not t or t == OBJ:
        t = decode_attr(blob).strip()
    if (not t or t == OBJ or mime) and is_audio(mime, blob):
        tx = transcribe(fname)
        return f"(voice memo) {tx}" if tx else "[audio message]"
    if not t or t == OBJ or mime:
        return label_media(mime, blob)
    return t


def main():
    mode, target, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    lines = []
    if mode == "handle":
        digits = re.sub(r"\D", "", target)
        rows = con.execute(
            """SELECT m.is_from_me, m.text, m.attributedBody, a.mime_type, a.filename
               FROM message m JOIN handle h ON m.handle_id=h.ROWID
               LEFT JOIN message_attachment_join maj ON maj.message_id=m.ROWID
               LEFT JOIN attachment a ON a.ROWID=maj.attachment_id
               WHERE h.id=? OR replace(replace(replace(h.id,'+',''),'-',''),' ','')=?
               ORDER BY m.date DESC LIMIT ?""", (target, digits, n)).fetchall()
        for is_me, text, blob, mime, fname in reversed(rows):
            lines.append(("Me" if is_me else "Them") + ": " + content(text, blob, mime, fname).replace("\n", " "))
    else:  # chat (group)
        rows = con.execute(
            """SELECT m.is_from_me, h.id, m.text, m.attributedBody, a.mime_type, a.filename
               FROM chat_message_join cmj JOIN message m ON m.ROWID=cmj.message_id
               LEFT JOIN handle h ON m.handle_id=h.ROWID
               LEFT JOIN message_attachment_join maj ON maj.message_id=m.ROWID
               LEFT JOIN attachment a ON a.ROWID=maj.attachment_id
               WHERE cmj.chat_id=? ORDER BY m.date DESC LIMIT ?""", (int(target), n)).fetchall()
        for is_me, hid, text, blob, mime, fname in reversed(rows):
            who = "Me" if is_me else name_for(hid)
            lines.append(f"{who}: " + content(text, blob, mime, fname).replace("\n", " "))
    print("\n".join(lines) if lines else "No messages found, dear.")


if __name__ == "__main__":
    main()
