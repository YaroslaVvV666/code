#!/usr/bin/env python3
"""
Orbita Server — бэкенд соцсети. Всё, что хранится на сервере, зашифровано AES-256-GCM.

Установка:  pip3 install cryptography
Запуск:     python3 server.py          → http://0.0.0.0:8080

Профили (имя, @username, о себе, аватар), публикации с форматированием, несколько фото и видео,
лайки, комментарии, приватность. Вход — токен устройства.

Шифрование и выдача ключей: см. orbita_crypto.py и keytool.py.
Для интернета поставьте перед сервером HTTPS (nginx / Caddy).
"""
import datetime
import gzip
import html as htmllib
import ipaddress
import socket
import urllib.request
import hashlib
import hmac
import json
import random
import math
import os
import re
import secrets
import sqlite3
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import moderation
import otp
import push
from orbita_crypto import (COL, HEADER, KeyRing, decrypt_range, encrypt_stream, field_aad, file_key,
                           seal, unseal)

HOST = os.environ.get("ORBITA_HOST", "0.0.0.0")
PORT = int(os.environ.get("ORBITA_PORT", "8080"))
BASE = os.path.dirname(os.path.abspath(__file__))
# Данные и ключ живут ВНЕ папки проекта (~/.orbita), чтобы замена папки на новую версию их не стирала.
STATE_DIR = os.environ.get("ORBITA_HOME", os.path.join(os.path.expanduser("~"), ".orbita"))


def _migrate_legacy_state():
    """Старые версии хранили данные рядом с server.py — переносим один раз (копированием)."""
    import shutil
    for name in ("data", "keys"):
        old, new = os.path.join(BASE, name), os.path.join(STATE_DIR, name)
        if os.path.isdir(old) and not os.path.exists(new):
            os.makedirs(STATE_DIR, exist_ok=True)
            shutil.copytree(old, new)
            print("перенёс %s -> %s" % (old, new))


if "ORBITA_DATA" not in os.environ:
    _migrate_legacy_state()
DATA_DIR = os.environ.get("ORBITA_DATA", os.path.join(STATE_DIR, "data"))
MEDIA_DIR = os.path.join(DATA_DIR, "media-v2")

MAX_MEDIA_BYTES = 80 * 1024 * 1024
MAX_TEXT = 4000
MAX_MEDIA_PER_POST = 10
MAX_BIO = 70
MAX_AVATARS = 50
QR_TTL = 120
USERNAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]{4,31}$")
ENTITY_TYPES = {"bold", "italic", "underline", "strike", "mono", "quote", "link", "highlight"}
ALLOWED_MIME = {"image/jpeg", "image/png", "video/mp4", "video/quicktime",
                "audio/mpeg", "audio/mp3", "audio/mp4", "audio/x-m4a", "audio/aac"}
MAX_AUDIO_BYTES = 40 * 1024 * 1024
MAX_TRACKS = 100
OTP_TTL = 300
OTP_RESEND = 45
OTP_PER_HOUR = 5
OTP_IP_PER_HOUR = 20
OTP_ATTEMPTS = 5
OTP_DEV = os.environ.get("ORBITA_OTP_DEV", "0") == "1"      # без провайдера отдаёт код в ответе (только для разработки!)
if not OTP_DEV and not otp.configured("sms"):
    print("\n!!! SMS-провайдер не настроен и ORBITA_OTP_DEV не включён: войти по номеру нельзя.\n"
          "!!! Для разработки запустите так:  ORBITA_OTP_DEV=1 python3 server.py\n")
PRIVACY_KEYS = ("phone", "last_seen", "photos", "bio", "birthday", "music", "wall", "calls", "forwards", "invites",
                "comments", "find", "followers", "orbit")
PRIVACY_DEFAULTS = {"followers": "all", "last_seen": "all", "photos": "all", "bio": "all", "birthday": "nobody", "music": "all",
                    "wall": "all", "calls": "all", "forwards": "all", "invites": "all", "find": "all", "orbit": "nobody"}

os.makedirs(MEDIA_DIR, exist_ok=True)
KR = KeyRing.load(STATE_DIR)
if os.path.exists(os.path.join(DATA_DIR, "orbita.db")):
    print("ВНИМАНИЕ: найдена старая НЕзашифрованная база data/orbita.db. Она не используется и не переносится — "
          "удалите её вместе с data/media.")

DB = sqlite3.connect(os.path.join(DATA_DIR, "orbita-v2.db"), check_same_thread=False, isolation_level=None)
DB.row_factory = sqlite3.Row
DB.execute("PRAGMA foreign_keys = ON")
DB.execute("PRAGMA journal_mode = WAL")
DB.execute("PRAGMA secure_delete = ON")
# скорость: кэш страниц в памяти, реже fsync (в режиме WAL это безопасно), mmap, временные таблицы в памяти
DB.execute("PRAGMA synchronous = NORMAL")
DB.execute("PRAGMA cache_size = -65536")
DB.execute("PRAGMA temp_store = MEMORY")
DB.execute("PRAGMA mmap_size = 268435456")
DB.execute("PRAGMA busy_timeout = 5000")
DB.execute("PRAGMA wal_autocheckpoint = 2000")
LOCK = threading.RLock()

# *_enc — шифртекст AES-256-GCM, *_idx — слепой индекс (HMAC) для поиска без хранения значения
SCHEMA = """
CREATE TABLE IF NOT EXISTS users(
  id TEXT PRIMARY KEY, token_hash TEXT NOT NULL,
  name_enc BLOB NOT NULL, username_idx TEXT UNIQUE, username_enc BLOB, bio_enc BLOB, phone_enc BLOB,
  avatar TEXT, phone_visibility TEXT NOT NULL DEFAULT 'nobody',
  comments_policy TEXT NOT NULL DEFAULT 'all', created_at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS media(
  id TEXT PRIMARY KEY, owner TEXT NOT NULL, kind TEXT NOT NULL, mime TEXT NOT NULL,
  width INTEGER, height INTEGER, duration REAL, thumb TEXT, size INTEGER NOT NULL, created_at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS media_blocked(
  hash TEXT PRIMARY KEY, created_at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS media_review(
  media_id TEXT PRIMARY KEY, owner TEXT NOT NULL, verdict TEXT NOT NULL, detail TEXT, created_at REAL NOT NULL,
  status TEXT NOT NULL DEFAULT 'open');
CREATE TABLE IF NOT EXISTS posts(
  id TEXT PRIMARY KEY, author TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  text_enc BLOB NOT NULL, entities_enc BLOB NOT NULL,
  created_at REAL NOT NULL, likes_seed INTEGER NOT NULL DEFAULT 0, pinned_comment TEXT);
CREATE INDEX IF NOT EXISTS idx_posts_created ON posts(created_at DESC);
CREATE TABLE IF NOT EXISTS post_media(
  post_id TEXT NOT NULL REFERENCES posts(id) ON DELETE CASCADE, position INTEGER NOT NULL,
  media_id TEXT NOT NULL, kind TEXT NOT NULL, width INTEGER, height INTEGER, duration REAL, thumb TEXT,
  PRIMARY KEY(post_id, position));
CREATE TABLE IF NOT EXISTS likes(
  post_id TEXT NOT NULL REFERENCES posts(id) ON DELETE CASCADE, user_id TEXT NOT NULL,
  PRIMARY KEY(post_id, user_id));
CREATE TABLE IF NOT EXISTS comments(
  id TEXT PRIMARY KEY, post_id TEXT NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
  author TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, text_enc BLOB NOT NULL, created_at REAL NOT NULL,
  parent_id TEXT, reply_to_id TEXT);
CREATE INDEX IF NOT EXISTS idx_comments_post ON comments(post_id, created_at);
CREATE TABLE IF NOT EXISTS comment_likes(
  comment_id TEXT NOT NULL REFERENCES comments(id) ON DELETE CASCADE, user_id TEXT NOT NULL,
  PRIMARY KEY(comment_id, user_id));
CREATE TABLE IF NOT EXISTS sessions(
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE, info_enc BLOB, created_at REAL NOT NULL, last_active REAL NOT NULL);
CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id);
CREATE TABLE IF NOT EXISTS avatars(
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  media_id TEXT NOT NULL, position INTEGER NOT NULL, created_at REAL NOT NULL);
CREATE INDEX IF NOT EXISTS idx_avatars_user ON avatars(user_id, position);
CREATE TABLE IF NOT EXISTS blocks(
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  blocked_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at REAL NOT NULL, PRIMARY KEY(user_id, blocked_id));
CREATE INDEX IF NOT EXISTS idx_blocks_blocked ON blocks(blocked_id);
CREATE TABLE IF NOT EXISTS tracks(
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  media_id TEXT NOT NULL, position INTEGER NOT NULL, title_enc BLOB NOT NULL, artist_enc BLOB,
  duration REAL, created_at REAL NOT NULL);
CREATE INDEX IF NOT EXISTS idx_tracks_user ON tracks(user_id, position);
CREATE INDEX IF NOT EXISTS idx_posts_author ON posts(author, created_at DESC);
CREATE TABLE IF NOT EXISTS messages(
  id TEXT PRIMARY KEY, sender TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  recipient TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  text_enc BLOB NOT NULL, entities_enc BLOB NOT NULL, reply_to TEXT,
  created_at REAL NOT NULL, edited_at REAL, read_at REAL,
  del_sender INTEGER NOT NULL DEFAULT 0, del_recipient INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS idx_msg_pair ON messages(sender, recipient, created_at);
CREATE INDEX IF NOT EXISTS idx_msg_unread ON messages(recipient, read_at);
CREATE TABLE IF NOT EXISTS contacts(
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  contact_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name_enc BLOB NOT NULL, created_at REAL NOT NULL, PRIMARY KEY(user_id, contact_id));
CREATE TABLE IF NOT EXISTS groups(
  id TEXT PRIMARY KEY, owner TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title_enc BLOB NOT NULL, about_enc BLOB, kind TEXT NOT NULL DEFAULT 'closed',
  code TEXT NOT NULL UNIQUE, created_at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS group_members(
  group_id TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role TEXT NOT NULL DEFAULT 'member', joined_at REAL NOT NULL, last_read REAL NOT NULL DEFAULT 0,
  PRIMARY KEY(group_id, user_id));
CREATE INDEX IF NOT EXISTS idx_gm_user ON group_members(user_id);
CREATE TABLE IF NOT EXISTS group_messages(
  id TEXT PRIMARY KEY, group_id TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  sender TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  text_enc BLOB NOT NULL, entities_enc BLOB NOT NULL, attachments_enc BLOB, reply_to TEXT,
  created_at REAL NOT NULL, edited_at REAL);
CREATE INDEX IF NOT EXISTS idx_gmsg ON group_messages(group_id, created_at);
CREATE TABLE IF NOT EXISTS group_hidden(
  message_id TEXT NOT NULL REFERENCES group_messages(id) ON DELETE CASCADE, user_id TEXT NOT NULL,
  PRIMARY KEY(message_id, user_id));
CREATE TABLE IF NOT EXISTS group_requests(
  group_id TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at REAL NOT NULL, PRIMARY KEY(group_id, user_id));
CREATE TABLE IF NOT EXISTS group_bans(
  group_id TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  PRIMARY KEY(group_id, user_id));
CREATE TABLE IF NOT EXISTS imported_contacts(
  owner TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  phone_idx TEXT NOT NULL, name_enc BLOB, notified INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL,
  PRIMARY KEY(owner, phone_idx));
CREATE INDEX IF NOT EXISTS idx_imported_phone ON imported_contacts(phone_idx);
CREATE TABLE IF NOT EXISTS notices(
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  about TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, kind TEXT NOT NULL, name_enc BLOB,
  created_at REAL NOT NULL);
CREATE INDEX IF NOT EXISTS idx_notices_user ON notices(user_id);
CREATE TABLE IF NOT EXISTS push_tokens(
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  session_id TEXT REFERENCES sessions(id) ON DELETE CASCADE,
  token_idx TEXT NOT NULL UNIQUE, token_enc BLOB NOT NULL, env TEXT NOT NULL, updated_at REAL NOT NULL);
CREATE INDEX IF NOT EXISTS idx_push_user ON push_tokens(user_id);
CREATE TABLE IF NOT EXISTS reactions(
  message_id TEXT NOT NULL, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  emoji TEXT NOT NULL, created_at REAL NOT NULL, PRIMARY KEY(message_id, user_id));
CREATE TABLE IF NOT EXISTS user_interests(
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  topics_enc BLOB NOT NULL, updated_at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS user_taste(
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  data_enc BLOB NOT NULL, updated_at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS username_prefix(
  prefix_idx TEXT NOT NULL, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  PRIMARY KEY(prefix_idx, user_id));
CREATE INDEX IF NOT EXISTS username_prefix_user ON username_prefix(user_id);
CREATE TABLE IF NOT EXISTS friend_requests(
  from_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  to_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at REAL NOT NULL, PRIMARY KEY(from_id, to_id));
CREATE TABLE IF NOT EXISTS friends(
  a TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  b TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at REAL NOT NULL, PRIMARY KEY(a, b));
CREATE INDEX IF NOT EXISTS friends_b ON friends(b);
CREATE TABLE IF NOT EXISTS follows(
  follower TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  followee TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at REAL NOT NULL, PRIMARY KEY(follower, followee));
CREATE INDEX IF NOT EXISTS follows_followee ON follows(followee);
CREATE TABLE IF NOT EXISTS group_mentions(
  message_id TEXT NOT NULL, group_id TEXT NOT NULL,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at REAL NOT NULL, PRIMARY KEY(message_id, user_id));
CREATE INDEX IF NOT EXISTS group_mentions_user ON group_mentions(user_id, group_id, created_at);
CREATE TABLE IF NOT EXISTS dm_mentions(
  message_id TEXT PRIMARY KEY, sender TEXT NOT NULL, recipient TEXT NOT NULL, created_at REAL NOT NULL);
CREATE INDEX IF NOT EXISTS dm_mentions_rcpt ON dm_mentions(recipient, sender);
CREATE TABLE IF NOT EXISTS scheduled(
  id TEXT PRIMARY KEY, sender TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, peer TEXT NOT NULL,
  payload_enc BLOB NOT NULL, send_at REAL NOT NULL, created_at REAL NOT NULL);
CREATE INDEX IF NOT EXISTS idx_sched_due ON scheduled(send_at);
CREATE TABLE IF NOT EXISTS stories(
  id TEXT PRIMARY KEY, author TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  media_id TEXT NOT NULL, kind TEXT NOT NULL, caption_enc BLOB,
  created_at REAL NOT NULL, expires_at REAL NOT NULL);
CREATE INDEX IF NOT EXISTS idx_stories_author ON stories(author, created_at);
CREATE TABLE IF NOT EXISTS story_views(
  story_id TEXT NOT NULL, viewer TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  viewed_at REAL NOT NULL, PRIMARY KEY(story_id, viewer));
CREATE TABLE IF NOT EXISTS story_likes(
  story_id TEXT NOT NULL, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at REAL NOT NULL, PRIMARY KEY(story_id, user_id));
CREATE TABLE IF NOT EXISTS pins(
  chat_key TEXT NOT NULL, message_id TEXT NOT NULL, pinned_by TEXT NOT NULL, created_at REAL NOT NULL,
  PRIMARY KEY(chat_key, message_id));
"""
DB.executescript(SCHEMA)


def ensure_column(table, column, ddl):
    """Лёгкая миграция для баз, созданных прежней версией"""
    if column not in [r["name"] for r in DB.execute("PRAGMA table_info(%s)" % table)]:
        DB.execute("ALTER TABLE %s ADD COLUMN %s" % (table, ddl))


ensure_column("group_messages", "kind", "kind TEXT")
ensure_column("tracks", "cover", "cover TEXT")                                       # обложка трека (картинка из тегов файла)
ensure_column("stories", "permanent", "permanent INTEGER NOT NULL DEFAULT 0")
ensure_column("messages", "kind", "kind TEXT")
ensure_column("messages", "fwd_enc", "fwd_enc BLOB")
ensure_column("group_messages", "fwd_enc", "fwd_enc BLOB")
DB.executescript("""CREATE TABLE IF NOT EXISTS polls(
  message_id TEXT PRIMARY KEY, creator TEXT NOT NULL, multiple INTEGER NOT NULL DEFAULT 0,
  anonymous INTEGER NOT NULL DEFAULT 1, closed INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS poll_options(
  message_id TEXT NOT NULL, idx INTEGER NOT NULL, text_enc BLOB NOT NULL, PRIMARY KEY(message_id, idx));
CREATE TABLE IF NOT EXISTS poll_votes(
  message_id TEXT NOT NULL, user_id TEXT NOT NULL, idx INTEGER NOT NULL, created_at REAL NOT NULL,
  PRIMARY KEY(message_id, user_id, idx));""")
ensure_column("posts", "pinned_comment", "pinned_comment TEXT")
ensure_column("comments", "parent_id", "parent_id TEXT")
ensure_column("comments", "reply_to_id", "reply_to_id TEXT")
ensure_column("users", "last_name_enc", "last_name_enc BLOB")
ensure_column("users", "birthday_enc", "birthday_enc BLOB")
ensure_column("users", "privacy_enc", "privacy_enc BLOB")
ensure_column("posts", "edited_at", "edited_at REAL")
ensure_column("posts", "reel", "reel INTEGER NOT NULL DEFAULT 0")
ensure_column("posts", "music_enc", "music_enc BLOB")
ensure_column("posts", "repost_of", "repost_of TEXT")
ensure_column("posts", "music_media", "music_media TEXT")
ensure_column("posts", "music_key", "music_key TEXT")
DB.execute("CREATE TABLE IF NOT EXISTS reel_queries(q TEXT NOT NULL, user_id TEXT NOT NULL, created_at REAL NOT NULL)")
DB.execute("CREATE INDEX IF NOT EXISTS idx_reel_queries ON reel_queries(created_at, q)")
DB.execute("CREATE TABLE IF NOT EXISTS post_stats(post_id TEXT PRIMARY KEY, views INTEGER NOT NULL DEFAULT 0, watch_ms INTEGER NOT NULL DEFAULT 0, "
           "ratio_sum REAL NOT NULL DEFAULT 0, completes INTEGER NOT NULL DEFAULT 0, skips INTEGER NOT NULL DEFAULT 0, "
           "shares INTEGER NOT NULL DEFAULT 0, since REAL NOT NULL DEFAULT 0)")
DB.execute("CREATE TABLE IF NOT EXISTS follow_source(follower TEXT NOT NULL, followee TEXT NOT NULL, post_id TEXT NOT NULL, "
           "created_at REAL NOT NULL, PRIMARY KEY(follower, followee))")
DB.execute("CREATE INDEX IF NOT EXISTS idx_follow_source_post ON follow_source(post_id)")
DB.execute("CREATE TABLE IF NOT EXISTS post_viewers(post_id TEXT NOT NULL, user_id TEXT NOT NULL, PRIMARY KEY(post_id, user_id))")
DB.execute("CREATE TABLE IF NOT EXISTS post_views_day(post_id TEXT NOT NULL, day INTEGER NOT NULL, views INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(post_id, day))")
ensure_column("likes", "created_at", "created_at REAL NOT NULL DEFAULT 0")            # для колокольчика уведомлений
ensure_column("comment_likes", "created_at", "created_at REAL NOT NULL DEFAULT 0")
DB.execute("CREATE TABLE IF NOT EXISTS notif_state(user_id TEXT PRIMARY KEY, seen_at REAL NOT NULL)")
# записи гостей на стене: текст, фото или рисунок от руки
DB.execute("CREATE TABLE IF NOT EXISTS wall_entries(id TEXT PRIMARY KEY, owner TEXT NOT NULL, author TEXT NOT NULL, kind TEXT NOT NULL, "
           "text_enc BLOB, media_id TEXT, width INTEGER NOT NULL DEFAULT 0, height INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL)")
DB.execute("CREATE INDEX IF NOT EXISTS idx_wall_owner ON wall_entries(owner, created_at)")
DB.execute("CREATE INDEX IF NOT EXISTS idx_wall_author ON wall_entries(author, created_at)")
DB.execute("CREATE INDEX IF NOT EXISTS idx_posts_author ON posts(author, created_at)")
DB.execute("CREATE INDEX IF NOT EXISTS idx_comments_author ON comments(author)")
ensure_column("posts", "comments_off", "comments_off INTEGER NOT NULL DEFAULT 0")   # автор выключил комментарии
ensure_column("posts", "no_repost", "no_repost INTEGER NOT NULL DEFAULT 0")          # автор запретил репосты
DB.execute("CREATE INDEX IF NOT EXISTS idx_posts_repost ON posts(repost_of, author)")
DB.execute("CREATE TABLE IF NOT EXISTS post_saves(post_id TEXT NOT NULL, user_id TEXT NOT NULL, created_at REAL NOT NULL, "
           "PRIMARY KEY(post_id, user_id))")
DB.execute("CREATE INDEX IF NOT EXISTS idx_saves_user ON post_saves(user_id)")
# жалобы на публикации: одна от человека на публикацию (повторная обновляет причину)
DB.execute("CREATE TABLE IF NOT EXISTS post_reports(post_id TEXT NOT NULL, reporter TEXT NOT NULL, reason TEXT NOT NULL, "
           "created_at REAL NOT NULL, PRIMARY KEY(post_id, reporter))")
# индексы под самые частые выборки (лента «для вас», непрочитанные, скрытые сообщения групп)
DB.execute("CREATE INDEX IF NOT EXISTS idx_likes_user ON likes(user_id)")
DB.execute("CREATE INDEX IF NOT EXISTS idx_posts_reel ON posts(reel, created_at DESC)")
DB.execute("CREATE INDEX IF NOT EXISTS idx_msg_recipient ON messages(recipient, sender, created_at)")
DB.execute("CREATE INDEX IF NOT EXISTS idx_gm_sender ON group_messages(group_id, sender, created_at)")
ensure_column("messages", "attachments_enc", "attachments_enc BLOB")
ensure_column("users", "style_enc", "style_enc BLOB")
ensure_column("users", "phone_idx", "phone_idx TEXT")
DB.execute("CREATE INDEX IF NOT EXISTS idx_users_phone ON users(phone_idx)")
ensure_column("users", "status_emoji_enc", "status_emoji_enc BLOB")   # эмодзи-статус рядом с именем
ensure_column("users", "pw_salt", "pw_salt BLOB")          # облачный пароль (2FA): соль, хэш и подсказка
ensure_column("users", "pw_hash_enc", "pw_hash_enc BLOB")
ensure_column("users", "pw_hint_enc", "pw_hint_enc BLOB")
ensure_column("users", "email_enc", "email_enc BLOB")      # почта восстановления
ensure_column("users", "settings_enc", "settings_enc BLOB")  # настройки приложения: при входе возвращаются как были
ensure_column("groups", "type", "type TEXT NOT NULL DEFAULT 'group'")
ensure_column("groups", "handle", "handle TEXT")
ensure_column("groups", "discussion", "discussion TEXT")             # чат для комментариев канала
ensure_column("group_messages", "mirror_of", "mirror_of TEXT")        # копия поста канала в чате обсуждения
DB.execute("CREATE INDEX IF NOT EXISTS idx_gm_mirror ON group_messages(mirror_of)")
DB.execute("CREATE INDEX IF NOT EXISTS idx_gm_reply ON group_messages(reply_to)")
ensure_column("groups", "approve", "approve INTEGER NOT NULL DEFAULT 0")
ensure_column("groups", "no_forward", "no_forward INTEGER NOT NULL DEFAULT 0")
ensure_column("groups", "slow", "slow INTEGER NOT NULL DEFAULT 0")
ensure_column("groups", "who_writes", "who_writes TEXT NOT NULL DEFAULT 'all'")
ensure_column("groups", "history", "history INTEGER NOT NULL DEFAULT 1")
ensure_column("group_members", "muted", "muted INTEGER NOT NULL DEFAULT 0")
DB.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_group_handle ON groups(handle)")


# ---------- утилиты ----------

def u16len(s):
    """Длина строки в UTF-16 единицах (так считает iOS)"""
    return len(s.encode("utf-16-le")) // 2


def token_hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


# Кэш в пределах одного запроса (на поток): одни и те же блокировки, приватность и имена в контактах
# в списках читались десятки раз. Любая запись через run() сбрасывает его, так что устаревших данных нет.
_RC = threading.local()


def rcache():
    d = getattr(_RC, "d", None)
    if d is None:
        d = _RC.d = {}
    return d


def rcache_clear():
    _RC.d = {}


def q(sql, args=()):
    with LOCK:
        if sql[:6] not in ("SELECT", "select"):
            _RC.d = {}
        return DB.execute(sql, args).fetchall()


def q1(sql, args=()):
    with LOCK:
        if sql[:6] not in ("SELECT", "select"):
            _RC.d = {}
        return DB.execute(sql, args).fetchone()


def run(sql, args=()):
    with LOCK:
        _RC.d = {}
        return DB.execute(sql, args)


# ---------- шифрование полей ----------

def enc(uid, scope, column, rid, text):
    """Шифрует поле ключом категории пользователя uid"""
    return seal(KR.scope_key(uid, scope), text.encode("utf-8"), field_aad(column, rid))


def dec(uid, scope, column, rid, blob):
    if blob is None:
        return None
    try:
        return unseal(KR.scope_key(uid, scope), blob, field_aad(column, rid)).decode("utf-8")
    except Exception:
        return None


def dec_profile(row, column_name, col):
    return dec(row["id"], "profile", col, row["id"], row[column_name])


def media_key(owner, media_id):
    return file_key(KR.scope_key(owner, "media"), media_id)


def clean_entities(raw, text):
    out = []
    if not isinstance(raw, list):
        return out
    total = u16len(text)
    for e in raw[:300]:
        if not isinstance(e, dict):
            continue
        t, o, l = e.get("type"), e.get("offset"), e.get("length")
        if t not in ENTITY_TYPES or not isinstance(o, int) or not isinstance(l, int):
            continue
        if o < 0 or l <= 0 or o + l > total:
            continue
        item = {"type": t, "offset": o, "length": l}
        if t == "link":
            url = str(e.get("url", ""))[:500]
            if not re.match(r"^https?://", url, re.I):
                continue
            item["url"] = url
        out.append(item)
    return out


def names(r):
    first = dec_profile(r, "name_enc", COL["name"]) or "—"
    last = dec_profile(r, "last_name_enc", COL["last_name"]) or ""
    return first, last, (first + " " + last).strip()


def avatar_list(uid):
    return [{"id": a["id"], "media": a["media_id"], "created_at": a["created_at"]}
            for a in q("SELECT * FROM avatars WHERE user_id = ? ORDER BY position", (uid,))]


def sync_avatar(uid):
    first = q1("SELECT media_id FROM avatars WHERE user_id = ? ORDER BY position LIMIT 1", (uid,))
    run("UPDATE users SET avatar = ? WHERE id = ?", (first["media_id"] if first else None, uid))


def is_blocked(by, target):
    """by заблокировал target"""
    if not (by and target):
        return False
    c = rcache()
    k = ("blk", by, target)
    v = c.get(k)
    if v is None:
        v = c[k] = q1("SELECT 1 FROM blocks WHERE user_id = ? AND blocked_id = ?", (by, target)) is not None
    return v


def either_blocked(a, b):
    return is_blocked(a, b) or is_blocked(b, a)


def privacy_of(r):
    c = rcache()
    k = ("prv", r["id"])
    v = c.get(k)
    if v is None:
        v = c[k] = _privacy_of(r)
    return v


def _privacy_of(r):
    """Настройки видимости владельца r: телефон и комментарии лежат в своих колонках, остальное — JSON"""
    stored = {}
    if r["privacy_enc"]:
        try:
            stored = json.loads(dec(r["id"], "profile", COL["privacy"], r["id"], r["privacy_enc"]) or "{}")
        except ValueError:
            stored = {}
    out = {**PRIVACY_DEFAULTS, **{k: v for k, v in stored.items() if k in PRIVACY_DEFAULTS and v in ("all", "contacts", "nobody")}}
    out["phone"] = r["phone_visibility"]
    out["comments"] = r["comments_policy"]
    return out


def can_see(r, viewer, key):
    """Видит ли viewer поле key профиля r"""
    if viewer == r["id"]:
        return True
    if is_blocked(r["id"], viewer):
        return False
    return policy_allows(r, viewer, privacy_of(r).get(key, "all"))


def policy_allows(owner, viewer, value):
    """«all» — все, «contacts» — только те, кого владелец сохранил в контактах, «nobody» — никто"""
    if value == "all":
        return True
    if value == "contacts" and viewer:
        c = rcache()
        k = ("ctc", owner["id"], viewer)
        v = c.get(k)
        if v is None:
            v = c[k] = q1("SELECT 1 FROM contacts WHERE user_id = ? AND contact_id = ?", (owner["id"], viewer)) is not None
        return v
    return False


def contact_name(viewer, uid):
    """Имя, под которым viewer сохранил человека в контактах (или None)"""
    if not viewer or viewer == uid:
        return None
    cc = rcache()
    k = ("cn", viewer, uid)
    if k in cc:
        return cc[k]
    c = q1("SELECT name_enc FROM contacts WHERE user_id = ? AND contact_id = ?", (viewer, uid))
    v = cc[k] = dec(viewer, "contacts", COL["contact_name"], viewer + ":" + uid, c["name_enc"]) if c else None
    return v


def user_brief(uid, viewer=None, row=None):
    if row is None:
        c = rcache()
        r = c.get(("usr", uid))
        if r is None:
            r = q1("SELECT * FROM users WHERE id = ?", (uid,))
            if r:
                c[("usr", uid)] = r
    else:
        r = row
    if not r:
        return {"id": uid, "name": "—", "username": None, "avatar": None}
    shown = viewer is None or can_see(r, viewer, "photos")
    return {"id": r["id"], "name": contact_name(viewer, uid) or names(r)[2],
            "username": dec_profile(r, "username_enc", COL["username"]), "avatar": r["avatar"] if shown else None}


def track_json(t):
    uid = t["user_id"]
    return {"id": t["id"], "media": t["media_id"], "duration": t["duration"] or 0,
            "title": dec(uid, "profile", COL["track_title"], t["id"], t["title_enc"]) or "",
            "artist": dec(uid, "profile", COL["track_artist"], t["id"], t["artist_enc"]) or "",
            "cover": (t["cover"] if "cover" in t.keys() else None) or None}


def tracks_of(uid):
    return [track_json(t) for t in q("SELECT * FROM tracks WHERE user_id = ? ORDER BY position", (uid,))]


def style_of(r):
    """Цвет профиля (0–15) и фоновый эмодзи — видны всем"""
    try:
        raw = dec(r["id"], "profile", COL["style"], r["id"], r["style_enc"]) if r["style_enc"] else None
        d = json.loads(raw) if raw else {}
    except ValueError:
        d = {}
    return {"color": d.get("color"), "emoji": d.get("emoji")}


def friend_state(me_id, uid):
    """none | friends | outgoing (я отправил заявку) | incoming (мне отправили)"""
    if q1("SELECT 1 FROM friends WHERE a = ? AND b = ?", (me_id, uid)):
        return "friends"
    if q1("SELECT 1 FROM friend_requests WHERE from_id = ? AND to_id = ?", (me_id, uid)):
        return "outgoing"
    if q1("SELECT 1 FROM friend_requests WHERE from_id = ? AND to_id = ?", (uid, me_id)):
        return "incoming"
    return "none"


def is_following(me_id, uid):
    return bool(me_id) and bool(q1("SELECT 1 FROM follows WHERE follower = ? AND followee = ?", (me_id, uid))
                                or q1("SELECT 1 FROM friends WHERE a = ? AND b = ?", (me_id, uid)))


def followers_count(uid):
    return q1("SELECT COUNT(*) c FROM (SELECT follower f FROM follows WHERE followee = ? "
              "UNION SELECT a f FROM friends WHERE b = ?)", (uid, uid))["c"]


_orbit_cache = {}


def orbit_of(r, viewer):
    """Лучшие друзья: с кем человек переписывался больше всего за последние 90 дней (кружат вокруг аватарки).
    Показываются, только если владелец включил «Отображение лучших друзей». Кэш на 5 минут"""
    uid = r["id"]
    hit = _orbit_cache.get(uid)
    if not hit or time.time() - hit[0] > 300:
        since = time.time() - 90 * 86400
        rows = q("SELECT other, COUNT(*) c FROM ("
                 "SELECT recipient other FROM messages WHERE sender = ? AND created_at > ? AND recipient <> sender "
                 "UNION ALL SELECT sender other FROM messages WHERE recipient = ? AND created_at > ? AND recipient <> sender"
                 ") GROUP BY other ORDER BY c DESC LIMIT 14", (uid, since, uid, since))
        hit = (time.time(), [x["other"] for x in rows])
        _orbit_cache[uid] = hit
    out = []
    for oid in hit[1]:
        if viewer != oid and either_blocked(uid, oid) or (viewer and either_blocked(viewer, oid)):
            continue
        o = q1("SELECT * FROM users WHERE id = ?", (oid,))
        if not o:
            continue
        out.append({"id": oid, "name": names(o)[2],
                    "avatar": o["avatar"] if can_see(o, viewer, "photos") else None})
        if len(out) >= 6:
            break
    return out


def profile_json(r, me_id=None):
    uid = r["id"]
    own = me_id == uid
    pv = privacy_of(r)
    first, last, full = names(r)

    def vis(key):
        return can_see(r, me_id, key)

    last_seen = q1("SELECT MAX(last_active) m FROM sessions WHERE user_id = ?", (uid,))["m"]
    track = q1("SELECT * FROM tracks WHERE user_id = ? ORDER BY position LIMIT 1", (uid,)) if vis("music") else None
    wall_ok = vis("wall")
    out = {
        "id": uid, "name": full, "first_name": first, "last_name": last,
        "birthday": dec_profile(r, "birthday_enc", COL["birthday"]) if vis("birthday") else None,
        "avatars": avatar_list(uid) if vis("photos") else [],
        "username": dec_profile(r, "username_enc", COL["username"]),
        "bio": (dec_profile(r, "bio_enc", COL["bio"]) or "") if vis("bio") else "",
        "avatar": r["avatar"] if vis("photos") else None,
        "phone": dec_profile(r, "phone_enc", COL["phone"]) if vis("phone") else None,
        "last_seen": last_seen if vis("last_seen") else None,
        "wall_private": not wall_ok,
        "posts_count": q1("SELECT COUNT(*) c FROM posts WHERE author = ?", (uid,))["c"] if wall_ok else None,
        "track": track_json(track) if track else None,
        "listening": (own or vis("music")) and is_listening(uid),
        "tracks_count": q1("SELECT COUNT(*) c FROM tracks WHERE user_id = ?", (uid,))["c"] if vis("music") else 0,
        "phone_visibility": pv["phone"] if own else None,
        "comments_policy": pv["comments"] if own else None,
        "privacy": pv if own else None,
        "orbit": orbit_of(r, me_id) if pv.get("orbit") == "all" else [],
        "blocked_by_me": (not own) and is_blocked(me_id, uid),
        "blocked_me": (not own) and is_blocked(uid, me_id),
        "style": style_of(r),
        "status_emoji": dec(uid, "profile", "users.status_emoji", uid, r["status_emoji_enc"]) if r["status_emoji_enc"] else None,
        "contact_name": contact_name(me_id, uid),
        "is_contact": bool(contact_name(me_id, uid)),
        "friend_state": friend_state(me_id, uid) if me_id and not own else "none",
        "friends_count": q1("SELECT COUNT(*) c FROM friends WHERE a = ?", (uid,))["c"],
        "followers_count": followers_count(uid) if (own or vis("followers")) else None,
        "following": (not own) and is_following(me_id, uid),
        "requests_count": q1("SELECT COUNT(*) c FROM friend_requests WHERE to_id = ?", (uid,))["c"] if own else None,
    }
    return out


def media_json(m):
    return {"id": m["media_id"], "kind": m["kind"], "width": m["width"], "height": m["height"],
            "duration": m["duration"], "thumb": m["thumb"]}


def music_of(p):
    raw = dec(p["author"], "posts", COL["post_music"], p["id"], p["music_enc"]) if p["music_enc"] else None
    try:
        return json.loads(raw) if raw else None
    except ValueError:
        return None


def music_key(title, artist):
    """Один и тот же трек у разных людей (разные загрузки файла) узнаётся по «исполнитель|название»"""
    return ((artist or "").strip().lower() + "|" + (title or "").strip().lower())[:300]


def _backfill_music_keys():
    for p in q("SELECT * FROM posts WHERE music_enc IS NOT NULL AND music_key IS NULL"):
        m = music_of(p)
        if m:
            run("UPDATE posts SET music_media = ?, music_key = ? WHERE id = ?",
                (str(m.get("media", "")), music_key(m.get("title"), m.get("artist")), p["id"]))


_backfill_music_keys()
DB.execute("CREATE INDEX IF NOT EXISTS idx_posts_music ON posts(music_key, reel)")


def origin_brief(p, me_id):
    """У репост-копии — карточка автора оригинала (чтобы вести на профиль создателя), иначе None"""
    if not p["repost_of"]:
        return None
    o = q1("SELECT author FROM posts WHERE id = ?", (p["repost_of"],))
    return user_brief(o["author"], me_id) if o else None


def friend_reposters(me_id, bases):
    """Кто из друзей сделал репост этих публикаций: {оригинал: [краткие карточки друзей]}, до 8 на публикацию"""
    bases = list(set(bases))
    if not bases or not me_id:
        return {}
    marks = ",".join("?" * len(bases))
    rows = q("SELECT r.repost_of AS base, r.author AS who FROM posts r "
             "JOIN friends f ON f.a = ? AND f.b = r.author "
             "WHERE r.repost_of IN (%s) AND r.author != ? ORDER BY r.created_at DESC" % marks, [me_id] + bases + [me_id])
    out = {}
    for r in rows:
        lst = out.setdefault(r["base"], [])
        if len(lst) < 8:
            lst.append(user_brief(r["who"], me_id))
    return out


def post_json(p, me_id):
    pid, author = p["id"], p["author"]
    media = [media_json(m) for m in q("SELECT * FROM post_media WHERE post_id = ? ORDER BY position", (pid,))]
    likes = p["likes_seed"] + q1("SELECT COUNT(*) c FROM likes WHERE post_id = ?", (pid,))["c"]
    liked = q1("SELECT 1 FROM likes WHERE post_id = ? AND user_id = ?", (pid, me_id)) is not None
    comments = q1("SELECT COUNT(*) c FROM comments WHERE post_id = ?", (pid,))["c"]
    saves = q1("SELECT COUNT(*) c FROM post_saves WHERE post_id = ?", (pid,))["c"]
    saved = q1("SELECT 1 FROM post_saves WHERE post_id = ? AND user_id = ?", (pid, me_id)) is not None
    owner = q1("SELECT * FROM users WHERE id = ?", (author,))
    base = p["repost_of"] or pid                     # у копии-репоста счётчик и «я репостнул» считаются по оригиналу
    reposts = q1("SELECT COUNT(*) c FROM posts WHERE repost_of = ?", (base,))["c"]
    reposted = q1("SELECT 1 FROM posts WHERE repost_of = ? AND author = ?", (base, me_id)) is not None
    return {
        "reposts": reposts, "reposted_by_me": reposted, "is_repost": bool(p["repost_of"]), "music": music_of(p),
        "repost_friends": friend_reposters(me_id, [base]).get(base, []), "origin": origin_brief(p, me_id),
        "saves": saves, "saved_by_me": saved, "reel": bool(p["reel"]),
        "id": pid, "author": user_brief(author, me_id),
        "text": dec(author, "posts", COL["post_text"], pid, p["text_enc"]) or "",
        "entities": json.loads(dec(author, "posts", COL["post_entities"], pid, p["entities_enc"]) or "[]"),
        "media": media, "created_at": p["created_at"], "likes": likes, "liked_by_me": liked,
        "views": (q1("SELECT views FROM post_stats WHERE post_id = ?", (pid,)) or {"views": 0})["views"],
        "comments": comments, "mine": author == me_id, "edited_at": p["edited_at"],
        "comments_enabled": (not p["comments_off"]) and ((author == me_id or policy_allows(owner, me_id, owner["comments_policy"])) if owner else True),
        "allow_repost": not p["no_repost"],
    }


def _in(ids):
    return ",".join("?" * len(ids))


def posts_json(rows, me_id):
    """Те же объекты, что и post_json, но счётчики, медиа и авторы берутся пакетными запросами (без N+1)"""
    rows = list(rows)
    if not rows:
        return []
    ids = [p["id"] for p in rows]
    authors = list({p["author"] for p in rows})
    marks = _in(ids)
    media, likes, liked, comments, saves, saved = {}, {}, set(), {}, {}, set()
    reposts, reposted, views = {}, set(), {}
    with LOCK:
        for r in DB.execute("SELECT post_id, views FROM post_stats WHERE post_id IN (%s)" % marks, ids):
            views[r["post_id"]] = r["views"]
        for m in DB.execute("SELECT * FROM post_media WHERE post_id IN (%s) ORDER BY position" % marks, ids):
            media.setdefault(m["post_id"], []).append(media_json(m))
        for r in DB.execute("SELECT post_id, COUNT(*) c FROM likes WHERE post_id IN (%s) GROUP BY post_id" % marks, ids):
            likes[r["post_id"]] = r["c"]
        for r in DB.execute("SELECT post_id FROM likes WHERE user_id = ? AND post_id IN (%s)" % marks, [me_id] + ids):
            liked.add(r["post_id"])
        for r in DB.execute("SELECT post_id, COUNT(*) c FROM comments WHERE post_id IN (%s) GROUP BY post_id" % marks, ids):
            comments[r["post_id"]] = r["c"]
        for r in DB.execute("SELECT post_id, COUNT(*) c FROM post_saves WHERE post_id IN (%s) GROUP BY post_id" % marks, ids):
            saves[r["post_id"]] = r["c"]
        for r in DB.execute("SELECT post_id FROM post_saves WHERE user_id = ? AND post_id IN (%s)" % marks, [me_id] + ids):
            saved.add(r["post_id"])
        bases = list({p["repost_of"] or p["id"] for p in rows})
        bmarks = _in(bases)
        for r in DB.execute("SELECT repost_of, COUNT(*) c FROM posts WHERE repost_of IN (%s) GROUP BY repost_of" % bmarks, bases):
            reposts[r["repost_of"]] = r["c"]
        for r in DB.execute("SELECT repost_of FROM posts WHERE author = ? AND repost_of IN (%s)" % bmarks, [me_id] + bases):
            reposted.add(r["repost_of"])
        owners = {u["id"]: u for u in DB.execute("SELECT * FROM users WHERE id IN (%s)" % _in(authors), authors)}
    briefs = {a: user_brief(a, me_id, owners.get(a)) for a in authors}
    rfriends = friend_reposters(me_id, [p["repost_of"] or p["id"] for p in rows])
    out = []
    for p in rows:
        pid, author = p["id"], p["author"]
        owner = owners.get(author)
        out.append({
            "repost_friends": rfriends.get(p["repost_of"] or pid, []), "origin": origin_brief(p, me_id),
            "reposts": reposts.get(p["repost_of"] or pid, 0), "reposted_by_me": (p["repost_of"] or pid) in reposted, "is_repost": bool(p["repost_of"]), "music": music_of(p),
            "saves": saves.get(pid, 0), "saved_by_me": pid in saved, "reel": bool(p["reel"]),
            "id": pid, "author": briefs[author],
            "text": dec(author, "posts", COL["post_text"], pid, p["text_enc"]) or "",
            "entities": json.loads(dec(author, "posts", COL["post_entities"], pid, p["entities_enc"]) or "[]"),
            "media": media.get(pid, []), "created_at": p["created_at"],
            "likes": p["likes_seed"] + likes.get(pid, 0), "liked_by_me": pid in liked, "views": views.get(pid, 0),
            "comments": comments.get(pid, 0), "mine": author == me_id, "edited_at": p["edited_at"],
            "comments_enabled": (not p["comments_off"]) and ((author == me_id or policy_allows(owner, me_id, owner["comments_policy"])) if owner else True),
            "allow_repost": not p["no_repost"],
        })
    return out


# ---------- сеансы ----------

def clean_info(d, ip):
    def field(key, limit=60):
        return " ".join(str(d.get(key, "") or "").split())[:limit]
    return {"device": field("device") or "Unknown device", "system": field("system"), "app": field("app"), "ip": ip}


SESSION_IDLE_DAYS = 30


def new_session(uid, info):
    token = secrets.token_urlsafe(32)
    sid = uuid.uuid4().hex
    now = time.time()
    # сеансы, которыми не пользовались 30 дней, завершаются сами
    run("DELETE FROM sessions WHERE last_active < ? AND id NOT IN (SELECT id FROM sessions WHERE user_id = ? ORDER BY last_active DESC LIMIT 1)",
        (now - SESSION_IDLE_DAYS * 86400, uid))
    run("INSERT INTO sessions(id, user_id, token_hash, info_enc, created_at, last_active) VALUES (?,?,?,?,?,?)",
        (sid, uid, token_hash(token),
         enc(uid, "profile", COL["session"], sid, json.dumps(info, ensure_ascii=False)), now, now))
    return token, sid


def migrate_legacy():
    """Прежняя версия хранила один токен на пользователя — превращаем его в сеанс; аватар — в галерею"""
    now = time.time()
    for u in q("SELECT id, token_hash FROM users WHERE id NOT LIKE 'demo-%' AND token_hash NOT IN (SELECT token_hash FROM sessions)"):
        sid = uuid.uuid4().hex
        info = json.dumps({"device": "Unknown device", "system": "", "app": "", "ip": ""})
        run("INSERT INTO sessions(id, user_id, token_hash, info_enc, created_at, last_active) VALUES (?,?,?,?,?,?)",
            (sid, u["id"], u["token_hash"], enc(u["id"], "profile", COL["session"], sid, info), now, now))
    for u in q("SELECT id, avatar FROM users WHERE avatar IS NOT NULL AND id NOT IN (SELECT user_id FROM avatars)"):
        m = q1("SELECT created_at FROM media WHERE id = ?", (u["avatar"],))
        run("INSERT INTO avatars(id, user_id, media_id, position, created_at) VALUES (?,?,?,?,?)",
            (uuid.uuid4().hex, u["id"], u["avatar"], 0, m["created_at"] if m else now))


migrate_legacy()


def reindex_username(uid, username):
    """Индекс префиксов @username для подсказок «похожие». Хранятся только слепые хэши, не сам ник"""
    run("DELETE FROM username_prefix WHERE user_id = ?", (uid,))
    u = (username or "").lower()
    for n in range(2, min(len(u), 32) + 1):
        run("INSERT OR IGNORE INTO username_prefix(prefix_idx, user_id) VALUES (?,?)",
            (KR.blind_index(u[:n], "uprefix"), uid))


def backfill_username_prefixes():
    for r in q("SELECT * FROM users WHERE username_enc IS NOT NULL AND id NOT IN (SELECT user_id FROM username_prefix)"):
        try:
            reindex_username(r["id"], dec_profile(r, "username_enc", COL["username"]))
        except Exception:
            pass


backfill_username_prefixes()

QR_PENDING = {}
QR_LOCK = threading.Lock()


def valid_birthday(value):
    m = re.match(r"^(?:(\d{4})-|--)(\d{2})-(\d{2})$", value)
    if not m:
        return False
    y, mo, d = m.groups()
    today = datetime.date.today()
    try:
        if y is None:
            datetime.date(2000, int(mo), int(d))        # 2000 — високосный: 29 февраля допустимо
            return True
        date = datetime.date(int(y), int(mo), int(d))
    except ValueError:
        return False
    return 1900 <= date.year and date <= today


# ---------- маршрутизация ----------

ROUTES = []


def route(method, pattern, auth=True):
    def deco(fn):
        ROUTES.append((method, re.compile("^" + pattern + "$"), fn, auth))
        return fn
    return deco


DB_PATH = os.path.join(DATA_DIR, "orbita-v2.db")
_warned = [False]


def data_intact():
    """Папку data удалили, пока сервер работал: база и файлы уже не те, нужен перезапуск"""
    if os.path.exists(DB_PATH):
        os.makedirs(MEDIA_DIR, exist_ok=True)
        return True
    if not _warned[0]:
        _warned[0] = True
        print("\n!!! Папка data была удалена при работающем сервере — перезапускаюсь сам и создаю базу заново.\n")
        # без этого сервер навсегда отвечал бы «data_lost»: перезапускаем процесс на месте
        t = threading.Timer(1.0, lambda: os.execv(sys.executable, [sys.executable] + sys.argv))
        t.daemon = True
        t.start()
    return False


class ApiError(Exception):
    def __init__(self, status, code, **extra):
        self.status, self.code, self.extra = status, code, extra


# Кэш ответов на частые опросы (список чатов, ленты): ключ включает счётчик собственных изменений пользователя,
# поэтому его же действия видны сразу, а чужие — не позже чем через TTL секунд.
RESP_CACHE = {}
UVER = {}


def cache_ttl(path, params):
    if path == "/v1/chats":
        return 1.5
    if path == "/v1/posts":
        return 8.0 if params.get("sort") == "for_you" else 3.0
    if path == "/v1/reels":
        return 8.0
    return 0


class Handler(BaseHTTPRequestHandler):
    server_version = "Orbita/2.0"
    protocol_version = "HTTP/1.1"
    timeout = 75                            # молчащее keep-alive соединение закрывается, поток не висит вечно
    disable_nagle_algorithm = True          # маленькие ответы уходят сразу, без задержки ~40 мс

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def send_json(self, status, obj):
        body = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode()
        key = getattr(self, "_cache_key", None)
        if key is not None and status == 200:
            self._cache_key = None
            if len(RESP_CACHE) > 3000:
                RESP_CACHE.clear()
            RESP_CACHE[key[0]] = [time.time() + key[1], body, None]
        self._write_json(status, body)

    def _write_json(self, status, body, gz=None):
        gzipped = False
        # большие ответы (лента, переписка) сжимаем: на мобильной сети это в разы быстрее
        if len(body) > 1200 and "gzip" in (self.headers.get("Accept-Encoding") or ""):
            body = gz if gz is not None else gzip.compress(body, compresslevel=4)
            gzipped = True
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        if gzipped:
            self.send_header("Content-Encoding", "gzip")
            self.send_header("Vary", "Accept-Encoding")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body_json(self):
        cached = getattr(self, "_body_cache", None)
        if cached is not None:
            return cached
        length = int(self.headers.get("Content-Length") or 0)
        if length > 2_000_000:
            raise ApiError(413, "too_large")
        raw = self.rfile.read(length) if length else b"{}"
        try:
            data = json.loads(raw or b"{}")
        except ValueError:
            raise ApiError(400, "bad_json")
        if not isinstance(data, dict):
            raise ApiError(400, "bad_json")
        self._body_cache = data
        return data

    def query(self):
        return {k: v[0] for k, v in parse_qs(urlparse(self.path).query).items()}

    def client_ip(self):
        forwarded = self.headers.get("X-Forwarded-For", "").split(",")[0].strip()
        return (forwarded or self.client_address[0])[:45]

    def current_user(self):
        header = self.headers.get("Authorization", "")
        if not header.startswith("Bearer "):
            return None
        r = q1("SELECT u.*, s.id AS session_id, s.last_active AS session_last FROM sessions s "
               "JOIN users u ON u.id = s.user_id WHERE s.token_hash = ?", (token_hash(header[7:].strip()),))
        if r and time.time() - r["session_last"] > 60:
            run("UPDATE sessions SET last_active = ? WHERE id = ?", (time.time(), r["session_id"]))
        return r

    def dispatch(self, method):
        path = urlparse(self.path).path
        self._cache_key = None
        rcache_clear()
        self._body_cache = None          # тело запроса кэшируется только в пределах одного запроса, а не всего соединения
        try:
            if path != "/v1/ping" and not data_intact():
                self.drain()
                raise ApiError(503, "data_lost")
            for m, regex, fn, needs_auth in ROUTES:
                match = regex.match(path)
                if m == method and match:
                    me = self.current_user()
                    if needs_auth and not me:
                        self.drain()
                        raise ApiError(401, "unauthorized")
                    if me and method != "GET":
                        UVER[me["id"]] = UVER.get(me["id"], 0) + 1       # свои изменения сразу сбрасывают кэш
                    elif me and method == "GET":
                        ttl = cache_ttl(path, self.query())
                        if ttl:
                            ck = (me["id"], UVER.get(me["id"], 0), self.path)
                            hit = RESP_CACHE.get(ck)
                            if hit and hit[0] > time.time():
                                if hit[2] is None and len(hit[1]) > 1200 and "gzip" in (self.headers.get("Accept-Encoding") or ""):
                                    hit[2] = gzip.compress(hit[1], compresslevel=4)
                                return self._write_json(200, hit[1], hit[2])
                            self._cache_key = (ck, ttl)
                    return fn(self, me, *match.groups())
            self.drain()
            raise ApiError(404, "not_found")
        except ApiError as e:
            self.close_connection = self.close_connection or e.status in (413,)
            self.send_json(e.status, {"error": e.code, **e.extra})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as e:  # noqa
            sys.stderr.write("ERROR %r\n" % (e,))
            self.close_connection = True          # тело запроса могло остаться непрочитанным — не склеиваем запросы
            try:
                self.send_json(500, {"error": "server_error"})
            except OSError:
                pass

    def drain(self):
        length = int(self.headers.get("Content-Length") or 0)
        if 0 < length <= 5_000_000:
            self.rfile.read(length)
        elif length > 5_000_000:
            self.close_connection = True

    def do_GET(self): self.dispatch("GET")
    def do_POST(self): self.dispatch("POST")
    def do_PUT(self): self.dispatch("PUT")
    def do_DELETE(self): self.dispatch("DELETE")


# ---------- сервис и профиль ----------

@route("GET", r"/v1/ping", auth=False)
def ping(req, me):
    req.send_json(200, {"ok": True, "name": "Orbita Server", "version": 5, "push": push.configured(), "otp": {"sms": otp.configured("sms"), "email": otp.configured("email"), "dev": OTP_DEV}, "encrypted": True})


@route("POST", r"/v1/session", auth=False)
def create_session(req, me):
    data = req.body_json()
    try:
        uid = str(uuid.UUID(str(data.get("user_id", "")))).lower()
    except ValueError:
        raise ApiError(400, "bad_user_id")
    name = " ".join(str(data.get("name", "")).split())
    if not 1 <= len(name) <= 40:
        raise ApiError(400, "name_invalid")
    if q1("SELECT 1 FROM users WHERE id = ?", (uid,)):
        raise ApiError(409, "user_exists")
    run("INSERT INTO users(id, token_hash, name_enc, created_at) VALUES (?, ?, ?, ?)",
        (uid, secrets.token_hex(32), enc(uid, "profile", COL["name"], uid, name), time.time()))
    token, _ = new_session(uid, clean_info(data, req.client_ip()))
    req.send_json(201, {"token": token, "profile": profile_json(q1("SELECT * FROM users WHERE id = ?", (uid,)), uid)})


@route("GET", r"/v1/me")
def get_me(req, me):
    req.send_json(200, profile_json(me, me["id"]))


@route("PUT", r"/v1/me")
def update_me(req, me):
    d = req.body_json()
    uid = me["id"]
    fields = {}
    if "name" in d or "first_name" in d:
        name = " ".join(str(d.get("first_name", d.get("name"))).split())
        if not 1 <= len(name) <= 40:
            raise ApiError(400, "name_invalid")
        fields["name_enc"] = enc(uid, "profile", COL["name"], uid, name)
    if "last_name" in d:
        last = " ".join(str(d["last_name"] or "").split())
        if len(last) > 40:
            raise ApiError(400, "name_invalid")
        fields["last_name_enc"] = enc(uid, "profile", COL["last_name"], uid, last) if last else None
    if "birthday" in d:
        b = str(d["birthday"] or "").strip()
        if b and not valid_birthday(b):
            raise ApiError(400, "birthday_invalid")
        fields["birthday_enc"] = enc(uid, "profile", COL["birthday"], uid, b) if b else None
    if "username" in d:
        u = str(d["username"] or "").strip().lstrip("@")
        if u == "":
            fields["username_idx"] = None
            fields["username_enc"] = None
        else:
            if not USERNAME_RE.match(u):
                raise ApiError(400, "username_invalid")
            idx = KR.blind_index(u.lower(), "username")
            if q1("SELECT 1 FROM users WHERE username_idx = ? AND id <> ?", (idx, uid)):
                raise ApiError(409, "username_taken")
            fields["username_idx"] = idx
            fields["username_enc"] = enc(uid, "profile", COL["username"], uid, u)
    if "bio" in d:
        bio = str(d["bio"] or "").strip()
        if len(bio) > MAX_BIO:
            raise ApiError(400, "bio_too_long")
        fields["bio_enc"] = enc(uid, "profile", COL["bio"], uid, bio) if bio else None
    if "status_emoji" in d:
        em = str(d["status_emoji"] or "").strip()
        if len(em) > 12:
            raise ApiError(400, "bad_value")
        fields["status_emoji_enc"] = enc(uid, "profile", "users.status_emoji", uid, em) if em else None
    if isinstance(d.get("style"), dict):
        st = d["style"]
        color, emoji = st.get("color"), st.get("emoji")
        if color is not None and not (isinstance(color, int) and not isinstance(color, bool) and 0 <= color <= 31):
            raise ApiError(400, "bad_value")
        if emoji is not None:
            emoji = str(emoji).strip()
            if not emoji or len(emoji) > 8 or any(ord(ch) < 32 for ch in emoji):
                raise ApiError(400, "bad_value")
        fields["style_enc"] = (enc(uid, "profile", COL["style"], uid, json.dumps({"color": color, "emoji": emoji}))
                               if color is not None or emoji is not None else None)
    if isinstance(d.get("privacy"), dict):
        incoming = d["privacy"]
        stored = {k: v for k, v in privacy_of(me).items() if k in PRIVACY_DEFAULTS}
        for k, v in incoming.items():
            if k not in PRIVACY_KEYS or v not in ("all", "contacts", "nobody"):
                raise ApiError(400, "bad_value")
            if k == "phone":
                d["phone_visibility"] = v
            elif k == "comments":
                d["comments_policy"] = v
            else:
                stored[k] = v
        fields["privacy_enc"] = enc(uid, "profile", COL["privacy"], uid, json.dumps(stored))
    if "phone_visibility" in d:
        if d["phone_visibility"] not in ("all", "contacts", "nobody"):
            raise ApiError(400, "bad_value")
        fields["phone_visibility"] = d["phone_visibility"]
        if d["phone_visibility"] == "nobody":
            fields["phone_enc"] = None
    if d.get("phone"):
        ph = norm_phone(d["phone"])
        if ph:
            # индекс для поиска по номеру ставим всегда; сам номер храним только если его разрешено показывать
            fields["phone_idx"] = KR.blind_index(ph, "phone")
            if (fields.get("phone_visibility") or me["phone_visibility"]) != "nobody":
                fields["phone_enc"] = enc(uid, "profile", COL["phone"], uid, str(d["phone"])[:20])
    if "comments_policy" in d:
        if d["comments_policy"] not in ("all", "contacts", "nobody"):
            raise ApiError(400, "bad_value")
        fields["comments_policy"] = d["comments_policy"]
    if fields:
        sets = ", ".join("%s = ?" % k for k in fields)
        run("UPDATE users SET %s WHERE id = ?" % sets, (*fields.values(), uid))
    if "username_idx" in fields:
        reindex_username(uid, d.get("username") and str(d["username"]).strip().lstrip("@"))
    if "phone_idx" in fields or "privacy_enc" in fields:
        announce_join(uid)
    req.send_json(200, profile_json(q1("SELECT * FROM users WHERE id = ?", (uid,)), uid))


@route("DELETE", r"/v1/me")
def delete_me(req, me):
    for m in q("SELECT id FROM media WHERE owner = ?", (me["id"],)):
        try:
            os.remove(os.path.join(MEDIA_DIR, m["id"]))
        except OSError:
            pass
    run("DELETE FROM media WHERE owner = ?", (me["id"],))
    run("DELETE FROM likes WHERE user_id = ?", (me["id"],))
    run("DELETE FROM users WHERE id = ?", (me["id"],))
    req.send_json(200, {"ok": True})


@route("GET", r"/v1/username/check")
def username_check(req, me):
    u = req.query().get("u", "").strip().lstrip("@")
    valid = bool(USERNAME_RE.match(u))
    free = valid and not q1("SELECT 1 FROM users WHERE username_idx = ? AND id <> ?",
                            (KR.blind_index(u.lower(), "username"), me["id"]))
    req.send_json(200, {"valid": valid, "available": bool(free)})


@route("GET", r"/v1/users/([A-Za-z0-9_\-]+)")
def get_user(req, me, uid):
    r = q1("SELECT * FROM users WHERE id = ?", (uid,))
    if not r:
        raise ApiError(404, "not_found")
    req.send_json(200, profile_json(r, me["id"]))


@route("GET", r"/v1/lookup")
def lookup(req, me):
    u = req.query().get("u", "").strip().lstrip("@")
    r = q1("SELECT * FROM users WHERE username_idx = ?", (KR.blind_index(u.lower(), "username"),)) if u else None
    if not r:
        raise ApiError(404, "not_found")
    req.send_json(200, profile_json(r, me["id"]))


@route("GET", r"/v1/lookup_phone")
def lookup_phone(req, me):
    """Профиль по номеру из текста сообщения. Находится только тот, у кого включено «Найти меня по номеру»"""
    ph = norm_phone(req.query().get("p", ""))
    r = q1("SELECT * FROM users WHERE phone_idx = ? AND id <> ? ORDER BY created_at LIMIT 1",
           (KR.blind_index(ph, "phone"), me["id"])) if ph else None
    if not r or not findable(r) or either_blocked(me["id"], r["id"]):
        raise ApiError(404, "not_found")
    req.send_json(200, profile_json(r, me["id"]))


def friend_brief(uid, me_id):
    b = user_brief(uid, me_id)
    b["friend_state"] = friend_state(me_id, uid) if uid != me_id else "none"
    return b


@route("GET", r"/v1/users/([A-Za-z0-9_\-]+)/friends")
def user_friends(req, me, uid):
    if not q1("SELECT 1 FROM users WHERE id = ?", (uid,)):
        raise ApiError(404, "not_found")
    if uid != me["id"] and either_blocked(me["id"], uid):
        req.send_json(200, {"users": [], "count": 0})
        return
    rows = q("SELECT b FROM friends WHERE a = ? ORDER BY created_at DESC LIMIT 500", (uid,))
    users = [friend_brief(r["b"], me["id"]) for r in rows if not either_blocked(me["id"], r["b"])]
    req.send_json(200, {"users": users, "count": len(users)})


@route("GET", r"/v1/me/friend-requests")
def my_friend_requests(req, me):
    inc = q("SELECT from_id FROM friend_requests WHERE to_id = ? ORDER BY created_at DESC LIMIT 200", (me["id"],))
    out = q("SELECT to_id FROM friend_requests WHERE from_id = ? ORDER BY created_at DESC LIMIT 200", (me["id"],))
    req.send_json(200, {"incoming": [friend_brief(r["from_id"], me["id"]) for r in inc if not either_blocked(me["id"], r["from_id"])],
                        "outgoing": [friend_brief(r["to_id"], me["id"]) for r in out]})


@route("PUT", r"/v1/friends/([A-Za-z0-9_\-]+)")
def friend_add(req, me, uid):
    mid = me["id"]
    if uid == mid or not q1("SELECT 1 FROM users WHERE id = ?", (uid,)):
        raise ApiError(404, "not_found")
    if either_blocked(mid, uid):
        raise ApiError(403, "blocked")
    st = friend_state(mid, uid)
    now = time.time()
    if st == "none":
        run("INSERT OR IGNORE INTO friend_requests(from_id, to_id, created_at) VALUES (?,?,?)", (mid, uid, now))
        st = "outgoing"
    elif st == "incoming":                       # встречная заявка — становимся друзьями
        run("DELETE FROM friend_requests WHERE (from_id = ? AND to_id = ?) OR (from_id = ? AND to_id = ?)", (uid, mid, mid, uid))
        run("INSERT OR IGNORE INTO friends(a, b, created_at) VALUES (?,?,?)", (mid, uid, now))
        run("INSERT OR IGNORE INTO friends(a, b, created_at) VALUES (?,?,?)", (uid, mid, now))
        st = "friends"
    req.send_json(200, {"state": st})


@route("POST", r"/v1/follow/([A-Za-z0-9_\-]+)")
def follow_add(req, me, uid):
    mid = me["id"]
    if uid == mid or not q1("SELECT 1 FROM users WHERE id = ?", (uid,)):
        raise ApiError(404, "not_found")
    if either_blocked(mid, uid):
        raise ApiError(403, "blocked")
    fresh = q1("SELECT 1 FROM follows WHERE follower = ? AND followee = ?", (mid, uid)) is None
    run("INSERT OR IGNORE INTO follows(follower, followee, created_at) VALUES (?,?,?)", (mid, uid, time.time()))
    if fresh:
        # подписка сделана со страницы шортса — запоминаем, с какого именно видео (для статистики автора)
        src = str(req.body_json().get("post", "") or "")[:40]
        sp = q1("SELECT author FROM posts WHERE id = ?", (src,)) if src else None
        if sp and sp["author"] == uid:
            run("INSERT OR IGNORE INTO follow_source(follower, followee, post_id, created_at) VALUES (?,?,?,?)",
                (mid, uid, src, time.time()))
    req.send_json(200, {"following": True, "followers": followers_count(uid)})


@route("DELETE", r"/v1/follow/([A-Za-z0-9_\-]+)")
def follow_remove(req, me, uid):
    mid = me["id"]
    run("DELETE FROM follows WHERE follower = ? AND followee = ?", (mid, uid))
    # подписка через дружбу тоже снимается: убираем дружбу
    run("DELETE FROM friends WHERE a = ? AND b = ?", (mid, uid))
    run("DELETE FROM friends WHERE a = ? AND b = ?", (uid, mid))
    run("DELETE FROM friend_requests WHERE (from_id = ? AND to_id = ?) OR (from_id = ? AND to_id = ?)", (mid, uid, uid, mid))
    req.send_json(200, {"following": False, "followers": followers_count(uid)})


@route("DELETE", r"/v1/friends/([A-Za-z0-9_\-]+)")
def friend_remove(req, me, uid):
    mid = me["id"]
    run("DELETE FROM friends WHERE (a = ? AND b = ?) OR (a = ? AND b = ?)", (mid, uid, uid, mid))
    run("DELETE FROM friend_requests WHERE (from_id = ? AND to_id = ?) OR (from_id = ? AND to_id = ?)", (mid, uid, uid, mid))
    req.send_json(200, {"state": "none"})


@route("GET", r"/v1/search/users")
def search_users(req, me):
    """Подсказки по началу @username: @userna → @username, @username2 …"""
    u = req.query().get("q", "").strip().lstrip("@").lower()
    if not re.match(r"^[a-z0-9_]{2,32}$", u):
        req.send_json(200, {"users": []})
        return
    ids, seen = [], set()
    tries = [u] + ([u[:-1]] if len(u) >= 4 else [])        # вторая попытка — на случай опечатки в конце
    for t in tries:
        rows = q("SELECT p.user_id FROM username_prefix p JOIN users x ON x.id = p.user_id "
                 "WHERE p.prefix_idx = ? AND x.id <> ? LIMIT 60", (KR.blind_index(t, "uprefix"), me["id"]))
        found = []
        for r in rows:
            if r["user_id"] in seen or either_blocked(me["id"], r["user_id"]):
                continue
            row = q1("SELECT * FROM users WHERE id = ?", (r["user_id"],))
            nick = (dec_profile(row, "username_enc", COL["username"]) or "") if row else ""
            if nick:
                found.append((0 if nick.lower() == u else 1 if nick.lower().startswith(u) else 2, len(nick), nick, r["user_id"]))
        found.sort()
        for item in found:
            seen.add(item[3])
            ids.append(item[3])
        if len(ids) >= 8:
            break
    out = [profile_json(q1("SELECT * FROM users WHERE id = ?", (i,)), me["id"]) for i in ids[:8]]
    req.send_json(200, {"users": out})


# ---------- фотографии профиля ----------

@route("GET", r"/v1/users/([A-Za-z0-9_\-]+)/avatars")
def user_avatars(req, me, uid):
    if not q1("SELECT 1 FROM users WHERE id = ?", (uid,)):
        raise ApiError(404, "not_found")
    req.send_json(200, {"avatars": avatar_list(uid)})


def me_json(uid):
    return profile_json(q1("SELECT * FROM users WHERE id = ?", (uid,)), uid)


@route("POST", r"/v1/me/avatars")
def add_avatar(req, me):
    uid = me["id"]
    mid = str(req.body_json().get("media_id", ""))
    if not q1("SELECT 1 FROM media WHERE id = ? AND owner = ? AND kind = 'image'", (mid, uid)):
        raise ApiError(400, "media_not_found")
    if q1("SELECT 1 FROM avatars WHERE user_id = ? AND media_id = ?", (uid, mid)):
        raise ApiError(409, "already_added")
    if q1("SELECT COUNT(*) c FROM avatars WHERE user_id = ?", (uid,))["c"] >= MAX_AVATARS:
        raise ApiError(400, "too_many_avatars")
    low = q1("SELECT MIN(position) m FROM avatars WHERE user_id = ?", (uid,))["m"]
    run("INSERT INTO avatars(id, user_id, media_id, position, created_at) VALUES (?,?,?,?,?)",
        (uuid.uuid4().hex, uid, mid, (low if low is not None else 1) - 1, time.time()))
    sync_avatar(uid)
    req.send_json(201, me_json(uid))


@route("PUT", r"/v1/me/avatars/order")
def order_avatars(req, me):
    uid = me["id"]
    ids = req.body_json().get("ids")
    current = [a["id"] for a in q("SELECT id FROM avatars WHERE user_id = ?", (uid,))]
    if not isinstance(ids, list) or sorted(map(str, ids)) != sorted(current):
        raise ApiError(400, "bad_value")
    with LOCK:
        for pos, aid in enumerate(ids):
            _RC.d = {}
            DB.execute("UPDATE avatars SET position = ? WHERE id = ? AND user_id = ?", (pos, str(aid), uid))
    sync_avatar(uid)
    req.send_json(200, me_json(uid))


@route("DELETE", r"/v1/me/avatars/([a-f0-9]+)")
def delete_avatar(req, me, aid):
    uid = me["id"]
    a = q1("SELECT * FROM avatars WHERE id = ? AND user_id = ?", (aid, uid))
    if not a:
        raise ApiError(404, "not_found")
    run("DELETE FROM avatars WHERE id = ?", (aid,))
    run("DELETE FROM media WHERE id = ? AND owner = ?", (a["media_id"], uid))
    try:
        os.remove(os.path.join(MEDIA_DIR, a["media_id"]))
    except OSError:
        pass
    sync_avatar(uid)
    req.send_json(200, me_json(uid))


# ---------- сеансы (устройства) ----------

def session_json(s, current_id):
    info = {}
    raw = dec(s["user_id"], "profile", COL["session"], s["id"], s["info_enc"])
    if raw:
        try:
            info = json.loads(raw)
        except ValueError:
            pass
    return {"id": s["id"], "device": info.get("device") or "—", "system": info.get("system", ""),
            "app": info.get("app", ""), "ip": info.get("ip", ""), "created_at": s["created_at"],
            "last_active": s["last_active"], "current": s["id"] == current_id}


@route("GET", r"/v1/sessions")
def list_sessions(req, me):
    rows = q("SELECT * FROM sessions WHERE user_id = ? ORDER BY last_active DESC", (me["id"],))
    out = [session_json(s, me["session_id"]) for s in rows]
    out.sort(key=lambda s: not s["current"])
    req.send_json(200, {"sessions": out})


@route("DELETE", r"/v1/sessions")
def terminate_others(req, me):
    run("DELETE FROM sessions WHERE user_id = ? AND id <> ?", (me["id"], me["session_id"]))
    req.send_json(200, {"ok": True})


@route("DELETE", r"/v1/sessions/([a-f0-9]+)")
def terminate_session(req, me, sid):
    if not q1("SELECT 1 FROM sessions WHERE id = ? AND user_id = ?", (sid, me["id"])):
        raise ApiError(404, "not_found")
    run("DELETE FROM sessions WHERE id = ?", (sid,))
    req.send_json(200, {"ok": True, "was_current": sid == me["session_id"]})


# ---------- облачный пароль (2FA) и данные аккаунта на сервере ----------
# Пароль хранится как scrypt-хэш (хэш шифруется ключом пользователя). После 5 неверных попыток — пауза 5 минут.
# Имя, интересы, почта и настройки лежат на сервере: после выхода и нового входа аккаунт открывается как был.

TWOFA_FAILS = {}      # user_id -> [ошибок, заблокирован до]
TWOFA_TICKETS = {}    # билет входа по номеру -> {user_id, info, exp}
TWOFA_LOCK = threading.Lock()
TWOFA_MAX, TWOFA_PAUSE = 5, 300


def _pw_digest(password, salt):
    return hashlib.scrypt(password.encode("utf-8"), salt=salt, n=2 ** 14, r=8, p=1, dklen=32).hex()


def has_twofa(uid):
    r = q1("SELECT pw_hash_enc FROM users WHERE id = ?", (uid,))
    return bool(r and r["pw_hash_enc"])


def twofa_hint(uid):
    r = q1("SELECT pw_hint_enc FROM users WHERE id = ?", (uid,))
    return (dec(uid, "profile", "users.pw_hint", uid, r["pw_hint_enc"]) or "") if r and r["pw_hint_enc"] else ""


def twofa_verify(uid, password):
    now = time.time()
    with TWOFA_LOCK:
        f = TWOFA_FAILS.get(uid)
        if f and f[1] > now:
            raise ApiError(429, "locked", retry_after=int(f[1] - now) + 1)
    r = q1("SELECT pw_salt, pw_hash_enc FROM users WHERE id = ?", (uid,))
    good = False
    if r and r["pw_hash_enc"] and r["pw_salt"]:
        stored = dec(uid, "profile", "users.pw_hash", uid, r["pw_hash_enc"]) or ""
        good = hmac.compare_digest(stored, _pw_digest(password, r["pw_salt"]))
    with TWOFA_LOCK:
        if good:
            TWOFA_FAILS.pop(uid, None)
            return
        f = TWOFA_FAILS.setdefault(uid, [0, 0])
        if f[1] and f[1] <= now:
            f[0], f[1] = 0, 0
        f[0] += 1
        left = max(0, TWOFA_MAX - f[0])
        if f[0] >= TWOFA_MAX:
            f[1] = now + TWOFA_PAUSE
            f[0] = 0
            raise ApiError(429, "locked", retry_after=TWOFA_PAUSE)
    raise ApiError(400, "wrong_password", attempts_left=left)


def twofa_ticket(uid, info):
    now = time.time()
    with TWOFA_LOCK:
        for k in [k for k, v in TWOFA_TICKETS.items() if v["exp"] < now]:
            del TWOFA_TICKETS[k]
        if len(TWOFA_TICKETS) > 5000:
            raise ApiError(503, "busy")
        t = secrets.token_urlsafe(24)
        TWOFA_TICKETS[t] = {"user_id": uid, "info": info, "exp": now + 600}
    return t


@route("POST", r"/v1/auth/2fa", auth=False)
def auth_twofa(req, me):
    d = req.body_json()
    t = str(d.get("ticket", ""))
    with TWOFA_LOCK:
        rec = TWOFA_TICKETS.get(t)
        if not rec or rec["exp"] < time.time():
            raise ApiError(400, "code_expired")
    uid = rec["user_id"]
    twofa_verify(uid, str(d.get("password", "")))
    with TWOFA_LOCK:
        rec = TWOFA_TICKETS.pop(t, None)
    if not rec:
        raise ApiError(400, "code_expired")
    u = q1("SELECT * FROM users WHERE id = ?", (uid,))
    token, _ = new_session(uid, rec["info"])
    req.send_json(200, {"login": {"token": token, "user_id": uid, "name": names(u)[2]}})


@route("GET", r"/v1/me/account")
def account_get(req, me):
    r = q1("SELECT email_enc, settings_enc FROM users WHERE id = ?", (me["id"],))
    email = dec(me["id"], "profile", "users.email", me["id"], r["email_enc"]) if r["email_enc"] else None
    raw = dec(me["id"], "profile", "users.settings", me["id"], r["settings_enc"]) if r["settings_enc"] else None
    try:
        settings = json.loads(raw) if raw else None
    except ValueError:
        settings = None
    req.send_json(200, {"twofa": has_twofa(me["id"]), "hint": twofa_hint(me["id"]),
                        "email": email, "settings": settings})


@route("PUT", r"/v1/me/account")
def account_put(req, me):
    d = req.body_json()
    uid = me["id"]
    if "email" in d:
        email = str(d["email"] or "").strip()[:200]
        if email and not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", email):
            raise ApiError(400, "bad_email")
        run("UPDATE users SET email_enc = ? WHERE id = ?",
            (enc(uid, "profile", "users.email", uid, email) if email else None, uid))
    if "settings" in d:
        raw = json.dumps(d["settings"], ensure_ascii=False) if d["settings"] is not None else ""
        if len(raw) > 60000:
            raise ApiError(413, "too_large")
        run("UPDATE users SET settings_enc = ? WHERE id = ?",
            (enc(uid, "profile", "users.settings", uid, raw) if raw else None, uid))
    req.send_json(200, {"ok": True})


@route("PUT", r"/v1/me/2fa")
def twofa_set(req, me):
    d = req.body_json()
    uid, password = me["id"], str(d.get("password", ""))
    if len(password) < 4 or len(password) > 128:
        raise ApiError(400, "bad_password")
    if has_twofa(uid):
        twofa_verify(uid, str(d.get("current", "")))      # менять пароль можно, зная прежний
    salt = secrets.token_bytes(16)
    hint = " ".join(str(d.get("hint", "") or "").split())[:80]
    run("UPDATE users SET pw_salt = ?, pw_hash_enc = ?, pw_hint_enc = ? WHERE id = ?",
        (salt, enc(uid, "profile", "users.pw_hash", uid, _pw_digest(password, salt)),
         enc(uid, "profile", "users.pw_hint", uid, hint) if hint else None, uid))
    req.send_json(200, {"ok": True})


@route("POST", r"/v1/me/2fa/check")
def twofa_check(req, me):
    if not has_twofa(me["id"]):
        raise ApiError(409, "no_2fa")
    twofa_verify(me["id"], str(req.body_json().get("password", "")))
    req.send_json(200, {"ok": True})


@route("POST", r"/v1/me/2fa/remove")
def twofa_remove(req, me):
    uid = me["id"]
    if has_twofa(uid):
        twofa_verify(uid, str(req.body_json().get("password", "")))
    run("UPDATE users SET pw_salt = NULL, pw_hash_enc = NULL, pw_hint_enc = NULL WHERE id = ?", (uid,))
    req.send_json(200, {"ok": True})


# ---------- вход по QR-коду ----------
# Новое устройство показывает QR, уже вошедшее — сканирует и подтверждает. Токен выдаётся один раз тому,
# кто знает секрет, созданный вместе с QR.

def qr_cleanup(now):
    for k in [k for k, e in QR_PENDING.items() if e["expires"] + 60 < now]:
        del QR_PENDING[k]


@route("POST", r"/v1/qr", auth=False)
def qr_new(req, me):
    data = req.body_json()
    ip, now = req.client_ip(), time.time()
    with QR_LOCK:
        qr_cleanup(now)
        if sum(1 for e in QR_PENDING.values() if e["info"]["ip"] == ip and now - e["created"] < 60) >= 15:
            raise ApiError(429, "too_many_requests")
        if len(QR_PENDING) > 2000:
            raise ApiError(503, "busy")
        qid, secret = secrets.token_hex(16), secrets.token_urlsafe(24)
        QR_PENDING[qid] = {"secret_hash": token_hash(secret), "info": clean_info(data, ip), "created": now,
                           "expires": now + QR_TTL, "token": None}
    req.send_json(201, {"id": qid, "secret": secret, "expires_in": QR_TTL})


@route("GET", r"/v1/qr/([a-f0-9]{32})", auth=False)
def qr_poll(req, me, qid):
    secret = req.query().get("secret", "")
    now = time.time()
    with QR_LOCK:
        e = QR_PENDING.get(qid)
        if not e or not hmac.compare_digest(e["secret_hash"], token_hash(secret)):
            raise ApiError(404, "not_found")
        if e["expires"] < now:
            del QR_PENDING[qid]
            return req.send_json(200, {"status": "expired"})
        if e.get("twofa"):
            # QR подтверждён, но в аккаунте есть облачный пароль: сеанс выдаётся только после него
            return req.send_json(200, {"status": "twofa", "hint": twofa_hint(e["user_id"]),
                                       "name": e["name"], "user_id": e["user_id"]})
        if e["token"] is None:
            return req.send_json(200, {"status": "pending"})
        del QR_PENDING[qid]
    req.send_json(200, {"status": "approved", "token": e["token"], "user_id": e["user_id"],
                        "name": e["name"], "phone": e["phone"]})


@route("POST", r"/v1/qr/([a-f0-9]{32})/2fa", auth=False)
def qr_twofa(req, me, qid):
    d = req.body_json()
    secret, password = str(d.get("secret", "")), str(d.get("password", ""))
    with QR_LOCK:
        e = QR_PENDING.get(qid)
        if not e or e["expires"] < time.time() or not hmac.compare_digest(e["secret_hash"], token_hash(secret)):
            raise ApiError(404, "not_found")
        if not e.get("twofa"):
            raise ApiError(400, "not_required")
        uid = e["user_id"]
    twofa_verify(uid, password)          # бросит wrong_password / locked
    with QR_LOCK:
        e = QR_PENDING.pop(qid, None)
    if not e:
        raise ApiError(404, "not_found")
    token, _ = new_session(uid, e["info"])
    req.send_json(200, {"status": "approved", "token": token, "user_id": uid, "name": e["name"], "phone": e["phone"]})


@route("GET", r"/v1/qr/([a-f0-9]{32})/info")
def qr_info(req, me, qid):
    with QR_LOCK:
        e = QR_PENDING.get(qid)
        if not e or e["expires"] < time.time() or e["token"] is not None or e.get("twofa"):
            raise ApiError(404, "qr_expired")
        info = dict(e["info"])
    req.send_json(200, info)


@route("POST", r"/v1/qr/([a-f0-9]{32})/approve")
def qr_approve(req, me, qid):
    phone = str(req.body_json().get("phone", ""))
    phone = phone[:20] if re.match(r"^\+\d{6,18}$", phone) else ""
    with QR_LOCK:
        e = QR_PENDING.get(qid)
        if not e or e["expires"] < time.time() or e["token"] is not None or e.get("twofa"):
            raise ApiError(404, "qr_expired")
        if has_twofa(me["id"]):
            e.update(twofa=True, user_id=me["id"], name=names(me)[2], phone=phone)
        else:
            token, _ = new_session(me["id"], e["info"])
            e.update(token=token, user_id=me["id"], name=names(me)[2], phone=phone)
    req.send_json(200, {"ok": True, "twofa": bool(e.get("twofa"))})


# ---------- медиа (файлы хранятся зашифрованными блоками) ----------

@route("POST", r"/v1/media")
def upload_media(req, me):
    params = req.query()
    kind = params.get("kind", "")
    mime = (req.headers.get("Content-Type") or "").split(";")[0].strip().lower()
    if kind == "file":
        allowed = re.fullmatch(r"[a-z0-9][a-z0-9.+\-]*/[a-z0-9][a-z0-9.+\-]*", mime) is not None
    else:
        allowed = kind in ("image", "video", "audio") and mime in ALLOWED_MIME and mime.split("/")[0] == kind
    if not allowed:
        req.drain()
        raise ApiError(415, "unsupported_media")
    length = int(req.headers.get("Content-Length") or 0)
    if length <= 0:
        raise ApiError(400, "empty")
    if length > (MAX_AUDIO_BYTES if kind == "audio" else MAX_MEDIA_BYTES):
        req.close_connection = True
        raise ApiError(413, "too_large")
    thumb = params.get("thumb") or None
    if thumb and not q1("SELECT 1 FROM media WHERE id = ? AND owner = ?", (thumb, me["id"])):
        req.drain()
        raise ApiError(400, "media_not_found")

    mid = uuid.uuid4().hex
    os.makedirs(MEDIA_DIR, exist_ok=True)
    path = os.path.join(MEDIA_DIR, mid)
    # проверка нейросетью: пока файл шифруется, копия открытых байт кладётся во временный файл
    scan = moderation.enabled() and kind in ("image", "video")
    scan_path, scan_file, digest = path + ".scan", None, hashlib.sha256()
    read = req.rfile.read
    if scan:
        scan_file = open(scan_path, "wb")

        def read(n, _r=req.rfile.read):
            b = _r(n)
            scan_file.write(b)
            digest.update(b)
            return b
    try:
        try:
            with open(path, "wb") as f:
                encrypt_stream(media_key(me["id"], mid), mid, read, length, f.write)
        except EOFError:
            os.remove(path)
            req.close_connection = True
            raise ApiError(400, "incomplete")
        verdict, detail = "ok", {}
        if scan:
            scan_file.close()
            h = digest.hexdigest()
            if q1("SELECT 1 FROM media_blocked WHERE hash = ?", (h,)):
                verdict = "block"                          # этот файл уже отклоняли — модели не нужны
            else:
                try:
                    dur = float(params.get("dur", 0) or 0)
                except ValueError:
                    dur = 0.0
                verdict, detail = moderation.check(scan_path, kind, dur)
                if verdict == "block":
                    run("INSERT OR IGNORE INTO media_blocked(hash, created_at) VALUES (?,?)", (h, time.time()))
            if verdict in ("block", "error"):
                os.remove(path)
                if verdict == "block":
                    raise ApiError(422, "content_blocked")
                raise ApiError(503, "moderation_unavailable")
    finally:
        if scan_file:
            scan_file.close()
        if scan and os.path.exists(scan_path):
            os.remove(scan_path)

    def to_int(v):
        try:
            return max(0, min(int(v), 20000))
        except (TypeError, ValueError):
            return 0

    width, height = to_int(params.get("w")), to_int(params.get("h"))
    try:
        duration = max(0.0, min(float(params.get("dur", 0)), 36000.0))
    except ValueError:
        duration = 0.0
    run("INSERT INTO media(id, owner, kind, mime, width, height, duration, thumb, size, created_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
        (mid, me["id"], kind, mime, width, height, duration, thumb, length, time.time()))
    if verdict == "review":                                # спорное — публикуется, но попадает в очередь на проверку человеком
        run("INSERT OR REPLACE INTO media_review(media_id, owner, verdict, detail, created_at) VALUES (?,?,?,?,?)",
            (mid, me["id"], verdict, json.dumps(detail, ensure_ascii=False)[:2000], time.time()))
    req.send_json(201, {"id": mid, "kind": kind, "width": width, "height": height,
                        "duration": duration, "thumb": thumb})


@route("GET", r"/media/([A-Za-z0-9]+)", auth=False)
def get_media(req, me, mid):
    row = q1("SELECT * FROM media WHERE id = ?", (mid,))
    path = os.path.join(MEDIA_DIR, mid)
    if not row or not os.path.isfile(path):
        raise ApiError(404, "not_found")
    size = row["size"]                     # длина открытого файла
    start, end, status = 0, size - 1, 200
    header = req.headers.get("Range")
    if header:
        m = re.match(r"^bytes=(\d*)-(\d*)$", header.strip())
        if m:
            s, e = m.groups()
            if s == "" and e != "":
                start = max(0, size - int(e))
            elif s != "":
                start = int(s)
                end = int(e) if e else size - 1
            end = min(end, size - 1)
            if start > end or start >= size:
                req.send_response(416)
                req.send_header("Content-Range", "bytes */%d" % size)
                req.send_header("Content-Length", "0")
                req.end_headers()
                return
            status = 206
    req.send_response(status)
    if row["kind"] == "file":                  # чужие файлы никогда не исполняются и не отображаются в браузере
        req.send_header("Content-Type", "application/octet-stream")
        req.send_header("Content-Disposition", "attachment")
    else:
        req.send_header("Content-Type", row["mime"])
    req.send_header("X-Content-Type-Options", "nosniff")
    req.send_header("Content-Length", str(end - start + 1))
    req.send_header("Accept-Ranges", "bytes")
    req.send_header("Cache-Control", "public, max-age=31536000, immutable")
    if status == 206:
        req.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
    req.end_headers()
    with open(path, "rb") as f:
        for piece in decrypt_range(media_key(row["owner"], mid), mid, f, size, start, end):
            req.wfile.write(piece)


def _synchsafe(b):
    return ((b[0] & 0x7F) << 21) | ((b[1] & 0x7F) << 14) | ((b[2] & 0x7F) << 7) | (b[3] & 0x7F)


def id3_cover(data):
    """Картинка из тега ID3v2 (APIC / PIC): (mime, bytes) либо None"""
    if len(data) < 10 or data[:3] != b"ID3":
        return None
    ver = data[3]
    if ver not in (2, 3, 4):
        return None
    total = min(_synchsafe(data[6:10]), len(data) - 10)
    pos, end = 10, 10 + total
    if data[5] & 0x40 and ver in (3, 4) and end - pos >= 4:   # расширенный заголовок
        ext = _synchsafe(data[pos:pos + 4]) if ver == 4 else int.from_bytes(data[pos:pos + 4], "big") + 4
        pos += max(0, ext)
    hlen = 6 if ver == 2 else 10
    while pos + hlen <= end:
        fid = data[pos:pos + (3 if ver == 2 else 4)]
        if fid[0:1] == b"\x00":
            break
        if ver == 2:
            size = int.from_bytes(data[pos + 3:pos + 6], "big")
        elif ver == 3:
            size = int.from_bytes(data[pos + 4:pos + 8], "big")
        else:
            size = _synchsafe(data[pos + 4:pos + 8])
        body = data[pos + hlen:pos + hlen + size]
        pos += hlen + size
        if size <= 0 or len(body) < size:
            if size <= 0:
                continue
            break
        if fid not in (b"APIC", b"PIC"):
            continue
        enc = body[0]
        i = 1
        if ver == 2:
            fmt = body[i:i + 3].lower()
            mime = "image/png" if fmt == b"png" else "image/jpeg"
            i += 3
        else:
            z = body.find(b"\x00", i)
            if z < 0:
                continue
            mime = body[i:z].decode("latin-1").lower() or "image/jpeg"
            i = z + 1
        i += 1                                                  # тип картинки
        if enc in (1, 2):                                       # UTF-16: описание кончается двумя нулями
            while i + 1 < len(body) and body[i:i + 2] != b"\x00\x00":
                i += 2
            i += 2
        else:
            z = body.find(b"\x00", i)
            i = len(body) if z < 0 else z + 1
        img = body[i:]
        if img[:3] == b"\xff\xd8\xff":
            mime = "image/jpeg"
        elif img[:8] == b"\x89PNG\r\n\x1a\n":
            mime = "image/png"
        else:
            continue
        return mime, img
    return None


_COVER_CACHE = {}


# ---------- Предпросмотр ссылок (картинка, заголовок, описание) ----------

_LINK_CACHE = {}
_LINK_TTL = 6 * 3600


def _public_host(host):
    """Только публичные адреса: никаких localhost и локальной сети (защита от SSRF)"""
    try:
        infos = socket.getaddrinfo(host, None)
    except OSError:
        return False
    for info in infos:
        ip = ipaddress.ip_address(info[4][0])
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_reserved or ip.is_unspecified:
            return False
    return bool(infos)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def parse_og(page, base):
    """Достаёт og:/twitter: теги и <title> из начала страницы"""
    meta = {}
    for m in re.finditer(r"<meta\s+([^>]+?)/?>", page, re.I | re.S):
        attrs = dict((k.lower(), v) for k, _, v in re.findall(r"([\w:-]+)\s*=\s*([\"'])(.*?)\2", m.group(1), re.S))
        key = (attrs.get("property") or attrs.get("name") or "").lower()
        if key and "content" in attrs and key not in meta:
            meta[key] = htmllib.unescape(attrs["content"]).strip()
    title = meta.get("og:title") or meta.get("twitter:title")
    if not title:
        t = re.search(r"<title[^>]*>(.*?)</title>", page, re.I | re.S)
        title = htmllib.unescape(t.group(1)).strip() if t else ""
    image = meta.get("og:image") or meta.get("twitter:image") or ""
    if image:
        from urllib.parse import urljoin
        image = urljoin(base, image)
        if not image.startswith(("http://", "https://")):
            image = ""
    return {"title": title[:160], "description": (meta.get("og:description") or meta.get("description") or "")[:240],
            "site": (meta.get("og:site_name") or "")[:60], "image": image}


def fetch_link_preview(url):
    from urllib.parse import urlparse as _up, urljoin
    opener = urllib.request.build_opener(_NoRedirect)
    cur = url
    for _ in range(4):
        u = _up(cur)
        if u.scheme not in ("http", "https") or not u.hostname or not _public_host(u.hostname):
            return None
        req = urllib.request.Request(cur, headers={"User-Agent": "Mozilla/5.0 (compatible; OrbitaBot/1.0)",
                                                   "Accept": "text/html,application/xhtml+xml"})
        try:
            resp = opener.open(req, timeout=5)
        except urllib.error.HTTPError as e:
            if e.code in (301, 302, 303, 307, 308) and e.headers.get("Location"):
                cur = urljoin(cur, e.headers["Location"])
                continue
            return None
        except Exception:
            return None
        ctype = resp.headers.get("Content-Type", "")
        if "html" not in ctype.lower():
            return None
        raw = resp.read(300_000)
        charset = "utf-8"
        m = re.search(r"charset=([\w-]+)", ctype, re.I)
        if m:
            charset = m.group(1)
        try:
            page = raw.decode(charset, "replace")
        except LookupError:
            page = raw.decode("utf-8", "replace")
        info = parse_og(page, cur)
        if not info["title"] and not info["description"]:
            return None
        info["url"] = cur
        return info
    return None


@route("GET", r"/v1/link_preview")
def link_preview(req, me):
    url = req.query().get("url", "").strip()
    if not url.startswith(("http://", "https://")) or len(url) > 1000:
        raise ApiError(400, "bad_url")
    now = time.time()
    hit = _LINK_CACHE.get(url)
    if hit and now - hit[0] < _LINK_TTL:
        info = hit[1]
    else:
        info = fetch_link_preview(url)
        if len(_LINK_CACHE) > 500:
            _LINK_CACHE.clear()
        _LINK_CACHE[url] = (now, info)
    if not info:
        raise ApiError(404, "no_preview")
    req.send_json(200, info)


@route("GET", r"/media/([A-Za-z0-9]+)/cover", auth=False)
def get_media_cover(req, me, mid):
    """Обложка трека — картинка, вшитая в аудиофайл; нет её — 404"""
    if mid in _COVER_CACHE:
        found = _COVER_CACHE[mid]
    else:
        row = q1("SELECT * FROM media WHERE id = ?", (mid,))
        path = os.path.join(MEDIA_DIR, mid)
        if not row or row["kind"] not in ("audio", "file") or not os.path.isfile(path):
            raise ApiError(404, "not_found")
        size = row["size"]
        found = None
        try:
            with open(path, "rb") as f:
                head = b"".join(decrypt_range(media_key(row["owner"], mid), mid, f, size, 0, min(size, 10) - 1))
                if head[:3] == b"ID3" and len(head) >= 10:
                    n = min(size, 10 + _synchsafe(head[6:10]), 8 * 1024 * 1024)
                    f.seek(0)
                    data = b"".join(decrypt_range(media_key(row["owner"], mid), mid, f, size, 0, n - 1))
                    found = id3_cover(data)
        except Exception:
            found = None
        if len(_COVER_CACHE) > 200:
            _COVER_CACHE.clear()
        _COVER_CACHE[mid] = found
    if not found:
        raise ApiError(404, "no_cover")
    mime, img = found
    req.send_response(200)
    req.send_header("Content-Type", mime)
    req.send_header("X-Content-Type-Options", "nosniff")
    req.send_header("Content-Length", str(len(img)))
    req.send_header("Cache-Control", "public, max-age=86400")
    req.end_headers()
    req.wfile.write(img)


# ---------- публикации ----------

@route("GET", r"/v1/posts/([a-f0-9]+)")
def get_post(req, me, pid):
    p = q1("SELECT * FROM posts WHERE id = ?", (pid,))
    if not p or (p["author"] != me["id"] and either_blocked(p["author"], me["id"])):
        raise ApiError(404, "not_found")
    req.send_json(200, post_json(p, me["id"]))


# Ссылка, которой делятся: открывается в любом мессенджере и перекидывает в приложение (orbita://post/…)
OPEN_PAGE = """<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Orbita</title>
<style>body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#0b0d14;
color:#e8eaf2;font:17px -apple-system,system-ui,sans-serif;text-align:center}
a{display:inline-block;margin-top:18px;padding:14px 28px;border-radius:16px;background:#5b7cff;color:#fff;
text-decoration:none;font-weight:600}</style></head><body><div><div style="font-size:26px;font-weight:700">Orbita</div>
<div style="opacity:.7;margin-top:8px">Открываем в приложении…</div>
<a href="%(link)s">Открыть в Orbita</a></div>
<script>setTimeout(function(){location.href="%(link)s"},150)</script></body></html>"""


PROFILE_PAGE = """<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>%(name)s — Orbita</title>
<style>body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
background:radial-gradient(ellipse at 50%% 0%%,#1b2350,#0b0d14 70%%);color:#e8eaf2;
font:17px -apple-system,system-ui,sans-serif;text-align:center}
.c{padding:32px;max-width:340px}.o{width:96px;height:96px;margin:0 auto 20px;border-radius:50%%;
border:2px solid rgba(255,255,255,.18);position:relative;display:flex;align-items:center;justify-content:center;
font-size:38px;background:rgba(255,255,255,.05)}
.o:after{content:"";position:absolute;width:12px;height:12px;border-radius:50%%;background:#8fa5ff;top:-6px;left:42px;
transform-origin:6px 54px;animation:r 4s linear infinite}@keyframes r{to{transform:rotate(360deg)}}
h1{font-size:24px;margin:0 0 6px}.s{opacity:.65;margin-bottom:26px}
a.b{display:block;padding:15px;border-radius:16px;background:#5b7cff;color:#fff;text-decoration:none;font-weight:600}
.h{opacity:.5;font-size:14px;margin-top:18px;line-height:1.4}</style></head><body><div class="c">
<div class="o">🪐</div><h1>%(name)s</h1><div class="s">%(sub)s</div>
<a class="b" href="%(link)s">Открыть в Orbita</a>
<div class="h">Нет приложения? Установите Orbita и снова откройте эту ссылку.</div></div></body></html>"""


def send_html(req, body):
    body = body.encode()
    req.send_response(200)
    req.send_header("Content-Type", "text/html; charset=utf-8")
    req.send_header("Content-Length", str(len(body)))
    req.end_headers()
    req.wfile.write(body)


@route("GET", r"/u/([A-Za-z][A-Za-z0-9_]{4,31})", auth=False)
def open_profile_page(req, me, username):
    # на странице только то, что и так есть в ссылке: никаких данных из базы
    send_html(req, PROFILE_PAGE % {"name": "@" + username, "sub": "Профиль в Orbita",
                                   "link": "orbita://u/" + username})


@route("GET", r"/id/([A-Za-z0-9\-]{8,64})", auth=False)
def open_profile_id_page(req, me, uid):
    send_html(req, PROFILE_PAGE % {"name": "Профиль", "sub": "Orbita", "link": "orbita://id/" + uid})


@route("GET", r"/p/([a-f0-9]{32})", auth=False)
def open_post_page(req, me, pid):
    body = (OPEN_PAGE % {"link": "orbita://post/" + pid}).encode()
    req.send_response(200)
    req.send_header("Content-Type", "text/html; charset=utf-8")
    req.send_header("Content-Length", str(len(body)))
    req.end_headers()
    req.wfile.write(body)



# ---------- интересы и рекомендации ----------

# Темы: id → (ключевые основы слов). Тема поста определяется по тексту и хэштегам; тексты зашифрованы,
# поэтому классификация идёт «на лету» при построении ленты и нигде не сохраняется.
TOPICS = {
    "music":    ("музык", "песн", "трек", "альбом", "концерт", "гитар", "рэп", "рок", "джаз", "плейлист", "music", "song", "album", "concert", "guitar"),
    "movies":   ("фильм", "кино", "сериал", "актёр", "актер", "режисс", "аниме", "movie", "film", "series", "netflix", "anime"),
    "games":    ("игр", "гейм", "steam", "playstation", "xbox", "майнкрафт", "minecraft", "стрим", "game", "gaming", "esport", "киберспорт"),
    "sport":    ("спорт", "футбол", "хоккей", "баскетбол", "тренировк", "зал", "бег", "матч", "чемпионат", "sport", "football", "workout", "gym", "fitness"),
    "tech":     ("технолог", "айти", "программ", "код", "python", "swift", "iphone", "android", "ии ", "нейросет", "gadget", "tech", "software", "coding", "ai "),
    "travel":   ("путешеств", "поездк", "отпуск", "страна", "город", "отель", "самолёт", "самолет", "туризм", "travel", "trip", "flight", "vacation"),
    "food":     ("еда", "рецепт", "готов", "кухн", "ресторан", "кофе", "вкусн", "пицц", "food", "recipe", "cooking", "restaurant", "coffee"),
    "art":      ("искусств", "рисун", "картин", "художник", "дизайн", "иллюстрац", "арт", "art", "design", "drawing", "illustration"),
    "science":  ("наук", "космос", "физик", "химия", "биолог", "учёны", "ученые", "исследован", "science", "space", "physics", "research"),
    "books":    ("книг", "читать", "роман", "писател", "литератур", "стих", "book", "reading", "novel", "author"),
    "fashion":  ("мода", "стиль", "одежд", "образ", "кроссовк", "fashion", "style", "outfit"),
    "cars":     ("авто", "машин", "двигатель", "тачк", "bmw", "tesla", "мотоцикл", "car", "motor", "engine"),
    "animals":  ("кот", "собак", "питомец", "животн", "щенок", "котик", "cat", "dog", "pet", "animal"),
    "humor":    ("мем", "смешн", "юмор", "шутк", "прикол", "ахах", "meme", "funny", "joke", "lol"),
    "photo":    ("фото", "съёмк", "съемк", "камера", "кадр", "photo", "photograph", "camera"),
    "business": ("бизнес", "стартап", "инвест", "деньги", "финанс", "маркетинг", "карьер", "business", "startup", "money", "career", "invest"),
    "education":("учёб", "учеб", "университет", "школ", "курс", "экзамен", "язык", "study", "course", "university", "exam", "learning"),
    "health":   ("здоровь", "медитац", "сон", "питание", "психолог", "йога", "health", "wellness", "yoga", "sleep", "mental"),
    "nature":   ("природ", "лес", "горы", "море", "закат", "поход", "nature", "mountain", "forest", "sunset", "hiking"),
    "diy":      ("своими руками", "ремонт", "мастер", "рукодел", "diy", "handmade", "craft"),
    "news":     ("новост", "политик", "событи", "news", "politics", "breaking"),
    "history":  ("истори", "война", "древн", "археолог", "history", "ancient", "museum", "музей"),
    "crypto":   ("крипт", "биткоин", "bitcoin", "ethereum", "блокчейн", "nft", "crypto"),
    "dance":    ("танец", "танц", "балет", "хореограф", "dance", "ballet"),
}
MAX_INTERESTS = 10


def post_topics(text):
    t = " " + (text or "").lower() + " "
    tags = set(re.findall(r"#(\w+)", t))
    found = set()
    for tid, words in TOPICS.items():
        if tid in tags or any(w in t for w in words) or any(tag.startswith(w.strip()) for tag in tags for w in words if len(w.strip()) > 3):
            found.add(tid)
    return found


def interests_of(uid):
    r = q1("SELECT topics_enc FROM user_interests WHERE user_id = ?", (uid,))
    if not r:
        return None
    raw = dec(uid, "profile", "user_interests.topics", uid, r["topics_enc"])
    try:
        return [t for t in json.loads(raw or "[]") if t in TOPICS]
    except ValueError:
        return []


@route("GET", r"/v1/me/interests")
def get_interests(req, me):
    got = interests_of(me["id"])
    req.send_json(200, {"topics": got or [], "set": got is not None, "available": list(TOPICS.keys())})


@route("PUT", r"/v1/me/interests")
def put_interests(req, me):
    d = req.body_json()
    topics = d.get("topics", [])
    if not isinstance(topics, list):
        raise ApiError(400, "bad_value")
    clean = []
    for t in topics:
        if t in TOPICS and t not in clean:
            clean.append(t)
    clean = clean[:MAX_INTERESTS]
    run("INSERT INTO user_interests(user_id, topics_enc, updated_at) VALUES (?,?,?) "
        "ON CONFLICT(user_id) DO UPDATE SET topics_enc = excluded.topics_enc, updated_at = excluded.updated_at",
        (me["id"], enc(me["id"], "profile", "user_interests.topics", me["id"], json.dumps(clean)), time.time()))
    req.send_json(200, {"topics": clean})


# ---------- «вкус»: что человек смотрит, лайкает, комментирует и пересылает ----------
# Мини-модель без нейросети: по каждой теме и автору копится оценка с затуханием.
# «Раньше» — медленное затухание (период полураспада 30 дней), «Сейчас» — быстрое (3 дня).
# Хранится зашифрованно отдельно от явных «Интересов»: смена интересов в настройках вкус не стирает.

TASTE_HALF = {"long": 30 * 86400.0, "recent": 3 * 86400.0}
TASTE_W = {"like": 3.0, "unlike": -3.0, "comment": 4.0, "share": 5.0, "save": 3.0, "dislike": -6.0}
TASTE_LOCK = threading.Lock()


def dwell_weight(ms):
    """Сколько смотрел: пролистал — минус, задержался — плюс"""
    if ms < 1200:
        return -0.25
    if ms < 3000:
        return 0.1
    if ms < 8000:
        return 0.6
    if ms < 20000:
        return 1.0
    return 1.4


def taste_blank():
    return {"long": {}, "recent": {}, "authors": {}, "off": False,
            "stats": {"views": 0, "likes": 0, "comments": 0, "shares": 0, "saves": 0, "watch_ms": 0}}


def taste_load(uid):
    r = q1("SELECT data_enc FROM user_taste WHERE user_id = ?", (uid,))
    if not r:
        return taste_blank()
    try:
        t = json.loads(dec(uid, "profile", "user_taste", uid, r["data_enc"]) or "{}")
    except ValueError:
        t = {}
    base = taste_blank()
    base.update({k: v for k, v in t.items() if k in base})
    base["stats"] = {**taste_blank()["stats"], **(t.get("stats") or {})}
    return base


def taste_save(uid, t):
    run("INSERT INTO user_taste(user_id, data_enc, updated_at) VALUES (?,?,?) "
        "ON CONFLICT(user_id) DO UPDATE SET data_enc = excluded.data_enc, updated_at = excluded.updated_at",
        (uid, enc(uid, "profile", "user_taste", uid, json.dumps(t, ensure_ascii=False)), time.time()))


def taste_value(entry, half, now):
    if not entry:
        return 0.0
    return entry[0] * (0.5 ** (max(0.0, now - entry[1]) / half))


def taste_bump(bucket, key, delta, half, now):
    bucket[key] = [round(taste_value(bucket.get(key), half, now) + delta, 4), now]


def reel_weight(ratio):
    """Для коротких видео важна доля просмотра: досмотрел/пересмотрел — сильный плюс, смахнул сразу — минус"""
    if ratio < 0.15:
        return -0.7
    if ratio < 0.4:
        return 0.1
    if ratio < 0.8:
        return 1.0
    if ratio < 1.5:
        return 2.0
    return 2.6


def taste_event(uid, post, kind, ms=0, ratio=None):
    """Учесть действие человека с постом. kind: view | like | unlike | comment | share | save"""
    if not post or post["author"] == uid:
        return
    now = time.time()
    with TASTE_LOCK:
        t = taste_load(uid)
        if t["off"]:
            return
        if kind == "view" and ratio is not None:
            w = reel_weight(ratio)
        else:
            w = dwell_weight(ms) if kind == "view" else TASTE_W.get(kind, 0.0)
        if not w:
            return
        topics = post_topics(dec(post["author"], "posts", COL["post_text"], post["id"], post["text_enc"]))
        for scope in ("long", "recent"):
            for tp in topics:
                taste_bump(t[scope], tp, w, TASTE_HALF[scope], now)
        taste_bump(t["authors"], post["author"], w, TASTE_HALF["long"], now)
        if len(t["authors"]) > 80:
            keep = sorted(t["authors"], key=lambda k: -abs(taste_value(t["authors"][k], TASTE_HALF["long"], now)))[:60]
            t["authors"] = {k: t["authors"][k] for k in keep}
        st = t["stats"]
        if kind == "view":
            st["views"] += 1
            st["watch_ms"] += int(ms)
        elif kind == "like":
            st["likes"] += 1
        elif kind == "comment":
            st["comments"] += 1
        elif kind == "share":
            st["shares"] += 1
        elif kind == "save":
            st["saves"] += 1
        taste_save(uid, t)


@route("POST", r"/v1/events")
def post_events(req, me):
    """Пачка событий из приложения: показ поста (сколько миллисекунд был на экране) и сохранение"""
    items = req.body_json().get("events", [])
    if not isinstance(items, list):
        raise ApiError(400, "bad_value")
    done = 0
    for e in items[:50]:
        if not isinstance(e, dict) or e.get("type") not in ("view", "save", "dislike"):
            continue
        p = q1("SELECT * FROM posts WHERE id = ?", (str(e.get("post_id", "")),))
        try:
            ms = max(0, min(int(e.get("ms", 0)), 120000))
        except (TypeError, ValueError):
            continue
        ratio = None
        if e.get("ratio") is not None:
            try:
                ratio = max(0.0, min(float(e["ratio"]), 5.0))
            except (TypeError, ValueError):
                ratio = None
        if p and not either_blocked(me["id"], p["author"]):
            taste_event(me["id"], p, e["type"], ms, ratio)
            if e["type"] == "view" and ratio is not None and p["reel"] and p["author"] != me["id"]:
                reel_stat_view(p["id"], me["id"], ms, ratio)
            done += 1
    req.send_json(200, {"ok": True, "count": done})


def taste_profile(uid):
    now = time.time()
    t = taste_load(uid)

    def top(scope):
        vals = {k: taste_value(v, TASTE_HALF[scope], now) for k, v in t[scope].items() if k in TOPICS}
        peak = max([abs(v) for v in vals.values()] + [3.0])
        return {k: v / peak for k, v in vals.items()}

    lng, rec = top("long"), top("recent")
    lst = lambda d: [{"topic": k, "score": round(v, 3)} for k, v in sorted(d.items(), key=lambda x: -x[1]) if v > 0.05][:8]
    trend = {k: rec.get(k, 0) - lng.get(k, 0) for k in set(lng) | set(rec)}
    rising = [k for k, v in sorted(trend.items(), key=lambda x: -x[1]) if v > 0.25 and rec.get(k, 0) > 0.1][:3]
    fading = [k for k, v in sorted(trend.items(), key=lambda x: x[1]) if v < -0.25 and lng.get(k, 0) > 0.1][:3]
    return {"enabled": not t["off"], "long": lst(lng), "recent": lst(rec), "rising": rising, "fading": fading,
            "stats": t["stats"]}


@route("GET", r"/v1/me/taste")
def get_taste(req, me):
    req.send_json(200, taste_profile(me["id"]))


@route("PUT", r"/v1/me/taste")
def put_taste(req, me):
    on = bool(req.body_json().get("enabled", True))
    with TASTE_LOCK:
        t = taste_load(me["id"])
        t["off"] = not on
        taste_save(me["id"], t)
    req.send_json(200, taste_profile(me["id"]))


@route("DELETE", r"/v1/me/taste")
def reset_taste(req, me):
    with TASTE_LOCK:
        old = taste_load(me["id"])
        fresh = taste_blank()
        fresh["off"] = old["off"]
        taste_save(me["id"], fresh)
    req.send_json(200, taste_profile(me["id"]))


_TOPIC_CACHE = {}


def topics_cached(p):
    """Темы поста: считаются один раз на (id, шифртекст) — без повторной расшифровки и разбора текста"""
    key = (p["id"], bytes(p["text_enc"]))
    t = _TOPIC_CACHE.get(key)
    if t is None:
        if len(_TOPIC_CACHE) > 60000:
            _TOPIC_CACHE.clear()
        t = frozenset(post_topics(dec(p["author"], "posts", COL["post_text"], p["id"], p["text_enc"]) or ""))
        _TOPIC_CACHE[key] = t
    return t


def ranked_feed(me, rows, limit):
    """Лента «Для вас»: совпадение тем с интересами, темы лайкнутых постов, свежесть, популярность, лёгкая случайность."""
    mine = set(interests_of(me["id"]) or [])
    implicit = {}
    liked = q("SELECT p.id, p.author, p.text_enc FROM likes l JOIN posts p ON p.id = l.post_id "
              "WHERE l.user_id = ? ORDER BY l.rowid DESC LIMIT 60", (me["id"],))
    for p in liked:
        for t in topics_cached(p):
            implicit[t] = implicit.get(t, 0) + 1
    now = time.time()
    taste = taste_load(me["id"])
    use_taste = not taste["off"]

    def prep(bucket, half, floor):
        # значения с учётом затухания и знаменатель — один раз на запрос, а не на каждый пост
        vals = {k: taste_value(v, half, now) for k, v in bucket.items()}
        return vals, max(max((abs(v) for v in vals.values()), default=0.0), floor)

    if use_taste:
        rec_v, rec_d = prep(taste["recent"], TASTE_HALF["recent"], 3.0)
        lon_v, lon_d = prep(taste["long"], TASTE_HALF["long"], 3.0)
        aut_v, aut_d = prep(taste["authors"], TASTE_HALF["long"], 5.0)

    def aff(vals, den, key):
        return max(-1.0, min(1.0, vals.get(key, 0.0) / den))

    like_counts = {}
    if rows:
        ids = [p["id"] for p in rows]
        for r in q("SELECT post_id, COUNT(*) c FROM likes WHERE post_id IN (%s) GROUP BY post_id" % _in(ids), ids):
            like_counts[r["post_id"]] = r["c"]

    scored = []
    for p in rows:
        topics = topics_cached(p)
        hit = len(topics & mine)
        like_hit = sum(min(implicit.get(t, 0), 5) for t in topics) / 5.0
        learned = 0.0
        if use_taste:
            now_aff = sum(aff(rec_v, rec_d, t) for t in topics)
            old_aff = sum(aff(lon_v, lon_d, t) for t in topics)
            author_aff = aff(aut_v, aut_d, p["author"])
            learned = 2.5 * max(-1.5, min(1.5, now_aff)) + 1.8 * max(-1.5, min(1.5, old_aff)) + 1.5 * author_aff
        likes = p["likes_seed"] + like_counts.get(p["id"], 0)
        age_h = max(0.0, (now - p["created_at"]) / 3600.0)
        fresh = 1.0 / (1.0 + age_h / 18.0)
        score = 3.0 * min(hit, 3) + 0.7 * min(like_hit, 2) + learned + 2.0 * fresh + 0.5 * math.log1p(likes)
        if p["author"] == me["id"]:
            score += 1.0
        score += random.random() * 0.4
        scored.append((score, p))
    scored.sort(key=lambda x: -x[0])
    return [p for _, p in scored[:limit]]


MAX_REEL_SECONDS = 180


# ---- Поиск по шортсам: по подписи, хэштегам, автору и названию музыки. Популярные запросы — из тех, что давали результат.
DEFAULT_REEL_QUERIES = ["юмор", "музыка", "путешествия", "кот", "еда", "спорт", "танцы", "авто", "игры", "природа"]
_REEL_TEXT_CACHE = {}


def reel_haystack(p):
    key = (p["id"], bytes(p["text_enc"]))
    h = _REEL_TEXT_CACHE.get(key)
    if h is None:
        text = dec(p["author"], "posts", COL["post_text"], p["id"], p["text_enc"]) or ""
        ub = user_brief(p["author"])
        music = music_of(p) or {}
        h = " ".join([text, ub.get("name") or "", ub.get("username") or "", music.get("title", ""), music.get("artist", "")]).lower().replace("ё", "е")
        if len(_REEL_TEXT_CACHE) > 4000:
            _REEL_TEXT_CACHE.clear()
        _REEL_TEXT_CACHE[key] = h
    return h


def reel_tokens(query):
    out = []
    for w in re.findall(r"[\w#@]+", query.lower().replace("ё", "е")):
        w = w.lstrip("#@")
        if not w:
            continue
        out.append(w[:-2] if len(w) >= 6 else (w[:-1] if len(w) == 5 else w))     # «собаки» найдёт «собака»
    return out[:6]


# ---- Статистика шортса для автора: просмотры, удержание, среднее время, подписчики… (считается с момента появления этой функции)
def reel_stat_view(pid, viewer, ms, ratio):
    now = time.time()
    run("INSERT OR IGNORE INTO post_stats(post_id, since) VALUES (?, ?)", (pid, now))
    run("UPDATE post_stats SET views = views + 1, watch_ms = watch_ms + ?, ratio_sum = ratio_sum + ?, "
        "completes = completes + ?, skips = skips + ? WHERE post_id = ?",
        (ms, min(ratio, 1.0), 1 if ratio >= 0.9 else 0, 1 if ms < 2000 else 0, pid))
    run("INSERT OR IGNORE INTO post_viewers(post_id, user_id) VALUES (?, ?)", (pid, viewer))
    day = int(now // 86400)
    run("INSERT OR IGNORE INTO post_views_day(post_id, day, views) VALUES (?, ?, 0)", (pid, day))
    run("UPDATE post_views_day SET views = views + 1 WHERE post_id = ? AND day = ?", (pid, day))


@route("GET", r"/v1/posts/([a-f0-9]+)/stats")
def post_stats(req, me, pid):
    p = q1("SELECT * FROM posts WHERE id = ? AND author = ?", (pid, me["id"]))
    if not p:
        raise ApiError(404, "not_found")
    st = q1("SELECT * FROM post_stats WHERE post_id = ?", (pid,))
    views = st["views"] if st else 0
    uniq = q1("SELECT COUNT(*) c FROM post_viewers WHERE post_id = ?", (pid,))["c"]
    now = time.time()
    today = int(now // 86400)
    days = {r["day"]: r["views"] for r in q("SELECT day, views FROM post_views_day WHERE post_id = ? AND day > ?", (pid, today - 7))}
    base = p["repost_of"] or pid
    likes = q1("SELECT COUNT(*) c FROM likes WHERE post_id = ?", (pid,))["c"] + (p["likes_seed"] or 0)
    comments = q1("SELECT COUNT(*) c FROM comments WHERE post_id = ?", (pid,))["c"]
    saves = q1("SELECT COUNT(*) c FROM post_saves WHERE post_id = ?", (pid,))["c"]
    reposts = q1("SELECT COUNT(*) c FROM posts WHERE repost_of = ?", (pid,))["c"]
    follow_new = q1("SELECT COUNT(*) c FROM follows WHERE followee = ? AND created_at > ?", (me["id"], now - 7 * 86400))["c"]
    friends_new = q1("SELECT COUNT(*) c FROM friends WHERE a = ? AND created_at > ?", (me["id"], now - 7 * 86400))["c"]
    eng = (likes + comments + saves + reposts + (st["shares"] if st else 0))
    req.send_json(200, {
        "views": views, "unique": uniq,
        "avg_watch": round(st["watch_ms"] / views / 1000.0, 1) if st and views else 0,
        "retention": round(st["ratio_sum"] / views, 3) if st and views else 0,
        "completion": round(st["completes"] / views, 3) if st and views else 0,
        "skip": round(st["skips"] / views, 3) if st and views else 0,
        "duration": (q1("SELECT duration FROM post_media WHERE post_id = ? AND position = 0", (pid,)) or {"duration": 0})["duration"] or 0,
        "likes": likes, "comments": comments, "saves": saves, "reposts": reposts, "shares": st["shares"] if st else 0,
        "engagement": round(eng / views, 3) if views else 0,
        "followers": followers_count(me["id"]), "followers_week": follow_new + friends_new,
        "followers_from_video": q1("SELECT COUNT(*) c FROM follow_source fs JOIN follows f ON f.follower = fs.follower AND f.followee = fs.followee "
                                   "WHERE fs.post_id = ?", (pid,))["c"],
        "daily": [days.get(today - i, 0) for i in range(6, -1, -1)],
        "since": st["since"] if st else 0,
    })


@route("GET", r"/v1/reels/search/popular")
def reel_popular(req, me):
    rows = q("SELECT q, COUNT(DISTINCT user_id) n FROM reel_queries WHERE created_at > ? GROUP BY q ORDER BY n DESC, MAX(created_at) DESC LIMIT 12",
             (time.time() - 14 * 86400,))
    items = [r["q"] for r in rows]
    for d in DEFAULT_REEL_QUERIES:
        if len(items) >= 10:
            break
        if d not in items:
            items.append(d)
    req.send_json(200, {"queries": items[:10]})


@route("GET", r"/v1/reels/search")
def reel_search(req, me):
    params = req.query()
    query = re.sub(r"\s+", " ", params.get("q", "")).strip()[:80]
    if len(query) < 2:
        raise ApiError(400, "bad_value")
    if moderation.query_blocked(query):
        raise ApiError(422, "query_blocked")
    try:
        offset = max(0, int(params.get("offset", 0)))
        limit = max(1, min(int(params.get("limit", 20)), 30))
    except ValueError:
        raise ApiError(400, "bad_value")
    uid = me["id"]
    tokens = reel_tokens(query)
    phrase = query.lower().replace("ё", "е").lstrip("#@")
    rows = q("SELECT p.* FROM posts p JOIN post_media m ON m.post_id = p.id AND m.position = 0 "
             "WHERE p.reel = 1 AND p.repost_of IS NULL AND m.kind = 'video' AND (m.duration IS NULL OR m.duration <= ?) "
             "AND p.author NOT IN (SELECT blocked_id FROM blocks WHERE user_id = ?) "
             "AND p.author NOT IN (SELECT user_id FROM blocks WHERE blocked_id = ?) "
             "AND p.id NOT IN (SELECT post_id FROM post_reports WHERE reporter = ?) "
             "ORDER BY p.created_at DESC LIMIT 600", (MAX_REEL_SECONDS, uid, uid, uid))
    hits = []
    for p in rows:
        h = reel_haystack(p)
        if all(t in h for t in tokens):
            hits.append((0 if phrase in h else 1, p))
    hits.sort(key=lambda x: x[0])            # точное совпадение фразы — выше, внутри — свежие сверху (порядок сохраняется)
    page = [p for _, p in hits[offset:offset + limit]]
    if offset == 0 and hits:
        run("INSERT INTO reel_queries(q, user_id, created_at) VALUES (?,?,?)", (phrase[:60], uid, time.time()))
    out = []
    for p, j in zip(page, posts_json(page, uid)):
        j["author_state"] = "me" if p["author"] == uid else ("following" if is_following(uid, p["author"]) else "none")
        out.append(j)
    req.send_json(200, {"reels": out, "total": len(hits), "more": offset + limit < len(hits)})


@route("GET", r"/v1/reels")
def list_reels(req, me):
    """Короткие видео (шортс): публикации, у которых первое медиа — видео не длиннее 3 минут.
    feed=friends — только друзья; иначе — рекомендации (тот же «вкус», но с упором на долю просмотра)."""
    params = req.query()
    try:
        limit = max(1, min(int(params.get("limit", 12)), 30))
    except ValueError:
        raise ApiError(400, "bad_value")
    uid = me["id"]
    exclude = {x for x in params.get("exclude", "").split(",") if x}
    sql = ("SELECT p.* FROM posts p JOIN post_media m ON m.post_id = p.id AND m.position = 0 "
           "WHERE p.reel = 1 AND m.kind = 'video' AND (m.duration IS NULL OR m.duration <= ?) "
           "AND p.author NOT IN (SELECT blocked_id FROM blocks WHERE user_id = ?) "
           "AND p.author NOT IN (SELECT user_id FROM blocks WHERE blocked_id = ?) ")
    args = [MAX_REEL_SECONDS, uid, uid]
    if params.get("feed") == "friends":
        sql += "AND (p.author = ? OR p.author IN (SELECT b FROM friends WHERE a = ?)) "
        args += [uid, uid]
    sql += "ORDER BY p.created_at DESC LIMIT 300"
    rows = [r for r in q(sql, tuple(args)) if r["id"] not in exclude]
    if params.get("feed") == "friends":
        rows = rows[:limit]
    else:
        rows = ranked_feed(me, rows, limit)
    out = []
    for p, j in zip(rows, posts_json(rows, uid)):
        j["author_state"] = "me" if p["author"] == uid else ("following" if is_following(uid, p["author"]) else "none")
        out.append(j)
    req.send_json(200, {"reels": out})


@route("GET", r"/v1/posts")
def list_posts(req, me):
    params = req.query()
    try:
        before = float(params.get("before", time.time() + 1))
        limit = max(1, min(int(params.get("limit", 40)), 100))
    except ValueError:
        raise ApiError(400, "bad_value")
    rows = q("SELECT * FROM posts WHERE created_at < ? AND reel = 0 "
             "AND author NOT IN (SELECT blocked_id FROM blocks WHERE user_id = ?) "
             "AND author NOT IN (SELECT user_id FROM blocks WHERE blocked_id = ?) "
             "ORDER BY created_at DESC LIMIT ?", (before, me["id"], me["id"], 150 if params.get("sort") == "for_you" else limit))
    if params.get("sort") == "for_you":
        rows = ranked_feed(me, rows, limit)
    req.send_json(200, {"posts": posts_json(rows, me["id"])})


def parse_post_body(d, me):
    text = str(d.get("text", ""))
    media = d.get("media", [])
    if not isinstance(media, list) or len(media) > MAX_MEDIA_PER_POST:
        raise ApiError(400, "too_many_media")
    if len(text) > MAX_TEXT:
        raise ApiError(400, "text_too_long")
    if not text.strip() and not media:
        raise ApiError(400, "empty")
    entities = clean_entities(d.get("entities", []), text)
    items = []
    for m in media:
        if not isinstance(m, dict):
            raise ApiError(400, "bad_media")
        mid = str(m.get("id", ""))
        if mid.startswith("art:"):
            items.append((mid, "art", m.get("width"), m.get("height"), None, None))
            continue
        r = q1("SELECT * FROM media WHERE id = ? AND owner = ? AND kind IN ('image','video')", (mid, me["id"]))
        if not r:
            raise ApiError(400, "media_not_found")
        items.append((mid, r["kind"], r["width"], r["height"], r["duration"], r["thumb"]))
    return text, entities, items


def write_post_media(pid, items):
    for i, it in enumerate(items):
        run("INSERT INTO post_media(post_id, position, media_id, kind, width, height, duration, thumb) VALUES (?,?,?,?,?,?,?,?)",
            (pid, i, *it))


def drop_orphan_media(owner, ids):
    """Удаляет файлы, на которые больше никто не ссылается"""
    for mid in {i for i in ids if i and not i.startswith("art:")}:
        used = (q1("SELECT 1 FROM post_media WHERE media_id = ? OR thumb = ?", (mid, mid))
                or q1("SELECT 1 FROM avatars WHERE media_id = ?", (mid,))
                or q1("SELECT 1 FROM tracks WHERE media_id = ?", (mid,)))
        if used:
            continue
        run("DELETE FROM media WHERE id = ? AND owner = ?", (mid, owner))
        try:
            os.remove(os.path.join(MEDIA_DIR, mid))
        except OSError:
            pass


@route("POST", r"/v1/posts")
def create_post(req, me):
    body = req.body_json()
    text, entities, items = parse_post_body(body, me)
    reel = 1 if body.get("reel") else 0
    if reel:
        # шортс — одно короткое видео (до 3 минут)
        if len(items) != 1 or items[0][1] != "video" or (items[0][4] or 0) > MAX_REEL_SECONDS:
            raise ApiError(400, "bad_reel")
    pid = uuid.uuid4().hex
    uid = me["id"]
    music_enc = None
    if reel and body.get("music_track"):
        t = q1("SELECT * FROM tracks WHERE id = ? AND user_id = ?", (str(body["music_track"]), uid))
        if not t:
            raise ApiError(400, "track_not_found")
        tj = track_json(t)
        music_enc = enc(uid, "posts", COL["post_music"], pid, json.dumps(
            {"title": tj["title"], "artist": tj["artist"], "media": tj["media"]}, ensure_ascii=False))
        music_media, mkey = str(tj["media"]), music_key(tj["title"], tj["artist"])
    else:
        music_media = mkey = None
    with LOCK:
        run("BEGIN")
        try:
            run("INSERT INTO posts(id, author, text_enc, entities_enc, created_at, reel, music_enc, music_media, music_key, "
                "comments_off, no_repost) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                (pid, uid, enc(uid, "posts", COL["post_text"], pid, text),
                 enc(uid, "posts", COL["post_entities"], pid, json.dumps(entities, ensure_ascii=False)), time.time(), reel,
                 music_enc, music_media, mkey, 1 if body.get("comments_off") else 0, 1 if (reel and body.get("no_repost")) else 0))
            write_post_media(pid, items)
            run("COMMIT")
        except Exception:
            run("ROLLBACK")
            raise
    req.send_json(201, post_json(q1("SELECT * FROM posts WHERE id = ?", (pid,)), uid))


@route("PUT", r"/v1/posts/([a-f0-9]+)")
def edit_post(req, me, pid):
    p = q1("SELECT * FROM posts WHERE id = ?", (pid,))
    if not p:
        raise ApiError(404, "not_found")
    if p["author"] != me["id"]:
        raise ApiError(403, "forbidden")
    text, entities, items = parse_post_body(req.body_json(), me)
    uid = me["id"]
    old = [m["media_id"] for m in q("SELECT media_id, thumb FROM post_media WHERE post_id = ?", (pid,))]
    old += [m["thumb"] for m in q("SELECT thumb FROM post_media WHERE post_id = ?", (pid,))]
    with LOCK:
        run("BEGIN")
        try:
            run("UPDATE posts SET text_enc = ?, entities_enc = ?, edited_at = ? WHERE id = ?",
                (enc(uid, "posts", COL["post_text"], pid, text),
                 enc(uid, "posts", COL["post_entities"], pid, json.dumps(entities, ensure_ascii=False)),
                 time.time(), pid))
            run("DELETE FROM post_media WHERE post_id = ?", (pid,))
            write_post_media(pid, items)
            run("COMMIT")
        except Exception:
            run("ROLLBACK")
            raise
    drop_orphan_media(uid, old)
    req.send_json(200, post_json(q1("SELECT * FROM posts WHERE id = ?", (pid,)), uid))


@route("DELETE", r"/v1/posts/([a-f0-9]+)")
def delete_post(req, me, pid):
    p = q1("SELECT * FROM posts WHERE id = ?", (pid,))
    if not p:
        raise ApiError(404, "not_found")
    if p["author"] != me["id"]:
        raise ApiError(403, "forbidden")
    gone = [m["media_id"] for m in q("SELECT media_id FROM post_media WHERE post_id = ?", (pid,))]
    gone += [m["thumb"] for m in q("SELECT thumb FROM post_media WHERE post_id = ?", (pid,))]
    run("DELETE FROM posts WHERE id = ?", (pid,))
    drop_orphan_media(me["id"], gone)
    req.send_json(200, {"ok": True})


@route("PUT", r"/v1/posts/([a-f0-9]+)/like")
def like(req, me, pid):
    if not q1("SELECT 1 FROM posts WHERE id = ?", (pid,)):
        raise ApiError(404, "not_found")
    fresh = q1("SELECT 1 FROM likes WHERE post_id = ? AND user_id = ?", (pid, me["id"])) is None
    run("INSERT OR IGNORE INTO likes(post_id, user_id, created_at) VALUES (?, ?, ?)", (pid, me["id"], time.time()))
    if fresh:
        taste_event(me["id"], q1("SELECT * FROM posts WHERE id = ?", (pid,)), "like")
    req.send_json(200, {"ok": True})


@route("PUT", r"/v1/posts/([a-f0-9]+)/save")
def save_post(req, me, pid):
    p = q1("SELECT * FROM posts WHERE id = ?", (pid,))
    if not p:
        raise ApiError(404, "not_found")
    fresh = q1("SELECT 1 FROM post_saves WHERE post_id = ? AND user_id = ?", (pid, me["id"])) is None
    run("INSERT OR IGNORE INTO post_saves(post_id, user_id, created_at) VALUES (?,?,?)", (pid, me["id"], time.time()))
    if fresh:
        taste_event(me["id"], p, "save")
    req.send_json(200, {"ok": True, "saves": q1("SELECT COUNT(*) c FROM post_saves WHERE post_id = ?", (pid,))["c"]})


REPORT_REASONS = {"spam", "violence", "adult", "illegal", "copyright", "other"}


@route("POST", r"/v1/posts/([a-f0-9]+)/report")
def report_post(req, me, pid):
    """Пожаловаться на публикацию или шортс: сохраняем жалобу для модерации"""
    p = q1("SELECT id, author FROM posts WHERE id = ?", (pid,))
    if not p:
        raise ApiError(404, "not_found")
    reason = str(req.body_json().get("reason", "other"))
    if reason not in REPORT_REASONS:
        reason = "other"
    run("INSERT OR REPLACE INTO post_reports(post_id, reporter, reason, created_at) VALUES (?,?,?,?)",
        (pid, me["id"], reason, time.time()))
    taste_event(me["id"], q1("SELECT * FROM posts WHERE id = ?", (pid,)), "dislike")      # такое больше не показываем
    req.send_json(200, {"ok": True})


@route("DELETE", r"/v1/posts/([a-f0-9]+)/save")
def unsave_post(req, me, pid):
    run("DELETE FROM post_saves WHERE post_id = ? AND user_id = ?", (pid, me["id"]))
    req.send_json(200, {"ok": True, "saves": q1("SELECT COUNT(*) c FROM post_saves WHERE post_id = ?", (pid,))["c"]})


def repost_state(orig):
    return q1("SELECT COUNT(*) c FROM posts WHERE repost_of = ?", (orig,))["c"]


@route("PUT", r"/v1/posts/([a-f0-9]+)/repost")
def repost_post(req, me, pid):
    """Репост: у человека на странице появляется своя копия шортса (то же видео, подпись и музыка)"""
    p = q1("SELECT * FROM posts WHERE id = ?", (pid,))
    if not p:
        raise ApiError(404, "not_found")
    orig = p["repost_of"] or pid
    if p["repost_of"]:
        p = q1("SELECT * FROM posts WHERE id = ?", (orig,)) or p
    uid = me["id"]
    if p["author"] != uid and either_blocked(uid, p["author"]):
        raise ApiError(403, "blocked")
    if p["no_repost"] and p["author"] != uid:
        raise ApiError(403, "repost_disabled")
    if q1("SELECT 1 FROM posts WHERE repost_of = ? AND author = ?", (orig, uid)):
        return req.send_json(200, {"ok": True, "reposts": repost_state(orig), "reposted_by_me": True})
    new = uuid.uuid4().hex
    a = p["author"]
    text = dec(a, "posts", COL["post_text"], p["id"], p["text_enc"]) or ""
    ents = dec(a, "posts", COL["post_entities"], p["id"], p["entities_enc"]) or "[]"
    music = dec(a, "posts", COL["post_music"], p["id"], p["music_enc"]) if p["music_enc"] else None
    with LOCK:
        run("BEGIN")
        try:
            run("INSERT INTO posts(id, author, text_enc, entities_enc, created_at, reel, music_enc, repost_of) VALUES (?,?,?,?,?,?,?,?)",
                (new, uid, enc(uid, "posts", COL["post_text"], new, text), enc(uid, "posts", COL["post_entities"], new, ents),
                 time.time(), p["reel"], enc(uid, "posts", COL["post_music"], new, music) if music else None, orig))
            run("INSERT INTO post_media(post_id, position, media_id, kind, width, height, duration, thumb) "
                "SELECT ?, position, media_id, kind, width, height, duration, thumb FROM post_media WHERE post_id = ?", (new, p["id"]))
            run("COMMIT")
        except Exception:
            run("ROLLBACK")
            raise
    taste_event(uid, p, "save")
    req.send_json(200, {"ok": True, "reposts": repost_state(orig), "reposted_by_me": True})


@route("DELETE", r"/v1/posts/([a-f0-9]+)/repost")
def unrepost_post(req, me, pid):
    p = q1("SELECT * FROM posts WHERE id = ?", (pid,))
    orig = (p["repost_of"] or pid) if p else pid
    mine = q("SELECT id FROM posts WHERE repost_of = ? AND author = ?", (orig, me["id"]))
    for r in mine:
        run("DELETE FROM posts WHERE id = ?", (r["id"],))
    req.send_json(200, {"ok": True, "reposts": repost_state(orig), "reposted_by_me": False})


@route("POST", r"/v1/me/saves/sync")
def sync_saves(req, me):
    """Закладки раньше жили только на устройстве — разовая выгрузка, чтобы они попали в счётчики"""
    ids = [str(i) for i in (req.body_json().get("ids") or []) if isinstance(i, str)][:500]
    now = time.time()
    for pid in ids:
        if q1("SELECT 1 FROM posts WHERE id = ?", (pid,)):
            run("INSERT OR IGNORE INTO post_saves(post_id, user_id, created_at) VALUES (?,?,?)", (pid, me["id"], now))
    req.send_json(200, {"ok": True})


@route("GET", r"/v1/posts/([a-f0-9]+)/likes")
def post_likers(req, me, pid):
    """Кто лайкнул пост — видит только его автор"""
    post = q1("SELECT author FROM posts WHERE id = ?", (pid,))
    if not post:
        raise ApiError(404, "not_found")
    if post["author"] != me["id"]:
        raise ApiError(403, "forbidden")
    rows = q("SELECT user_id FROM likes WHERE post_id = ? ORDER BY rowid DESC LIMIT 500", (pid,))
    users = [friend_brief(r["user_id"], me["id"]) for r in rows if q1("SELECT 1 FROM users WHERE id = ?", (r["user_id"],))]
    req.send_json(200, {"users": users, "count": len(users)})


@route("DELETE", r"/v1/posts/([a-f0-9]+)/like")
def unlike(req, me, pid):
    had = q1("SELECT 1 FROM likes WHERE post_id = ? AND user_id = ?", (pid, me["id"])) is not None
    run("DELETE FROM likes WHERE post_id = ? AND user_id = ?", (pid, me["id"]))
    if had:
        taste_event(me["id"], q1("SELECT * FROM posts WHERE id = ?", (pid,)), "unlike")
    req.send_json(200, {"ok": True})


def comment_json(c, me_id):
    cid = c["id"]
    post = q1("SELECT author FROM posts WHERE id = ?", (c["post_id"],))
    liked_by_author = bool(post) and q1("SELECT 1 FROM comment_likes WHERE comment_id = ? AND user_id = ?",
                                        (cid, post["author"])) is not None
    reply_name = None
    if c["reply_to_id"]:
        replied = q1("SELECT author FROM comments WHERE id = ?", (c["reply_to_id"],))
        if replied:
            reply_name = user_brief(replied["author"], me_id)["name"]
    return {
        "id": cid, "author": user_brief(c["author"], me_id),
        "text": dec(c["author"], "comments", COL["comment_text"], cid, c["text_enc"]) or "",
        "created_at": c["created_at"],
        "likes": q1("SELECT COUNT(*) c FROM comment_likes WHERE comment_id = ?", (cid,))["c"],
        "liked_by_me": q1("SELECT 1 FROM comment_likes WHERE comment_id = ? AND user_id = ?", (cid, me_id)) is not None,
        "liked_by_author": liked_by_author,
        "parent_id": c["parent_id"],
        "reply_to_name": reply_name,
        "pinned": q1("SELECT 1 FROM posts WHERE id = ? AND pinned_comment = ?", (c["post_id"], cid)) is not None,
    }


@route("GET", r"/v1/posts/([a-f0-9]+)/comments")
def get_comments(req, me, pid):
    rows = q("SELECT * FROM comments WHERE post_id = ? "
             "AND author NOT IN (SELECT blocked_id FROM blocks WHERE user_id = ?) "
             "AND author NOT IN (SELECT user_id FROM blocks WHERE blocked_id = ?) "
             "ORDER BY created_at ASC LIMIT 1000", (pid, me["id"], me["id"]))
    req.send_json(200, {"comments": [comment_json(c, me["id"]) for c in rows]})


@route("POST", r"/v1/posts/([a-f0-9]+)/comments")
def add_comment(req, me, pid):
    p = q1("SELECT * FROM posts WHERE id = ?", (pid,))
    if not p:
        raise ApiError(404, "not_found")
    owner = q1("SELECT * FROM users WHERE id = ?", (p["author"],))
    if p["author"] != me["id"] and either_blocked(p["author"], me["id"]):
        raise ApiError(403, "blocked")
    if owner and p["author"] != me["id"] and not policy_allows(owner, me["id"], owner["comments_policy"]):
        raise ApiError(403, "comments_disabled")
    if p["comments_off"]:
        raise ApiError(403, "comments_disabled")
    data = req.body_json()
    text = str(data.get("text", "")).strip()
    if not 1 <= len(text) <= 1000:
        raise ApiError(400, "bad_text")

    parent_id = reply_to_id = None
    if data.get("parent_id"):
        target = q1("SELECT * FROM comments WHERE id = ? AND post_id = ?", (str(data["parent_id"]), pid))
        if not target:
            raise ApiError(404, "comment_not_found")
        reply_to_id = target["id"]                       # кому отвечаем
        parent_id = target["id"]                         # ответ — прямой потомок: получается дерево любой глубины

    cid = uuid.uuid4().hex
    run("INSERT INTO comments(id, post_id, author, text_enc, created_at, parent_id, reply_to_id) VALUES (?,?,?,?,?,?,?)",
        (cid, pid, me["id"], enc(me["id"], "comments", COL["comment_text"], cid, text), time.time(),
         parent_id, reply_to_id))
    taste_event(me["id"], p, "comment")
    req.send_json(201, comment_json(q1("SELECT * FROM comments WHERE id = ?", (cid,)), me["id"]))


@route("PUT", r"/v1/comments/([a-f0-9]+)/like")
def like_comment(req, me, cid):
    if not q1("SELECT 1 FROM comments WHERE id = ?", (cid,)):
        raise ApiError(404, "not_found")
    run("INSERT OR IGNORE INTO comment_likes(comment_id, user_id, created_at) VALUES (?, ?, ?)", (cid, me["id"], time.time()))
    req.send_json(200, {"ok": True})


@route("DELETE", r"/v1/comments/([a-f0-9]+)/like")
def unlike_comment(req, me, cid):
    run("DELETE FROM comment_likes WHERE comment_id = ? AND user_id = ?", (cid, me["id"]))
    req.send_json(200, {"ok": True})


def post_of_comment(cid):
    c = q1("SELECT * FROM comments WHERE id = ?", (cid,))
    if not c:
        raise ApiError(404, "not_found")
    return c, q1("SELECT * FROM posts WHERE id = ?", (c["post_id"],))


@route("PUT", r"/v1/comments/([a-f0-9]+)/pin")
def pin_comment(req, me, cid):
    c, p = post_of_comment(cid)
    if p["author"] != me["id"]:
        raise ApiError(403, "forbidden")                 # закреплять может только автор публикации
    if c["parent_id"]:
        raise ApiError(400, "only_top_level")            # закрепляются только верхние комментарии
    run("UPDATE posts SET pinned_comment = ? WHERE id = ?", (cid, p["id"]))
    req.send_json(200, {"ok": True})


@route("DELETE", r"/v1/comments/([a-f0-9]+)/pin")
def unpin_comment(req, me, cid):
    c, p = post_of_comment(cid)
    if p["author"] != me["id"]:
        raise ApiError(403, "forbidden")
    if p["pinned_comment"] == cid:
        run("UPDATE posts SET pinned_comment = NULL WHERE id = ?", (p["id"],))
    req.send_json(200, {"ok": True})


# ---------- демо-контент (создаётся один раз, тоже зашифрован) ----------

# ---------- стена пользователя ----------

@route("GET", r"/v1/users/([A-Za-z0-9_\-]+)/posts")
def user_wall(req, me, uid):
    r = q1("SELECT * FROM users WHERE id = ?", (uid,))
    if not r:
        raise ApiError(404, "not_found")
    if not can_see(r, me["id"], "wall"):
        req.send_json(200, {"posts": [], "private": True})
        return
    params = req.query()
    try:
        before = float(params.get("before", time.time() + 1))
        limit = max(1, min(int(params.get("limit", 40)), 100))
    except ValueError:
        raise ApiError(400, "bad_value")
    rows = q("SELECT * FROM posts WHERE author = ? AND reel = 0 AND created_at < ? ORDER BY created_at DESC LIMIT ?",
             (uid, before, limit))
    req.send_json(200, {"posts": posts_json(rows, me["id"]), "private": False})


# ---------- записи гостей на стене ----------

def wall_entry_json(e, viewer):
    text = dec(e["author"], "comments", COL["comment_text"], e["id"], e["text_enc"]) if e["text_enc"] else ""
    return {"id": e["id"], "owner": e["owner"], "author": user_brief(e["author"], viewer), "kind": e["kind"],
            "text": text or "", "media": e["media_id"], "width": e["width"], "height": e["height"],
            "created_at": e["created_at"], "can_delete": viewer in (e["author"], e["owner"])}


def wall_can_write(owner, viewer):
    """Писать на стену могут все, кого владелец не заблокировал и кому разрешил комментировать (общая настройка)"""
    if viewer == owner["id"]:
        return True
    if either_blocked(owner["id"], viewer):
        return False
    return policy_allows(owner, viewer, owner["comments_policy"])


@route("GET", r"/v1/users/([A-Za-z0-9_\-]+)/wall")
def wall_entries_list(req, me, uid):
    owner = q1("SELECT * FROM users WHERE id = ?", (uid,))
    if not owner:
        raise ApiError(404, "not_found")
    if owner["id"] != me["id"] and either_blocked(owner["id"], me["id"]):
        req.send_json(200, {"entries": [], "can_write": False})
        return
    if not can_see(owner, me["id"], "wall"):
        req.send_json(200, {"entries": [], "private": True, "can_write": False})
        return
    params = req.query()
    try:
        before = float(params.get("before", time.time() + 1))
        limit = max(1, min(int(params.get("limit", 40)), 100))
    except ValueError:
        raise ApiError(400, "bad_value")
    rows = q("SELECT * FROM wall_entries WHERE owner = ? AND created_at < ? ORDER BY created_at DESC LIMIT ?",
             (owner["id"], before, limit))
    out = [wall_entry_json(e, me["id"]) for e in rows if not is_blocked(me["id"], e["author"])]
    req.send_json(200, {"entries": out, "can_write": wall_can_write(owner, me["id"])})


@route("POST", r"/v1/users/([A-Za-z0-9_\-]+)/wall")
def wall_entry_add(req, me, uid):
    owner = q1("SELECT * FROM users WHERE id = ?", (uid,))
    if not owner:
        req.drain()
        raise ApiError(404, "not_found")
    if not wall_can_write(owner, me["id"]):
        req.drain()
        raise ApiError(403, "wall_closed")
    data = req.body_json()
    kind = data.get("kind")
    text = str(data.get("text") or "").strip()
    if kind not in ("text", "photo", "drawing") or len(text) > 500:
        raise ApiError(400, "bad_entry")
    media_id, width, height = None, 0, 0
    if kind == "text":
        if not text:
            raise ApiError(400, "bad_text")
    else:
        # фото и рисунок уже прошли проверку нейросетью при загрузке (/v1/media) — здесь только убеждаемся, что файл свой и это картинка
        m = q1("SELECT * FROM media WHERE id = ? AND owner = ?", (str(data.get("media") or ""), me["id"]))
        if not m or m["kind"] != "image":
            raise ApiError(400, "media_not_found")
        media_id, width, height = m["id"], m["width"] or 0, m["height"] or 0
    if q1("SELECT COUNT(*) c FROM wall_entries WHERE author = ? AND created_at > ?", (me["id"], time.time() - 3600))["c"] >= 20:
        raise ApiError(429, "too_many")
    eid = uuid.uuid4().hex
    run("INSERT INTO wall_entries(id, owner, author, kind, text_enc, media_id, width, height, created_at) VALUES (?,?,?,?,?,?,?,?,?)",
        (eid, owner["id"], me["id"], kind, enc(me["id"], "comments", COL["comment_text"], eid, text) if text else None,
         media_id, width, height, time.time()))
    req.send_json(201, wall_entry_json(q1("SELECT * FROM wall_entries WHERE id = ?", (eid,)), me["id"]))


@route("DELETE", r"/v1/wall/([a-f0-9]+)")
def wall_entry_delete(req, me, eid):
    e = q1("SELECT * FROM wall_entries WHERE id = ?", (eid,))
    if not e:
        raise ApiError(404, "not_found")
    if me["id"] not in (e["author"], e["owner"]):
        raise ApiError(403, "forbidden")
    run("DELETE FROM wall_entries WHERE id = ?", (eid,))
    req.send_json(200, {"ok": True})


@route("GET", r"/v1/music/([A-Za-z0-9_\-]+)/reels")
def music_reels(req, me, media):
    """Страница трека: все шортсы, снятые под эту музыку (как в TikTok)"""
    first = q1("SELECT * FROM posts WHERE music_media = ? AND music_key IS NOT NULL ORDER BY created_at DESC LIMIT 1", (media,))
    if not first:
        raise ApiError(404, "not_found")
    meta = music_of(first) or {}
    rows = q("SELECT * FROM posts WHERE music_key = ? AND reel = 1 AND repost_of IS NULL ORDER BY created_at DESC LIMIT 120",
             (first["music_key"],))
    visible = []
    for p in rows:
        owner = q1("SELECT * FROM users WHERE id = ?", (p["author"],))
        if not owner or either_blocked(me["id"], p["author"]):
            continue
        if p["author"] != me["id"] and not can_see(owner, me["id"], "wall"):
            continue
        visible.append(p)
        if len(visible) >= 60:
            break
    req.send_json(200, {"title": meta.get("title", ""), "artist": meta.get("artist", ""), "media": media,
                        "posts": posts_json(visible, me["id"])})


@route("GET", r"/v1/users/([A-Za-z0-9_\-]+)/reels")
def user_reels(req, me, uid):
    """Шортсы человека на его странице (как в TikTok): kind=own — свои, kind=reposts — репосты чужих"""
    r = q1("SELECT * FROM users WHERE id = ?", (uid,))
    if not r:
        raise ApiError(404, "not_found")
    if not can_see(r, me["id"], "wall"):
        req.send_json(200, {"posts": [], "private": True})
        return
    kind = req.query().get("kind", "own")
    cond = "repost_of IS NOT NULL" if kind == "reposts" else "repost_of IS NULL"
    rows = q("SELECT * FROM posts WHERE author = ? AND reel = 1 AND %s ORDER BY created_at DESC LIMIT 60" % cond, (uid,))
    req.send_json(200, {"posts": posts_json(rows, me["id"]), "private": False})


# ---------- чёрный список ----------

@route("GET", r"/v1/me/blocks")
def list_blocks(req, me):
    rows = q("SELECT * FROM blocks WHERE user_id = ? ORDER BY created_at DESC", (me["id"],))
    req.send_json(200, {"users": [{**user_brief(b["blocked_id"]), "blocked_at": b["created_at"]} for b in rows]})


@route("PUT", r"/v1/me/blocks/([A-Za-z0-9_\-]+)")
def block_user(req, me, uid):
    if uid == me["id"]:
        raise ApiError(400, "bad_value")
    if not q1("SELECT 1 FROM users WHERE id = ?", (uid,)):
        raise ApiError(404, "not_found")
    run("INSERT OR IGNORE INTO blocks(user_id, blocked_id, created_at) VALUES (?,?,?)", (me["id"], uid, time.time()))
    run("DELETE FROM friends WHERE (a = ? AND b = ?) OR (a = ? AND b = ?)", (me["id"], uid, uid, me["id"]))
    run("DELETE FROM friend_requests WHERE (from_id = ? AND to_id = ?) OR (from_id = ? AND to_id = ?)", (me["id"], uid, uid, me["id"]))
    req.send_json(200, {"ok": True})


@route("DELETE", r"/v1/me/blocks/([A-Za-z0-9_\-]+)")
def unblock_user(req, me, uid):
    run("DELETE FROM blocks WHERE user_id = ? AND blocked_id = ?", (me["id"], uid))
    req.send_json(200, {"ok": True})


# ---------- мессенджер ----------

TYPING = {}                       # (от кого, кому) -> (время, действие: typing|voice|video|photo|file)
TYPING_TTL = 6
MAX_MSG = 4000


STICKER_DIR = os.path.join(BASE, "stickers")
STICKER_PACKS = []
STICKER_IDS = {}                 # "пак/имя" -> эмодзи


def load_stickers():
    try:
        with open(os.path.join(STICKER_DIR, "packs.json"), encoding="utf-8") as f:
            packs = json.load(f)
    except (OSError, ValueError):
        return
    for pack in packs:
        items = []
        for s in pack.get("stickers", []):
            sid = "%s/%s" % (pack["id"], s["id"])
            if os.path.isfile(os.path.join(STICKER_DIR, pack["id"], s["id"] + ".png")):
                STICKER_IDS[sid] = s.get("emoji", "")
                items.append({"id": sid, "emoji": s.get("emoji", "")})
        STICKER_PACKS.append({"id": pack["id"], "title": pack["title"], "icon": "%s/%s" % (pack["id"], pack["icon"]),
                              "stickers": items})


load_stickers()


@route("GET", r"/v1/stickers")
def list_stickers(req, me):
    req.send_json(200, {"packs": STICKER_PACKS})


@route("GET", r"/stickers/([a-z0-9_]+)/([a-z0-9_]+)\.png", auth=False)
def get_sticker(req, me, pack, name):
    if "%s/%s" % (pack, name) not in STICKER_IDS:
        raise ApiError(404, "not_found")
    with open(os.path.join(STICKER_DIR, pack, name + ".png"), "rb") as f:
        body = f.read()
    req.send_response(200)
    req.send_header("Content-Type", "image/png")
    req.send_header("Content-Length", str(len(body)))
    req.send_header("Cache-Control", "public, max-age=31536000, immutable")
    req.end_headers()
    req.wfile.write(body)


ATT_KINDS = {"photo": "image", "video": "video", "circle": "video", "voice": "audio", "audio": "audio", "file": "file"}


def clean_attachments(raw, uid):
    """Вложения сообщения. Размеры и тип берём из записи о файле на сервере, а не от клиента."""
    out = []
    if not isinstance(raw, list):
        return out
    for a in raw[:10]:
        if not isinstance(a, dict):
            continue
        t = a.get("type")
        if t == "sticker":
            sid = str(a.get("sticker", ""))
            if sid in STICKER_IDS:
                out.append({"type": "sticker", "sticker": sid})
            continue
        kind = ATT_KINDS.get(t)
        if not kind:
            continue
        m = q1("SELECT * FROM media WHERE id = ? AND owner = ? AND kind = ?", (str(a.get("media_id", "")), uid, kind))
        if not m:
            raise ApiError(400, "media_not_found")
        item = {"type": t, "media_id": m["id"], "size": m["size"], "mime": m["mime"],
                "width": m["width"] or 0, "height": m["height"] or 0, "duration": m["duration"] or 0}
        if m["thumb"]:
            item["thumb"] = m["thumb"]
        if t in ("file", "audio"):
            item["name"] = clean_line(a.get("name"), 120) or "file"
        if t == "audio":
            item["title"] = clean_line(a.get("title"), 120)
            item["artist"] = clean_line(a.get("artist"), 120)
            cover = str(a.get("thumb") or "")
            if cover and q1("SELECT 1 FROM media WHERE id = ? AND owner = ? AND kind = 'image'", (cover, uid)):
                item["thumb"] = cover
        if t == "voice" and isinstance(a.get("waveform"), list):
            item["waveform"] = [max(0, min(31, int(v))) for v in a["waveform"][:64] if isinstance(v, (int, float))]
        out.append(item)
    return out


def attachments_of(m):
    raw = dec(m["sender"], "messages", COL["msg_attach"], m["id"], m["attachments_enc"]) if m["attachments_enc"] else None
    try:
        return json.loads(raw) if raw else []
    except ValueError:
        return []


def attachment_label(att):
    t = att.get("type")
    if t == "photo":
        return "Фото"
    if t == "video":
        return "Видео"
    if t == "circle":
        return "Видеосообщение"
    if t == "voice":
        return "Голосовое сообщение"
    if t == "audio":
        return att.get("title") or att.get("name") or "Музыка"
    if t == "sticker":
        return "%s Стикер" % STICKER_IDS.get(att.get("sticker"), "")
    return att.get("name") or "Файл"


CALL_MARK = "\u200bcall:"          # служебная запись о звонке в переписке: «call:статус:видео:секунды»


def call_label(text):
    try:
        _, status, video, dur = text[len(CALL_MARK) - 5:].split(":")[0:4]
    except ValueError:
        return "Звонок"
    kind = "Видеозвонок" if video == "1" else "Звонок"
    if status == "ended":
        s = int(float(dur or 0))
        return "%s · %d:%02d" % (kind, s // 60, s % 60)
    return {"missed": "Пропущенный звонок", "declined": "Отклонённый звонок",
            "cancelled": "Отменённый звонок"}.get(status, kind)


SYS_LABELS = {"left": "вышел(а) из группы", "joined": "вступил(а) в группу", "removed": "исключён(а) из группы"}


def summary_of(m, limit=120):
    """Текст для списка чатов, ответов и push: подпись или вид вложения"""
    text = (dec(m["sender"], "messages", COL["msg_text"], m["id"], m["text_enc"]) or "").replace("\n", " ")
    if text.startswith(CALL_MARK):
        return call_label(text)
    keys = m.keys()
    if "kind" in keys and m["kind"] == "poll":
        return "📊 " + text[:limit]
    if "kind" in keys and m["kind"] in SYS_LABELS:
        return user_brief(m["sender"])["name"] + " " + SYS_LABELS[m["kind"]]
    atts = attachments_of(m)
    if atts:
        label = attachment_label(atts[0])
        return ("%s, %s" % (label, text) if text else label)[:limit]
    return text[:limit]


def last_thumb(m):
    """Миниатюра вложения для списка чатов: фото — само фото, видео и кружок — их обложка (если есть)"""
    try:
        atts = attachments_of(m)
        if not atts:
            return None
        a = atts[0]
        t = a.get("type")
        if t == "photo":
            mid = a.get("thumb") or a.get("media_id")
        elif t in ("video", "circle"):
            mid = a.get("thumb")
        else:
            return None
        return {"type": t, "media": mid} if mid else None
    except Exception:
        return None


def drop_message_media(m):
    for att in attachments_of(m):
        mid = att.get("media_id")
        if not mid:
            continue
        for media_id in (mid, att.get("thumb")):
            if media_id:
                run("DELETE FROM media WHERE id = ? AND owner = ?", (media_id, m["sender"]))
                try:
                    os.remove(os.path.join(MEDIA_DIR, media_id))
                except OSError:
                    pass


def typing_action(frm, to):
    """Что сейчас делает собеседник ("typing", "voice", …) или None"""
    t = TYPING.get((frm, to))
    return t[1] if t and time.time() - t[0] < TYPING_TTL else None


def message_json(m, me_id):
    mid = m["id"]
    reply = None
    if m["reply_to"]:
        r = q1("SELECT * FROM messages WHERE id = ?", (m["reply_to"],))
        if r:
            reply = {"id": r["id"], "from_me": r["sender"] == me_id,
                     "name": user_brief(r["sender"], me_id)["name"],
                     "text": summary_of(r, 140)}
    return {
        "id": mid, "mine": m["sender"] == me_id,
        "text": dec(m["sender"], "messages", COL["msg_text"], mid, m["text_enc"]) or "",
        "entities": json.loads(dec(m["sender"], "messages", COL["msg_entities"], mid, m["entities_enc"]) or "[]"),
        "created_at": m["created_at"], "edited_at": m["edited_at"],
        "read": m["read_at"] is not None, "reply": reply, "attachments": attachments_of(m),
        "reactions": reactions_of(mid, me_id),
        **({"poll": poll_json(mid, me_id)} if m["kind"] == "poll" else {}),
        **fwd_fields(m),
    }


def fwd_fields(m):
    if not m["fwd_enc"]:
        return {}
    f = fwd_of(m)
    if not f:
        return {}
    if "story" in f:
        return {"story_reply": f["story"]}
    return {"forwarded": f}


def fwd_of(m):
    raw = dec(m["sender"], "messages", COL["msg_entities"], m["id"] + ":fwd", m["fwd_enc"])
    try:
        return json.loads(raw) if raw else None
    except ValueError:
        return None


def clone_media(media_id, new_owner):
    """Копия файла вложения для пересылающего: оригинал можно удалить, пересланное останется"""
    src = q1("SELECT * FROM media WHERE id = ?", (media_id,))
    if not src or not os.path.isfile(os.path.join(MEDIA_DIR, media_id)):
        return None
    nid = uuid.uuid4().hex
    size = src["size"]
    with open(os.path.join(MEDIA_DIR, media_id), "rb") as f, open(os.path.join(MEDIA_DIR, nid), "wb") as out:
        gen = decrypt_range(media_key(src["owner"], media_id), media_id, f, size, 0, size - 1)
        buf = bytearray()

        def read(n):
            while len(buf) < n:
                try:
                    buf.extend(next(gen))
                except StopIteration:
                    break
            piece = bytes(buf[:n])
            del buf[:n]
            return piece

        encrypt_stream(media_key(new_owner, nid), nid, read, size, out.write)
    thumb = clone_media(src["thumb"], new_owner) if src["thumb"] else None
    run("INSERT INTO media(id, owner, kind, mime, width, height, duration, thumb, size, created_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
        (nid, new_owner, src["kind"], src["mime"], src["width"], src["height"], src["duration"], thumb, size, time.time()))
    return nid


def fwd_target(uid, peer):
    """Проверка, что в этот чат можно писать; возвращает True для группы"""
    group = is_group(peer)
    if group:
        g = group_row(peer)
        mem = member_row(peer, uid) if g else None
        if not mem:
            raise ApiError(404, "not_found")
        if not can_post(g, mem):
            raise ApiError(403, "forbidden")
    elif peer != uid:
        if not q1("SELECT 1 FROM users WHERE id = ?", (peer,)):
            raise ApiError(404, "not_found")
        if either_blocked(uid, peer):
            raise ApiError(403, "blocked")
    return group


def insert_fwd(uid, peer, group, text, entities, atts, fwd, t):
    nid = uuid.uuid4().hex
    # fwd=None — «скрыть имя отправителя»: сообщение приходит как обычное, без пометки «Переслано»
    fwd_blob = enc(uid, "messages", COL["msg_entities"], nid + ":fwd", json.dumps(fwd, ensure_ascii=False)) if fwd else None
    ent = enc(uid, "messages", COL["msg_entities"], nid, json.dumps(entities, ensure_ascii=False))
    att = enc(uid, "messages", COL["msg_attach"], nid, json.dumps(atts)) if atts else None
    if group:
        run("INSERT INTO group_messages(id, group_id, sender, text_enc, entities_enc, attachments_enc, created_at, fwd_enc) "
            "VALUES (?,?,?,?,?,?,?,?)",
            (nid, peer, uid, enc(uid, "messages", COL["msg_text"], nid, text), ent, att, t, fwd_blob))
    else:
        run("INSERT INTO messages(id, sender, recipient, text_enc, entities_enc, created_at, read_at, attachments_enc, fwd_enc) "
            "VALUES (?,?,?,?,?,?,?,?,?)",
            (nid, uid, peer, enc(uid, "messages", COL["msg_text"], nid, text), ent, t,
             t if peer == uid else None, att, fwd_blob))


def notify_fwd(uid, peer, group):
    if group:
        run("UPDATE group_members SET last_read = ? WHERE group_id = ? AND user_id = ?", (time.time(), peer, uid))
        last = q1("SELECT * FROM group_messages WHERE group_id = ? ORDER BY created_at DESC LIMIT 1", (peer,))
        notify_group(group_row(peer), uid, summary_of(last, 150), set())
    elif peer != uid:
        last = q1("SELECT * FROM messages WHERE sender = ? AND recipient = ? ORDER BY created_at DESC LIMIT 1", (uid, peer))
        notify_message(uid, peer, summary_of(last, 150))


@route("POST", r"/v1/chats/([A-Za-z0-9_\-]+)/forward")
def forward_messages(req, me, peer):
    """Пересылка: копия сообщения с пометкой «Переслано от …» (как в Telegram)"""
    uid = me["id"]
    d = req.body_json()
    ids = [str(i) for i in (d.get("ids") or []) if isinstance(i, str)][:50]
    if not ids:
        raise ApiError(400, "bad_value")
    hide_caption = bool(d.get("hide_caption"))
    hide_sender = bool(d.get("hide_sender")) or hide_caption      # «без подписей»: ни текста, ни пометки «Переслано от»
    group = fwd_target(uid, peer)
    items = []
    for mid in ids:
        m, grp, _ = find_message(mid, uid)
        if grp and (group_row(m["group_id"]) or {"no_forward": 0})["no_forward"]:
            raise ApiError(403, "no_forward")
        if m["kind"] in SYS_LABELS:
            continue
        items.append(m)
    items.sort(key=lambda r: r["created_at"])
    now = time.time()
    count = 0
    for i, m in enumerate(items):
        text = dec(m["sender"], "messages", COL["msg_text"], m["id"], m["text_enc"]) or ""
        if text.startswith(CALL_MARK):
            continue
        entities = [] if m["kind"] == "poll" else json.loads(
            dec(m["sender"], "messages", COL["msg_entities"], m["id"], m["entities_enc"]) or "[]")
        atts = []
        for a in attachments_of(m):
            a = dict(a)
            if a.get("media_id"):
                nid = clone_media(a["media_id"], uid)
                if not nid:
                    continue
                a["media_id"] = nid
                if a.get("thumb"):
                    a["thumb"] = clone_media(a["thumb"], uid) or None
                    if not a["thumb"]:
                        del a["thumb"]
            atts.append(a)
        if hide_caption and atts:                      # «скрыть подписи»: остаётся только медиа
            text, entities = "", []
        if not (text or atts):
            continue
        # автор: если он скрыл пересылки в приватности — показываем «скрытый автор»
        sender_row = q1("SELECT * FROM users WHERE id = ?", (m["sender"],))
        shown = sender_row is not None and (m["sender"] == uid or can_see(sender_row, uid, "forwards"))
        fwd = {"id": m["sender"] if shown else None,
               "name": user_brief(m["sender"], uid)["name"] if shown else "Скрытый автор"}
        insert_fwd(uid, peer, group, text, entities, atts, None if hide_sender else fwd, now + i * 0.001)
        count += 1
    if count:
        notify_fwd(uid, peer, group)
    req.send_json(200, {"ok": True, "count": count})


@route("POST", r"/v1/chats/([A-Za-z0-9_\-]+)/share-post")
def share_post(req, me, peer):
    """Отправить пост в чат как пересылку: текст + медиа поста, «Переслано от автора»"""
    uid = me["id"]
    d = req.body_json()
    pid = str(d.get("post_id", ""))
    p = q1("SELECT * FROM posts WHERE id = ?", (pid,))
    if not p or (p["author"] != uid and either_blocked(p["author"], uid)):
        raise ApiError(404, "not_found")
    group = fwd_target(uid, peer)
    text = dec(p["author"], "posts", COL["post_text"], pid, p["text_enc"]) or ""
    entities = json.loads(dec(p["author"], "posts", COL["post_entities"], pid, p["entities_enc"]) or "[]")
    atts = []
    for pm in q("SELECT * FROM post_media WHERE post_id = ? ORDER BY position", (pid,))[:10]:
        nid = clone_media(pm["media_id"], uid)
        if not nid:
            continue
        item = {"type": "video" if pm["kind"] == "video" else "photo", "media_id": nid, "size": 0, "mime": "",
                "width": pm["width"] or 0, "height": pm["height"] or 0, "duration": pm["duration"] or 0}
        row = q1("SELECT size, mime, thumb FROM media WHERE id = ?", (nid,))
        if row:
            item["size"], item["mime"] = row["size"], row["mime"]
            if row["thumb"]:
                item["thumb"] = row["thumb"]
        atts.append(item)
    if d.get("hide_caption") and atts:
        text, entities = "", []
    if not (text or atts):
        raise ApiError(400, "bad_value")
    if d.get("hide_sender") or d.get("hide_caption"):
        fwd = {"id": None, "name": "", "post": pid}              # пометку не показываем, но ссылка на пост остаётся
    else:
        fwd = {"id": p["author"], "name": user_brief(p["author"], uid)["name"], "post": pid}
    insert_fwd(uid, peer, group, text, entities, atts, fwd, time.time())
    taste_event(uid, p, "share")
    if p["author"] != uid:
        run("INSERT OR IGNORE INTO post_stats(post_id, since) VALUES (?, ?)", (pid, time.time()))
        run("UPDATE post_stats SET shares = shares + 1 WHERE post_id = ?", (pid,))
    notify_fwd(uid, peer, group)
    req.send_json(200, {"ok": True})


def clean_poll(raw):
    if not isinstance(raw, dict):
        return None
    question = clean_line(raw.get("question"), 200)
    opts = [clean_line(o, 100) for o in (raw.get("options") or []) if isinstance(o, str)]
    opts = [o for o in opts if o][:10]
    if not question or len(opts) < 2:
        raise ApiError(400, "bad_poll")
    return {"question": question, "options": opts, "multiple": 1 if raw.get("multiple") else 0,
            "anonymous": 0 if raw.get("anonymous") is False else 1}


def create_poll(mid, uid, poll):
    run("INSERT INTO polls(message_id, creator, multiple, anonymous) VALUES (?,?,?,?)",
        (mid, uid, poll["multiple"], poll["anonymous"]))
    for i, text in enumerate(poll["options"]):
        run("INSERT INTO poll_options(message_id, idx, text_enc) VALUES (?,?,?)",
            (mid, i, enc(uid, "messages", COL["msg_text"], "%s:%d" % (mid, i), text)))


def poll_json(mid, me_id):
    p = q1("SELECT * FROM polls WHERE message_id = ?", (mid,))
    if not p:
        return None
    question_row = q1("SELECT * FROM messages WHERE id = ?", (mid,)) or q1("SELECT * FROM group_messages WHERE id = ?", (mid,))
    options = []
    total_voters = q1("SELECT COUNT(DISTINCT user_id) c FROM poll_votes WHERE message_id = ?", (mid,))["c"]
    for o in q("SELECT * FROM poll_options WHERE message_id = ? ORDER BY idx", (mid,)):
        votes = q("SELECT user_id, created_at FROM poll_votes WHERE message_id = ? AND idx = ? ORDER BY created_at",
                  (mid, o["idx"]))
        item = {"idx": o["idx"],
                "text": dec(p["creator"], "messages", COL["msg_text"], "%s:%d" % (mid, o["idx"]), o["text_enc"]) or "",
                "votes": len(votes), "mine": any(v["user_id"] == me_id for v in votes)}
        if not p["anonymous"]:
            item["voters"] = [{**user_brief(v["user_id"], me_id), "at": v["created_at"]} for v in votes[:50]]
        options.append(item)
    return {"multiple": bool(p["multiple"]), "anonymous": bool(p["anonymous"]), "closed": bool(p["closed"]),
            "total": total_voters, "options": options, "mine_created": p["creator"] == me_id}


@route("PUT", r"/v1/messages/([a-f0-9]+)/vote")
def vote_poll(req, me, mid):
    find_message(mid, me["id"])
    p = q1("SELECT * FROM polls WHERE message_id = ?", (mid,))
    if not p:
        raise ApiError(404, "not_found")
    if p["closed"]:
        raise ApiError(400, "poll_closed")
    picked = req.body_json().get("options")
    if not isinstance(picked, list):
        raise ApiError(400, "bad_value")
    valid = {r["idx"] for r in q("SELECT idx FROM poll_options WHERE message_id = ?", (mid,))}
    picked = sorted({int(i) for i in picked if isinstance(i, int) and i in valid})
    if not p["multiple"]:
        picked = picked[:1]
    run("DELETE FROM poll_votes WHERE message_id = ? AND user_id = ?", (mid, me["id"]))
    now = time.time()
    for i in picked:
        run("INSERT INTO poll_votes(message_id, user_id, idx, created_at) VALUES (?,?,?,?)", (mid, me["id"], i, now))
    req.send_json(200, poll_json(mid, me["id"]))


@route("PUT", r"/v1/messages/([a-f0-9]+)/poll-close")
def close_poll(req, me, mid):
    find_message(mid, me["id"])
    p = q1("SELECT * FROM polls WHERE message_id = ? AND creator = ?", (mid, me["id"]))
    if not p:
        raise ApiError(404, "not_found")
    run("UPDATE polls SET closed = 1 WHERE message_id = ?", (mid,))
    req.send_json(200, poll_json(mid, me["id"]))


def post_system(gid, uid, kind):
    """Служебная запись в группе («вышел», «вступил»): видна всем, непрочитанным не считается"""
    g = group_row(gid)
    if not g or g["type"] == "channel":
        return
    mid = uuid.uuid4().hex
    now = time.time()
    run("INSERT INTO group_messages(id, group_id, sender, text_enc, entities_enc, created_at, kind) VALUES (?,?,?,?,?,?,?)",
        (mid, gid, uid, enc(uid, "messages", COL["msg_text"], mid, kind),
         enc(uid, "messages", COL["msg_entities"], mid, "[]"), now, kind))


@route("GET", r"/v1/messages/([a-f0-9]+)/info")
def message_info(req, me, mid):
    """Кто прочитал и кто отреагировал (и когда)"""
    uid = me["id"]
    m, grp, _ = find_message(mid, uid)
    reactions = [{**user_brief(r["user_id"], uid), "emoji": r["emoji"], "at": r["created_at"]}
                 for r in q("SELECT * FROM reactions WHERE message_id = ? ORDER BY created_at", (mid,))]
    if grp:
        readers = [{**user_brief(r["user_id"], uid), "at": r["last_read"]}
                   for r in q("SELECT user_id, last_read FROM group_members WHERE group_id = ? AND user_id != ? "
                              "AND last_read >= ? ORDER BY last_read", (m["group_id"], m["sender"], m["created_at"]))]
        total = group_count(m["group_id"]) - 1
    else:
        peer = m["recipient"] if m["sender"] == uid else m["sender"]
        readers = [{**user_brief(peer, uid), "at": m["read_at"]}] if m["read_at"] else []
        total = 1
    req.send_json(200, {"readers": readers, "total": max(total, 0), "reactions": reactions,
                        "sent_at": m["created_at"], "mine": m["sender"] == uid})


def reactions_of(mid, me_id):
    agg = {}
    for r in q("SELECT emoji, user_id FROM reactions WHERE message_id = ? ORDER BY created_at", (mid,)):
        e = agg.setdefault(r["emoji"], {"emoji": r["emoji"], "count": 0, "mine": False})
        e["count"] += 1
        e["mine"] = e["mine"] or r["user_id"] == me_id
    return sorted(agg.values(), key=lambda x: -x["count"])


def dm_key(a, b):
    return "d:" + ":".join(sorted((a, b)))


def pinned_of(chat_key, me_id, group=False):
    out = []
    for p in q("SELECT message_id FROM pins WHERE chat_key = ? ORDER BY created_at DESC LIMIT 20", (chat_key,)):
        m = q1("SELECT * FROM group_messages WHERE id = ?", (p["message_id"],)) if group else \
            q1("SELECT * FROM messages WHERE id = ?", (p["message_id"],))
        if not m:
            continue
        out.append(gmsg_json(m, me_id) if group else message_json(m, me_id))
    return out


def visible_clause(me_id):
    return "((sender = ? AND del_sender = 0) OR (recipient = ? AND del_recipient = 0))", (me_id, me_id)


def preview_of(m, me_id):
    return summary_of(m)


# ---------- push (APNs) ----------

PUSH_PREVIEW = os.environ.get("ORBITA_PUSH_PREVIEW", "1") != "0"


def drop_push_token(token):
    run("DELETE FROM push_tokens WHERE token_idx = ?", (KR.blind_index(token, "push"),))


def unread_total(uid):
    return (q1("SELECT COUNT(*) c FROM messages WHERE recipient = ? AND read_at IS NULL AND del_recipient = 0",
               (uid,))["c"] + group_unread_total(uid))


def notify_message(sender, recipient, text):
    """Отправляет push всем устройствам получателя. Ошибки доставки не влияют на сообщение."""
    if not push.configured():
        return
    try:
        rows = q("SELECT * FROM push_tokens WHERE user_id = ?", (recipient,))
        if not rows:
            return
        brief = user_brief(sender, recipient)
        body = (text.replace("\n", " ")[:150] if PUSH_PREVIEW else "Новое сообщение")
        payload = push.build_payload(brief["name"], body, unread_total(recipient), "chat-" + sender,
                                     {"chat": sender, "name": brief["name"], "avatar": brief["avatar"]})
        for r in rows:
            token = dec(recipient, "push", COL["push_token"], r["id"], r["token_enc"])
            if token:
                push.enqueue(r["env"], token, payload)
    except Exception as e:
        print("push: %s" % e.__class__.__name__)


@route("PUT", r"/v1/me/push")
def register_push(req, me):
    d = req.body_json()
    token = str(d.get("token", "")).strip().lower()
    environment = "sandbox" if d.get("env") == "sandbox" else "production"
    if not re.fullmatch(r"[0-9a-f]{64,200}", token):
        raise ApiError(400, "bad_value")
    idx = KR.blind_index(token, "push")
    run("DELETE FROM push_tokens WHERE token_idx = ?", (idx,))       # устройство могло сменить аккаунт
    pid = uuid.uuid4().hex
    run("INSERT INTO push_tokens(id, user_id, session_id, token_idx, token_enc, env, updated_at) VALUES (?,?,?,?,?,?,?)",
        (pid, me["id"], me["session_id"], idx, enc(me["id"], "push", COL["push_token"], pid, token),
         environment, time.time()))
    req.send_json(200, {"ok": True, "push": push.configured()})


@route("DELETE", r"/v1/me/push")
def unregister_push(req, me):
    token = str(req.body_json().get("token", "")).strip().lower()
    if token:
        run("DELETE FROM push_tokens WHERE token_idx = ? AND user_id = ?", (KR.blind_index(token, "push"), me["id"]))
    req.send_json(200, {"ok": True})


@route("GET", r"/v1/chats")
def list_chats(req, me):
    uid = me["id"]
    group_rows, group_total = group_chat_rows(uid)
    # последнее сообщение каждого собеседника — одним запросом (оконная функция), непрочитанные — вторым
    last_rows = q("SELECT * FROM (SELECT m.*, CASE WHEN sender = ?1 THEN recipient ELSE sender END AS peer, "
                  "ROW_NUMBER() OVER (PARTITION BY CASE WHEN sender = ?1 THEN recipient ELSE sender END "
                  "ORDER BY created_at DESC) AS rn FROM messages m "
                  "WHERE (sender = ?1 AND del_sender = 0) OR (recipient = ?1 AND del_recipient = 0)) "
                  "WHERE rn = 1 ORDER BY created_at DESC LIMIT 200", (uid,))
    unread_by = {r["sender"]: r["c"] for r in q(
        "SELECT sender, COUNT(*) c FROM messages WHERE recipient = ? AND read_at IS NULL AND del_recipient = 0 "
        "GROUP BY sender", (uid,))}
    tags_by = {r["sender"]: r["c"] for r in q(
        "SELECT d.sender, COUNT(*) c FROM dm_mentions d JOIN messages m ON m.id = d.message_id "
        "WHERE d.recipient = ? AND m.read_at IS NULL AND m.del_recipient = 0 GROUP BY d.sender", (uid,))}
    peers = [r["peer"] for r in last_rows]
    users = {}
    if peers:
        users = {u["id"]: u for u in q("SELECT * FROM users WHERE id IN (%s)" % _in(peers), peers)}
    chats, total = [], 0
    for last in last_rows:
        peer = last["peer"]
        unread = unread_by.get(peer, 0) if peer != uid else 0
        total += unread
        chats.append({"peer": user_brief(peer, uid, users.get(peer)), "unread": unread, "updated_at": last["created_at"],
                      "last": {"text": preview_of(last, uid), "mine": last["sender"] == uid,
                               "read": last["read_at"] is not None, "created_at": last["created_at"],
                               "thumb": last_thumb(last)},
                      "typing": typing_action(peer, uid), "mentions": tags_by.get(peer, 0) if peer != uid else 0})
    chats.extend(group_rows)
    chats.sort(key=lambda c: c["updated_at"], reverse=True)
    req.send_json(200, {"chats": chats, "unread": total + group_total})


@route("GET", r"/v1/search/messages")
def search_messages(req, me):
    """Поиск слова по тексту всех переписок (личные и группы/каналы)"""
    uid = me["id"]
    needle = (req.query().get("q") or "").strip().lower()
    if len(needle) < 2:
        return req.send_json(200, {"hits": []})
    hits = []
    rows = q("SELECT * FROM messages WHERE ((sender = ?1 AND del_sender = 0) OR (recipient = ?1 AND del_recipient = 0)) "
             "ORDER BY created_at DESC LIMIT 4000", (uid,))
    users = {}
    for m in rows:
        if len(hits) >= 40:
            break
        try:
            text = summary_of(m, 400)
        except Exception:
            continue
        if needle not in text.lower():
            continue
        peer = m["recipient"] if m["sender"] == uid else m["sender"]
        if peer not in users:
            users[peer] = user_brief(peer, uid)
        hits.append({"peer": users[peer], "id": m["id"], "text": text, "mine": m["sender"] == uid,
                     "created_at": m["created_at"]})
    for mem in q("SELECT * FROM group_members WHERE user_id = ?", (uid,)):
        g = group_row(mem["group_id"])
        if not g:
            continue
        since = history_since(g, mem)
        grows = q("SELECT * FROM group_messages WHERE group_id = ? AND created_at >= ? AND id NOT IN "
                  "(SELECT message_id FROM group_hidden WHERE user_id = ?) ORDER BY created_at DESC LIMIT 1500",
                  (g["id"], since, uid))
        found = 0
        for m in grows:
            if found >= 10:
                break
            try:
                text = summary_of(m, 400)
            except Exception:
                continue
            if needle in text.lower():
                found += 1
                hits.append({"peer": group_peer(g), "id": m["id"], "text": text, "mine": m["sender"] == uid,
                             "created_at": m["created_at"]})
    hits.sort(key=lambda h: h["created_at"], reverse=True)
    req.send_json(200, {"hits": hits[:60]})


@route("GET", r"/v1/chats/([A-Za-z0-9_\-]+)/messages")
def chat_messages(req, me, peer):
    uid = me["id"]
    if is_group(peer):
        return group_messages(req, me, peer)
    pr = q1("SELECT * FROM users WHERE id = ?", (peer,))
    if not pr:
        raise ApiError(404, "not_found")
    try:
        limit = max(1, min(300, int(req.query().get("limit", "120"))))
    except ValueError:
        limit = 120
    now = time.time()
    fu = q1("SELECT id FROM messages WHERE sender = ? AND recipient = ? AND read_at IS NULL AND del_recipient = 0 "
            "ORDER BY created_at LIMIT 1", (peer, uid)) if peer != uid else None
    first_unread = fu["id"] if fu else None
    if req.query().get("peek") != "1":                       # предпросмотр не помечает прочитанным
        run("UPDATE messages SET read_at = ? WHERE sender = ? AND recipient = ? AND read_at IS NULL AND del_recipient = 0",
            (now, peer, uid))
    rows = q("SELECT * FROM messages WHERE ((sender = ? AND recipient = ? AND del_sender = 0) "
             "OR (sender = ? AND recipient = ? AND del_recipient = 0)) ORDER BY created_at DESC LIMIT ?",
             (uid, peer, peer, uid, limit))
    rows.reverse()
    req.send_json(200, {"messages": [message_json(m, uid) for m in rows],
                        "peer": {**profile_json(pr, uid), "name": contact_name(uid, peer) or names(pr)[2]},
                        "typing": typing_action(peer, uid),
                        "pinned": pinned_of(dm_key(uid, peer), uid), "first_unread": first_unread,
                        "can_write": not either_blocked(uid, peer)})


def record_dm_mention(peer, sender, mid, text, now):
    """В личной переписке «тегом» считается @username собеседника в тексте"""
    names = {n.lower() for n in MENTION_RE.findall(text or "")}
    if not names:
        return
    r = q1("SELECT username_enc FROM users WHERE id = ?", (peer,))
    uname = (dec_profile(q1("SELECT * FROM users WHERE id = ?", (peer,)), "username_enc", COL["username"]) or "").lower() if r else ""
    if uname and uname in names:
        run("INSERT OR IGNORE INTO dm_mentions(message_id, sender, recipient, created_at) VALUES (?,?,?,?)",
            (mid, sender, peer, now))


def deliver_dm(uid, peer, text, entities, attachments, reply_to, poll=None, story=None, silent=False):
    """Кладёт личное сообщение в базу. peer == uid — «Избранное» (сообщение сразу прочитано)."""
    mid = uuid.uuid4().hex
    now = time.time()
    run("INSERT INTO messages(id, sender, recipient, text_enc, entities_enc, reply_to, created_at, read_at, attachments_enc, kind) "
        "VALUES (?,?,?,?,?,?,?,?,?,?)",
        (mid, uid, peer, enc(uid, "messages", COL["msg_text"], mid, text),
         enc(uid, "messages", COL["msg_entities"], mid, json.dumps(entities, ensure_ascii=False)), reply_to, now,
         now if peer == uid else None,
         enc(uid, "messages", COL["msg_attach"], mid, json.dumps(attachments)) if attachments else None,
         "poll" if poll else None))
    if poll:
        create_poll(mid, uid, poll)
    if story:
        run("UPDATE messages SET fwd_enc = ? WHERE id = ?",
            (enc(uid, "messages", COL["msg_entities"], mid + ":fwd", json.dumps({"story": story}, ensure_ascii=False)), mid))
    TYPING.pop((uid, peer), None)
    UVER[peer] = UVER.get(peer, 0) + 1                 # у получателя список чатов обновится сразу
    row = q1("SELECT * FROM messages WHERE id = ?", (mid,))
    if peer != uid:
        record_dm_mention(peer, uid, mid, text, now)
    if peer != uid and not silent:
        notify_message(uid, peer, summary_of(row, 150))
    return row


@route("POST", r"/v1/chats/([A-Za-z0-9_\-]+)/messages")
def send_message(req, me, peer):
    uid = me["id"]
    d = req.body_json()
    send_at = d.get("send_at")
    if is_group(peer):
        if send_at:
            raise ApiError(400, "bad_value")
        return group_send(req, me, peer)
    if peer != uid:
        if not q1("SELECT 1 FROM users WHERE id = ?", (peer,)):
            raise ApiError(404, "not_found")
        if either_blocked(uid, peer):
            raise ApiError(403, "blocked")
    poll = clean_poll(d.get("poll"))
    text = poll["question"] if poll else str(d.get("text", "")).strip()
    attachments = [] if poll else clean_attachments(d.get("attachments"), uid)
    if len(text) > MAX_MSG or not (text or attachments):
        raise ApiError(400, "bad_text")
    entities = [] if poll else clean_entities(d.get("entities", []), text)
    reply_to = None
    if d.get("reply_to"):
        r = q1("SELECT * FROM messages WHERE id = ?", (str(d["reply_to"]),))
        if r and {r["sender"], r["recipient"]} == {uid, peer}:
            reply_to = r["id"]
    if send_at and not poll:
        try:
            when = float(send_at)
        except (TypeError, ValueError):
            raise ApiError(400, "bad_value")
        now = time.time()
        if when > now + 5:
            if when > now + 366 * 86400 or peer == uid:
                raise ApiError(400, "bad_value")
            if q1("SELECT COUNT(*) c FROM scheduled WHERE sender = ?", (uid,))["c"] >= 100:
                raise ApiError(400, "too_many")
            sid = uuid.uuid4().hex
            payload = json.dumps({"text": text, "entities": entities, "attachments": attachments,
                                  "reply_to": reply_to}, ensure_ascii=False)
            run("INSERT INTO scheduled(id, sender, peer, payload_enc, send_at, created_at) VALUES (?,?,?,?,?,?)",
                (sid, uid, peer, enc(uid, "messages", COL["msg_text"], sid, payload), when, now))
            req.send_json(201, {"scheduled": True, "id": sid, "send_at": when})
            return
    story = None
    if d.get("story_id") and peer != uid:
        st = q1("SELECT * FROM stories WHERE id = ? AND author = ? AND expires_at > ?", (str(d["story_id"]), peer, time.time()))
        if st:
            story = {"id": st["id"], "media_id": st["media_id"], "kind": st["kind"]}
    row = deliver_dm(uid, peer, text, entities, attachments, reply_to, poll, story, silent=bool(d.get("silent")))
    req.send_json(201, message_json(row, uid))


def scheduled_json(r, uid):
    p = json.loads(dec(uid, "messages", COL["msg_text"], r["id"], r["payload_enc"]) or "{}")
    return {"id": r["id"], "text": p.get("text", ""), "send_at": r["send_at"],
            "attachments": len(p.get("attachments") or [])}


@route("GET", r"/v1/chats/([A-Za-z0-9_\-]+)/scheduled")
def list_scheduled(req, me, peer):
    rows = q("SELECT * FROM scheduled WHERE sender = ? AND peer = ? ORDER BY send_at", (me["id"], peer))
    req.send_json(200, {"items": [scheduled_json(r, me["id"]) for r in rows]})


@route("DELETE", r"/v1/scheduled/([a-f0-9]+)")
def cancel_scheduled(req, me, sid):
    r = q1("SELECT * FROM scheduled WHERE id = ? AND sender = ?", (sid, me["id"]))
    if not r:
        raise ApiError(404, "not_found")
    p = json.loads(dec(me["id"], "messages", COL["msg_text"], sid, r["payload_enc"]) or "{}")
    run("DELETE FROM scheduled WHERE id = ?", (sid,))
    for a in p.get("attachments") or []:                 # вложения отменённого сообщения больше не нужны
        for media_id in (a.get("media_id"), a.get("thumb")):
            if media_id:
                run("DELETE FROM media WHERE id = ? AND owner = ?", (media_id, me["id"]))
                try:
                    os.remove(os.path.join(MEDIA_DIR, media_id))
                except OSError:
                    pass
    req.send_json(200, {"ok": True})


def scheduler_loop():
    """Раз в несколько секунд отправляет созревшие отложенные сообщения и убирает истёкшие истории"""
    while True:
        time.sleep(4)
        try:
            for r in q("SELECT * FROM scheduled WHERE send_at <= ? ORDER BY send_at LIMIT 50", (time.time(),)):
                run("DELETE FROM scheduled WHERE id = ?", (r["id"],))
                uid, peer = r["sender"], r["peer"]
                p = json.loads(dec(uid, "messages", COL["msg_text"], r["id"], r["payload_enc"]) or "{}")
                if either_blocked(uid, peer) or not q1("SELECT 1 FROM users WHERE id = ?", (peer,)):
                    continue
                deliver_dm(uid, peer, p.get("text", ""), p.get("entities") or [], p.get("attachments") or [],
                           p.get("reply_to"))
            for st in q("SELECT * FROM stories WHERE expires_at <= ? LIMIT 50", (time.time(),)):
                drop_story(st)
        except Exception as e:
            print("scheduler: %s" % e.__class__.__name__)


# ---------- истории (живут 24 часа) ----------

STORY_TTL = 24 * 3600
STORY_FOREVER = 100 * 365 * 86400
MAX_PERMANENT_STORIES = 50


def drop_story(st):
    run("DELETE FROM story_views WHERE story_id = ?", (st["id"],))
    run("DELETE FROM story_likes WHERE story_id = ?", (st["id"],))
    run("DELETE FROM stories WHERE id = ?", (st["id"],))
    run("DELETE FROM media WHERE id = ? AND owner = ?", (st["media_id"], st["author"]))
    try:
        os.remove(os.path.join(MEDIA_DIR, st["media_id"]))
    except OSError:
        pass


def story_json(st, me_id):
    return {"id": st["id"], "media_id": st["media_id"], "kind": st["kind"],
            "thumb": (q1("SELECT thumb FROM media WHERE id = ?", (st["media_id"],)) or {"thumb": None})["thumb"] if st["kind"] == "video" else None,
            "caption": dec(st["author"], "posts", COL["post_text"], st["id"], st["caption_enc"]) or "",
            "created_at": st["created_at"], "expires_at": st["expires_at"], "permanent": bool(st["permanent"]),
            "viewed": st["author"] == me_id or bool(q1("SELECT 1 FROM story_views WHERE story_id = ? AND viewer = ?",
                                                       (st["id"], me_id))),
            "views": q1("SELECT COUNT(*) c FROM story_views WHERE story_id = ?", (st["id"],))["c"]
            if st["author"] == me_id else 0,
            "likes": q1("SELECT COUNT(*) c FROM story_likes WHERE story_id = ?", (st["id"],))["c"],
            "liked": q1("SELECT 1 FROM story_likes WHERE story_id = ? AND user_id = ?", (st["id"], me_id)) is not None}


@route("POST", r"/v1/stories")
def create_story(req, me):
    uid = me["id"]
    d = req.body_json()
    kind = "video" if d.get("kind") == "video" else "image"
    m = q1("SELECT * FROM media WHERE id = ? AND owner = ? AND kind = ?", (str(d.get("media_id", "")), uid, kind))
    if not m:
        raise ApiError(400, "media_not_found")
    if kind == "video" and (m["duration"] or 0) > 61:
        raise ApiError(400, "too_long")
    caption = clean_line(d.get("caption"), 200) or ""
    forever = bool(d.get("forever"))
    if forever and q1("SELECT COUNT(*) c FROM stories WHERE author = ? AND permanent = 1", (uid,))["c"] >= MAX_PERMANENT_STORIES:
        raise ApiError(400, "story_limit")
    sid = uuid.uuid4().hex
    now = time.time()
    run("INSERT INTO stories(id, author, media_id, kind, caption_enc, created_at, expires_at, permanent) VALUES (?,?,?,?,?,?,?,?)",
        (sid, uid, m["id"], kind, enc(uid, "posts", COL["post_text"], sid, caption) if caption else None,
         now, now + (STORY_FOREVER if forever else STORY_TTL), 1 if forever else 0))
    req.send_json(201, story_json(q1("SELECT * FROM stories WHERE id = ?", (sid,)), uid))


@route("GET", r"/v1/stories")
def list_stories(req, me):
    uid = me["id"]
    audience = story_audience(uid)
    authors = [uid] + sorted(audience)
    out = []
    now = time.time()

    def collect(a, suggested=False):
        if a != uid and either_blocked(uid, a):
            return
        # «навсегда»-истории первые сутки — в ленте, потом только в профиле
        rows = [r for r in q("SELECT * FROM stories WHERE author = ? AND expires_at > ? ORDER BY created_at", (a, now))
                if not r["permanent"] or r["created_at"] > now - STORY_TTL]
        if not rows:
            return
        items = [story_json(r, uid) for r in rows]
        out.append({"user": user_brief(a, uid), "items": items, "suggested": suggested,
                    "all_viewed": all(i["viewed"] for i in items), "latest": rows[-1]["created_at"]})

    for a in authors:
        collect(a)
    if not any(g["user"]["id"] != uid for g in out):
        for a in story_suggested(uid):
            collect(a, True)
    out.sort(key=lambda g: (g["user"]["id"] != uid, g["all_viewed"], -g["latest"]))
    req.send_json(200, {"stories": out})


def story_for(sid, uid):
    st = q1("SELECT * FROM stories WHERE id = ? AND expires_at > ?", (sid, time.time()))
    if not st:
        raise ApiError(404, "not_found")
    if st["author"] != uid and either_blocked(uid, st["author"]):
        raise ApiError(403, "forbidden")
    return st


def story_audience(uid):
    """Чьи истории видны: друзья и те, кто добавил меня в контакты"""
    ids = {r["b"] for r in q("SELECT b FROM friends WHERE a = ?", (uid,))}
    ids |= {r["user_id"] for r in q("SELECT user_id FROM contacts WHERE contact_id = ?", (uid,))}
    ids.discard(uid)
    return ids


def story_suggested(uid, limit=5):
    """Нет ни друзей, ни контактов с историями — показываем несколько чужих, чтобы лента не была пустой"""
    now = time.time()
    out = []
    for r in q("SELECT author, MAX(created_at) t FROM stories WHERE expires_at > ? AND author != ? "
               "AND (permanent = 0 OR created_at > ?) GROUP BY author ORDER BY t DESC LIMIT 30",
               (now, uid, now - STORY_TTL)):
        if not either_blocked(uid, r["author"]):
            out.append(r["author"])
        if len(out) >= limit:
            break
    return out


@route("GET", r"/v1/stories/([a-f0-9]+)")
def get_story(req, me, sid):
    """Одна история по id — открыть из переписки («ответ на историю»)"""
    # доступ — как у самой истории (не истекла, нет блокировки): раньше тут ещё требовалась «аудитория»,
    # и история незнакомого автора из ленты рекомендаций после ответа на неё «пропадала»
    st = story_for(sid, me["id"])
    item = story_json(st, me["id"])
    u = q1("SELECT * FROM users WHERE id = ?", (st["author"],))
    b = user_brief(st["author"], me["id"], u)
    req.send_json(200, {"user": {"id": b["id"], "name": b["name"], "username": b["username"], "avatar": b["avatar"]},
                        "items": [item], "all_viewed": item["viewed"], "suggested": False})


@route("PUT", r"/v1/stories/([a-f0-9]+)/like")
def like_story(req, me, sid):
    st = story_for(sid, me["id"])
    on = bool(req.body_json().get("liked", True))
    if on:
        run("INSERT OR IGNORE INTO story_likes(story_id, user_id, created_at) VALUES (?,?,?)", (sid, me["id"], time.time()))
        if st["author"] != me["id"]:
            run("INSERT OR IGNORE INTO story_views(story_id, viewer, viewed_at) VALUES (?,?,?)", (sid, me["id"], time.time()))
    else:
        run("DELETE FROM story_likes WHERE story_id = ? AND user_id = ?", (sid, me["id"]))
    req.send_json(200, story_json(st, me["id"]))


@route("PUT", r"/v1/stories/([a-f0-9]+)/forever")
def keep_story(req, me, sid):
    st = q1("SELECT * FROM stories WHERE id = ? AND author = ? AND expires_at > ?", (sid, me["id"], time.time()))
    if not st:
        raise ApiError(404, "not_found")
    on = req.body_json().get("forever", True)
    if on and not st["permanent"]:
        if q1("SELECT COUNT(*) c FROM stories WHERE author = ? AND permanent = 1", (me["id"],))["c"] >= MAX_PERMANENT_STORIES:
            raise ApiError(400, "story_limit")
        run("UPDATE stories SET permanent = 1, expires_at = ? WHERE id = ?", (time.time() + STORY_FOREVER, sid))
    elif not on and st["permanent"]:
        run("UPDATE stories SET permanent = 0, expires_at = ? WHERE id = ?", (st["created_at"] + STORY_TTL, sid))
    req.send_json(200, story_json(q1("SELECT * FROM stories WHERE id = ?", (sid,)), me["id"]))


@route("GET", r"/v1/users/([A-Za-z0-9_\-]+)/stories")
def user_permanent_stories(req, me, uid):
    if uid != me["id"] and (either_blocked(me["id"], uid) or uid not in story_audience(me["id"])):
        req.send_json(200, {"stories": [], "count": 0})
        return
    rows = q("SELECT * FROM stories WHERE author = ? AND (permanent = 1 OR expires_at > ?) ORDER BY created_at", (uid, time.time()))
    req.send_json(200, {"stories": [story_json(r, me["id"]) for r in rows], "count": len(rows)})


@route("POST", r"/v1/stories/([a-f0-9]+)/view")
def view_story(req, me, sid):
    st = story_for(sid, me["id"])
    if st["author"] != me["id"]:
        run("INSERT OR IGNORE INTO story_views(story_id, viewer, viewed_at) VALUES (?,?,?)", (sid, me["id"], time.time()))
    req.send_json(200, {"ok": True})


@route("GET", r"/v1/stories/([a-f0-9]+)/viewers")
def story_viewers(req, me, sid):
    st = story_for(sid, me["id"])
    if st["author"] != me["id"]:
        raise ApiError(403, "forbidden")
    rows = q("SELECT * FROM story_views WHERE story_id = ? ORDER BY viewed_at DESC LIMIT 200", (sid,))
    liked = {r["user_id"]: r["created_at"] for r in q("SELECT * FROM story_likes WHERE story_id = ?", (sid,))}
    viewers = [{**user_brief(r["viewer"], me["id"]), "at": r["viewed_at"], "liked": r["viewer"] in liked} for r in rows]
    viewers.sort(key=lambda v: (not v["liked"]))        # поставившие сердечко — наверху (стабильная сортировка)
    req.send_json(200, {"viewers": viewers, "likes": len(liked)})


# ---- Колокольчик: лента активности (лайки, комментарии, подписки…). Ничего не хранится отдельно — читаем из тех же таблиц,
# поэтому тысяча событий в час не стоит записей. Непрочитанное = всё, что новее notif_seen.
ACT_SOURCES = [
    ("like", "SELECT l.user_id AS who, l.post_id AS ref, '' AS ref2, l.created_at AS at FROM likes l "
             "JOIN posts p ON p.id = l.post_id WHERE p.author = :me AND l.user_id <> :me AND l.created_at > 0"),
    ("comment", "SELECT c.author AS who, c.post_id AS ref, c.id AS ref2, c.created_at AS at FROM comments c "
                "JOIN posts p ON p.id = c.post_id WHERE p.author = :me AND c.author <> :me AND c.reply_to_id IS NULL"),
    ("reply", "SELECT c.author AS who, c.post_id AS ref, c.id AS ref2, c.created_at AS at FROM comments c "
              "WHERE c.author <> :me AND (c.reply_to_id IN (SELECT id FROM comments WHERE author = :me) "
              "OR c.parent_id IN (SELECT id FROM comments WHERE author = :me))"),
    ("comment_like", "SELECT cl.user_id AS who, cm.post_id AS ref, cl.comment_id AS ref2, cl.created_at AS at FROM comment_likes cl "
                     "JOIN comments cm ON cm.id = cl.comment_id WHERE cm.author = :me AND cl.user_id <> :me AND cl.created_at > 0"),
    ("follow", "SELECT follower AS who, '' AS ref, '' AS ref2, created_at AS at FROM follows WHERE followee = :me"),
    ("friend_request", "SELECT from_id AS who, '' AS ref, '' AS ref2, created_at AS at FROM friend_requests WHERE to_id = :me"),
    ("story_like", "SELECT sl.user_id AS who, sl.story_id AS ref, '' AS ref2, sl.created_at AS at FROM story_likes sl "
                   "JOIN stories st ON st.id = sl.story_id WHERE st.author = :me AND sl.user_id <> :me"),
    ("repost", "SELECT r.author AS who, r.repost_of AS ref, r.id AS ref2, r.created_at AS at FROM posts r "
               "JOIN posts o ON o.id = r.repost_of WHERE o.author = :me AND r.author <> :me"),
]


def notif_seen(uid):
    r = q1("SELECT seen_at FROM notif_state WHERE user_id = ?", (uid,))
    return r["seen_at"] if r else 0.0


@route("GET", r"/v1/me/activity/count")
def activity_count(req, me):
    seen, total = notif_seen(me["id"]), 0
    for kind, sql in ACT_SOURCES:
        r = q1("SELECT COUNT(*) c FROM (SELECT 1 FROM (%s) WHERE at > :seen LIMIT 1000)" % sql, {"me": me["id"], "seen": seen})
        total += r["c"] if r else 0
        if total >= 1000:
            break
    req.send_json(200, {"unread": min(total, 999), "more": total >= 1000})


@route("GET", r"/v1/me/activity")
def activity_list(req, me):
    qs = req.query()
    try:
        before = float(qs.get("before") or 0) or time.time() + 10
        limit = max(1, min(60, int(qs.get("limit") or 40)))
    except ValueError:
        raise ApiError(400, "bad_request")
    seen = notif_seen(me["id"])
    rows = []
    for kind, sql in ACT_SOURCES:
        for r in q("SELECT * FROM (%s) WHERE at < :before ORDER BY at DESC LIMIT :n" % sql,
                   {"me": me["id"], "before": before, "n": limit}):
            rows.append((kind, r))
    rows.sort(key=lambda kr: -kr[1]["at"])
    items, cache = [], {}
    for kind, r in rows:
        if len(items) >= limit:
            break
        who = r["who"]
        if who not in cache:
            cache[who] = None if either_blocked(me["id"], who) else user_brief(who, me["id"])
        if cache[who] is None:
            continue
        text = ""
        if kind in ("comment", "reply", "comment_like") and r["ref2"]:
            c = q1("SELECT * FROM comments WHERE id = ?", (r["ref2"],))
            if c:
                text = (dec(c["author"], "comments", COL["comment_text"], c["id"], c["text_enc"]) or "")[:90]
        elif kind in ("like", "repost") and r["ref"]:
            pp = q1("SELECT * FROM posts WHERE id = ?", (r["ref"],))
            if pp:
                text = (dec(pp["author"], "posts", COL["post_text"], pp["id"], pp["text_enc"]) or "")[:70]
        items.append({"id": "%s:%s:%s:%s" % (kind, who, r["ref"], r["ref2"]), "kind": kind, "at": r["at"],
                      "unread": r["at"] > seen, "user": cache[who], "post_id": r["ref"] if kind != "story_like" else "",
                      "story_id": r["ref"] if kind == "story_like" else "", "text": text})
    req.send_json(200, {"items": items})


@route("POST", r"/v1/me/activity/seen")
def activity_seen(req, me):
    run("INSERT OR REPLACE INTO notif_state(user_id, seen_at) VALUES (?, ?)", (me["id"], time.time()))
    req.send_json(200, {"ok": True})


@route("DELETE", r"/v1/stories/([a-f0-9]+)")
def delete_story(req, me, sid):
    st = q1("SELECT * FROM stories WHERE id = ? AND author = ?", (sid, me["id"]))
    if not st:
        raise ApiError(404, "not_found")
    drop_story(st)
    req.send_json(200, {"ok": True})


@route("POST", r"/v1/chats/([A-Za-z0-9_\-]+)/typing")
def chat_typing(req, me, peer):
    if is_group(peer) and not member_row(peer, me["id"]):
        raise ApiError(403, "forbidden")
    if len(TYPING) > 5000:
        TYPING.clear()
    action = str(req.body_json().get("action", "typing"))
    TYPING[(me["id"], peer)] = (time.time(), action if action in ("typing", "voice", "video", "photo", "file") else "typing")
    req.send_json(200, {"ok": True})


@route("PUT", r"/v1/messages/([a-f0-9]+)")
def edit_message(req, me, mid):
    if q1("SELECT 1 FROM group_messages WHERE id = ?", (mid,)):
        return group_edit(req, me, mid)
    m = q1("SELECT * FROM messages WHERE id = ? AND sender = ? AND del_sender = 0", (mid, me["id"]))
    if not m:
        raise ApiError(404, "not_found")
    d = req.body_json()
    text = str(d.get("text", "")).strip()
    if len(text) > MAX_MSG or not (text or attachments_of(m)):
        raise ApiError(400, "bad_text")
    entities = clean_entities(d.get("entities", []), text)
    run("UPDATE messages SET text_enc = ?, entities_enc = ?, edited_at = ? WHERE id = ?",
        (enc(me["id"], "messages", COL["msg_text"], mid, text),
         enc(me["id"], "messages", COL["msg_entities"], mid, json.dumps(entities, ensure_ascii=False)),
         time.time(), mid))
    req.send_json(200, message_json(q1("SELECT * FROM messages WHERE id = ?", (mid,)), me["id"]))


@route("DELETE", r"/v1/messages/([a-f0-9]+)")
def delete_message(req, me, mid):
    uid = me["id"]
    if q1("SELECT 1 FROM group_messages WHERE id = ?", (mid,)):
        return group_delete(req, me, mid)
    m = q1("SELECT * FROM messages WHERE id = ? AND (sender = ? OR recipient = ?)", (mid, uid, uid))
    if not m:
        raise ApiError(404, "not_found")
    if m["sender"] == uid and req.query().get("all") == "1":
        drop_message_media(m)
        run("DELETE FROM messages WHERE id = ?", (mid,))            # у обоих
        run("DELETE FROM reactions WHERE message_id = ?", (mid,))
        run("DELETE FROM pins WHERE message_id = ?", (mid,))
    elif m["sender"] == m["recipient"]:                         # «Избранное»
        drop_message_media(m)
        run("DELETE FROM messages WHERE id = ?", (mid,))
        run("DELETE FROM reactions WHERE message_id = ?", (mid,))
        run("DELETE FROM pins WHERE message_id = ?", (mid,))
    elif m["sender"] == uid:
        run("UPDATE messages SET del_sender = 1 WHERE id = ?", (mid,))
    else:
        run("UPDATE messages SET del_recipient = 1 WHERE id = ?", (mid,))
    req.send_json(200, {"ok": True})


# ---------- звонки (WebRTC): сервер только передаёт сигналы, медиа идёт напрямую / через TURN ----------

CALLS = {}                        # id -> {caller, callee, video, state, created, answered}
CALL_SIGNALS = {}                 # user_id -> [сигналы]; живут только в памяти и не пишутся на диск
USER_CALL = {}                    # user_id -> id текущего звонка
RING_SECONDS = 45
CALL_LOG_SCHEMA = """CREATE TABLE IF NOT EXISTS call_log(
  id TEXT PRIMARY KEY, caller TEXT NOT NULL, callee TEXT NOT NULL, video INTEGER NOT NULL,
  status TEXT NOT NULL, created_at REAL NOT NULL, duration REAL NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS idx_calllog_user ON call_log(caller, callee, created_at);"""
DB.executescript(CALL_LOG_SCHEMA)


def ice_servers():
    servers = [{"urls": ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"]}]
    turn = os.environ.get("ORBITA_TURN_URL")
    if turn:
        servers.append({"urls": [u.strip() for u in turn.split(",")],
                        "username": os.environ.get("ORBITA_TURN_USER", ""),
                        "credential": os.environ.get("ORBITA_TURN_PASS", "")})
    return servers


def call_push(call, caller):
    for u in (call["callee"],):
        notify_message(caller, u, "Входящий видеозвонок" if call["video"] else "Входящий звонок")


def finish_call(cid, status, by=None):
    c = CALLS.pop(cid, None)
    if not c:
        return
    for u in (c["caller"], c["callee"]):
        if USER_CALL.get(u) == cid:
            USER_CALL.pop(u, None)
        if u != by:
            CALL_SIGNALS.setdefault(u, []).append({"call": cid, "kind": "end", "data": status})
    dur = time.time() - c["answered"] if c.get("answered") else 0
    run("INSERT OR REPLACE INTO call_log(id, caller, callee, video, status, created_at, duration) VALUES (?,?,?,?,?,?,?)",
        (cid, c["caller"], c["callee"], 1 if c["video"] else 0, status, c["created"], dur))
    # запись о звонке в переписке: когда и сколько длился
    try:
        mid = uuid.uuid4().hex
        text = "%s%s:%d:%d" % (CALL_MARK, status, 1 if c["video"] else 0, int(dur))
        now = time.time()
        run("INSERT INTO messages(id, sender, recipient, text_enc, entities_enc, reply_to, created_at, read_at) "
            "VALUES (?,?,?,?,?,?,?,?)",
            (mid, c["caller"], c["callee"], enc(c["caller"], "messages", COL["msg_text"], mid, text),
             enc(c["caller"], "messages", COL["msg_entities"], mid, "[]"), None, now,
             now if status == "ended" else None))
    except Exception as e:
        print("call message: %s" % e.__class__.__name__)


def reap_calls():
    now = time.time()
    for cid, c in list(CALLS.items()):
        if c["state"] == "ringing" and now - c["created"] > RING_SECONDS:
            finish_call(cid, "missed")
        elif c["state"] == "active" and now - min(c["seen"].values()) > 25:      # приложение закрыли / пропала сеть
            finish_call(cid, "ended")


@route("POST", r"/v1/calls")
def start_call(req, me):
    uid = me["id"]
    d = req.body_json()
    to = str(d.get("to", ""))
    target = q1("SELECT * FROM users WHERE id = ?", (to,))
    if not target or to == uid:
        raise ApiError(404, "not_found")
    if either_blocked(uid, to):
        raise ApiError(403, "blocked")
    if not policy_allows(target, uid, privacy_of(target).get("calls", "all")):
        raise ApiError(403, "forbidden")
    reap_calls()
    if uid in USER_CALL:
        raise ApiError(409, "busy")
    if to in USER_CALL:
        raise ApiError(409, "callee_busy")
    cid = uuid.uuid4().hex
    CALLS[cid] = {"caller": uid, "callee": to, "video": bool(d.get("video")), "state": "ringing",
                  "created": time.time(), "answered": None, "seen": {uid: time.time(), to: time.time()}}
    USER_CALL[uid] = USER_CALL[to] = cid
    call_push(CALLS[cid], uid)
    req.send_json(201, {"id": cid, "ice": ice_servers()})


@route("GET", r"/v1/calls/poll")
def poll_calls(req, me):
    uid = me["id"]
    reap_calls()
    cid = USER_CALL.get(uid)
    c = CALLS.get(cid) if cid else None
    if c:
        c["seen"][uid] = time.time()
    incoming = None
    if c and c["callee"] == uid and c["state"] == "ringing":
        incoming = {"id": cid, "video": c["video"], "from": user_brief(c["caller"], uid), "ice": ice_servers()}
    current = None
    if c and c["caller"] == uid:
        current = {"id": cid, "state": c["state"], "video": c["video"]}
    signals = CALL_SIGNALS.pop(uid, [])
    req.send_json(200, {"incoming": incoming, "current": current, "signals": signals})


def _my_call(cid, uid):
    c = CALLS.get(cid)
    if not c or uid not in (c["caller"], c["callee"]):
        raise ApiError(404, "not_found")
    return c


@route("POST", r"/v1/calls/([a-f0-9]+)/signal")
def call_signal(req, me, cid):
    c = _my_call(cid, me["id"])
    d = req.body_json()
    kind = d.get("kind")
    data = str(d.get("data", ""))
    if kind not in ("offer", "answer", "ice") or len(data) > 20000:
        raise ApiError(400, "bad_value")
    other = c["callee"] if me["id"] == c["caller"] else c["caller"]
    q_ = CALL_SIGNALS.setdefault(other, [])
    if len(q_) > 400:
        del q_[:200]
    q_.append({"call": cid, "kind": kind, "data": data})
    req.send_json(200, {"ok": True})


@route("POST", r"/v1/calls/([a-f0-9]+)/answer")
def call_answer(req, me, cid):
    c = _my_call(cid, me["id"])
    if c["callee"] != me["id"] or c["state"] != "ringing":
        raise ApiError(409, "bad_state")
    c["state"] = "active"
    c["answered"] = time.time()
    c["seen"] = {c["caller"]: time.time(), c["callee"]: time.time()}
    CALL_SIGNALS.setdefault(c["caller"], []).append({"call": cid, "kind": "accepted", "data": ""})
    req.send_json(200, {"ok": True, "ice": ice_servers(), "video": c["video"]})


@route("POST", r"/v1/calls/([a-f0-9]+)/end")
def call_end(req, me, cid):
    c = _my_call(cid, me["id"])
    if c["state"] == "ringing":
        status = "cancelled" if c["caller"] == me["id"] else "declined"
    else:
        status = "ended"
    finish_call(cid, status, by=me["id"])
    req.send_json(200, {"ok": True})


@route("GET", r"/v1/calls/history")
def call_history(req, me):
    uid = me["id"]
    rows = q("SELECT * FROM call_log WHERE caller = ? OR callee = ? ORDER BY created_at DESC LIMIT 100", (uid, uid))
    out = [{"id": r["id"], "mine": r["caller"] == uid, "video": bool(r["video"]), "status": r["status"],
            "created_at": r["created_at"], "duration": r["duration"],
            "peer": user_brief(r["callee"] if r["caller"] == uid else r["caller"], uid)} for r in rows]
    req.send_json(200, {"calls": out})



def find_message(mid, uid):
    """(строка, это_группа, ключ_чата) если сообщение доступно пользователю"""
    m = q1("SELECT * FROM messages WHERE id = ? AND ((sender = ? AND del_sender = 0) OR (recipient = ? AND del_recipient = 0))",
           (mid, uid, uid))
    if m:
        peer = m["recipient"] if m["sender"] == uid else m["sender"]
        return m, False, dm_key(uid, peer)
    m = q1("SELECT * FROM group_messages WHERE id = ?", (mid,))
    if m and member_row(m["group_id"], uid):
        return m, True, m["group_id"]
    raise ApiError(404, "not_found")


@route("PUT", r"/v1/messages/([a-f0-9]+)/reaction")
def set_reaction(req, me, mid):
    m, grp, _ = find_message(mid, me["id"])
    emoji = str(req.body_json().get("emoji") or "").strip()
    if not emoji:
        run("DELETE FROM reactions WHERE message_id = ? AND user_id = ?", (mid, me["id"]))
    else:
        if len(emoji) > 12 or emoji.isascii():
            raise ApiError(400, "bad_value")
        run("INSERT OR REPLACE INTO reactions(message_id, user_id, emoji, created_at) VALUES (?,?,?,?)",
            (mid, me["id"], emoji, time.time()))
    req.send_json(200, gmsg_json(m, me["id"]) if grp else message_json(m, me["id"]))


@route("PUT", r"/v1/messages/([a-f0-9]+)/pin")
def set_pin(req, me, mid):
    m, grp, key = find_message(mid, me["id"])
    if grp and not is_admin(member_row(m["group_id"], me["id"])):
        raise ApiError(403, "forbidden")
    if req.body_json().get("pinned", True):
        run("INSERT OR REPLACE INTO pins(chat_key, message_id, pinned_by, created_at) VALUES (?,?,?,?)",
            (key, mid, me["id"], time.time()))
    else:
        run("DELETE FROM pins WHERE chat_key = ? AND message_id = ?", (key, mid))
    req.send_json(200, {"pinned": pinned_of(key, me["id"], group=grp)})


@route("DELETE", r"/v1/chats/([A-Za-z0-9_\-]+)")
def clear_chat(req, me, peer):
    uid = me["id"]
    if is_group(peer):
        leave_group(peer, uid)
        return req.send_json(200, {"ok": True})
    run("UPDATE messages SET del_sender = 1 WHERE sender = ? AND recipient = ?", (uid, peer))
    run("UPDATE messages SET del_recipient = 1 WHERE sender = ? AND recipient = ?", (peer, uid))
    req.send_json(200, {"ok": True})


# ---------- контакты ----------

@route("GET", r"/v1/contacts")
def list_contacts(req, me):
    uid = me["id"]
    rows = q("SELECT contact_id, created_at FROM contacts WHERE user_id = ?", (uid,))
    out = []
    for r in rows:
        u = q1("SELECT * FROM users WHERE id = ?", (r["contact_id"],))
        if not u:
            continue
        out.append({**user_brief(u["id"], uid), "real_name": names(u)[2]})
    out.sort(key=lambda c: c["name"].lower())
    req.send_json(200, {"contacts": out})


@route("PUT", r"/v1/contacts/([A-Za-z0-9_\-]+)")
def put_contact(req, me, cid):
    uid = me["id"]
    u = q1("SELECT * FROM users WHERE id = ?", (cid,))
    if cid == uid or not u:
        raise ApiError(400 if cid == uid else 404, "bad_value" if cid == uid else "not_found")
    name = clean_line(req.body_json().get("name"), 64) or names(u)[2]
    blob = enc(uid, "contacts", COL["contact_name"], uid + ":" + cid, name)
    run("INSERT INTO contacts(user_id, contact_id, name_enc, created_at) VALUES (?,?,?,?) "
        "ON CONFLICT(user_id, contact_id) DO UPDATE SET name_enc = excluded.name_enc", (uid, cid, blob, time.time()))
    req.send_json(200, {**user_brief(cid, uid), "real_name": names(u)[2]})


@route("DELETE", r"/v1/contacts/([A-Za-z0-9_\-]+)")
def delete_contact(req, me, cid):
    run("DELETE FROM contacts WHERE user_id = ? AND contact_id = ?", (me["id"], cid))
    req.send_json(200, {"ok": True})


# ---------- импорт контактов и «N теперь в Orbita» ----------

MAX_IMPORT = 3000


def norm_phone(raw):
    """Номер в едином виде +<цифры>. 8XXXXXXXXXX и 10 цифр без кода считаем российскими"""
    raw = str(raw or "").strip()
    digits = re.sub(r"\D", "", raw)
    if not 7 <= len(digits) <= 15:
        return None
    if raw.startswith("+"):
        return "+" + digits
    if len(digits) == 11 and digits[0] in "78":
        return "+7" + digits[1:]
    if len(digits) == 10:
        return "+7" + digits
    return "+" + digits


def findable(r):
    """Можно ли найти человека по номеру (настройка «Кто может найти меня по номеру»)"""
    return privacy_of(r).get("find") == "all"


def push_notice(rid, title, body, data):
    if not push.configured():
        return
    try:
        rows = q("SELECT * FROM push_tokens WHERE user_id = ?", (rid,))
        if not rows:
            return
        payload = push.build_payload(title, body, unread_total(rid), "joined", data)
        for r in rows:
            token = dec(rid, "push", COL["push_token"], r["id"], r["token_enc"])
            if token:
                push.enqueue(r["env"], token, payload)
    except Exception as e:
        print("push: %s" % e.__class__.__name__)


def announce_join(uid):
    """Новый (или вновь находимый) пользователь: тем, у кого его номер в записной книге, приходит «теперь в Orbita»"""
    me = q1("SELECT * FROM users WHERE id = ?", (uid,))
    if not me or not me["phone_idx"] or not findable(me):
        return
    for ic in q("SELECT * FROM imported_contacts WHERE phone_idx = ? AND owner <> ? AND notified = 0",
                (me["phone_idx"], uid)):
        owner = ic["owner"]
        run("UPDATE imported_contacts SET notified = 1 WHERE owner = ? AND phone_idx = ?", (owner, ic["phone_idx"]))
        if either_blocked(owner, uid):
            continue
        book = dec(owner, "contacts", COL["contact_name"], owner + ":" + ic["phone_idx"], ic["name_enc"]) if ic["name_enc"] else None
        name = book or names(me)[2]
        nid = uuid.uuid4().hex
        run("INSERT INTO notices(id, user_id, about, kind, name_enc, created_at) VALUES (?,?,?,?,?,?)",
            (nid, owner, uid, "joined", enc(owner, "contacts", COL["contact_name"], "n:" + nid, name), time.time()))
        push_notice(owner, "Orbita", "%s теперь в Orbita" % name, {"chat": uid, "name": name, "avatar": me["avatar"]})


@route("POST", r"/v1/import/contacts")
def import_contacts(req, me):
    uid = me["id"]
    items = req.body_json().get("contacts")
    if not isinstance(items, list):
        raise ApiError(400, "bad_value")
    matches, seen = [], set()
    for it in items[:MAX_IMPORT]:
        if not isinstance(it, dict):
            continue
        ph = norm_phone(it.get("phone"))
        if not ph:
            continue
        idx = KR.blind_index(ph, "phone")
        name = clean_line(it.get("name"), 60)
        u = q1("SELECT * FROM users WHERE phone_idx = ? AND id <> ?", (idx, uid))
        found = bool(u) and findable(u) and not either_blocked(uid, u["id"])
        run("INSERT OR REPLACE INTO imported_contacts(owner, phone_idx, name_enc, notified, created_at) VALUES (?,?,?,?,?)",
            (uid, idx, enc(uid, "contacts", COL["contact_name"], uid + ":" + idx, name) if name else None,
             1 if found else 0, time.time()))
        if found and u["id"] not in seen:
            seen.add(u["id"])
            matches.append({"user": user_brief(u["id"], uid), "book_name": name,
                            "in_contacts": q1("SELECT 1 FROM contacts WHERE user_id = ? AND contact_id = ?", (uid, u["id"])) is not None})
    req.send_json(200, {"matches": matches, "imported": min(len(items), MAX_IMPORT)})


@route("DELETE", r"/v1/import/contacts")
def forget_imported(req, me):
    run("DELETE FROM imported_contacts WHERE owner = ?", (me["id"],))
    req.send_json(200, {"ok": True})


@route("GET", r"/v1/notices")
def list_notices(req, me):
    uid = me["id"]
    out = []
    for n in q("SELECT * FROM notices WHERE user_id = ? ORDER BY created_at DESC LIMIT 20", (uid,)):
        if either_blocked(uid, n["about"]):
            continue
        out.append({"id": n["id"], "kind": n["kind"], "created_at": n["created_at"],
                    "name": dec(uid, "contacts", COL["contact_name"], "n:" + n["id"], n["name_enc"]) if n["name_enc"] else None,
                    "user": user_brief(n["about"], uid)})
    req.send_json(200, {"notices": out})


@route("POST", r"/v1/notices/dismiss")
def dismiss_notices(req, me):
    ids = req.body_json().get("ids")
    if not isinstance(ids, list):
        raise ApiError(400, "bad_value")
    for i in ids[:50]:
        run("DELETE FROM notices WHERE id = ? AND user_id = ?", (str(i), me["id"]))
    req.send_json(200, {"ok": True})


# ---------- группы и каналы ----------

MAX_GROUP_MEMBERS = 5000
HANDLE_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]{4,31}$")
SLOW_STEPS = (0, 10, 30, 60, 300, 900, 3600)


def is_group(cid):
    return isinstance(cid, str) and cid.startswith("g_")


def member_row(gid, uid):
    return q1("SELECT * FROM group_members WHERE group_id = ? AND user_id = ?", (gid, uid))


def group_row(gid):
    return q1("SELECT * FROM groups WHERE id = ?", (gid,))


def is_admin(mem):
    return bool(mem) and mem["role"] in ("owner", "admin")


def can_post(g, mem):
    if not mem:
        return False
    if g["type"] == "channel" or g["who_writes"] == "admins":
        return is_admin(mem)
    return True


def group_title(g):
    return dec(g["owner"], "groups", COL["group_title"], g["id"], g["title_enc"]) or ("Канал" if g["type"] == "channel" else "Группа")


def group_about(g):
    return (dec(g["owner"], "groups", COL["group_about"], g["id"], g["about_enc"]) or "") if g["about_enc"] else ""


def group_count(gid):
    return q1("SELECT COUNT(*) c FROM group_members WHERE group_id = ?", (gid,))["c"]


def group_peer(g):
    return {"id": g["id"], "name": group_title(g), "username": g["handle"], "avatar": None,
            "group": True, "kind": g["kind"], "type": g["type"], "handle": g["handle"],
            "members": group_count(g["id"]), "no_forward": bool(g["no_forward"])}


def history_since(g, mem):
    """Если история для новых участников скрыта — видны только сообщения после вступления"""
    if mem and not g["history"] and mem["role"] != "owner":
        return mem["joined_at"]
    return 0


def group_info(g, me_id):
    gid = g["id"]
    mem = member_row(gid, me_id)
    admin = is_admin(mem)
    show_members = bool(mem) and (g["type"] != "channel" or admin)
    members = [{**user_brief(m["user_id"], me_id), "role": m["role"]}
               for m in q("SELECT * FROM group_members WHERE group_id = ? ORDER BY joined_at", (gid,))] if show_members else []
    link_ok = admin or (bool(mem) and g["kind"] == "open")
    return {"id": gid, "name": group_title(g), "about": group_about(g), "kind": g["kind"], "type": g["type"],
            "handle": g["handle"], "approve": bool(g["approve"]), "no_forward": bool(g["no_forward"]),
            "slow": g["slow"], "who_writes": g["who_writes"], "history": bool(g["history"]),
            "members": members, "count": group_count(gid),
            "my_role": mem["role"] if mem else None, "code": g["code"] if (mem and link_ok) else None,
            "muted": bool(mem and mem["muted"]), "can_write": can_post(g, mem),
            "requests": q1("SELECT COUNT(*) c FROM group_requests WHERE group_id = ?", (gid,))["c"] if admin else 0,
            "pending": q1("SELECT 1 FROM group_requests WHERE group_id = ? AND user_id = ?", (gid, me_id)) is not None,
            "discussion": discussion_info(g)}


def discussion_info(g):
    """Чат, привязанный к каналу для комментариев: {id, name} или None"""
    did = g["discussion"] if g["type"] == "channel" else None
    dg = group_row(did) if did else None
    return {"id": dg["id"], "name": group_title(dg)} if dg and dg["type"] == "group" else None


def comments_count(g, mid):
    """Сколько комментариев под постом канала (None — комментарии выключены)"""
    di = g["discussion"] if g and g["type"] == "channel" else None
    if not di:
        return None
    mirror = q1("SELECT id FROM group_messages WHERE mirror_of = ? AND group_id = ?", (mid, di))
    if not mirror:
        return 0
    return q1("SELECT COUNT(*) c FROM group_messages WHERE group_id = ? AND reply_to = ?", (di, mirror["id"]))["c"]


def group_typing(gid, me_id):
    now = time.time()
    for (frm, to), (t, action) in list(TYPING.items()):
        if to == gid and frm != me_id and now - t < TYPING_TTL:
            return action
    return None


def group_unread(gid, uid, last_read, since=0):
    return q1("SELECT COUNT(*) c FROM group_messages WHERE group_id = ? AND sender != ? AND created_at > ? "
              "AND kind IS NOT 'left' AND kind IS NOT 'joined' AND kind IS NOT 'removed' "
              "AND id NOT IN (SELECT message_id FROM group_hidden WHERE user_id = ?)",
              (gid, uid, max(last_read, since), uid))["c"]


def group_unread_total(uid):
    total = 0
    for m in q("SELECT * FROM group_members WHERE user_id = ? AND muted = 0", (uid,)):
        g = group_row(m["group_id"])
        if g:
            total += group_unread(m["group_id"], uid, m["last_read"], history_since(g, m))
    return total


def group_chat_rows(uid):
    rows, total = [], 0
    for mem in q("SELECT * FROM group_members WHERE user_id = ?", (uid,)):
        g = group_row(mem["group_id"])
        if not g:
            continue
        since = history_since(g, mem)
        last = q1("SELECT * FROM group_messages WHERE group_id = ? AND created_at >= ? AND id NOT IN "
                  "(SELECT message_id FROM group_hidden WHERE user_id = ?) ORDER BY created_at DESC LIMIT 1",
                  (g["id"], since, uid))
        unread = group_unread(g["id"], uid, mem["last_read"], since)
        mentions = mentions_unread(g["id"], uid, mem["last_read"])
        total += unread if not mem["muted"] else mentions
        channel = g["type"] == "channel"
        if last:
            who = "" if (channel or last["sender"] == uid or last["kind"] in SYS_LABELS) else user_brief(last["sender"], uid)["name"].split(" ")[0] + ": "
            item = {"text": who + summary_of(last), "mine": last["sender"] == uid,
                    "read": q1("SELECT 1 FROM group_members WHERE group_id = ? AND user_id != ? AND last_read >= ?",
                               (g["id"], uid, last["created_at"])) is not None,
                    "created_at": last["created_at"], "thumb": last_thumb(last)}
            updated = last["created_at"]
        else:
            item = {"text": "Канал создан" if channel else "Группа создана", "mine": False, "read": True,
                    "created_at": g["created_at"]}
            updated = g["created_at"]
        rows.append({"peer": group_peer(g), "unread": unread, "updated_at": updated, "last": item,
                     "typing": group_typing(g["id"], uid), "muted": bool(mem["muted"]), "mentions": mentions})
    return rows, total


def gmsg_json(m, me_id, channel=None):
    mid = m["id"]
    reply = None
    if m["reply_to"]:
        r = q1("SELECT * FROM group_messages WHERE id = ?", (m["reply_to"],))
        if r:
            reply = {"id": r["id"], "from_me": r["sender"] == me_id,
                     "name": user_brief(r["sender"], me_id)["name"], "text": summary_of(r, 140)}
    read = q1("SELECT 1 FROM group_members WHERE group_id = ? AND user_id != ? AND last_read >= ?",
              (m["group_id"], m["sender"], m["created_at"])) is not None
    if channel is None:
        g = group_row(m["group_id"])
        channel = bool(g) and g["type"] == "channel"
    out = {
        "id": mid, "mine": m["sender"] == me_id,
        "text": dec(m["sender"], "messages", COL["msg_text"], mid, m["text_enc"]) or "",
        "entities": json.loads(dec(m["sender"], "messages", COL["msg_entities"], mid, m["entities_enc"]) or "[]"),
        "created_at": m["created_at"], "edited_at": m["edited_at"], "read": read,
        "reply": reply, "attachments": attachments_of(m), "sender": user_brief(m["sender"], me_id),
        "reactions": reactions_of(mid, me_id),
    }
    if m["fwd_enc"]:
        out["forwarded"] = fwd_of(m)
    if "kind" in m.keys() and m["kind"] in SYS_LABELS:
        out["system"] = m["kind"]
    if "kind" in m.keys() and m["kind"] == "poll":
        out["poll"] = poll_json(mid, me_id)
    if channel:
        out["views"] = max(1, q1("SELECT COUNT(*) c FROM group_members WHERE group_id = ? AND last_read >= ?",
                                 (m["group_id"], m["created_at"]))["c"])
        n = comments_count(group_row(m["group_id"]), mid)
        if n is not None:
            out["comments"] = n
    return out


def group_messages(req, me, gid):
    uid = me["id"]
    g = group_row(gid)
    mem = member_row(gid, uid) if g else None
    preview = False
    if not mem:
        # открытый канал/группу можно посмотреть, не вступая
        if g and g["kind"] == "open" and not q1("SELECT 1 FROM group_bans WHERE group_id = ? AND user_id = ?", (gid, uid)):
            preview = True
        else:
            raise ApiError(404, "not_found")
    try:
        limit = max(1, min(300, int(req.query().get("limit", "120"))))
    except ValueError:
        limit = 120
    first_unread = None
    if not preview:
        fu = q1("SELECT id FROM group_messages WHERE group_id = ? AND sender != ? AND created_at > ? "
                "AND kind IS NOT 'left' AND kind IS NOT 'joined' AND kind IS NOT 'removed' "
                "AND id NOT IN (SELECT message_id FROM group_hidden WHERE user_id = ?) ORDER BY created_at LIMIT 1",
                (gid, uid, max(mem["last_read"], history_since(g, mem)), uid))
        first_unread = fu["id"] if fu else None
    if not preview and req.query().get("peek") != "1":
        run("UPDATE group_members SET last_read = ? WHERE group_id = ? AND user_id = ?", (time.time(), gid, uid))
    if preview and not g["history"]:
        rows = []
    else:
        rows = q("SELECT * FROM group_messages WHERE group_id = ? AND created_at >= ? AND id NOT IN "
                 "(SELECT message_id FROM group_hidden WHERE user_id = ?) ORDER BY created_at DESC LIMIT ?",
                 (gid, 0 if preview else history_since(g, mem), uid, limit))
    rows.reverse()
    channel = g["type"] == "channel"
    req.send_json(200, {"messages": [gmsg_json(m, uid, channel) for m in rows], "peer": group_peer(g),
                        "typing": None if preview else group_typing(gid, uid),
                        "can_write": can_post(g, mem), "group": group_info(g, uid), "preview": preview,
                        "pinned": pinned_of(gid, uid, group=True), "first_unread": first_unread})


MENTION_RE = re.compile(r"(?<![\w@])@([A-Za-z][A-Za-z0-9_]{4,31})")


def record_mentions(g, sender, mid, text, now):
    """@username в тексте: если этот человек состоит в чате — его «тегнули». Возвращает множество id"""
    ids = set()
    for name in MENTION_RE.findall(text or ""):
        r = q1("SELECT id FROM users WHERE username_idx = ?", (KR.blind_index(name.lower(), "username"),))
        if r and r["id"] != sender and member_row(g["id"], r["id"]):
            ids.add(r["id"])
    for uid in ids:
        run("INSERT OR IGNORE INTO group_mentions(message_id, group_id, user_id, created_at) VALUES (?,?,?,?)",
            (mid, g["id"], uid, now))
    return ids


def mentions_unread(gid, uid, last_read):
    return q1("SELECT COUNT(*) c FROM group_mentions WHERE group_id = ? AND user_id = ? AND created_at > ?",
              (gid, uid, last_read))["c"]


def notify_group(g, sender, text, mentioned=frozenset()):
    if not push.configured():
        return
    try:
        title = group_title(g)
        who = "" if g["type"] == "channel" else user_brief(sender)["name"].split(" ")[0] + ": "
        for m in q("SELECT user_id, muted FROM group_members WHERE group_id = ? AND user_id != ?", (g["id"], sender)):
            rid = m["user_id"]
            tagged = rid in mentioned
            if m["muted"] and not tagged:                   # выключенный чат молчит, но если тегнули — уведомление приходит
                continue
            rows = q("SELECT * FROM push_tokens WHERE user_id = ?", (rid,))
            if not rows:
                continue
            body = (who + text.replace("\n", " ")[:140]) if PUSH_PREVIEW else "Новое сообщение"
            if tagged:
                body = "@ " + ((user_brief(sender)["name"].split(" ")[0] + " упомянул(а) вас: " + text.replace("\n", " ")[:120])
                               if PUSH_PREVIEW else "Вас упомянули")
            payload = push.build_payload(title, body, unread_total(rid), "chat-" + g["id"],
                                         {"chat": g["id"], "name": title, "avatar": None})
            for r in rows:
                token = dec(rid, "push", COL["push_token"], r["id"], r["token_enc"])
                if token:
                    push.enqueue(r["env"], token, payload)
    except Exception as e:
        print("push: %s" % e.__class__.__name__)


def group_send(req, me, gid):
    uid = me["id"]
    g = group_row(gid)
    mem = member_row(gid, uid) if g else None
    if not mem:
        raise ApiError(404, "not_found")
    if not can_post(g, mem):
        raise ApiError(403, "forbidden")
    d = req.body_json()
    poll = clean_poll(d.get("poll"))
    text = poll["question"] if poll else str(d.get("text", "")).strip()
    attachments = [] if poll else clean_attachments(d.get("attachments"), uid)
    if len(text) > MAX_MSG or not (text or attachments):
        raise ApiError(400, "bad_text")
    now = time.time()
    if g["slow"] and not is_admin(mem):
        last = q1("SELECT MAX(created_at) t FROM group_messages WHERE group_id = ? AND sender = ? AND kind IS NULL", (gid, uid))
        wait = g["slow"] - (now - last["t"]) if last and last["t"] else 0
        if wait > 0:
            raise ApiError(429, "slow_mode", wait=int(wait) + 1)
    entities = [] if poll else clean_entities(d.get("entities", []), text)
    reply_to = None
    if d.get("reply_to"):
        r = q1("SELECT id FROM group_messages WHERE id = ? AND group_id = ?", (str(d["reply_to"]), gid))
        reply_to = r["id"] if r else None
    mid = uuid.uuid4().hex
    run("INSERT INTO group_messages(id, group_id, sender, text_enc, entities_enc, attachments_enc, reply_to, created_at, kind) "
        "VALUES (?,?,?,?,?,?,?,?,?)",
        (mid, gid, uid, enc(uid, "messages", COL["msg_text"], mid, text),
         enc(uid, "messages", COL["msg_entities"], mid, json.dumps(entities, ensure_ascii=False)),
         enc(uid, "messages", COL["msg_attach"], mid, json.dumps(attachments)) if attachments else None,
         reply_to, now, "poll" if poll else None))
    if poll:
        create_poll(mid, uid, poll)
    run("UPDATE group_members SET last_read = ? WHERE group_id = ? AND user_id = ?", (now, gid, uid))
    TYPING.pop((uid, gid), None)
    row = q1("SELECT * FROM group_messages WHERE id = ?", (mid,))
    tagged = record_mentions(g, uid, mid, text, now)
    if not d.get("silent"):
        notify_group(g, uid, summary_of(row, 150), tagged)
    if g["type"] == "channel" and g["discussion"]:
        mirror_post(g, row, uid, text, entities, now)
    req.send_json(201, gmsg_json(row, uid, g["type"] == "channel"))


def mirror_post(g, row, uid, text, entities, now):
    """Пост канала дублируется в чате обсуждения — комментарии это ответы на эту копию"""
    dg = group_row(g["discussion"])
    if not dg or dg["type"] != "group":
        return
    mid = uuid.uuid4().hex
    body = text or summary_of(row, 200)
    run("INSERT INTO group_messages(id, group_id, sender, text_enc, entities_enc, attachments_enc, reply_to, created_at, kind, mirror_of) "
        "VALUES (?,?,?,?,?,?,?,?,?,?)",
        (mid, dg["id"], uid, enc(uid, "messages", COL["msg_text"], mid, body),
         enc(uid, "messages", COL["msg_entities"], mid, json.dumps(entities if text else [], ensure_ascii=False)),
         None, None, now, None, row["id"]))


def group_edit(req, me, mid):
    m = q1("SELECT * FROM group_messages WHERE id = ? AND sender = ?", (mid, me["id"]))
    if not m:
        raise ApiError(404, "not_found")
    d = req.body_json()
    text = str(d.get("text", "")).strip()
    if len(text) > MAX_MSG or not (text or attachments_of(m)):
        raise ApiError(400, "bad_text")
    entities = clean_entities(d.get("entities", []), text)
    run("UPDATE group_messages SET text_enc = ?, entities_enc = ?, edited_at = ? WHERE id = ?",
        (enc(me["id"], "messages", COL["msg_text"], mid, text),
         enc(me["id"], "messages", COL["msg_entities"], mid, json.dumps(entities, ensure_ascii=False)),
         time.time(), mid))
    req.send_json(200, gmsg_json(q1("SELECT * FROM group_messages WHERE id = ?", (mid,)), me["id"]))


def group_delete(req, me, mid):
    uid = me["id"]
    m = q1("SELECT * FROM group_messages WHERE id = ?", (mid,))
    mem = member_row(m["group_id"], uid) if m else None
    if not mem:
        raise ApiError(404, "not_found")
    if req.query().get("all") == "1" and (m["sender"] == uid or is_admin(mem)):
        drop_message_media(m)
        run("DELETE FROM group_messages WHERE id = ?", (mid,))
    else:
        run("INSERT OR IGNORE INTO group_hidden(message_id, user_id) VALUES (?,?)", (mid, uid))
    req.send_json(200, {"ok": True})


def purge_group(gid):
    for m in q("SELECT * FROM group_messages WHERE group_id = ?", (gid,)):
        drop_message_media(m)
    run("DELETE FROM groups WHERE id = ?", (gid,))


def leave_group(gid, uid):
    run("DELETE FROM group_members WHERE group_id = ? AND user_id = ?", (gid, uid))
    left = q("SELECT * FROM group_members WHERE group_id = ? ORDER BY joined_at", (gid,))
    if not left:
        purge_group(gid)
    elif not any(m["role"] == "owner" for m in left):
        pick = next((m for m in left if m["role"] == "admin"), left[0])
        run("UPDATE group_members SET role = 'owner' WHERE group_id = ? AND user_id = ?", (gid, pick["user_id"]))


def add_members(g, by, ids, announce=True):
    added = 0
    count = group_count(g["id"])
    for cid in ids[:100]:
        cid = str(cid)
        if count >= MAX_GROUP_MEMBERS:
            break
        if not q1("SELECT 1 FROM users WHERE id = ?", (cid,)) or either_blocked(by, cid) or member_row(g["id"], cid):
            continue
        if by != cid:   # приглашение админом снимает бан
            run("DELETE FROM group_bans WHERE group_id = ? AND user_id = ?", (g["id"], cid))
        elif q1("SELECT 1 FROM group_bans WHERE group_id = ? AND user_id = ?", (g["id"], cid)):
            continue
        run("DELETE FROM group_requests WHERE group_id = ? AND user_id = ?", (g["id"], cid))
        run("INSERT INTO group_members(group_id, user_id, role, joined_at, last_read) VALUES (?,?,?,?,?)",
            (g["id"], cid, "member", time.time(), time.time()))
        if announce:
            post_system(g["id"], cid, "joined")
        count += 1
        added += 1
    return added


def try_join(g, uid):
    """Вступление по ссылке или из каталога: сразу или заявкой, если группа так настроена"""
    if member_row(g["id"], uid):
        return
    if q1("SELECT 1 FROM group_bans WHERE group_id = ? AND user_id = ?", (g["id"], uid)):
        raise ApiError(403, "banned")
    if g["approve"]:
        run("INSERT OR IGNORE INTO group_requests(group_id, user_id, created_at) VALUES (?,?,?)",
            (g["id"], uid, time.time()))
        return
    if group_count(g["id"]) >= MAX_GROUP_MEMBERS:
        raise ApiError(409, "group_full")
    add_members(g, uid, [uid])


def clean_kind(v):
    return "open" if v == "open" else "closed"


def clean_handle(v, gid=None):
    h = str(v or "").strip().lstrip("@")
    if not h:
        return None
    if not HANDLE_RE.match(h):
        raise ApiError(400, "bad_handle")
    h = h.lower()
    taken = q1("SELECT id FROM groups WHERE handle = ?", (h,))
    if taken and taken["id"] != gid:
        raise ApiError(409, "handle_taken")
    return h


def apply_settings(d, current=None):
    """Общие параметры группы/канала; возвращает словарь колонка -> значение для переданных полей"""
    out = {}
    if "approve" in d:
        out["approve"] = 1 if d["approve"] else 0
    if "no_forward" in d:
        out["no_forward"] = 1 if d["no_forward"] else 0
    if "history" in d:
        out["history"] = 1 if d["history"] else 0
    if "who_writes" in d:
        out["who_writes"] = "admins" if d["who_writes"] == "admins" else "all"
    if "slow" in d:
        try:
            v = int(d["slow"])
        except (TypeError, ValueError):
            raise ApiError(400, "bad_value")
        out["slow"] = v if v in SLOW_STEPS else 0
    return out


@route("POST", r"/v1/groups")
def create_group(req, me):
    uid = me["id"]
    d = req.body_json()
    title = clean_line(d.get("title"), 64)
    if not title:
        raise ApiError(400, "bad_text")
    about = clean_line(d.get("about"), 255)
    gtype = "channel" if d.get("type") == "channel" else "group"
    kind = clean_kind(d.get("kind"))
    gid = "g_" + uuid.uuid4().hex
    handle = clean_handle(d.get("handle")) if kind == "open" else None
    s = apply_settings(d)
    run("INSERT INTO groups(id, owner, title_enc, about_enc, kind, code, created_at, type, handle, approve, "
        "no_forward, slow, who_writes, history) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (gid, uid, enc(uid, "groups", COL["group_title"], gid, title),
         enc(uid, "groups", COL["group_about"], gid, about) if about else None,
         kind, uuid.uuid4().hex[:16], time.time(), gtype, handle, s.get("approve", 0), s.get("no_forward", 0),
         s.get("slow", 0) if gtype == "group" else 0, s.get("who_writes", "all") if gtype == "group" else "admins",
         s.get("history", 1)))
    run("INSERT INTO group_members(group_id, user_id, role, joined_at, last_read) VALUES (?,?,?,?,?)",
        (gid, uid, "owner", time.time(), time.time()))
    g = group_row(gid)
    ids = d.get("members")
    if isinstance(ids, list):
        add_members(g, uid, ids, announce=False)
    req.send_json(201, group_info(g, uid))


def group_preview(g, uid):
    return {**group_peer(g), "about": group_about(g), "joined": member_row(g["id"], uid) is not None,
            "approve": bool(g["approve"]), "code": g["code"] if g["kind"] == "open" else None,
            "pending": q1("SELECT 1 FROM group_requests WHERE group_id = ? AND user_id = ?", (g["id"], uid)) is not None}


@route("GET", r"/v1/groups/public")
def public_groups(req, me):
    params = req.query()
    needle = (params.get("q") or "").strip().lower().lstrip("@")
    gtype = params.get("type")
    out = []
    for g in q("SELECT * FROM groups WHERE kind = 'open' ORDER BY created_at DESC LIMIT 500"):
        if gtype in ("group", "channel") and g["type"] != gtype:
            continue
        if q1("SELECT 1 FROM group_bans WHERE group_id = ? AND user_id = ?", (g["id"], me["id"])):
            continue
        title, about = group_title(g), group_about(g)
        if needle and needle not in title.lower() and needle not in (g["handle"] or "") and needle not in about.lower():
            continue
        out.append(group_preview(g, me["id"]))
    out.sort(key=lambda x: -x["members"])
    req.send_json(200, {"groups": out[:60]})


def group_by_ref(ref):
    g = q1("SELECT * FROM groups WHERE code = ?", (ref,)) if re.fullmatch(r"[a-f0-9]{16}", ref) else None
    return g or q1("SELECT * FROM groups WHERE handle = ?", (ref.lower(),))


@route("GET", r"/v1/groups/code/([A-Za-z0-9_]{5,32})")
def group_by_code(req, me, code):
    g = group_by_ref(code)
    if not g:
        raise ApiError(404, "not_found")
    req.send_json(200, group_preview(g, me["id"]))


@route("POST", r"/v1/groups/code/([A-Za-z0-9_]{5,32})/join")
def join_by_code(req, me, code):
    g = group_by_ref(code)
    if not g:
        raise ApiError(404, "not_found")
    try_join(g, me["id"])
    req.send_json(200, group_info(g, me["id"]))


@route("GET", r"/v1/groups/(g_[a-f0-9]{32})")
def get_group(req, me, gid):
    g = group_row(gid)
    if not g or (g["kind"] != "open" and not member_row(gid, me["id"])):
        raise ApiError(404, "not_found")
    req.send_json(200, group_info(g, me["id"]))


@route("POST", r"/v1/groups/(g_[a-f0-9]{32})/join")
def join_open_group(req, me, gid):
    g = group_row(gid)
    if not g or g["kind"] != "open":
        raise ApiError(404, "not_found")
    try_join(g, me["id"])
    req.send_json(200, group_info(g, me["id"]))


@route("PUT", r"/v1/groups/(g_[a-f0-9]{32})")
def edit_group(req, me, gid):
    g = group_row(gid)
    mem = member_row(gid, me["id"]) if g else None
    if not mem:
        raise ApiError(404, "not_found")
    if not is_admin(mem):
        raise ApiError(403, "forbidden")
    d = req.body_json()
    if ("kind" in d or "handle" in d) and mem["role"] != "owner":
        raise ApiError(403, "forbidden")
    if "title" in d:
        title = clean_line(d["title"], 64)
        if not title:
            raise ApiError(400, "bad_text")
        run("UPDATE groups SET title_enc = ? WHERE id = ?", (enc(g["owner"], "groups", COL["group_title"], gid, title), gid))
    if "about" in d:
        about = clean_line(d["about"], 255)
        run("UPDATE groups SET about_enc = ? WHERE id = ?",
            (enc(g["owner"], "groups", COL["group_about"], gid, about) if about else None, gid))
    if "discussion" in d:
        if g["type"] != "channel" or mem["role"] != "owner":
            raise ApiError(403, "forbidden")
        target = str(d["discussion"] or "")
        if not target:
            run("UPDATE groups SET discussion = NULL WHERE id = ?", (gid,))
        else:
            dg = group_row(target)
            dmem = member_row(target, me["id"]) if dg else None
            if not dg or dg["type"] != "group" or not is_admin(dmem):
                raise ApiError(403, "forbidden")
            if q1("SELECT 1 FROM groups WHERE discussion = ? AND id != ?", (target, gid)):
                raise ApiError(400, "already_linked")
            run("UPDATE groups SET discussion = ? WHERE id = ?", (target, gid))
    kind = clean_kind(d["kind"]) if "kind" in d else g["kind"]
    handle = g["handle"]
    if "handle" in d:
        handle = clean_handle(d["handle"], gid)
    if kind != "open":
        handle = None
    run("UPDATE groups SET kind = ?, handle = ? WHERE id = ?", (kind, handle, gid))
    for col, val in apply_settings(d).items():
        if g["type"] == "channel" and col in ("slow", "who_writes"):
            continue
        run("UPDATE groups SET %s = ? WHERE id = ?" % col, (val, gid))
    if not d.get("approve", g["approve"]):
        # заявки больше не нужны — всех, кто ждёт, принимаем
        for r in q("SELECT user_id FROM group_requests WHERE group_id = ?", (gid,)):
            add_members(group_row(gid), r["user_id"], [r["user_id"]])
    req.send_json(200, group_info(group_row(gid), me["id"]))


def comment_thread(req, me, gid, mid):
    """Общая часть: канал, пост, его копия в чате обсуждения"""
    g = group_row(gid)
    if not g or g["type"] != "channel" or not g["discussion"]:
        raise ApiError(404, "not_found")
    mem = member_row(gid, me["id"])
    if not mem and g["kind"] != "open":
        raise ApiError(404, "not_found")
    dg = group_row(g["discussion"])
    mirror = q1("SELECT * FROM group_messages WHERE mirror_of = ? AND group_id = ?", (mid, g["discussion"])) if dg else None
    if not mirror:
        raise ApiError(404, "not_found")
    return g, dg, mem, mirror


@route("GET", r"/v1/groups/(g_[a-f0-9]{32})/comments/([a-f0-9]+)")
def get_comments(req, me, gid, mid):
    g, dg, mem, mirror = comment_thread(req, me, gid, mid)
    rows = q("SELECT * FROM group_messages WHERE group_id = ? AND reply_to = ? ORDER BY created_at LIMIT 300", (dg["id"], mirror["id"]))
    req.send_json(200, {"discussion": dg["id"], "mirror": mirror["id"], "can_comment": bool(mem),
                        "messages": [gmsg_json(r, me["id"], False) for r in rows]})


@route("POST", r"/v1/groups/(g_[a-f0-9]{32})/comments/([a-f0-9]+)")
def post_comment(req, me, gid, mid):
    uid = me["id"]
    g, dg, mem, mirror = comment_thread(req, me, gid, mid)
    if not mem:
        raise ApiError(403, "forbidden")
    if q1("SELECT 1 FROM group_bans WHERE group_id = ? AND user_id = ?", (dg["id"], uid)):
        raise ApiError(403, "forbidden")
    d = req.body_json()
    text = str(d.get("text", "")).strip()
    if not text or len(text) > MAX_MSG:
        raise ApiError(400, "bad_text")
    entities = clean_entities(d.get("entities", []), text)
    if not member_row(dg["id"], uid):
        add_members(dg, uid, [uid], announce=False)      # комментировать может любой подписчик канала
        if not member_row(dg["id"], uid):
            raise ApiError(403, "forbidden")
    now = time.time()
    cid = uuid.uuid4().hex
    run("INSERT INTO group_messages(id, group_id, sender, text_enc, entities_enc, attachments_enc, reply_to, created_at, kind) "
        "VALUES (?,?,?,?,?,?,?,?,?)",
        (cid, dg["id"], uid, enc(uid, "messages", COL["msg_text"], cid, text),
         enc(uid, "messages", COL["msg_entities"], cid, json.dumps(entities, ensure_ascii=False)), None, mirror["id"], now, None))
    run("UPDATE group_members SET last_read = ? WHERE group_id = ? AND user_id = ?", (now, dg["id"], uid))
    row = q1("SELECT * FROM group_messages WHERE id = ?", (cid,))
    tagged = record_mentions(dg, uid, cid, text, now)
    notify_group(dg, uid, summary_of(row, 150), tagged)
    req.send_json(201, gmsg_json(row, uid, False))


@route("DELETE", r"/v1/groups/(g_[a-f0-9]{32})")
def delete_group(req, me, gid):
    mem = member_row(gid, me["id"])
    if not mem or mem["role"] != "owner":
        raise ApiError(403, "forbidden")
    purge_group(gid)
    req.send_json(200, {"ok": True})


@route("POST", r"/v1/groups/(g_[a-f0-9]{32})/mute")
def mute_group(req, me, gid):
    if not member_row(gid, me["id"]):
        raise ApiError(404, "not_found")
    run("UPDATE group_members SET muted = ? WHERE group_id = ? AND user_id = ?",
        (1 if req.body_json().get("muted") else 0, gid, me["id"]))
    req.send_json(200, {"ok": True})


@route("POST", r"/v1/groups/(g_[a-f0-9]{32})/members")
def invite_members(req, me, gid):
    g = group_row(gid)
    mem = member_row(gid, me["id"]) if g else None
    if not mem:
        raise ApiError(404, "not_found")
    if (g["kind"] == "closed" or g["type"] == "channel") and not is_admin(mem):
        raise ApiError(403, "forbidden")
    ids = req.body_json().get("user_ids")
    if not isinstance(ids, list):
        raise ApiError(400, "bad_value")
    allowed = []
    for x in ids:
        r = q1("SELECT * FROM users WHERE id = ?", (str(x),))
        if r and (str(x) == me["id"] or policy_allows(r, me["id"], privacy_of(r).get("invites", "all"))):
            allowed.append(str(x))
    add_members(g, me["id"], allowed)
    req.send_json(200, group_info(g, me["id"]))


@route("PUT", r"/v1/groups/(g_[a-f0-9]{32})/members/([A-Za-z0-9_\-]+)")
def set_member_role(req, me, gid, uid):
    mem = member_row(gid, me["id"])
    if not mem or mem["role"] != "owner":
        raise ApiError(403, "forbidden")
    target = member_row(gid, uid)
    if not target or target["role"] == "owner":
        raise ApiError(404, "not_found")
    role = req.body_json().get("role")
    if role not in ("admin", "member"):
        raise ApiError(400, "bad_value")
    run("UPDATE group_members SET role = ? WHERE group_id = ? AND user_id = ?", (role, gid, uid))
    req.send_json(200, group_info(group_row(gid), me["id"]))


@route("DELETE", r"/v1/groups/(g_[a-f0-9]{32})/members/([A-Za-z0-9_\-]+)")
def remove_member(req, me, gid, uid):
    g = group_row(gid)
    mem = member_row(gid, me["id"]) if g else None
    if not mem:
        raise ApiError(404, "not_found")
    target = member_row(gid, uid)
    if not target:
        raise ApiError(404, "not_found")
    if uid != me["id"]:
        # участника убирает админ; админа — только владелец; владельца — никто
        if not is_admin(mem) or target["role"] == "owner" or (target["role"] == "admin" and mem["role"] != "owner"):
            raise ApiError(403, "forbidden")
        run("INSERT OR IGNORE INTO group_bans(group_id, user_id) VALUES (?,?)", (gid, uid))
    post_system(gid, uid, "left" if uid == me["id"] else "removed")
    leave_group(gid, uid)
    g = group_row(gid)
    req.send_json(200, group_info(g, me["id"]) if g and member_row(gid, me["id"]) else {"ok": True})


@route("GET", r"/v1/groups/(g_[a-f0-9]{32})/requests")
def list_requests(req, me, gid):
    if not is_admin(member_row(gid, me["id"])):
        raise ApiError(403, "forbidden")
    rows = q("SELECT * FROM group_requests WHERE group_id = ? ORDER BY created_at", (gid,))
    req.send_json(200, {"requests": [{"user": user_brief(r["user_id"], me["id"]), "created_at": r["created_at"]} for r in rows]})


@route("POST", r"/v1/groups/(g_[a-f0-9]{32})/requests/([A-Za-z0-9_\-]+)")
def answer_request(req, me, gid, uid):
    g = group_row(gid)
    if not g or not is_admin(member_row(gid, me["id"])):
        raise ApiError(403, "forbidden")
    if not q1("SELECT 1 FROM group_requests WHERE group_id = ? AND user_id = ?", (gid, uid)):
        raise ApiError(404, "not_found")
    if req.body_json().get("approve"):
        add_members(g, uid, [uid])
    else:
        run("DELETE FROM group_requests WHERE group_id = ? AND user_id = ?", (gid, uid))
    req.send_json(200, group_info(g, me["id"]))


@route("GET", r"/v1/groups/(g_[a-f0-9]{32})/bans")
def list_bans(req, me, gid):
    if not is_admin(member_row(gid, me["id"])):
        raise ApiError(403, "forbidden")
    req.send_json(200, {"users": [user_brief(r["user_id"], me["id"])
                                  for r in q("SELECT user_id FROM group_bans WHERE group_id = ?", (gid,))]})


@route("DELETE", r"/v1/groups/(g_[a-f0-9]{32})/bans/([A-Za-z0-9_\-]+)")
def unban(req, me, gid, uid):
    if not is_admin(member_row(gid, me["id"])):
        raise ApiError(403, "forbidden")
    run("DELETE FROM group_bans WHERE group_id = ? AND user_id = ?", (gid, uid))
    req.send_json(200, {"ok": True})


@route("GET", r"/g/([A-Za-z0-9_]{5,32})", auth=False)
def open_group_page(req, me, ref):
    g = group_by_ref(ref)
    if not g:
        return send_html(req, PROFILE_PAGE % {"name": "Orbita", "sub": "Ссылка недействительна",
                                              "link": "orbita://group/" + ref})
    channel = g["type"] == "channel"
    if g["kind"] == "open":
        name, sub = group_title(g), ("Публичный канал" if channel else "Публичная группа") + " · %d" % group_count(g["id"])
    else:
        name, sub = "Закрытый канал" if channel else "Закрытая группа", "Приглашение в Orbita"
    name = name.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
    send_html(req, PROFILE_PAGE % {"name": name, "sub": sub, "link": "orbita://group/" + ref})


# ---------- музыка из переписки -> в профиль ----------

AUDIO_EXT_MIME = {"mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac", "mp4": "audio/mp4"}


def copy_media(src, new_owner, kind, mime):
    """Копия файла для другого владельца (файлы шифруются ключом владельца, поэтому перешифровываем)"""
    nid = uuid.uuid4().hex
    size = src["size"]
    with open(os.path.join(MEDIA_DIR, src["id"]), "rb") as f, open(os.path.join(MEDIA_DIR, nid), "wb") as out:
        gen = decrypt_range(media_key(src["owner"], src["id"]), src["id"], f, size, 0, size - 1)
        buf = bytearray()

        def read(n):
            while len(buf) < n:
                try:
                    buf.extend(next(gen))
                except StopIteration:
                    break
            piece = bytes(buf[:n])
            del buf[:n]
            return piece

        encrypt_stream(media_key(new_owner, nid), nid, read, size, out.write)
    run("INSERT INTO media(id, owner, kind, mime, width, height, duration, thumb, size, created_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
        (nid, new_owner, kind, mime, 0, 0, src["duration"] or 0, None, size, time.time()))
    return nid


@route("POST", r"/v1/me/playlist/from-chat")
def add_track_from_chat(req, me):
    uid = me["id"]
    d = req.body_json()
    mid = str(d.get("message_id", ""))
    m = q1("SELECT * FROM messages WHERE id = ? AND (sender = ? OR recipient = ?)", (mid, uid, uid))
    if not m:
        g = q1("SELECT * FROM group_messages WHERE id = ?", (mid,))
        m = g if g and member_row(g["group_id"], uid) else None
    if not m:
        raise ApiError(404, "not_found")
    att = next((a for a in attachments_of(m) if a.get("media_id") == str(d.get("media_id", "")) and a.get("type") in ("audio", "file")), None)
    if not att:
        raise ApiError(404, "not_found")
    src = q1("SELECT * FROM media WHERE id = ?", (att["media_id"],))
    if not src or not os.path.isfile(os.path.join(MEDIA_DIR, src["id"])):
        raise ApiError(404, "not_found")
    ext = (att.get("name") or "").rsplit(".", 1)[-1].lower()
    mime = src["mime"] if src["mime"] in ALLOWED_MIME and src["mime"].startswith("audio/") else AUDIO_EXT_MIME.get(ext)
    if not mime:
        raise ApiError(415, "unsupported_media")
    if q1("SELECT COUNT(*) c FROM tracks WHERE user_id = ?", (uid,))["c"] >= MAX_TRACKS:
        raise ApiError(400, "too_many_tracks")
    nid = copy_media(src, uid, "audio", mime)
    title = clean_line(d.get("title") or att.get("title") or (att.get("name") or "").rsplit(".", 1)[0], 120) or "Без названия"
    artist = clean_line(d.get("artist") or att.get("artist"), 120)
    tid = uuid.uuid4().hex
    pos = (q1("SELECT COALESCE(MAX(position), -1) p FROM tracks WHERE user_id = ?", (uid,))["p"]) + 1
    run("INSERT INTO tracks(id, user_id, media_id, position, title_enc, artist_enc, duration, created_at) VALUES (?,?,?,?,?,?,?,?)",
        (tid, uid, nid, pos, enc(uid, "profile", COL["track_title"], tid, title),
         enc(uid, "profile", COL["track_artist"], tid, artist) if artist else None,
         float(src["duration"] or att.get("duration") or 0), time.time()))
    req.send_json(201, track_json(q1("SELECT * FROM tracks WHERE id = ?", (tid,))))


@route("POST", r"/v1/me/playlist/from-sound")
def add_track_from_sound(req, me):
    """Звук из шортса — в свой плейлист (как любая песня). Берём только то, что реально звучит в чьём-то шортсе"""
    uid = me["id"]
    d = req.body_json()
    media_id = str(d.get("media_id", ""))
    if not q1("SELECT 1 FROM posts WHERE music_media = ? LIMIT 1", (media_id,)) \
            and not q1("SELECT 1 FROM tracks WHERE media_id = ? LIMIT 1", (media_id,)):
        raise ApiError(404, "not_found")
    src = q1("SELECT * FROM media WHERE id = ?", (media_id,))
    if not src or not os.path.isfile(os.path.join(MEDIA_DIR, src["id"])):
        raise ApiError(404, "not_found")
    mime = src["mime"] if src["mime"] in ALLOWED_MIME and src["mime"].startswith("audio/") else None
    if not mime:
        raise ApiError(415, "unsupported_media")
    if q1("SELECT COUNT(*) c FROM tracks WHERE user_id = ?", (uid,))["c"] >= MAX_TRACKS:
        raise ApiError(400, "too_many_tracks")
    nid = copy_media(src, uid, "audio", mime)
    title = clean_line(d.get("title"), 120) or "Без названия"
    artist = clean_line(d.get("artist"), 120)
    tid = uuid.uuid4().hex
    pos = (q1("SELECT COALESCE(MAX(position), -1) p FROM tracks WHERE user_id = ?", (uid,))["p"]) + 1
    run("INSERT INTO tracks(id, user_id, media_id, position, title_enc, artist_enc, duration, created_at) VALUES (?,?,?,?,?,?,?,?)",
        (tid, uid, nid, pos, enc(uid, "profile", COL["track_title"], tid, title),
         enc(uid, "profile", COL["track_artist"], tid, artist) if artist else None,
         float(src["duration"] or 0), time.time()))
    req.send_json(201, track_json(q1("SELECT * FROM tracks WHERE id = ?", (tid,))))


# ---------- плейлист ----------

def clean_line(v, limit):
    return " ".join(str(v or "").split())[:limit]


@route("GET", r"/v1/users/([A-Za-z0-9_\-]+)/playlist")
def user_playlist(req, me, uid):
    r = q1("SELECT * FROM users WHERE id = ?", (uid,))
    if not r:
        raise ApiError(404, "not_found")
    req.send_json(200, {"tracks": tracks_of(uid) if can_see(r, me["id"], "music") else []})


# кто сейчас слушает музыку: uid -> когда запись протухнет (приложение шлёт «я слушаю» каждые ~20 с)
LISTENING = {}
LISTENING_TTL = 45


def is_listening(uid):
    until = LISTENING.get(uid)
    if until and until > time.time():
        return True
    LISTENING.pop(uid, None)
    return False


@route("POST", r"/v1/me/listening")
def set_listening(req, me):
    d = req.body_json()
    if d.get("on"):
        LISTENING[me["id"]] = time.time() + LISTENING_TTL
    else:
        LISTENING.pop(me["id"], None)
    req.send_json(200, {"ok": True})


@route("POST", r"/v1/me/playlist")
def add_track(req, me):
    d = req.body_json()
    uid = me["id"]
    m = q1("SELECT * FROM media WHERE id = ? AND owner = ? AND kind = 'audio'", (str(d.get("media_id", "")), uid))
    if not m:
        raise ApiError(400, "media_not_found")
    if q1("SELECT COUNT(*) c FROM tracks WHERE user_id = ?", (uid,))["c"] >= MAX_TRACKS:
        raise ApiError(400, "too_many_tracks")
    if q1("SELECT 1 FROM tracks WHERE media_id = ?", (m["id"],)):
        raise ApiError(409, "already_added")
    title = clean_line(d.get("title"), 120) or "Без названия"
    artist = clean_line(d.get("artist"), 120)
    try:
        duration = max(0.0, min(float(d.get("duration", m["duration"] or 0)), 36000.0))
    except (TypeError, ValueError):
        duration = 0.0
    tid = uuid.uuid4().hex
    pos = (q1("SELECT COALESCE(MAX(position), -1) p FROM tracks WHERE user_id = ?", (uid,))["p"]) + 1
    run("INSERT INTO tracks(id, user_id, media_id, position, title_enc, artist_enc, duration, created_at) VALUES (?,?,?,?,?,?,?,?)",
        (tid, uid, m["id"], pos, enc(uid, "profile", COL["track_title"], tid, title),
         enc(uid, "profile", COL["track_artist"], tid, artist) if artist else None, duration, time.time()))
    cover = str(d.get("cover") or "")
    if cover and q1("SELECT 1 FROM media WHERE id = ? AND owner = ? AND kind = 'image'", (cover, uid)):
        run("UPDATE tracks SET cover = ? WHERE id = ?", (cover, tid))
    req.send_json(201, track_json(q1("SELECT * FROM tracks WHERE id = ?", (tid,))))


@route("PUT", r"/v1/me/playlist/order")
def order_tracks(req, me):
    ids = req.body_json().get("ids")
    mine = [t["id"] for t in q("SELECT id FROM tracks WHERE user_id = ?", (me["id"],))]
    if not isinstance(ids, list) or sorted(map(str, ids)) != sorted(mine):
        raise ApiError(400, "bad_order")
    with LOCK:
        for i, tid in enumerate(ids):
            run("UPDATE tracks SET position = ? WHERE id = ?", (i, str(tid)))
    req.send_json(200, {"tracks": tracks_of(me["id"])})


@route("PUT", r"/v1/me/playlist/([a-f0-9]+)")
def edit_track(req, me, tid):
    t = q1("SELECT * FROM tracks WHERE id = ? AND user_id = ?", (tid, me["id"]))
    if not t:
        raise ApiError(404, "not_found")
    d = req.body_json()
    uid = me["id"]
    if "title" in d:
        title = clean_line(d["title"], 120)
        if not title:
            raise ApiError(400, "bad_text")
        run("UPDATE tracks SET title_enc = ? WHERE id = ?", (enc(uid, "profile", COL["track_title"], tid, title), tid))
    if "artist" in d:
        artist = clean_line(d["artist"], 120)
        run("UPDATE tracks SET artist_enc = ? WHERE id = ?",
            (enc(uid, "profile", COL["track_artist"], tid, artist) if artist else None, tid))
    req.send_json(200, track_json(q1("SELECT * FROM tracks WHERE id = ?", (tid,))))


@route("DELETE", r"/v1/me/playlist/([a-f0-9]+)")
def delete_track(req, me, tid):
    t = q1("SELECT * FROM tracks WHERE id = ? AND user_id = ?", (tid, me["id"]))
    if not t:
        raise ApiError(404, "not_found")
    run("DELETE FROM tracks WHERE id = ?", (tid,))
    drop_orphan_media(me["id"], [t["media_id"]])
    req.send_json(200, {"tracks": tracks_of(me["id"])})


# ---------- коды подтверждения (SMS и почта) ----------

OTP_STORE = {}
OTP_IPS = {}
OTP_LOCK = threading.Lock()
EMAIL_RE = re.compile(r"^[^@\s]{1,64}@[^@\s]+\.[^@\s]{2,}$")
PHONE_RE = re.compile(r"^\+\d{8,15}$")


def otp_target(d):
    channel = d.get("channel")
    to = str(d.get("to", "")).strip()
    if channel == "email":
        to = to.lower()
        if len(to) > 120 or not EMAIL_RE.match(to):
            raise ApiError(400, "bad_target")
    elif channel == "sms":
        to = re.sub(r"[\s\-()]", "", to)
        if not PHONE_RE.match(to):
            raise ApiError(400, "bad_target")
    else:
        raise ApiError(400, "bad_target")
    return channel, to, "%s:%s" % (channel, to)


@route("POST", r"/v1/otp/send", auth=False)
def otp_send(req, me):
    d = req.body_json()
    channel, to, key = otp_target(d)
    lang = "en" if d.get("lang") == "en" else "ru"
    now = time.time()
    ip = req.client_ip()
    with OTP_LOCK:
        for k in [k for k, v in OTP_STORE.items() if now - v["sent"][-1] > 3600 and v["exp"] < now]:
            del OTP_STORE[k]
        hist = [t for t in OTP_IPS.get(ip, []) if now - t < 3600]
        if len(hist) >= OTP_IP_PER_HOUR:
            raise ApiError(429, "too_many_requests", retry_after=int(3600 - (now - hist[0])))
        rec = OTP_STORE.get(key)
        if rec:
            rec["sent"] = [t for t in rec["sent"] if now - t < 3600]
            if rec["sent"] and now - rec["sent"][-1] < OTP_RESEND:
                raise ApiError(429, "too_many_requests", retry_after=int(OTP_RESEND - (now - rec["sent"][-1])) + 1)
            if len(rec["sent"]) >= OTP_PER_HOUR:
                raise ApiError(429, "too_many_requests", retry_after=int(3600 - (now - rec["sent"][0])))
        real = otp.configured(channel)
        if not real and not OTP_DEV:
            raise ApiError(503, "otp_not_configured")
        code = "%06d" % secrets.randbelow(1_000_000)
        if real:
            try:
                (otp.send_email if channel == "email" else otp.send_sms)(to, code, lang)
            except otp.DeliveryError as e:
                sys.stderr.write("OTP delivery failed (%s): %s\n" % (channel, e))
                raise ApiError(502, "delivery_failed")
        hist.append(now)
        OTP_IPS[ip] = hist
        sent = (rec["sent"] if rec else []) + [now]
        OTP_STORE[key] = {"hash": KR.blind_index("%s|%s" % (key, code), "otp"), "exp": now + OTP_TTL,
                          "attempts": 0, "sent": sent}
    out = {"ok": True, "resend_in": OTP_RESEND, "expires_in": OTP_TTL}
    if not real:
        out["debug_code"] = code
    req.send_json(200, out)


@route("POST", r"/v1/otp/verify", auth=False)
def otp_verify(req, me):
    d = req.body_json()
    _, _, key = otp_target(d)
    code = re.sub(r"\D", "", str(d.get("code", "")))
    with OTP_LOCK:
        rec = OTP_STORE.get(key)
        if not rec:
            raise ApiError(400, "code_expired")
        if time.time() > rec["exp"]:
            del OTP_STORE[key]
            raise ApiError(400, "code_expired")
        if rec["attempts"] >= OTP_ATTEMPTS:
            raise ApiError(429, "too_many_attempts")
        rec["attempts"] += 1
        good = hmac.compare_digest(rec["hash"], KR.blind_index("%s|%s" % (key, code), "otp"))
        if not good:
            left = OTP_ATTEMPTS - rec["attempts"]
            raise ApiError(400, "wrong_code" if left else "too_many_attempts", attempts_left=left)
        rec["exp"] = 0
        del OTP_STORE[key]
    out = {"ok": True}
    # вход: если на этот номер уже есть аккаунт — выдаём новый сеанс в него, а не создаём новый
    if d.get("login") and d.get("channel") == "sms":
        ph = norm_phone(d.get("to"))
        u = q1("SELECT * FROM users WHERE phone_idx = ? ORDER BY created_at LIMIT 1",
               (KR.blind_index(ph, "phone"),)) if ph else None
        if u:
            info = clean_info(d, req.client_ip())
            if has_twofa(u["id"]):
                out["twofa"] = {"ticket": twofa_ticket(u["id"], info), "hint": twofa_hint(u["id"]),
                                "user_id": u["id"], "name": names(u)[2]}
            else:
                token, _ = new_session(u["id"], info)
                out["login"] = {"token": token, "user_id": u["id"], "name": names(u)[2]}
    req.send_json(200, out)



def seed():
    if os.environ.get("ORBITA_DEMO", "1") == "0" or q1("SELECT 1 FROM users LIMIT 1"):
        return
    now = time.time()
    people = {
        "orbita": ("Orbita", "orbita_team", "Официальный аккаунт Orbita"),
        "artem": ("Артём Козлов", "artem_kozlov", "Люблю город и закаты"),
        "sofia": ("София Миронова", "sofia_m", "Горы, кофе, фото"),
        "danil": ("Данил Орлов", "danil_orlov", "Бег по утрам"),
        "anya": ("Аня Белова", "anya_b", ""),
    }
    ids = {}
    for key, (name, username, bio) in people.items():
        uid = "demo-" + key
        ids[key] = uid
        run("INSERT INTO users(id, token_hash, name_enc, username_idx, username_enc, bio_enc, created_at) VALUES (?,?,?,?,?,?,?)",
            (uid, secrets.token_hex(32), enc(uid, "profile", COL["name"], uid, name),
             KR.blind_index(username.lower(), "username"), enc(uid, "profile", COL["username"], uid, username),
             enc(uid, "profile", COL["bio"], uid, bio) if bio else None, now))

    def ent(text, sub, kind, url=None):
        idx = text.index(sub)
        e = {"type": kind, "offset": u16len(text[:idx]), "length": u16len(sub)}
        if url:
            e["url"] = url
        return e

    def post(author, text, entities, media, likes, minutes_ago, comments=()):
        uid, pid = ids[author], uuid.uuid4().hex
        created = now - minutes_ago * 60
        run("INSERT INTO posts(id, author, text_enc, entities_enc, created_at, likes_seed) VALUES (?,?,?,?,?,?)",
            (pid, uid, enc(uid, "posts", COL["post_text"], pid, text),
             enc(uid, "posts", COL["post_entities"], pid, json.dumps(entities, ensure_ascii=False)), created, likes))
        for i, (mid, w, h) in enumerate(media):
            run("INSERT INTO post_media(post_id, position, media_id, kind, width, height) VALUES (?,?,?,?,?,?)",
                (pid, i, mid, "art", w, h))
        for i, (who, body) in enumerate(comments):
            cid = uuid.uuid4().hex
            run("INSERT INTO comments(id, post_id, author, text_enc, created_at) VALUES (?,?,?,?,?)",
                (cid, pid, ids[who], enc(ids[who], "comments", COL["comment_text"], cid, body), created + (i + 1) * 240))

    t1 = "Добро пожаловать в Orbita!\nДелитесь моментами, общайтесь и находите сообщества.\nВ тексте можно использовать жирный, курсив, зачёркнутый, код и цитаты."
    post("orbita", t1, [ent(t1, "Добро пожаловать в Orbita!", "bold"), ent(t1, "жирный", "bold"),
                        ent(t1, "курсив", "italic"), ent(t1, "зачёркнутый", "strike"), ent(t1, "код", "mono"),
                        ent(t1, "В тексте можно использовать жирный, курсив, зачёркнутый, код и цитаты.", "quote")],
         [("art:2", 1000, 1000)], 128, 20,
         [("danil", "Круто выглядит! Давно ждал такое приложение."), ("sofia", "Очень приятный дизайн")])

    t2 = "Сегодня был невероятный день!\nСобрались с друзьями, погуляли по городу, сделали кучу классных фото."
    post("artem", t2, [ent(t2, "невероятный", "bold")], [("art:0", 1600, 1000)], 33, 120,
         [("anya", "Завидую! Покажешь остальные фото?"), ("danil", "Закат просто огонь"), ("sofia", "Какая красота!")])

    t3 = "Утро в горах. Тишина, холодный воздух и кофе из термоса."
    post("sofia", t3, [ent(t3, "кофе из термоса", "italic")], [("art:1", 1000, 1250)], 87, 300,
         [("artem", "Где это? Хочу туда!")])

    t4 = "Подборка с прогулки: город, горы и немного космоса."
    post("anya", t4, [ent(t4, "Подборка", "bold")],
         [("art:0", 1600, 1000), ("art:1", 1000, 1250), ("art:2", 1000, 1000)], 41, 420)

    t5 = "Кто-нибудь пробовал новый маршрут вдоль набережной?\nДумаю, в выходные устроить пробежку."
    post("danil", t5, [ent(t5, "Думаю, в выходные устроить пробежку.", "quote")], [], 12, 540,
         [("anya", "Я за! Напиши время.")])

    post("artem", "Короткий пост большим шрифтом", [], [], 5, 700)


seed()


def main():
    ThreadingHTTPServer.request_queue_size = 128          # больше ожидающих соединений — пики не отбиваются
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    httpd.daemon_threads = True
    threading.Thread(target=scheduler_loop, daemon=True).start()
    print("Orbita Server: http://%s:%d   данные: %s   отпечаток мастер-ключа: %s"
          % (HOST, PORT, DATA_DIR, KR.fingerprint()))
    if push.configured():
        push.start(drop_push_token)
        print("Push (APNs): включены, topic %s" % os.environ.get("ORBITA_APNS_TOPIC"))
    else:
        print("Push (APNs): не настроены — уведомления вне приложения не придут (см. Server/push.py)")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nОстановлено")


if __name__ == "__main__":
    main()
