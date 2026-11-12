"""Удаление переписки «у меня» и «у всех», удаление сообщения у всех."""
import sys

from smoke import jbody, req, session


def main():
    fails = 0

    def check(label, cond, extra=""):
        nonlocal fails
        print(("OK   " if cond else "FAIL ") + label + (" " + str(extra) if extra and not cond else ""))
        fails += 0 if cond else 1

    a, ta = session("Аня")
    b, tb = session("Боря")

    def msgs(token, peer):
        return (jbody(req("GET", "/v1/chats/%s/messages?peek=1" % peer, token)[1]) or {}).get("messages", [])

    for i in range(3):
        req("POST", "/v1/chats/%s/messages" % b, ta, {"text": "от Ани %d" % i})
        req("POST", "/v1/chats/%s/messages" % a, tb, {"text": "от Бори %d" % i})
    check("у обоих по 6 сообщений", len(msgs(ta, b)) == 6 and len(msgs(tb, a)) == 6)

    one = msgs(ta, b)[0]
    mine = [m for m in msgs(ta, b) if m["mine"]][0]
    check("удалить своё у всех", req("DELETE", "/v1/messages/%s?all=1" % mine["id"], ta)[0] == 200)
    check("у собеседника пропало", all(m["id"] != mine["id"] for m in msgs(tb, a)))

    check("очистить «у меня»", req("DELETE", "/v1/chats/%s" % b, ta)[0] == 200)
    check("у меня пусто", len(msgs(ta, b)) == 0)
    check("у собеседника осталось", len(msgs(tb, a)) == 5, len(msgs(tb, a)))

    req("POST", "/v1/chats/%s/messages" % b, ta, {"text": "снова"})
    s, body, _ = req("DELETE", "/v1/chats/%s?all=1" % b, ta)
    check("очистить «у всех»", s == 200 and (jbody(body) or {}).get("deleted", 0) >= 1, body[:100])
    check("у меня пусто", len(msgs(ta, b)) == 0)
    check("и у собеседника пусто", len(msgs(tb, a)) == 0, len(msgs(tb, a)))
    print("FAILS: %d" % fails)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
