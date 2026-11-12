"""Закладки: сохранил пост — он в «Закладках»; убрал — пропал"""
import sys
from smoke import jbody, req, session
fails = 0
def check(label, cond, extra=""):
    global fails
    print(("OK   " if cond else "FAIL ") + label + ("" if cond else " " + str(extra))); fails += 0 if cond else 1
a, ta = session("Автор")
b, tb = session("Читатель")
s, body, _ = req("POST", "/v1/posts", ta, {"text": "пост для закладок"})
pid = (jbody(body) or {}).get("id")
check("пост создан", s in (200, 201) and pid, body[:200])
check("сохранить", req("PUT", "/v1/posts/%s/save" % pid, tb)[0] == 200)
saved = (jbody(req("GET", "/v1/me/saved", tb)[1]) or {}).get("posts", [])
check("пост в закладках", [p["id"] for p in saved] == [pid] and saved[0]["saved_by_me"], saved[:1])
check("убрать", req("DELETE", "/v1/posts/%s/save" % pid, tb)[0] == 200)
saved = (jbody(req("GET", "/v1/me/saved", tb)[1]) or {}).get("posts", [])
check("закладок нет", saved == [], saved[:1])
print("FAILS: %d" % fails)
sys.exit(1 if fails else 0)
