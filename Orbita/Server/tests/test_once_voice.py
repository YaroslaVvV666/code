"""Сгорающее голосовое: получатель слушает один раз, переслать нельзя, в личке файл удаляется"""
import sys

from smoke import jbody, req, session


def main():
    fails = 0

    def check(label, cond, extra=""):
        nonlocal fails
        print(("OK   " if cond else "FAIL ") + label + (" " + str(extra) if extra and not cond else ""))
        fails += 0 if cond else 1

    a, ta = session("Отправитель")
    b, tb = session("Получатель")
    s, body, _ = req("POST", "/v1/media?kind=audio&dur=3", ta, raw=b"ID3" + b"\x00" * 4000, ctype="audio/mpeg")
    mid = (jbody(body) or {}).get("id")
    s, body, _ = req("POST", "/v1/chats/%s/messages" % b, ta, {"text": "", "attachments": [{"type": "voice", "media_id": mid, "once": True}]})
    m = jbody(body) or {}
    check("отправлено", s == 201 and m.get("attachments", [{}])[0].get("once"), body[:200])
    th = jbody(req("GET", "/v1/chats/%s/messages" % a, tb)[1]) or {}
    att = [x for x in th.get("messages", []) if x["id"] == m.get("id")][0]["attachments"][0]
    check("получатель не видит файл заранее", "media_id" not in att and att.get("once") and not att.get("consumed"), att)
    check("переслать нельзя", req("POST", "/v1/chats/%s/forward" % a, tb, {"ids": [m.get("id")]})[0] == 403)
    s, body, _ = req("POST", "/v1/messages/%s/once-open" % m.get("id"), tb)
    check("первое прослушивание", s == 200 and (jbody(body) or {}).get("media_id") == mid, body[:150])
    check("второй раз — нельзя", req("POST", "/v1/messages/%s/once-open" % m.get("id"), tb)[0] == 410)
    req("POST", "/v1/messages/%s/once-done" % m.get("id"), tb)
    check("файл удалён", req("GET", "/v1/media/%s" % mid, tb)[0] == 404)
    th = jbody(req("GET", "/v1/chats/%s/messages" % b, ta)[1]) or {}
    att = [x for x in th.get("messages", []) if x["id"] == m.get("id")][0]["attachments"][0]
    check("отправитель видит «прослушано»", att.get("consumed") is True, att)
    print("FAILS: %d" % fails)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
