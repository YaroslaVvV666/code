"""«Кратко»: пересказ непрочитанного (без ключа Claude — простая выжимка). Сервер должен быть запущен."""
import sys

from smoke import jbody, req, session


def main():
    fails = 0

    def check(label, cond, extra=""):
        nonlocal fails
        print(("OK   " if cond else "FAIL ") + label + (" " + str(extra) if extra and not cond else ""))
        fails += 0 if cond else 1

    a, ta = session("Алиса")
    b, tb = session("Боря")
    texts = ["привет", "завтра встречаемся у метро в 18:00, не опаздывай пожалуйста",
             "возьми с собой зарядку и наушники, мои сломались", "ты придёшь?", "напиши как сможешь"]
    for t in texts:
        req("POST", "/v1/chats/%s/messages" % b, ta, {"text": t})
    s, body, _ = req("GET", "/v1/chats/%s/messages?peek=1" % a, tb)
    fu = jbody(body).get("first_unread")
    check("first_unread есть", s == 200 and fu, s)
    s, body, _ = req("GET", "/v1/chats/%s/summary?from=%s" % (a, fu), tb)
    d = jbody(body) or {}
    check("summary 200", s == 200, (s, body[:200]))
    check("summary текст", "метро" in d.get("summary", "") or "Алиса" in d.get("summary", ""), d)
    check("count", d.get("count") == len(texts), d)
    s2, body2, _ = req("GET", "/v1/chats/%s/summary?from=%s" % (a, fu), tb)
    check("кэш тот же", jbody(body2) == d)
    # чужой чат — нельзя
    c, tc = session("Чужой")
    s, _, _ = req("GET", "/v1/chats/%s/summary?from=%s" % (a, fu), tc)
    check("чужой — 404", s == 404, s)
    s, _, _ = req("GET", "/v1/chats/%s/summary" % a, tb)
    check("без from — 400", s == 400, s)

    # группа
    s, body, _ = req("POST", "/v1/groups", ta, {"title": "Кратко-группа", "type": "group", "members": [b]})
    gid = (jbody(body) or {}).get("id")
    check("группа", s == 201 and gid, (s, body[:200]))
    if gid:
        for t in ["всем привет, в субботу субботник в 10 утра", "кто берёт грабли?", "я возьму перчатки на всех"]:
            req("POST", "/v1/chats/%s/messages" % gid, ta, {"text": t})
        s, body, _ = req("GET", "/v1/chats/%s/messages?peek=1" % gid, tb)
        gfu = (jbody(body) or {}).get("first_unread")
        check("group first_unread", s == 200 and gfu, (s, body[:200]))
        if gfu:
            s, body, _ = req("GET", "/v1/chats/%s/summary?from=%s" % (gid, gfu), tb)
            d = jbody(body) or {}
            check("group summary", s == 200 and d.get("count", 0) >= 3 and d.get("summary"), (s, body[:300]))
            print(d.get("summary"))
            s, _, _ = req("GET", "/v1/chats/%s/summary?from=%s" % (gid, gfu), tc)
            check("group чужой — 404", s == 404, s)
    print("FAILS:", fails)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
