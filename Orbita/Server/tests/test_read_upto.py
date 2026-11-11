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
# много непрочитанных (больше 300): чат загружается целиком от первого непрочитанного
senders = [session("Болтун %d" % k) for k in range(4)]
bg = jbody(req("POST", "/v1/groups", senders[0][1], {"title": "Болталка", "type": "group",
                                                    "members": [a] + [x[0] for x in senders[1:]]})[1])["id"]
many = []
for i in range(350):          # четверо пишут по очереди — 350 сообщений, не упираясь в лимит частоты одного человека
    many.append(jbody(req("POST", "/v1/chats/%s/messages" % bg, senders[i % 4][1], {"text": "м%d" % i})[1])["id"])
d = jbody(req("GET", "/v1/chats/%s/messages?read=manual&limit=380" % bg, ta)[1]) or {}
check("350 непрочитанных: первое есть в загруженном", d.get("unread") == 350 and many[0] in [m["id"] for m in d.get("messages", [])],
      (d.get("unread"), len(d.get("messages", []))))
# тема форума: свои непрочитанные и отметка «прочитано до»
fg = jbody(req("POST", "/v1/groups", tb, {"title": "Форум", "type": "group", "members": [a]})[1])["id"]
req("PUT", "/v1/groups/%s/forum" % fg, tb, {"on": True})
tid = jbody(req("POST", "/v1/groups/%s/topics" % fg, tb, {"title": "Новости"})[1])["id"]
tids = [jbody(req("POST", "/v1/chats/%s/messages" % fg, tb, {"text": "т%d" % i, "topic_id": tid})[1])["id"] for i in range(4)]
d = jbody(req("GET", "/v1/chats/%s/messages?read=manual&topic=%s" % (fg, tid), ta)[1]) or {}
check("тема: 4 непрочитанных, с первого", d.get("unread") == 4 and d.get("first_unread") == tids[0], (d.get("unread"), d.get("first_unread")))
d = jbody(req("GET", "/v1/chats/%s/messages?read=manual&topic=%s" % (fg, tid), ta)[1]) or {}
check("тема: вход не отметил прочитанным", d.get("unread") == 4, d.get("unread"))
r = jbody(req("POST", "/v1/chats/%s/read" % fg, ta, {"up_to": tids[1], "topic": tid})[1]) or {}
check("тема: прочитал 2 — осталось 2", r.get("unread") == 2, r)
topics = (jbody(req("GET", "/v1/groups/%s/topics" % fg, ta)[1]) or {}).get("topics", [])
tt = next((x for x in topics if x.get("id") == tid), {})
check("в списке тем — 2", tt.get("unread") == 2, tt)
# окно от первого непрочитанного: 10 до + limit после, has_newer — есть ли ниже
w = jbody(req("GET", "/v1/chats/%s/messages?read=manual&limit=50&from=%s&context=10" % (bg, many[100]), ta)[1]) or {}
wid = [m["id"] for m in w.get("messages", [])]
check("окно: 10 до и 50 начиная с нужного", len(wid) == 60 and wid[10] == many[100] and w.get("has_newer") is True, (len(wid), w.get("has_newer")))
w = jbody(req("GET", "/v1/chats/%s/messages?read=manual&limit=500&from=%s" % (bg, many[100]), ta)[1]) or {}
check("окно до самого конца — ниже ничего", w.get("has_newer") is False and w["messages"][-1]["id"] == many[-1], w.get("has_newer"))
dw = jbody(req("GET", "/v1/chats/%s/messages?read=manual&limit=3&from=%s&context=2" % (b, ids[5]), ta)[1]) or {}
check("личка: окно", [m["id"] for m in dw.get("messages", [])] == ids[3:8] and dw.get("has_newer") is True, [m["text"] for m in dw.get("messages", [])])
print("FAILS: %d" % fails)
sys.exit(1 if fails else 0)
