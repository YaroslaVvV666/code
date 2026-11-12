"""Записи от имени бота: владелец публикует из приложения, бот — через Bot API (sendPost), страница бота их показывает."""
import re
import sys

from smoke import jbody, req, session

BOTGOD = "b0790d00-0000-4000-8000-00000000b070"


def main():
    fails = 0

    def check(label, cond, extra=""):
        nonlocal fails
        print(("OK   " if cond else "FAIL ") + label + (" " + str(extra) if extra and not cond else ""))
        fails += 0 if cond else 1

    owner, to = session("Хозяин")
    other, tx = session("Чужой")

    def god(text):
        req("POST", "/v1/chats/%s/messages" % BOTGOD, to, {"text": text})
        s, b, _ = req("GET", "/v1/chats/%s/messages?peek=1" % BOTGOD, to)
        return (jbody(b) or {}).get("messages", [])[-1]["text"]

    god("/newbot")
    god("Новости")
    reply = god("news_post_bot")
    m = re.search(r"\n([0-9a-f]{12}:[A-Za-z0-9_\-]+)\n", reply)
    token = m.group(1) if m else ""
    s, b, _ = req("GET", "/bot%s/getMe" % token)
    bot_id = (jbody(b) or {}).get("result", {}).get("id", "")
    check("бот создан", bool(bot_id), reply[:200])

    s, b, _ = req("GET", "/v1/users/%s" % bot_id, to)
    check("владелец видит bot_owned", (jbody(b) or {}).get("bot_owned") is True, b[:200])
    s, b, _ = req("GET", "/v1/users/%s" % bot_id, tx)
    check("чужой — нет", (jbody(b) or {}).get("bot_owned") is False, b[:200])

    s, b, _ = req("POST", "/v1/bots/%s/posts" % bot_id, to, {"text": "Первая запись бота"})
    post = jbody(b) or {}
    check("владелец публикует от имени бота", s == 201 and post.get("author", {}).get("id") == bot_id and post.get("mine"), (s, b[:200]))
    check("чужой не может", req("POST", "/v1/bots/%s/posts" % bot_id, tx, {"text": "взлом"})[0] == 403)

    s, b, _ = req("POST", "/bot%s/sendPost" % token, body={"text": "Запись из кода бота"})
    check("Bot API sendPost", s == 200 and (jbody(b) or {}).get("result", {}).get("post_id"), (s, b[:200]))
    bot_post = (jbody(b) or {}).get("result", {}).get("post_id", "")

    s, b, _ = req("GET", "/v1/users/%s/posts" % bot_id, tx)
    texts = [p["text"] for p in (jbody(b) or {}).get("posts", [])]
    check("на странице бота обе записи", "Первая запись бота" in texts and "Запись из кода бота" in texts, texts)

    s, b, _ = req("PUT", "/v1/posts/%s" % post.get("id"), to, {"text": "Исправлено"})
    check("владелец правит запись бота", s == 200 and (jbody(b) or {}).get("text") == "Исправлено", (s, b[:200]))
    check("чужой не удалит", req("DELETE", "/v1/posts/%s" % post.get("id"), tx)[0] == 403)
    check("владелец удаляет", req("DELETE", "/v1/posts/%s" % post.get("id"), to)[0] == 200)
    s, b, _ = req("POST", "/bot%s/deletePost" % token, body={"post_id": bot_post})
    check("Bot API deletePost", s == 200)
    print("FAILS: %d" % fails)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
