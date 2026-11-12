"""Опросы-викторины: правильный ответ скрыт до ответа, ответ один и навсегда, пояснение."""
import sys

from smoke import jbody, req, session


def main():
    fails = 0

    def check(label, cond, extra=""):
        nonlocal fails
        print(("OK   " if cond else "FAIL ") + label + (" " + str(extra) if extra and not cond else ""))
        fails += 0 if cond else 1

    a, ta = session("Автор")
    b_, tb = session("Игрок")
    s, b, _ = req("POST", "/v1/chats/%s/messages" % b_, ta, {"text": "Столица Австралии?", "poll": {
        "question": "Столица Австралии?", "options": ["Сидней", "Канберра", "Мельбурн"],
        "quiz": True, "correct": 1, "explanation": "Канберру построили как компромисс"}})
    check("викторина создана", s == 201, (s, b[:200]))
    mid = (jbody(b) or {}).get("id")
    check("кривой правильный ответ — 400", req("POST", "/v1/chats/%s/messages" % b_, ta, {"text": "x", "poll": {
        "question": "x", "options": ["a", "b"], "quiz": True, "correct": 5}})[0] == 400)
    s, b, _ = req("GET", "/v1/chats/%s/messages" % a, tb)
    poll = [m for m in (jbody(b) or {}).get("messages", []) if m["id"] == mid][0]["poll"]
    check("до ответа правильный ответ скрыт", poll.get("quiz") and "correct" not in poll and "explanation" not in poll, poll)
    s, b, _ = req("PUT", "/v1/messages/%s/vote" % mid, tb, {"options": [0]})
    p = jbody(b) or {}
    check("после ответа виден правильный и пояснение", s == 200 and p.get("correct") == 1 and "Канберру" in p.get("explanation", ""), p)
    check("переответить нельзя", req("PUT", "/v1/messages/%s/vote" % mid, tb, {"options": [1]})[0] == 400)
    print("FAILS: %d" % fails)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
