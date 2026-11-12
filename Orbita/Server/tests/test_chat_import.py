"""Экспорт переписки и импорт истории из Telegram / WhatsApp."""
import sys

from smoke import jbody, req, session


def main():
    fails = 0

    def check(label, cond, extra=""):
        nonlocal fails
        print(("OK   " if cond else "FAIL ") + label + (" " + str(extra) if extra and not cond else ""))
        fails += 0 if cond else 1

    a, ta = session("Ира")
    b, tb = session("Олег")
    batch = [{"mine": True, "text": "Привет из Telegram", "date": 1700000000, "name": "Ира"},
             {"mine": False, "text": "Здорово!", "date": 1700000060, "name": "Олег Т."},
             {"mine": True, "text": "", "date": 1700000100},                       # пустое — пропускается
             {"mine": True, "text": "из будущего", "date": 4102444800}]             # дата в будущем — пропускается
    s, body, _ = req("POST", "/v1/chats/%s/import" % b, ta, {"source": "telegram", "messages": batch})
    check("импорт принят", s == 200 and (jbody(body) or {}).get("added") == 2, body[:200])
    msgs = (jbody(req("GET", "/v1/chats/%s/messages?peek=1" % b, ta)[1]) or {}).get("messages", [])
    check("сообщения на месте с исходной датой", len(msgs) == 2 and msgs[0]["created_at"] == 1700000000, [m.get("created_at") for m in msgs])
    check("пометка «Импортировано из Telegram»", msgs and msgs[0].get("imported", {}).get("source") == "Telegram", msgs[:1])
    other = (jbody(req("GET", "/v1/chats/%s/messages?peek=1" % a, tb)[1]) or {}).get("messages", [])
    check("у собеседника тоже видно", len(other) == 2 and not other[0]["mine"] and other[1]["mine"], other)
    check("в группу / себе нельзя", req("POST", "/v1/chats/%s/import" % a, ta, {"messages": batch})[0] == 404)
    for i in range(5):
        req("POST", "/v1/chats/%s/messages" % b, ta, {"text": "живое %d" % i})
    s, body, _ = req("GET", "/v1/chats/%s/export?limit=3" % b, ta)
    page = jbody(body) or {}
    check("экспорт постранично", s == 200 and len(page.get("messages", [])) == 3 and page.get("more"), body[:200])
    s, body, _ = req("GET", "/v1/chats/%s/export?limit=100&before=%s" % (b, page.get("before")), ta)
    check("следующая страница", len((jbody(body) or {}).get("messages", [])) == 4, body[:200])
    print("FAILS: %d" % fails)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
