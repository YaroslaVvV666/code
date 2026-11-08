"""Непрочитанные как в Telegram: открыл чат — сервер ничего не отмечает сам (read=manual);
телефон отмечает «прочитано до» увиденного сообщения; в списке остаётся точное число"""
import sys
from smoke import jbody, req, session
fails = 0
def check(label, cond, extra=""):
    global fails
    print(("OK   " if cond else "FAIL ") + label + ("" if cond else " " + str(extra))); fails += 0 if cond else 1
a, ta = session("Я")
b, tb = session("Друг")
ids = [jbody(req("POST", "/v1/chats/%s/messages" % a, tb, {"text": "сообщение %d" % i})[1])["id"] for i in range(10)]
d = jbody(req("GET", "/v1/chats/%s/messages?read=manual" % b, ta)[1]) or {}
check("первое непрочитанное и счётчик", d.get("first_unread") == ids[0] and d.get("unread") == 10, (d.get("first_unread"), d.get("unread")))
d2 = jbody(req("GET", "/v1/chats/%s/messages?read=manual" % b, ta)[1]) or {}
check("открытие не отметило прочитанным", d2.get("unread") == 10, d2.get("unread"))
r = jbody(req("POST", "/v1/chats/%s/read" % b, ta, {"up_to": ids[3]})[1]) or {}
check("прочитал 4 — осталось 6", r.get("unread") == 6, r)
r = jbody(req("POST", "/v1/chats/%s/read" % b, ta, {"up_to": ids[1]})[1]) or {}
check("назад не «непрочитывается»", r.get("unread") == 6, r)
chats = (jbody(req("GET", "/v1/chats", ta)[1]) or {}).get("chats", [])
c = next((x for x in chats if x.get("peer", {}).get("id") == b or x.get("id") == b), {})
check("в списке чатов — 6", c.get("unread") == 6, c)
# группа
g = jbody(req("POST", "/v1/groups", tb, {"title": "Чат", "type": "group", "members": [a]})[1])["id"]
gids = [jbody(req("POST", "/v1/chats/%s/messages" % g, tb, {"text": "г%d" % i})[1])["id"] for i in range(5)]
d = jbody(req("GET", "/v1/chats/%s/messages?read=manual" % g, ta)[1]) or {}
check("группа: непрочитанных 5", d.get("unread") == 5 and d.get("first_unread") == gids[0], (d.get("unread"), d.get("first_unread")))
r = jbody(req("POST", "/v1/chats/%s/read" % g, ta, {"up_to": gids[2]})[1]) or {}
check("группа: прочитал 3 — осталось 2", r.get("unread") == 2, r)
r = jbody(req("POST", "/v1/chats/%s/read" % g, ta, {"all": True})[1]) or {}
check("всё прочитано", r.get("unread") == 0, r)
print("FAILS: %d" % fails)
sys.exit(1 if fails else 0)
