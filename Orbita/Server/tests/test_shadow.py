"""Теневое ограничение: «бесплатно/купить…» — шортс видят только первые 5 человек в рекомендациях и поиске"""
import io
import json
import sys
import urllib.parse
import urllib.request
from smoke import jbody, req, session
from PIL import Image
fails = 0
def check(label, cond, extra=""):
    global fails
    print(("OK   " if cond else "FAIL ") + label + ("" if cond else " " + str(extra))); fails += 0 if cond else 1
a, ta = session("Продавец")
b, tb = session("Зритель")
def jpg():
    out = io.BytesIO(); Image.new("RGB", (600, 800), (200, 120, 60)).save(out, "JPEG"); return out.getvalue()
s, body, _ = req("POST", "/v1/media?kind=image&w=600&h=800", ta, raw=jpg(), ctype="image/jpeg")
img = (jbody(body) or {}).get("id")
s, body, _ = req("POST", "/v1/posts", ta, {"text": "Б е с п л а т н о раздаю айфоны тенькотик", "media": [{"id": img, "width": 600, "height": 800}], "reel": True})
pid = (jbody(body) or {}).get("id")
s, body, _ = req("POST", "/v1/posts", ta, {"text": "закат тенькотик", "media": [{"id": img, "width": 600, "height": 800}], "reel": True})
ok_pid = (jbody(body) or {}).get("id")
Q = urllib.parse.quote("тенькотик")
found = lambda tok: [r["id"] for r in (jbody(req("GET", "/v1/reels/search?q=" + Q, tok)[1]) or {}).get("reels", [])]
check("пока зрителей мало — находится", pid in found(tb))
for i in range(5):
    _, tv = session("Зр%d" % i)
    req("POST", "/v1/events", tv, {"events": [{"type": "view", "post_id": pid, "ms": 3000, "ratio": 1.0}]})
f = found(tb)
check("после 5 зрителей — в поиске не попадается", pid not in f and ok_pid in f, f)
check("в рекомендациях тоже нет", pid not in [r["id"] for r in (jbody(req("GET", "/v1/reels", tb)[1]) or {}).get("reels", [])])
check("автор свой ролик видит", pid in found(ta))
def admin(method, path, body=None):
    rq = urllib.request.Request("http://127.0.0.1:8080" + path, method=method,
                                headers={"X-Admin-Token": "testadmin", "Content-Type": "application/json"},
                                data=json.dumps(body).encode() if body is not None else None)
    with urllib.request.urlopen(rq, timeout=10) as r:
        return json.loads(r.read() or b"{}")
lst = admin("GET", "/v1/admin/shadow")
check("админ видит ограниченные", any(p["id"] == pid for p in lst.get("posts", [])) and not any(p["id"] == ok_pid for p in lst.get("posts", [])))
admin("POST", "/v1/admin/posts/%s/shadow" % pid, {"on": False})
check("админ снял — снова находится", pid in found(tb))
print("FAILS: %d" % fails)
sys.exit(1 if fails else 0)
