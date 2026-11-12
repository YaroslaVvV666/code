"""Фильтр чатов («фокус»): сохраняется, неизвестное значение сбрасывается"""
import sys
from smoke import jbody, req, session
fails = 0
def check(label, cond, extra=""):
    global fails
    print(("OK   " if cond else "FAIL ") + label + ("" if cond else " " + str(extra))); fails += 0 if cond else 1
a, ta = session("Фокус")
s, b, _ = req("PUT", "/v1/me/chat-focus", ta, {"folder": "personal"})
check("фокус «личные» сохранён", s == 200 and (jbody(b) or {}).get("folder") == "personal", b[:100])
s, b, _ = req("PUT", "/v1/me/chat-focus", ta, {"folder": "hack"})
check("неизвестный фильтр — сброс", s == 200 and (jbody(b) or {}).get("folder") is None, b[:100])
s, b, _ = req("PUT", "/v1/me/chat-focus", ta, {"folder": None})
check("снять фокус", s == 200, b[:100])
print("FAILS: %d" % fails)
sys.exit(1 if fails else 0)
