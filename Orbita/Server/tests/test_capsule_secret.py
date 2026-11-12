"""Капсула времени, секрет на расстоянии, статус «чем я занят»."""
import sys
import time

from smoke import jbody, req, session


def main():
    fails = 0

    def check(label, cond, extra=""):
        nonlocal fails
        print(("OK   " if cond else "FAIL ") + label + (" " + str(extra) if extra and not cond else ""))
        fails += 0 if cond else 1

    a, ta = session("Аля")
    b, tb = session("Боб")

    def last(token, peer):
        return ((jbody(req("GET", "/v1/chats/%s/messages?peek=1" % peer, token)[1]) or {}).get("messages") or [{}])[-1]

    # капсула
    s, body, _ = req("POST", "/v1/chats/%s/messages" % b, ta, {"text": "Секрет из прошлого", "lock": {"open_at": time.time() + 3600}})
    m = jbody(body) or {}
    check("капсула отправлена, отправитель видит текст", s == 201 and m.get("text") == "Секрет из прошлого" and m.get("lock"), body[:200])
    got = last(tb, a)
    check("получатель не видит текст до срока", got.get("sealed") and got.get("text") == "" and got.get("lock", {}).get("open") is False, got)
    chats = (jbody(req("GET", "/v1/chats", tb)[1]) or {}).get("chats", [])
    prev = next((c for c in chats if c.get("peer", {}).get("id") == a), {})
    check("в списке чатов — только «Капсула»", "Секрет" not in str(prev.get("last", {})), prev.get("last"))
    check("переслать капсулу нельзя", req("POST", "/v1/chats/%s/forward" % a, tb, {"from": a, "ids": [got.get("id")]})[0] == 403)
    check("капсула в прошлом — отказ", req("POST", "/v1/chats/%s/messages" % b, ta, {"text": "x", "lock": {"open_at": time.time() - 10}})[0] == 400)

    # секрет на расстоянии (Красная площадь, радиус 200 м)
    s, body, _ = req("POST", "/v1/chats/%s/messages" % b, ta,
                     {"text": "Ты на месте!", "lock": {"lat": 55.7539, "lon": 37.6208, "radius": 200, "title": "Красная площадь"}})
    sm = jbody(body) or {}
    got = last(tb, a)
    check("секрет закрыт, место видно", got.get("sealed") and got.get("lock", {}).get("place", {}).get("title") == "Красная площадь", got)
    s, body, _ = req("POST", "/v1/messages/%s/unlock" % sm.get("id"), tb, {"lat": 59.93, "lon": 30.33})
    check("далеко — не открывается", s == 403 and (jbody(body) or {}).get("distance", 0) > 1000, (s, body[:120]))
    s, body, _ = req("POST", "/v1/messages/%s/unlock" % sm.get("id"), tb, {"lat": 55.7545, "lon": 37.6212, "acc": 10})
    check("на месте — открылся", s == 200 and (jbody(body) or {}).get("text") == "Ты на месте!", (s, body[:200]))
    check("после открытия текст виден", last(tb, a).get("text") == "Ты на месте!")
    check("открыть чужой секрет нельзя", req("POST", "/v1/messages/%s/unlock" % sm.get("id"), ta, {"lat": 55.75, "lon": 37.62})[0] == 404)

    # статус «чем я занят» убран: даже поставленный старым приложением, другим не виден
    req("PUT", "/v1/me/activity", ta, {"emoji": "🎧", "text": "Слушаю музыку", "hours": 2})
    prof = jbody(req("GET", "/v1/users/%s" % a, tb)[1]) or {}
    check("статус «чем я занят» не показывается", prof.get("activity") is None, prof.get("activity"))
    print("FAILS: %d" % fails)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
