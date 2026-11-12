"""Боты: BotGod (создание и настройка), Bot API (getMe, getUpdates, sendMessage, setMyCommands), «Старт». Сервер должен быть запущен."""
import json
import time as _time
import re
import sys

from smoke import jbody, req, session

BOTGOD = "b0790d00-0000-4000-8000-00000000b070"
JPEG_B64 = ("/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAAIAAgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDlqKKK+NP1M//Z")


def main():
    fails = 0

    def check(label, cond, extra=""):
        nonlocal fails
        print(("OK   " if cond else "FAIL ") + label + (" " + str(extra) if extra and not cond else ""))
        fails += 0 if cond else 1

    owner, to = session("Владелец")
    user, tu = session("Юзер")

    def god(text):
        req("POST", "/v1/chats/%s/messages" % BOTGOD, to, {"text": text})
        s, b, _ = req("GET", "/v1/chats/%s/messages?peek=1" % BOTGOD, to)
        return (jbody(b) or {}).get("messages", [])[-1]["text"]

    s, b, _ = req("GET", "/v1/chats/%s/messages" % BOTGOD, to)
    d = jbody(b) or {}
    check("BotGod: есть описание и команды", d.get("bot", {}).get("description") and len(d.get("bot_commands", [])) > 5, d.get("bot"))
    check("BotGod: ещё не начат", d.get("bot", {}).get("started") is False, d.get("bot"))

    check("/newbot", "Как его назовём" in god("/newbot"))
    check("имя", "username" in god("Тест Бот"))
    check("плохой username", "Не подходит" in god("tester"))
    reply = god("tester_test_bot")
    m = re.search(r"\n([0-9a-f]{12}:[A-Za-z0-9_\-]+)\n", reply)
    check("бот создан + токен", "создан" in reply and m, reply)
    token = m.group(1) if m else ""

    s, b, _ = req("GET", "/bot%s/getMe" % token)
    me = (jbody(b) or {}).get("result", {})
    check("getMe", s == 200 and me.get("username") == "tester_test_bot", (s, b[:200]))
    bot_id = me.get("id")
    check("неверный токен — 401", req("GET", "/botnope:bad/getMe")[0] == 401)

    god("/setdescription"); check("выбор бота", "Пришлите текст" in god("1"))
    check("описание сохранено", "обновлено" in god("Я тестовый бот.\nУмею отвечать эхом."))
    god("/setcommands"); god("@tester_test_bot")
    check("команды", "/start" in god("start - Начать\nhelp - Помощь"))

    # человек открывает бота
    s, b, _ = req("GET", "/v1/chats/%s/messages" % bot_id, tu)
    d = jbody(b) or {}
    bot = d.get("bot") or {}
    check("у человека: описание", bot.get("description", "").startswith("Я тестовый бот"), bot)
    check("у человека: не начат", bot.get("started") is False, bot)
    check("у человека: команды", [c["command"] for c in d.get("bot_commands", [])] == ["start", "help"], d.get("bot_commands"))
    check("бот не пишет первым — 403", req("POST", "/bot%s/sendMessage" % token, body={"chat_id": user, "text": "привет"})[0] == 403)

    req("POST", "/v1/chats/%s/messages" % bot_id, tu, {"text": "/start"})
    s, b, _ = req("GET", "/v1/chats/%s/messages" % bot_id, tu)
    bot = (jbody(b) or {}).get("bot") or {}
    check("после /start — начат, 1 пользователь", bot.get("started") is True and bot.get("users") == 1, bot)
    # удалил переписку с ботом (у себя) — снова «Старт»; число пользователей не меняется
    req("DELETE", "/v1/chats/%s" % bot_id, tu)
    bot = (jbody(req("GET", "/v1/chats/%s/messages" % bot_id, tu)[1]) or {}).get("bot") or {}
    check("чат удалён — снова «Старт»", bot.get("started") is False and bot.get("users") == 1, bot)

    s, b, _ = req("GET", "/bot%s/getUpdates" % token)
    ups = (jbody(b) or {}).get("result", [])
    check("getUpdates: /start", len(ups) == 1 and ups[0]["message"]["text"] == "/start"
          and ups[0]["message"]["entities"][0]["type"] == "bot_command", ups)
    off = ups[0]["update_id"] + 1 if ups else 0
    s, b, _ = req("GET", "/bot%s/getUpdates?offset=%d" % (token, off))
    check("подтверждённые убраны", (jbody(b) or {}).get("result") == [], b[:200])

    s, b, _ = req("POST", "/bot%s/sendMessage" % token, body={"chat_id": user, "text": "Привет от бота"})
    check("sendMessage", s == 200 and (jbody(b) or {}).get("ok"), (s, b[:200]))
    s, b, _ = req("GET", "/v1/chats/%s/messages" % bot_id, tu)
    check("человек видит ответ", (jbody(b) or {}).get("messages", [])[-1]["text"] == "Привет от бота")

    # --- кнопки под сообщением + ответ на нажатие ---
    kb = {"inline_keyboard": [[{"text": "Да", "callback_data": "yes"}, {"text": "Сайт", "url": "https://example.com"}]]}
    s, b, _ = req("POST", "/bot%s/sendMessage" % token, body={"chat_id": user, "text": "Выберите", "reply_markup": kb})
    sent = (jbody(b) or {}).get("result", {})
    check("sendMessage с кнопками", s == 200 and sent.get("reply_markup", {}).get("inline_keyboard"), (s, b[:300]))
    s, b, _ = req("GET", "/v1/chats/%s/messages" % bot_id, tu)
    last = (jbody(b) or {}).get("messages", [])[-1]
    check("у человека кнопки под сообщением", last.get("markup") == kb["inline_keyboard"], last)
    check("javascript: в кнопке — отказ", req("POST", "/bot%s/sendMessage" % token, body={
        "chat_id": user, "text": "x", "reply_markup": {"inline_keyboard": [[{"text": "x", "url": "javascript:alert(1)"}]]}})[0] == 400)
    req("GET", "/bot%s/getUpdates?offset=%d" % (token, int(_time.time() * 1e6) + 10**9))          # очистить очередь

    import threading
    answered = {}

    def bot_side():
        s, b, _ = req("GET", "/bot%s/getUpdates?timeout=5" % token, timeout=15)
        for u in (jbody(b) or {}).get("result", []):
            cq = u.get("callback_query")
            if cq:
                answered["data"] = cq["data"]
                req("POST", "/bot%s/answerCallbackQuery" % token, body={"callback_query_id": cq["id"], "text": "Принято!"})
    th = threading.Thread(target=bot_side); th.start()
    import time as _t; _t.sleep(0.3)
    s, b, _ = req("POST", "/v1/messages/%s/callback" % last["id"], tu, {"data": "yes"})
    th.join()
    d = jbody(b) or {}
    check("нажатие кнопки → callback_query и ответ бота", answered.get("data") == "yes" and d.get("text") == "Принято!", (d, answered))
    check("чужие callback_data — отказ", req("POST", "/v1/messages/%s/callback" % last["id"], tu, {"data": "hack"})[0] == 400)

    s, b, _ = req("POST", "/bot%s/editMessageText" % token, body={"chat_id": user, "message_id": last["id"], "text": "Готово ✅"})
    check("editMessageText", s == 200, (s, b[:200]))
    s, b, _ = req("GET", "/v1/chats/%s/messages" % bot_id, tu)
    last2 = (jbody(b) or {}).get("messages", [])[-1]
    check("текст изменён, кнопки убраны", last2["text"] == "Готово ✅" and not last2.get("markup") and last2.get("edited_at"), last2)

    # --- клавиатура вместо обычной ---
    s, b, _ = req("POST", "/bot%s/sendMessage" % token, body={"chat_id": user, "text": "Меню", "reply_markup": {
        "keyboard": [["Каталог", "Корзина"], [{"text": "Помощь"}]], "resize_keyboard": True, "one_time_keyboard": True}})
    s, b, _ = req("GET", "/v1/chats/%s/messages" % bot_id, tu)
    kbd = (jbody(b) or {}).get("bot_keyboard") or {}
    check("клавиатура бота", [[x["text"] for x in r] for r in kbd.get("keyboard", [])] == [["Каталог", "Корзина"], ["Помощь"]], kbd)
    req("POST", "/v1/chats/%s/messages" % bot_id, tu, {"text": "Каталог"})
    s, b, _ = req("GET", "/v1/chats/%s/messages" % bot_id, tu)
    check("одноразовая клавиатура спрятана", not (jbody(b) or {}).get("bot_keyboard"), b[-300:])

    # --- фото и файл (multipart, как в Telegram) ---
    import base64, uuid as _u
    jpeg = base64.b64decode(JPEG_B64)

    def multipart(method, fields, fname, filename, ctype, data):
        bnd = _u.uuid4().hex
        body = b""
        for k, v in fields.items():
            body += ("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n" % (bnd, k, v)).encode()
        body += ("--%s\r\nContent-Disposition: form-data; name=\"%s\"; filename=\"%s\"\r\nContent-Type: %s\r\n\r\n"
                 % (bnd, fname, filename, ctype)).encode() + data + ("\r\n--%s--\r\n" % bnd).encode()
        return req("POST", "/bot%s/%s" % (token, method), raw=body, ctype="multipart/form-data; boundary=" + bnd)
    s, b, _ = multipart("sendPhoto", {"chat_id": user, "caption": "Фото"}, "photo", "a.jpg", "image/jpeg", jpeg)
    ph = (jbody(b) or {}).get("result", {})
    check("sendPhoto", s == 200 and ph.get("photo") and ph.get("caption") == "Фото", (s, b[:300]))
    s, b, _ = multipart("sendDocument", {"chat_id": user}, "document", "../../отчёт.pdf", "application/pdf", b"%PDF-1.4 test")
    doc = (jbody(b) or {}).get("result", {}).get("document", {})
    check("sendDocument (имя очищено)", s == 200 and doc.get("file_name") and "/" not in doc["file_name"], (s, b[:300]))
    s, b, _ = multipart("sendPhoto", {"chat_id": user}, "photo", "x.jpg", "image/jpeg", b"<html><script>")
    check("sendPhoto с HTML — отказ", s == 400, (s, b[:200]))
    s, b, _ = req("POST", "/bot%s/sendPhoto" % token, body={"chat_id": user, "photo": ph.get("photo", [{}])[0].get("file_id")})
    check("sendPhoto по file_id", s == 200, (s, b[:200]))
    s, b, _ = req("GET", "/v1/chats/%s/messages" % bot_id, tu)
    msgs = (jbody(b) or {}).get("messages", [])
    check("человек видит фото и файл", any(a.get("type") == "photo" for m in msgs for a in m.get("attachments", []))
          and any(a.get("type") == "file" for m in msgs for a in m.get("attachments", [])))
    s, b, _ = req("POST", "/bot%s/deleteMessage" % token, body={"chat_id": user, "message_id": msgs[-1]["id"]})
    s2, b2, _ = req("GET", "/v1/chats/%s/messages" % bot_id, tu)
    check("deleteMessage", s == 200 and all(m["id"] != msgs[-1]["id"] for m in (jbody(b2) or {}).get("messages", [])))
    check("нельзя удалить чужое", req("POST", "/bot%s/deleteMessage" % token, body={"chat_id": user, "message_id": msgs[0]["id"]})[0] == 400
          if msgs and not msgs[0]["mine"] is False else True)

    s, b, _ = req("POST", "/bot%s/setMyCommands" % token, body={"commands": [{"command": "go", "description": "Поехали"}]})
    check("setMyCommands", s == 200)
    s, b, _ = req("GET", "/v1/bots/%s/commands" % bot_id, tu)
    check("команды обновлены", [c["command"] for c in (jbody(b) or {}).get("commands", [])] == ["go"], b[:200])

    god("/revoke"); god("1")
    check("старый токен после /revoke не работает", req("GET", "/bot%s/getMe" % token)[0] == 401)

    god("/deletebot"); god("1")
    check("удаление", "удалён" in god("@tester_test_bot"))
    check("бота больше нет", req("GET", "/v1/bots/%s/commands" % bot_id, tu)[0] == 404)
    print("FAILS:", fails)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
