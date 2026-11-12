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
check("продвижение ушло на проверку, бесплатно", s == 201 and pr.get("status") == "review" and pr.get("price") == 150 and pr.get("spent") == 0, body[:200])
feed0 = [r["id"] for r in (jbody(req("GET", "/v1/reels?exclude=", tb)[1]) or {}).get("reels", [])]
st0 = (jbody(req("GET", "/v1/posts/%s/promotions" % pid, ta)[1]) or {}).get("promotions", [{}])[0]
check("до проверки не показывается как продвижение", st0.get("impressions") == 0, st0)
ADM = {"X-Admin-Token": "testadmin"}
import json as _json, urllib.request as _u
def admin(method, path, body=None):
    rq = _u.Request("http://127.0.0.1:8080" + path, method=method, headers={**ADM, "Content-Type": "application/json"},
                    data=_json.dumps(body).encode() if body is not None else None)
    try:
        with _u.urlopen(rq, timeout=10) as r:
            return r.status, _json.loads(r.read() or b"{}")
    except _u.HTTPError as e:
        return e.code, {}
s2, lst = admin("GET", "/v1/admin/promotions")
check("админ видит на проверке", s2 == 200 and any(x["id"] == pr.get("id") for x in lst.get("promotions", [])), lst)
s2, dec = admin("POST", "/v1/admin/promotions/%s/decide" % pr.get("id"), {"decision": "personal"})
check("админ: обычное видео — запущено без пометки", s2 == 200 and dec["promotion"]["status"] == "active" and dec["promotion"]["ad_kind"] == "personal", dec)
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
# реклама: магазин — модератор отмечает «реклама», автор указывает рекламодателя, у зрителей пометка
s, body, _ = req("POST", "/v1/posts", ta, {"text": "продаю кроссовки скидки", "media": [{"id": img, "width": 600, "height": 800}], "reel": True})
pid2 = (jbody(body) or {}).get("id")
pr2 = (jbody(req("POST", "/v1/posts/%s/promote" % pid2, ta, {"kind": "top", "days": 1})[1]) or {}).get("promotion", {})
s2, dec = admin("POST", "/v1/admin/promotions/%s/decide" % pr2.get("id"), {"decision": "ad", "erid": "2VtzqvXyZ1"})
check("реклама без данных — ждёт рекламодателя", dec.get("promotion", {}).get("status") == "needs_info", dec)
check("неверный ИНН — отказ", req("POST", "/v1/promotions/%s/advertiser" % pr2.get("id"), ta, {"type": "ooo", "name": "Ромашка", "inn": "123"})[0] == 400)
s, body, _ = req("POST", "/v1/promotions/%s/advertiser" % pr2.get("id"), ta, {"type": "ooo", "name": "ООО «Ромашка»", "inn": "7701234567"})
check("рекламодатель указан — запущено", (jbody(body) or {}).get("promotion", {}).get("status") == "active", body[:200])
post2 = jbody(req("GET", "/v1/posts/%s" % pid2, tb)[1]) or {}
check("у зрителя пометка «Реклама» с данными", post2.get("ad", {}).get("inn") == "7701234567" and post2["ad"].get("erid") == "2VtzqvXyZ1", post2.get("ad"))
post1 = jbody(req("GET", "/v1/posts/%s" % pid, tb)[1]) or {}
check("обычное видео — без пометки", "ad" not in post1, post1.get("ad"))
s2, dec = admin("POST", "/v1/admin/promotions/%s/decide" % pr2.get("id"), {"decision": "reject", "note": "тест"})
check("отклонение с причиной", dec.get("promotion", {}).get("status") == "rejected" and dec["promotion"]["note"] == "тест", dec)
print("FAILS: %d" % fails)
sys.exit(1 if fails else 0)
