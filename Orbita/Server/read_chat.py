#!/usr/bin/env python3
"""
read_chat — прочитать расшифрованную переписку на СВОЁМ сервере (нужен мастер-ключ, т.е. вы — оператор).

  python3 read_chat.py users                       кто есть в базе (id, @имя, имя)
  python3 read_chat.py chat @я @собеседник [-n 50] последние сообщения между двумя людьми
  python3 read_chat.py raw  @я @собеседник [-n 5]  то же, но показать ещё и «сырые» зашифрованные байты (для проверки шифрования)

Переменные те же, что у сервера: ORBITA_DATA (папка с orbita-v2.db), ORBITA_HOME / ORBITA_MASTER_KEY_FILE (мастер-ключ).
Только чтение: база открывается в режиме read-only.
"""
import argparse
import datetime
import json
import os
import sqlite3
import sys

from orbita_crypto import COL, KeyRing, field_aad, unseal

BASE = os.path.dirname(os.path.abspath(__file__))
STATE = os.environ.get("ORBITA_HOME", os.path.join(os.path.expanduser("~"), ".orbita"))
DATA = os.environ.get("ORBITA_DATA", os.path.join(STATE, "data"))
KEYS = os.environ.get("ORBITA_HOME", STATE)


def keyring():
    if not (os.environ.get("ORBITA_MASTER_KEY") or os.environ.get("ORBITA_MASTER_KEY_FILE")):
        return KeyRing.load(STATE)
    return KeyRing.load(STATE)


def connect():
    path = os.path.join(DATA, "orbita-v2.db")
    if not os.path.exists(path):
        sys.exit("База не найдена: %s (задайте ORBITA_DATA)" % path)
    db = sqlite3.connect("file:%s?mode=ro" % path, uri=True)
    db.row_factory = sqlite3.Row
    return db


def opened(kr, uid, scope, column, rid, blob):
    if blob is None:
        return None
    try:
        return unseal(kr.scope_key(uid, scope), blob, field_aad(column, rid)).decode("utf-8")
    except Exception:
        return "⟨не удалось расшифровать⟩"


def uname(kr, db, uid):
    r = db.execute("SELECT username_enc FROM users WHERE id=?", (uid,)).fetchone()
    return "@" + (opened(kr, uid, "profile", COL["username"], uid, r["username_enc"]) or "?") if r else uid


def resolve(db, kr, ref):
    if ref.startswith("@"):
        row = db.execute("SELECT id FROM users WHERE username_idx=?", (kr.blind_index(ref[1:].lower(), "username"),)).fetchone()
    else:
        row = db.execute("SELECT id FROM users WHERE id=?", (ref.lower(),)).fetchone()
    if not row:
        sys.exit("Пользователь не найден: %s" % ref)
    return row["id"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["users", "chat", "raw"])
    ap.add_argument("a", nargs="?")
    ap.add_argument("b", nargs="?")
    ap.add_argument("-n", type=int, default=50)
    args = ap.parse_args()
    kr, db = keyring(), connect()
    if args.cmd == "users":
        for r in db.execute("SELECT id, name_enc FROM users ORDER BY created_at"):
            print("%s  %-18s %s" % (r["id"], uname(kr, db, r["id"]),
                                    opened(kr, r["id"], "profile", COL["name"], r["id"], r["name_enc"])))
        return
    if not (args.a and args.b):
        sys.exit("Нужны двое: chat @я @собеседник")
    a, b = resolve(db, kr, args.a), resolve(db, kr, args.b)
    rows = db.execute("SELECT * FROM messages WHERE (sender=? AND recipient=?) OR (sender=? AND recipient=?) "
                      "ORDER BY created_at DESC LIMIT ?", (a, b, b, a, args.n)).fetchall()
    for r in reversed(rows):
        t = datetime.datetime.fromtimestamp(r["created_at"]).strftime("%d.%m %H:%M")
        text = opened(kr, r["sender"], "messages", COL["msg_text"], r["id"], r["text_enc"]) or ""
        extra = ""
        if "attachments_enc" in r.keys() and r["attachments_enc"]:
            extra = "  📎 " + (opened(kr, r["sender"], "messages", COL["msg_attach"], r["id"], r["attachments_enc"]) or "")[:120]
        print("[%s] %-14s %s%s" % (t, uname(kr, db, r["sender"]), text, extra))
        if args.cmd == "raw":
            print("      в базе: %s…  (%d байт)" % (bytes(r["text_enc"]).hex()[:48], len(r["text_enc"])))


if __name__ == "__main__":
    main()
