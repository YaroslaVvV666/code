"""Продвижение шортсов: запуск, показ нужной аудитории в рекомендациях и поиске, статистика, пауза"""
import io
import sys
import urllib.parse
from smoke import jbody, req, session
from PIL import Image
fails = 0
def check(label, cond, extra=""):
    global fails
    print(("OK   " if cond else "FAIL ") + label + ("" if cond else " " + str(extra))); fails += 0 if cond else 1
a, ta = session("Автор Промо")
b, tb = session("Зритель Промо")
c, tc = session("Зритель Мужчина")
def jpg():
    out = io.BytesIO(); Image.new("RGB", (600, 800), (10, 120, 60)).save(out, "JPEG"); return out.getvalue()
s, body, _ = req("POST", "/v1/media?kind=image&w=600&h=800", ta, raw=jpg(), ctype="image/jpeg")
img = (jbody(body) or {}).get("id")
s, body, _ = req("POST", "/v1/posts", ta, {"text": "уникальныйпромо ролик", "media": [{"id": img, "width": 600, "height": 800}], "reel": True})
pid = (jbody(body) or {}).get("id")
opts = jbody(req("GET", "/v1/promo/options", ta)[1]) or {}
check("варианты продвижения", opts.get("free") is True and 1000 in opts.get("packs", []) and "music" in opts.get("interests", []), opts)
req("PUT", "/v1/me", tb, {"gender": "f"})
req("PUT", "/v1/me", tc, {"gender": "m"})
check("чужой не продвинет", req("POST", "/v1/posts/%s/promote" % pid, tb, {"kind": "views", "views": 1000})[0] == 404)
s, body, _ = req("POST", "/v1/posts/%s/promote" % pid, ta, {"kind": "views", "views": 1000, "goal": "views", "targeting": {"gender": "f"}})
pr = (jbody(body) or {}).get("promotion", {})
check("продвижение запущено, бесплатно", s == 201 and pr.get("status") == "active" and pr.get("price") == 150 and pr.get("spent") == 0, body[:200])
feed_b = [r["id"] for r in (jbody(req("GET", "/v1/reels", tb)[1]) or {}).get("reels", [])]
feed_c = [r["id"] for r in (jbody(req("GET", "/v1/reels", tc)[1]) or {}).get("reels", [])]
check("женщине показали в рекомендациях", pid in feed_b, feed_b)
shows = (jbody(req("GET", "/v1/posts/%s/promotions" % pid, ta)[1]) or {}).get("promotions", [{}])[0]
check("показ засчитан только женщине (аудитория)", shows.get("impressions") == 1, shows)
r = (jbody(req("GET", "/v1/reels", tb)[1]) or {}).get("reels", [])
check("без пометки «реклама»", all("promoted" not in x and "ad" not in x for x in r))
req("POST", "/v1/events", tb, {"events": [{"type": "view", "post_id": pid, "ms": 5000, "ratio": 1.0}]})
lst = (jbody(req("GET", "/v1/posts/%s/promotions" % pid, ta)[1]) or {}).get("promotions", [])
check("статистика: 1 показ, 1 просмотр", lst and lst[0]["impressions"] == 1 and lst[0]["views"] == 1, lst[:1])
s, body, _ = req("POST", "/v1/promotions/%s/pause" % pr.get("id"), ta)
check("пауза", s == 200 and (jbody(body) or {}).get("promotion", {}).get("status") == "paused", body[:150])
print("FAILS: %d" % fails)
sys.exit(1 if fails else 0)
