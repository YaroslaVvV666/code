"""Поиск в мессенджере: частые собеседники за месяц и всё присланное во всех чатах"""
import sys
from smoke import jbody, req, session
fails = 0
def check(label, cond, extra=""):
    global fails
    print(("OK   " if cond else "FAIL ") + label + ("" if cond else " " + str(extra))); fails += 0 if cond else 1
a, ta = session("Я")
b, tb = session("Друг")
c, tc = session("Знакомый")
for i in range(3):
    req("POST", "/v1/chats/%s/messages" % b, ta, {"text": "привет %d" % i})
req("POST", "/v1/chats/%s/messages" % c, ta, {"text": "глянь https://example.com/page и www.orbita.app"})
s, body, _ = req("POST", "/v1/media?kind=audio&dur=3", tb, raw=b"ID3" + b"\x00" * 4000, ctype="audio/mpeg")
mid = (jbody(body) or {}).get("id")
req("POST", "/v1/chats/%s/messages" % a, tb, {"text": "", "attachments": [{"type": "voice", "media_id": mid}]})
hub = jbody(req("GET", "/v1/me/search-hub", ta)[1]) or {}
top = hub.get("top", [])
check("частые собеседники: друг первым", top and top[0]["id"] == b and top[0]["count"] >= 4, top[:2])
links = (jbody(req("GET", "/v1/me/shared?kind=links", ta)[1]) or {}).get("items", [])
urls = [x["url"] for x in links]
check("ссылки из всех чатов", "https://example.com/page" in urls and "https://www.orbita.app" in urls, urls)
voice = (jbody(req("GET", "/v1/me/shared?kind=voice", ta)[1]) or {}).get("items", [])
check("голосовые из всех чатов", voice and voice[0]["chat"]["id"] == b and voice[0]["attachment"]["media_id"] == mid, voice[:1])
check("неверный вид — отказ", req("GET", "/v1/me/shared?kind=hack", ta)[0] == 400)
import urllib.parse
qq = urllib.parse.quote("привет")
allh = (jbody(req("GET", "/v1/search/messages?q=%s" % qq, ta)[1]) or {}).get("hits", [])
pers = (jbody(req("GET", "/v1/search/messages?q=%s&scope=personal" % qq, ta)[1]) or {}).get("hits", [])
grp = (jbody(req("GET", "/v1/search/messages?q=%s&scope=groups" % qq, ta)[1]) or {}).get("hits", [])
check("поиск слова в переписках", len(allh) >= 3 and all("привет" in h["text"] for h in allh), allh[:1])
check("«Личные чаты» находят, «Группы» — нет", len(pers) == len(allh) and grp == [], (len(pers), len(grp)))
print("FAILS: %d" % fails)
sys.exit(1 if fails else 0)
