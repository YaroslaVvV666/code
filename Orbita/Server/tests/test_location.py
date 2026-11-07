"""Геопозиция: точка, трансляция, обновление, остановка, чужие не могут двигать. Сервер должен быть запущен."""
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

    def last_loc(token, peer):
        s, body, _ = req("GET", "/v1/chats/%s/messages?peek=1" % peer, token)
        msgs = (jbody(body) or {}).get("messages", [])
        for m in reversed(msgs):
            for at in m.get("attachments", []):
                if at.get("type") == "location":
                    return m, at
        return None, None

    # обычная точка
    s, body, _ = req("POST", "/v1/chats/%s/messages" % b, ta,
                     {"text": "", "attachments": [{"type": "location", "lat": 55.7558, "lon": 37.6173, "acc": 12, "title": "Красная площадь"}]})
    check("точка отправлена", s in (200, 201), (s, body[:200]))
    m, at = last_loc(tb, a)
    check("точка у получателя", at and at["lat"] == 55.7558 and at.get("title") == "Красная площадь" and "live_until" not in at, at)
    s, body, _ = req("GET", "/v1/chats", tb)
    check("метка в списке", "Красная площадь" in body.decode(), body[:300])
    # плохие координаты отбрасываются
    s, body, _ = req("POST", "/v1/chats/%s/messages" % b, ta,
                     {"text": "x", "attachments": [{"type": "location", "lat": 200, "lon": 0}]})
    check("плохие координаты — без вложения", s in (200, 201) and not (jbody(body) or {}).get("attachments"), body[:200])

    # трансляция на 15 минут
    s, body, _ = req("POST", "/v1/chats/%s/messages" % b, ta,
                     {"text": "", "attachments": [{"type": "location", "lat": 55.75, "lon": 37.61, "live": 900}]})
    check("трансляция отправлена", s in (200, 201), (s, body[:200]))
    m, at = last_loc(tb, a)
    mid = m["id"] if m else None
    check("live_until", at and at.get("live_until"), at)
    s, _, _ = req("PUT", "/v1/live-location/%s" % mid, ta, {"lat": 55.76, "lon": 37.62, "acc": 8, "heading": 90})
    check("обновление 200", s == 200, s)
    m, at = last_loc(tb, a)
    check("получатель видит новую точку", at and at["lat"] == 55.76 and at["lon"] == 37.62 and at.get("updated_at"), at)
    s, _, _ = req("PUT", "/v1/live-location/%s" % mid, tb, {"lat": 1, "lon": 1})
    check("чужой не двигает — 404", s == 404, s)
    s, _, _ = req("PUT", "/v1/live-location/%s" % mid, ta, {"lat": "x", "lon": 1})
    check("мусор — 400", s == 400, s)
    s, _, _ = req("POST", "/v1/live-location/%s/stop" % mid, ta)
    check("стоп 200", s == 200, s)
    m, at = last_loc(tb, a)
    check("остановлена, точка последняя", at and at.get("stopped") and at["lat"] == 55.76, at)
    s, _, _ = req("PUT", "/v1/live-location/%s" % mid, ta, {"lat": 55.77, "lon": 37.63})
    check("после стопа — 410", s == 410, s)

    # группа
    s, body, _ = req("POST", "/v1/groups", ta, {"title": "Гео", "type": "group", "members": [b]})
    gid = (jbody(body) or {}).get("id")
    s, body, _ = req("POST", "/v1/chats/%s/messages" % gid, ta,
                     {"text": "", "attachments": [{"type": "location", "lat": 59.93, "lon": 30.33, "live": 3600}]})
    check("групповая трансляция", s in (200, 201), (s, body[:200]))
    m, at = last_loc(tb, gid)
    gmid = m["id"] if m else None
    s, _, _ = req("PUT", "/v1/live-location/%s" % gmid, ta, {"lat": 59.94, "lon": 30.34})
    m, at = last_loc(tb, gid)
    check("в группе видна новая точка", s == 200 and at and at["lat"] == 59.94, (s, at))
    # пересылка трансляции — обычная точка
    c, tc = session("Вика")
    s, body, _ = req("POST", "/v1/chats/%s/forward" % c, ta, {"from": gid, "ids": [gmid]})
    m, at = last_loc(tc, a)
    check("пересланная — без трансляции", at and "live_until" not in at and at["lat"] == 59.94, (s, body[:200], at))
    print("FAILS:", fails)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
