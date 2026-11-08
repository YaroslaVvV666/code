"""Поиск по шортсам: вкладки (лучшее/видео/фото/люди/хэштеги), подфильтры, «топовое», статистика для автора"""
import io
import sys
import urllib.parse
from smoke import jbody, req, session
from PIL import Image
fails = 0
def check(label, cond, extra=""):
    global fails
    print(("OK   " if cond else "FAIL ") + label + ("" if cond else " " + str(extra))); fails += 0 if cond else 1
a, ta = session("Зимний Автор")
b, tb = session("Зритель")
def jpg():
    out = io.BytesIO(); Image.new("RGB", (600, 800), (20, 30, 200)).save(out, "JPEG"); return out.getvalue()
s, body, _ = req("POST", "/v1/media?kind=image&w=600&h=800", ta, raw=jpg(), ctype="image/jpeg")
img = (jbody(body) or {}).get("id")
s, body, _ = req("POST", "/v1/posts", ta, {"text": "зимний вайб #зимавайб", "media": [{"id": img, "width": 600, "height": 800}], "reel": True})
pid = (jbody(body) or {}).get("id")
check("шортс-фото создан", s == 201 and pid, body[:150])
Q = urllib.parse.quote("зимний вайб")
best = (jbody(req("GET", "/v1/reels/search?q=%s&tab=best" % Q, tb)[1]) or {}).get("reels", [])
check("лучшее: нашлось и помечено «топовое»", best and best[0]["id"] == pid and best[0].get("top"), best[:1])
photo = (jbody(req("GET", "/v1/reels/search?q=%s&tab=photo" % Q, tb)[1]) or {}).get("reels", [])
video = (jbody(req("GET", "/v1/reels/search?q=%s&tab=video" % Q, tb)[1]) or {}).get("reels", [])
check("фото — во вкладке «Фото», не в «Видео»", any(r["id"] == pid for r in photo) and not any(r["id"] == pid for r in video))
unseen = (jbody(req("GET", "/v1/reels/search?q=%s&filter=unseen" % Q, tb)[1]) or {}).get("reels", [])
check("не просмотрено — есть", any(r["id"] == pid for r in unseen))
req("POST", "/v1/events", tb, {"events": [{"type": "view", "post_id": pid, "ms": 4000, "ratio": 1.0}]})
seen = (jbody(req("GET", "/v1/reels/search?q=%s&filter=seen" % Q, tb)[1]) or {}).get("reels", [])
check("после полноэкранного просмотра — в «Просмотрено»", any(r["id"] == pid for r in seen))
tags = (jbody(req("GET", "/v1/reels/search/extra?kind=tags&q=" + urllib.parse.quote("зимавайб"), tb)[1]) or {}).get("tags", [])
check("хэштег найден", any(t["tag"] == "зимавайб" for t in tags), tags)
people = (jbody(req("GET", "/v1/reels/search/extra?kind=people&q=" + urllib.parse.quote("Зимний"), tb)[1]) or {}).get("people", [])
check("автор найден в «Людях»", any(p["id"] == a for p in people), people[:1])
req("POST", "/v1/reels/search/track", tb, {"q": "зимний вайб", "events": [{"post_id": pid, "kind": "shown"}, {"post_id": pid, "kind": "autoplay"}, {"post_id": pid, "kind": "open"}]})
st = (jbody(req("GET", "/v1/posts/%s/stats" % pid, ta)[1]) or {}).get("search", {})
check("статистика автора: показ, автопроигрывание, открытие, запрос", st.get("shown") == 1 and st.get("autoplay") == 1 and st.get("opened") == 1
      and st.get("queries", [{}])[0].get("q") == "зимний вайб", st)
print("FAILS: %d" % fails)
sys.exit(1 if fails else 0)
