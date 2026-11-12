"""Восстановление из резервной копии: потерянное возвращается, существующее не дублируется."""
import sys, time

from smoke import jbody, req, session


def main():
    fails = 0

    def check(label, cond, extra=""):
        nonlocal fails
        print(("OK   " if cond else "FAIL ") + label + (" " + str(extra) if extra and not cond else ""))
        fails += 0 if cond else 1

    a, ta = session("Аня")
    b, tb = session("Боря")
    req("POST", "/v1/chats/%s/messages" % b, ta, {"text": "привет"})
    msgs = (jbody(req("GET", "/v1/chats/%s/messages" % b, ta)[1]) or {}).get("messages", [])
    have = msgs[-1]
    lost = time.time() - 3600
    batch = [{"mine": True, "text": "привет", "date": have["created_at"], "name": ""},
             {"mine": False, "text": "старое сообщение", "date": lost, "name": "Боря"}]
    s, body, _ = req("POST", "/v1/chats/%s/import" % b, ta, {"source": "orbita", "skip_existing": True, "messages": batch})
    check("восстановление принято", s == 200, body[:200])
    check("добавлено только потерянное", (jbody(body) or {}).get("added") == 1, body[:200])
    s, body, _ = req("POST", "/v1/chats/%s/import" % b, ta, {"source": "orbita", "skip_existing": True, "messages": batch})
    check("повторно — ничего не дублируется", (jbody(body) or {}).get("added") == 0, body[:200])
    print("FAILS: %d" % fails)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
