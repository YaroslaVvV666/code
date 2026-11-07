"""Фото-цепочка: тема, фото по кругу, проверка владельцем, удаление не по теме, коллаж в шортсы."""
import io
import sys

from smoke import jbody, req, session
from PIL import Image


def main():
    fails = 0

    def check(label, cond, extra=""):
        nonlocal fails
        print(("OK   " if cond else "FAIL ") + label + (" " + str(extra) if extra and not cond else ""))
        fails += 0 if cond else 1

    a, ta = session("Хозяйка")
    b, tb = session("Гость")
    c, tc = session("Чужой")

    def photo(token, color):
        out = io.BytesIO(); Image.new("RGB", (400, 400), color).save(out, "JPEG")
        s, body, _ = req("POST", "/v1/media?kind=image&w=400&h=400", token, raw=out.getvalue(), ctype="image/jpeg")
        return (jbody(body) or {}).get("id")

    s, body, _ = req("POST", "/v1/chats/%s/messages" % b, ta, {"chain": {"theme": "Мой завтрак", "moderated": True}})
    m = jbody(body) or {}
    mid = m.get("id")
    check("цепочка создана", s == 201 and m.get("chain", {}).get("theme") == "Мой завтрак" and m["chain"]["owner"], body[:200])
    s, body, _ = req("POST", "/v1/chains/%s/items" % mid, ta, {"media_id": photo(ta, "red")})
    check("фото владельца — сразу", s == 200 and (jbody(body) or {}).get("status") == "approved", body[:120])
    s, body, _ = req("POST", "/v1/chains/%s/items" % mid, tb, {"media_id": photo(tb, "blue")})
    check("фото гостя — на проверке", s == 200 and (jbody(body) or {}).get("status") == "pending", body[:120])
    guest_view = [x for x in (jbody(req("GET", "/v1/chats/%s/messages?peek=1" % a, tb)[1]) or {}).get("messages", []) if x.get("chain")][-1]["chain"]
    check("гость видит своё на проверке, но не в ленте", len(guest_view["items"]) == 1 and len(guest_view["pending"]) == 1, guest_view)
    owner_view = [x for x in (jbody(req("GET", "/v1/chats/%s/messages?peek=1" % b, ta)[1]) or {}).get("messages", []) if x.get("chain")][-1]["chain"]
    pid = owner_view["pending"][0]["id"] if owner_view["pending"] else ""
    s, body, _ = req("POST", "/v1/chains/%s/items/%s/approve" % (mid, pid), ta)
    check("владелец одобрил", s == 200 and len((jbody(body) or {}).get("chain", {}).get("items", [])) == 2, body[:200])
    s, body, _ = req("POST", "/v1/chains/%s/items" % mid, tb, {"media_id": photo(tb, "green")})
    off = (jbody(body) or {}).get("chain", {}).get("pending", [{}])[0].get("id", "")
    check("гость не может одобрить", req("POST", "/v1/chains/%s/items/%s/approve" % (mid, off), tb)[0] == 403)
    check("владелец убирает не по теме", req("DELETE", "/v1/chains/%s/items/%s" % (mid, off), ta)[0] == 200)
    check("чужой не добавит", req("POST", "/v1/chains/%s/items" % mid, tc, {"media_id": photo(tc, "black")})[0] == 404)
    s, body, _ = req("POST", "/v1/chains/%s/reel" % mid, ta)
    reel = jbody(body) or {}
    check("коллаж в шортсы", s == 201 and reel.get("reel") and len(reel.get("media", [])) == 2, body[:200])
    check("завершить", req("POST", "/v1/chains/%s/settings" % mid, ta, {"closed": True})[0] == 200)
    check("после завершения не добавить", req("POST", "/v1/chains/%s/items" % mid, tb, {"media_id": photo(tb, "white")})[0] == 409)
    print("FAILS: %d" % fails)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
