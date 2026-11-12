"""Скрепка: чек-лист, карточка контакта, недавняя музыка и копия трека."""
import sys

from smoke import jbody, req, session


def main():
    fails = 0

    def check(label, cond, extra=""):
        nonlocal fails
        print(("OK   " if cond else "FAIL ") + label + (" " + str(extra) if extra and not cond else ""))
        fails += 0 if cond else 1

    a, ta = session("Маша")
    b, tb = session("Паша")
    c, tc = session("Саша")

    s, body, _ = req("POST", "/v1/chats/%s/messages" % b, ta, {"checklist": {"title": "Купить", "items": ["Хлеб", "Молоко"], "others_add": True}})
    m = jbody(body) or {}
    cl = m.get("checklist") or {}
    check("чек-лист создан", s == 201 and len(cl.get("items", [])) == 2 and cl.get("owner"), body[:200])
    iid = cl["items"][0]["id"] if cl.get("items") else ""
    s, body, _ = req("POST", "/v1/checklists/%s/items/%s/toggle" % (m.get("id"), iid), tb)
    item = ((jbody(body) or {}).get("checklist") or {}).get("items", [{}])[0]
    check("собеседник отметил пункт", s == 200 and item.get("done") and item.get("done_by", {}).get("me"), body[:200])
    s, body, _ = req("POST", "/v1/checklists/%s/items" % m.get("id"), tb, {"text": "Сыр"})
    check("собеседник добавил пункт", s == 200 and len((jbody(body) or {}).get("checklist", {}).get("items", [])) == 3, body[:200])
    check("чужой не тронет", req("POST", "/v1/checklists/%s/items/%s/toggle" % (m.get("id"), iid), tc)[0] == 404)

    s, body, _ = req("POST", "/v1/chats/%s/messages" % b, ta, {"text": "", "attachments": [{"type": "contact", "user_id": c, "phone": "+79991234567"}]})
    att = ((jbody(body) or {}).get("attachments") or [{}])[0]
    check("карточка контакта", s == 201 and att.get("type") == "contact" and att.get("name") == "Саша" and att.get("phone") == "+79991234567", body[:200])

    s, body, _ = req("POST", "/v1/media?kind=audio&dur=30", tb, raw=b"ID3" + b"\x00" * 4000, ctype="audio/mpeg")
    mid = (jbody(body) or {}).get("id")
    s, body, _ = req("POST", "/v1/chats/%s/messages" % a, tb, {"text": "", "attachments": [{"type": "audio", "media_id": mid, "title": "Песня", "artist": "Певец"}]})
    msg = jbody(body) or {}
    rec = (jbody(req("GET", "/v1/me/recent-audio", ta)[1]) or {}).get("audio", [])
    check("недавняя музыка из чата", rec and rec[0]["title"] == "Песня", rec[:1])
    s, body, _ = req("POST", "/v1/messages/%s/audio-copy" % msg.get("id"), ta, {"media_id": mid})
    copy = jbody(body) or {}
    check("своя копия трека", s == 200 and copy.get("media_id") and copy["media_id"] != mid, body[:200])
    s, body, _ = req("POST", "/v1/chats/%s/messages" % c, ta, {"text": "", "attachments": [{"type": "audio", "media_id": copy.get("media_id"), "title": "Песня"}]})
    check("копию можно отправить дальше", s == 201, body[:150])
    check("чужой трек без доступа не скопировать", req("POST", "/v1/messages/%s/audio-copy" % msg.get("id"), tc, {"media_id": mid})[0] == 404)
    # свой плейлист: отправляется копия — удалят сообщение, песня в плейлисте останется
    s, body, _ = req("POST", "/v1/media?kind=audio&dur=30", ta, raw=b"ID3" + b"\x00" * 4000, ctype="audio/mpeg")
    pm = (jbody(body) or {}).get("id")
    s, body, _ = req("POST", "/v1/me/playlist", ta, {"media_id": pm, "title": "Моя", "artist": "Я"})
    tid = (jbody(body) or {}).get("id")
    s, body, _ = req("POST", "/v1/me/playlist/%s/copy" % tid, ta)
    pc = jbody(body) or {}
    check("копия трека из плейлиста", s == 200 and pc.get("media_id") and pc["media_id"] != pm and pc.get("title") == "Моя", body[:200])
    check("чужой плейлист не скопировать", req("POST", "/v1/me/playlist/%s/copy" % tid, tb)[0] == 404)
    print("FAILS: %d" % fails)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
