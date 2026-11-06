"""Темы в группах: включение форума, создание тем, сообщения по темам, непрочитанные, закрытая тема."""
import sys

from smoke import jbody, req, session


def main():
    fails = 0

    def check(label, cond, extra=""):
        nonlocal fails
        print(("OK   " if cond else "FAIL ") + label + (" " + str(extra) if extra and not cond else ""))
        fails += 0 if cond else 1

    a, ta = session("Админ")
    b_, tb = session("Участник")
    s, b, _ = req("POST", "/v1/groups", ta, {"title": "Клуб", "members": [b_]})
    gid = (jbody(b) or {}).get("id")
    check("группа", s == 201 and gid, b[:200])
    check("участник не включит форум", req("PUT", "/v1/groups/%s/forum" % gid, tb, {"on": True})[0] == 403)
    s, b, _ = req("PUT", "/v1/groups/%s/forum" % gid, ta, {"on": True})
    check("админ включил темы", s == 200 and (jbody(b) or {}).get("forum") is True, b[:200])
    s, b, _ = req("POST", "/v1/groups/%s/topics" % gid, ta, {"title": "Новости", "icon": "📰", "color": 2})
    t1 = (jbody(b) or {}).get("id")
    check("тема создана", s == 201 and t1 and (jbody(b) or {}).get("icon") == "📰", b[:200])
    check("участник не создаёт тему", req("POST", "/v1/groups/%s/topics" % gid, tb, {"title": "x"})[0] == 403)
    req("POST", "/v1/chats/%s/messages" % gid, ta, {"text": "Новость дня", "topic_id": t1})
    req("POST", "/v1/chats/%s/messages" % gid, ta, {"text": "Просто привет"})
    s, b, _ = req("GET", "/v1/groups/%s/topics" % gid, tb)
    d = jbody(b) or {}
    tops = {t["id"]: t for t in d.get("topics", [])}
    check("список тем: общая + новости", "general" in tops and t1 in tops and tops["general"]["general"], list(tops))
    check("непрочитанные по темам", tops.get(t1, {}).get("unread") == 1 and tops["general"]["unread"] == 1, tops)
    check("последнее сообщение темы", tops.get(t1, {}).get("last", {}).get("text") == "Новость дня", tops.get(t1))
    s, b, _ = req("GET", "/v1/chats/%s/messages?topic=%s" % (gid, t1), tb)
    msgs = (jbody(b) or {}).get("messages", [])
    check("в теме только её сообщения", [m["text"] for m in msgs] == ["Новость дня"] and msgs[0].get("topic") == t1, [m["text"] for m in msgs])
    s, b, _ = req("GET", "/v1/chats/%s/messages?topic=general" % gid, tb)
    check("в общей — без темы", [m["text"] for m in (jbody(b) or {}).get("messages", [])] == ["Просто привет"])
    s, b, _ = req("GET", "/v1/groups/%s/topics" % gid, tb)
    tops = {t["id"]: t for t in (jbody(b) or {}).get("topics", [])}
    check("прочитали — непрочитанных нет", tops[t1]["unread"] == 0, tops[t1])
    req("PUT", "/v1/groups/%s/topics/%s" % (gid, t1), ta, {"closed": True})
    check("в закрытую тему участник не пишет", req("POST", "/v1/chats/%s/messages" % gid, tb, {"text": "x", "topic_id": t1})[0] == 403)
    s, b, _ = req("GET", "/v1/chats/%s/messages?topic=%s" % (gid, t1), tb)
    check("закрытая тема: can_write = false", (jbody(b) or {}).get("can_write") is False)
    check("админ пишет в закрытую", req("POST", "/v1/chats/%s/messages" % gid, ta, {"text": "итог", "topic_id": t1})[0] == 201)
    s, b, _ = req("GET", "/v1/chats/%s/messages" % gid, tb)
    check("в группе forum=true", ((jbody(b) or {}).get("group") or {}).get("forum") is True)
    check("удаление темы", req("DELETE", "/v1/groups/%s/topics/%s" % (gid, t1), ta)[0] == 200)
    check("тема удалена", req("GET", "/v1/chats/%s/messages?topic=%s" % (gid, t1), tb)[0] == 404)
    print("FAILS: %d" % fails)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
