"""Боты: BotGod (создание и настройка), Bot API (getMe, getUpdates, sendMessage, setMyCommands), «Старт». Сервер должен быть запущен."""
import json
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
