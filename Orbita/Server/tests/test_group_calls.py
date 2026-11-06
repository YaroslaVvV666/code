"""Групповые звонки: начать, присоединиться, сигналы offer/answer/ice между участниками, выход, завершение."""
import sys
import threading

from smoke import jbody, req, session


def main():
    fails = 0

    def check(label, cond, extra=""):
        nonlocal fails
        print(("OK   " if cond else "FAIL ") + label + (" " + str(extra) if extra and not cond else ""))
        fails += 0 if cond else 1

    a, ta = session("Аня")
    b_, tb = session("Боря")
    c_, tc = session("Чужой")
    s, b, _ = req("POST", "/v1/groups", ta, {"title": "Созвон", "members": [b_]})
    gid = (jbody(b) or {}).get("id")
    check("нет звонка", (jbody(req("GET", "/v1/groups/%s/call" % gid, tb)[1]) or {}).get("active") is False)
    s, b, _ = req("POST", "/v1/groups/%s/call/join" % gid, ta, {"video": True})
    d = jbody(b) or {}
    check("Аня начала видеочат", s == 200 and d.get("active") and len(d.get("participants", [])) == 1 and d.get("ice"), b[:300])
    s, b, _ = req("GET", "/v1/chats/%s/messages" % gid, tb)
    dd = jbody(b) or {}
    check("в группе видно «идёт звонок»", (dd.get("group") or {}).get("call", {}).get("count") == 1, dd.get("group", {}).get("call"))
    check("служебное «начал(а) видеочат»", any(m.get("system") == "vc_start" for m in dd.get("messages", [])))
    check("чужой не присоединится", req("POST", "/v1/groups/%s/call/join" % gid, tc, {})[0] == 404)

    got = {}

    def anya_poll():
        s, b, _ = req("GET", "/v1/groups/%s/call/poll?timeout=6" % gid, ta, timeout=15)
        got["a"] = jbody(b) or {}
    th = threading.Thread(target=anya_poll); th.start()
    s, b, _ = req("POST", "/v1/groups/%s/call/join" % gid, tb, {})
    d = jbody(b) or {}
    check("Боря присоединился, видит Аню", s == 200 and [p["id"] for p in d.get("participants", [])] == [a, b_], d.get("participants"))
    th.join()
    check("Аню разбудило: участников стало 2", len(got.get("a", {}).get("participants", [])) == 2, got.get("a"))

    # новичок (Боря) шлёт offer Ане, она отвечает answer, плюс ice
    req("POST", "/v1/groups/%s/call/signal" % gid, tb, {"to": a, "kind": "offer", "data": "v=0 offer"})
    s, b, _ = req("GET", "/v1/groups/%s/call/poll?timeout=2" % gid, ta)
    sig = (jbody(b) or {}).get("signals", [])
    check("Аня получила offer от Бори", sig and sig[0]["from"] == b_ and sig[0]["kind"] == "offer", sig)
    req("POST", "/v1/groups/%s/call/signal" % gid, ta, {"to": b_, "kind": "answer", "data": "v=0 answer"})
    req("POST", "/v1/groups/%s/call/signal" % gid, ta, {"to": b_, "kind": "ice", "data": "{\"candidate\":\"x\"}"})
    s, b, _ = req("GET", "/v1/groups/%s/call/poll?timeout=2" % gid, tb)
    sig = (jbody(b) or {}).get("signals", [])
    check("Боря получил answer и ice", [x["kind"] for x in sig] == ["answer", "ice"], sig)
    check("сигнал не участнику — 404", req("POST", "/v1/groups/%s/call/signal" % gid, ta, {"to": c_, "kind": "ice", "data": "x"})[0] == 404)
    req("POST", "/v1/groups/%s/call/state" % gid, tb, {"muted": True, "video": False})
    s, b, _ = req("GET", "/v1/groups/%s/call" % gid, ta)
    ps = {p["id"]: p for p in (jbody(b) or {}).get("participants", [])}
    check("Боря выключил микрофон — видно", ps.get(b_, {}).get("muted") is True, ps)
    req("POST", "/v1/groups/%s/call/leave" % gid, tb, {})
    s, b, _ = req("GET", "/v1/groups/%s/call" % gid, ta)
    check("Боря вышел", len((jbody(b) or {}).get("participants", [])) == 1)
    req("POST", "/v1/groups/%s/call/leave" % gid, ta, {})
    s, b, _ = req("GET", "/v1/groups/%s/call" % gid, ta)
    check("последний вышел — звонок завершён", (jbody(b) or {}).get("active") is False, b[:200])
    s, b, _ = req("GET", "/v1/chats/%s/messages" % gid, tb)
    check("служебное «видеочат завершён»", any(m.get("system") == "vc_end" for m in (jbody(b) or {}).get("messages", [])))
    print("FAILS: %d" % fails)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
