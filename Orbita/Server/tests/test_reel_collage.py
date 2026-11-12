"""Шортс-коллаж: до 10 фото и живых фото, в ленте шортсов и в поиске."""
import io
import sys
import urllib.parse
from smoke import jbody, req, session
from PIL import Image
fails = 0
def check(label, cond, extra=""):
    global fails
    print(("OK   " if cond else "FAIL ") + label + ("" if cond else " " + str(extra))); fails += 0 if cond else 1
me, t = session("Коллаж")
def png(w, h):
    out = io.BytesIO(); Image.new("RGB", (w, h), (200, 30, 30)).save(out, "JPEG"); return out.getvalue()
ids = []
for i in range(3):
    s, b, _ = req("POST", "/v1/media?kind=image&w=600&h=800", t, raw=png(600, 800), ctype="image/jpeg")
    ids.append((jbody(b) or {}).get("id"))
media = [{"id": i, "width": 600, "height": 800} for i in ids]
s, b, _ = req("POST", "/v1/posts", t, {"text": "Коллаж #фото", "media": media, "reel": True})
post = jbody(b) or {}
check("шортс-коллаж из 3 фото создан", s == 201 and post.get("reel") and len(post.get("media", [])) == 3, (s, b[:200]))
s, b, _ = req("GET", "/v1/reels?feed=friends", t)
check("коллаж в ленте шортсов", any(r["id"] == post.get("id") for r in (jbody(b) or {}).get("reels", [])), b[:200])
s, b, _ = req("GET", "/v1/reels/search?q=" + urllib.parse.quote("фото"), t)
check("коллаж находится поиском", any(r["id"] == post.get("id") for r in (jbody(b) or {}).get("reels", [])), b[:200])
# "живое фото" без настоящего видео — сервер должен отказать в live для картинки (флаг игнорируется) и принять коллаж
s, b, _ = req("POST", "/v1/posts", t, {"text": "", "media": [{"id": ids[0], "live": True}], "reel": True})
m = (jbody(b) or {}).get("media", [{}])[0]
check("live у картинки не ставится", s == 201 and not m.get("live"), (s, b[:200]))
s, b, _ = req("POST", "/v1/posts", t, {"text": "много", "media": [{"id": ids[0]}] * 11, "reel": True})
check("больше 10 — отказ", s == 400, s)
print("FAILS: %d" % fails)
sys.exit(1 if fails else 0)
