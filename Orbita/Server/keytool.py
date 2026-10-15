#!/usr/bin/env python3
"""
keytool — выдача ключей по запросу, без раскрытия мастер-ключа.

  python3 keytool.py init                                  создать/проверить мастер-ключ, показать отпечаток
  python3 keytool.py users                                 список пользователей
  python3 keytool.py export --user @name|<id> --reason "…" [--scope posts,comments,profile,media] [--out файл]
                                                           пакет ключей ОДНОГО пользователя (нужен мастер-ключ, у оператора)
  python3 keytool.py decrypt --bundle файл [--db путь] [--media-out папка]
                                                           расшифровать данные пользователя ТОЛЬКО по пакету ключей
  python3 keytool.py log                                   журнал выдач

Пакет содержит производные ключи (HKDF): по ним нельзя восстановить мастер-ключ
и нельзя прочитать данные других пользователей. Каждая выдача записывается в журнал.
"""
import argparse
import base64
import getpass
import hashlib
import json
import os
import sqlite3
import sys
import time

from orbita_crypto import COL, SCOPES, KeyRing, decrypt_range, field_aad, file_key, unseal

BASE = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.environ.get("ORBITA_DATA", os.path.join(BASE, "data"))
DB_PATH = os.path.join(DATA_DIR, "orbita-v2.db")
MEDIA_DIR = os.path.join(DATA_DIR, "media-v2")
LOG_PATH = os.path.join(DATA_DIR, "disclosure.log")
EXT = {"image/jpeg": "jpg", "image/png": "png", "video/mp4": "mp4", "video/quicktime": "mov"}


def connect(path, readonly=True):
    if not os.path.exists(path):
        sys.exit("База не найдена: %s" % path)
    uri = "file:%s?mode=%s" % (path, "ro" if readonly else "rw")
    db = sqlite3.connect(uri, uri=True)
    db.row_factory = sqlite3.Row
    return db


# ---------- команды оператора (нужен мастер-ключ) ----------

def cmd_init(args):
    kr = KeyRing.load(BASE)
    print("Мастер-ключ найден. Отпечаток: %s" % kr.fingerprint())


def resolve_user(db, kr, ref):
    if ref.startswith("@"):
        idx = kr.blind_index(ref[1:].lower(), "username")
        row = db.execute("SELECT id FROM users WHERE username_idx = ?", (idx,)).fetchone()
    else:
        row = db.execute("SELECT id FROM users WHERE id = ?", (ref.lower(),)).fetchone()
    if not row:
        sys.exit("Пользователь не найден: %s" % ref)
    return row["id"]


def cmd_users(args):
    kr = KeyRing.load(BASE)
    db = connect(DB_PATH)
    for r in db.execute("SELECT * FROM users ORDER BY created_at"):
        uid = r["id"]
        key = kr.scope_key(uid, "profile")
        def field(col, name):
            blob = r[name]
            try:
                return unseal(key, blob, field_aad(col, uid)).decode() if blob else ""
            except Exception:
                return "?"
        print("%s  @%-16s %s" % (uid, field(COL["username"], "username_enc"), field(COL["name"], "name_enc")))


def cmd_export(args):
    kr = KeyRing.load(BASE)
    db = connect(DB_PATH)
    uid = resolve_user(db, kr, args.user)
    scopes = [s.strip() for s in args.scope.split(",")] if args.scope else list(SCOPES)
    for s in scopes:
        if s not in SCOPES:
            sys.exit("Неизвестная категория %r. Доступно: %s" % (s, ", ".join(SCOPES)))

    bundle = kr.bundle(uid, scopes, args.reason)
    out = args.out or "bundle-%s-%s.json" % (uid[:8], time.strftime("%Y%m%d-%H%M%S"))
    payload = json.dumps(bundle, ensure_ascii=False, indent=2)
    fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(payload)

    entry = {"time": bundle["issued_at"], "user_id": uid, "scopes": scopes, "reason": args.reason,
             "operator": getpass.getuser(), "bundle_sha256": hashlib.sha256(payload.encode()).hexdigest()}
    with open(LOG_PATH, "a") as log:
        log.write(json.dumps(entry, ensure_ascii=False) + "\n")

    print("Пакет ключей записан: %s" % out)
    print("  пользователь: %s\n  категории: %s\n  в журнал выдач добавлена запись" % (uid, ", ".join(scopes)))


def cmd_log(args):
    if not os.path.exists(LOG_PATH):
        print("Выдач не было.")
        return
    print(open(LOG_PATH).read().rstrip())


# ---------- расшифровка только по пакету ключей (мастер-ключ не используется) ----------

def cmd_decrypt(args):
    bundle = json.load(open(args.bundle))
    uid = bundle["user_id"]
    keys = {s: base64.b64decode(k) for s, k in bundle["scopes"].items()}
    db = connect(args.db or DB_PATH)

    def text(scope, col, rid, blob):
        if scope not in keys:
            return "[нет ключа категории %s]" % scope
        if blob is None:
            return None
        try:
            return unseal(keys[scope], blob, field_aad(col, rid)).decode("utf-8")
        except Exception:
            return "[не расшифровано]"

    result = {"user_id": uid, "scopes": sorted(keys)}

    u = db.execute("SELECT * FROM users WHERE id = ?", (uid,)).fetchone()
    if u:
        result["profile"] = {
            "name": text("profile", COL["name"], uid, u["name_enc"]),
            "username": text("profile", COL["username"], uid, u["username_enc"]),
            "bio": text("profile", COL["bio"], uid, u["bio_enc"]),
            "phone": text("profile", COL["phone"], uid, u["phone_enc"]),
            "last_name": text("profile", COL["last_name"], uid, u["last_name_enc"]) if "last_name_enc" in u.keys() else None,
            "birthday": text("profile", COL["birthday"], uid, u["birthday_enc"]) if "birthday_enc" in u.keys() else None,
        }

    result["posts"] = [{
        "id": p["id"], "created_at": p["created_at"],
        "text": text("posts", COL["post_text"], p["id"], p["text_enc"]),
        "entities": text("posts", COL["post_entities"], p["id"], p["entities_enc"]),
    } for p in db.execute("SELECT * FROM posts WHERE author = ? ORDER BY created_at", (uid,))]

    result["comments"] = [{
        "id": c["id"], "post_id": c["post_id"], "created_at": c["created_at"],
        "text": text("comments", COL["comment_text"], c["id"], c["text_enc"]),
    } for c in db.execute("SELECT * FROM comments WHERE author = ? ORDER BY created_at", (uid,))]

    media = []
    for m in db.execute("SELECT * FROM media WHERE owner = ? ORDER BY created_at", (uid,)):
        item = {"id": m["id"], "kind": m["kind"], "bytes": m["size"]}
        if "media" not in keys:
            item["file"] = "[нет ключа категории media]"
        elif args.media_out:
            os.makedirs(args.media_out, exist_ok=True)
            target = os.path.join(args.media_out, "%s.%s" % (m["id"], EXT.get(m["mime"], "bin")))
            try:
                key = file_key(keys["media"], m["id"])
                with open(os.path.join(MEDIA_DIR, m["id"]), "rb") as src, open(target, "wb") as dst:
                    for piece in decrypt_range(key, m["id"], src, m["size"], 0, m["size"] - 1):
                        dst.write(piece)
                item["file"] = target
            except Exception:
                item["file"] = "[не расшифровано]"
        media.append(item)
    result["media"] = media

    print(json.dumps(result, ensure_ascii=False, indent=2))


def main():
    parser = argparse.ArgumentParser(description="Выдача ключей Orbita без раскрытия мастер-ключа")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("init").set_defaults(fn=cmd_init)
    sub.add_parser("users").set_defaults(fn=cmd_users)
    sub.add_parser("log").set_defaults(fn=cmd_log)

    e = sub.add_parser("export")
    e.add_argument("--user", required=True, help="@username или id")
    e.add_argument("--reason", required=True, help="основание выдачи (номер запроса и т.п.) — попадёт в журнал")
    e.add_argument("--scope", help="через запятую: " + ",".join(SCOPES) + " (по умолчанию все)")
    e.add_argument("--out")
    e.set_defaults(fn=cmd_export)

    d = sub.add_parser("decrypt")
    d.add_argument("--bundle", required=True)
    d.add_argument("--db")
    d.add_argument("--media-out")
    d.set_defaults(fn=cmd_decrypt)

    args = parser.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
