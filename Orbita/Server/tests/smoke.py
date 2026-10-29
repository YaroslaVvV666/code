#!/usr/bin/env python3
"""Дымовой тест сервера Orbita: гоняет основные сценарии по HTTP против запущенного сервера.
Только стандартная библиотека. Проверяет здоровье, сессии, переписку, группы, реакции, заметки,
медиа (загрузка/скачивание/диапазон), звонки (сигналинг), long-poll события, лимиты и — если задан
токен администратора — законную выгрузку.

Запуск:
    python3 Server/tests/smoke.py                 # по умолчанию http://127.0.0.1:8080
    ORBITA_TEST_URL=http://127.0.0.1:8080 ORBITA_ADMIN_TOKEN=... python3 Server/tests/smoke.py

Сервер удобно поднять так (локально, SQLite, без Redis):
    ORBITA_OTP_DEV=1 python3 Server/server.py
Коды выхода: 0 — всё прошло, 1 — есть провалы.
"""

import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid

BASE = os.environ.get("ORBITA_TEST_URL", "http://127.0.0.1:8080").rstrip("/")
ADMIN = os.environ.get("ORBITA_ADMIN_TOKEN", "")

_fails = []


def ok(label, cond, extra=""):
    print(("PASS " if cond else "FAIL "), label, extra)
    if not cond:
        _fails.append(label)
    return cond


def req(method, path, token=None, body=None, raw=None, ctype=None, headers=None, timeout=30):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    r = urllib.request.Request(BASE + path, data=data, method=method)
    if ctype:
        r.add_header("Content-Type", ctype)
    elif body is not None:
        r.add_header("Content-Type", "application/json")
    if token:
        r.add_header("Authorization", "Bearer " + token)
    for k, v in (headers or {}).items():
        r.add_header(k, v)
    try:
        with urllib.request.urlopen(r, timeout=timeout) as x:
            return x.status, x.read(), dict(x.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers)


def jbody(b):
    try:
        return json.loads(b or b"null")
    except ValueError:
        return None


def session(name="User"):
    uid = str(uuid.uuid4())
    s, b, _ = req("POST", "/v1/session", body={"user_id": uid, "name": name})
    return uid, jbody(b)["token"]


def main():
    # 1. здоровье
    s, b, _ = req("GET", "/v1/ping")
    ok("ping", s == 200 and jbody(b).get("ok") is True)

    # 2. сессии и профиль
    a, ta = session("Алиса")
    bb, tb = session("Боря")
    s, b, _ = req("GET", "/v1/me", ta)
    ok("me", s == 200 and (jbody(b).get("name") == "Алиса" or jbody(b).get("first_name") == "Алиса"))

    # 3. личная переписка: отправка и получение другой стороной
    s, _, _ = req("POST", "/v1/chats/%s/messages" % bb, ta, {"text": "привет-смоук"})
    ok("send DM", s in (200, 201))
    s, b, _ = req("GET", "/v1/chats/%s/messages" % a, tb)
    msgs = jbody(b).get("messages", []) if s == 200 else []
    mid = next((m["id"] for m in msgs if "привет-смоук" in (m.get("text") or "")), None)
    ok("receive DM", mid is not None)

    # 4. реакция и заметка (INSERT OR REPLACE пути)
    if mid:
        ok("reaction", req("PUT", "/v1/messages/%s/reaction" % mid, tb, {"emoji": "🔥"})[0] == 200)
        ok("note", req("PUT", "/v1/messages/%s/note" % mid, ta, {"text": "пометка"})[0] == 200)

    # 5. группа + статистика
    s, b, _ = req("POST", "/v1/groups", ta, {"title": "Смоук-группа", "type": "group"})
    ok("create group", s == 201)
    gid = jbody(b).get("id") if s == 201 else None
    if gid:
        ok("group stats", req("GET", "/v1/groups/%s/stats" % gid, ta)[0] == 200)

    # 6. медиа: загрузка -> скачивание байт-в-байт -> диапазон
    # сервер проверяет, что это настоящая картинка (защита от кода в стикерах),
    # поэтому берём валидный JPEG и дописываем «хвост» для проверки хранения байт-в-байт
    import base64
    jpeg = base64.b64decode(
        "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAAIAAgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDlqKKK+NP1M//Z")
    blob = jpeg + os.urandom(6000)          # валидный JPEG + хвост (Pillow игнорирует хвост, хранилище отдаёт байты как есть)
    s, b, _ = req("POST", "/v1/media?kind=image&w=8&h=8", ta, raw=blob, ctype="image/jpeg")
    ok("media upload", s == 201)
    media_id = jbody(b).get("id") if s == 201 else None
    if media_id:
        s, got, _ = req("GET", "/media/%s" % media_id, ta)
        ok("media download exact", s == 200 and got == blob)
        s, part, _ = req("GET", "/media/%s" % media_id, ta, headers={"Range": "bytes=1000-1099"})
        ok("media range", s == 206 and part == blob[1000:1100])

    # 7. звонки (в одном процессе: старт -> собеседник видит входящий -> ответ -> сигнал -> конец)
    s, b, _ = req("POST", "/v1/calls", ta, {"to": bb, "video": False})
    ok("call start", s == 201)
    cid = jbody(b).get("id") if s == 201 else None
    if cid:
        s, b, _ = req("GET", "/v1/calls/poll", tb)
        inc = jbody(b).get("incoming")
        ok("callee sees incoming", bool(inc) and inc["id"] == cid)
        ok("call answer", req("POST", "/v1/calls/%s/answer" % cid, tb)[0] == 200)
        req("POST", "/v1/calls/%s/signal" % cid, ta, {"kind": "ice", "data": "X"})
        s, b, _ = req("GET", "/v1/calls/poll", tb)
        ok("call signal delivered", any(sig["kind"] == "ice" for sig in jbody(b).get("signals", [])))
        ok("call end", req("POST", "/v1/calls/%s/end" % cid, ta)[0] == 200)

    # 8. long-poll: висящий events/wait будится входящим сообщением
    res = {}

    def waiter():
        st, bd, _ = req("GET", "/v1/events/wait?timeout=10", tb)
        res["r"] = (st, jbody(bd).get("topics") if st == 200 else None)
    w = threading.Thread(target=waiter)
    w.start()
    time.sleep(0.5)
    req("POST", "/v1/chats/%s/messages" % bb, ta, {"text": "будильник"})
    w.join(12)
    ok("long-poll woken by dm", res.get("r", (0, None))[0] == 200 and "dm" in (res["r"][1] or []), str(res.get("r")))

    # 9. events/wait таймаут отдаёт пусто (свежий пользователь без накопленных событий)
    _, tfresh = session("Тихоня")
    st, bd, _ = req("GET", "/v1/events/wait?timeout=2", tfresh)
    ok("long-poll timeout empty", st == 200 and jbody(bd).get("topics") == [])

    # 10. метрики
    s, b, _ = req("GET", "/metrics")
    ok("metrics", s == 200 and b"orbita_requests_total" in b)

    # 11. лимит: создание аккаунтов с одного IP (30/час) — пачка упирается в 429
    codes = [req("POST", "/v1/session", body={"user_id": str(uuid.uuid4()), "name": "L"})[0] for _ in range(34)]
    ok("rate limit hits 429", 429 in codes, "201=%d 429=%d" % (codes.count(201), codes.count(429)))

    # 12. комплаенс (если задан токен администратора)
    if ADMIN:
        ok("admin export denied w/o token", req("GET", "/v1/admin/export/%s" % a)[0] == 403)
        s, b, _ = req("GET", "/v1/admin/export/%s" % a, headers={"X-Admin-Token": ADMIN})
        data = jbody(b) if s == 200 else {}
        texts = [m.get("text", "") for m in data.get("messages", [])]
        ok("admin export decrypts", s == 200 and any("привет-смоук" in t for t in texts))
    else:
        print("SKIP  admin compliance (ORBITA_ADMIN_TOKEN не задан)")

    print("\nИТОГ:", "ВСЁ ПРОШЛО" if not _fails else "ПРОВАЛЫ: " + ", ".join(_fails))
    return 1 if _fails else 0


if __name__ == "__main__":
    sys.exit(main())
