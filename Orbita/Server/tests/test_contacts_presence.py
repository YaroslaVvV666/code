"""«Написать сообщение»: контакты приходят с временем «в сети» (если человек его показывает)"""
import sys
from smoke import jbody, req, session
fails = 0
def check(label, cond, extra=""):
    global fails
    print(("OK   " if cond else "FAIL ") + label + ("" if cond else " " + str(extra))); fails += 0 if cond else 1
a, ta = session("Я")
b, tb = session("Друг")
check("добавил в контакты", req("PUT", "/v1/contacts/%s" % b, ta, {"name": "Друг"})[0] == 200)
req("GET", "/v1/chats", tb)                     # друг что-то делал — он «в сети»
lst = (jbody(req("GET", "/v1/contacts", ta)[1]) or {}).get("contacts", [])
c = next((x for x in lst if x["id"] == b), {})
check("контакт в списке", bool(c), lst)
check("время в сети пришло", isinstance(c.get("last_seen"), (int, float)), c)
print("FAILS: %d" % fails)
sys.exit(1 if fails else 0)
