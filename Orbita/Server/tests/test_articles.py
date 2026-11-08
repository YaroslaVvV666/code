"""Статьи в сообщениях: блоки (заголовки, текст, цитаты, код, формула, списки, таблица, медиа, кнопки),
кнопки под сообщением, проверка ссылок и чужих файлов, личка и группа."""
import base64
import sys

from smoke import jbody, req, session

JPEG = base64.b64decode(
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAAIAAgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDlqKKK+NP1M//Z")


def main():
    fails = 0

    def check(label, cond, extra=""):
        nonlocal fails
        print(("OK   " if cond else "FAIL ") + label + (" " + str(extra) if extra and not cond else ""))
        fails += 0 if cond else 1

    a, ta = session("Автор")
    b_, tb = session("Читатель")
    s, b, _ = req("POST", "/v1/media?kind=image&w=8&h=8", ta, raw=JPEG, ctype="image/jpeg")
    mid = (jbody(b) or {}).get("id")
    blocks = [
        {"kind": "heading", "level": 1, "text": "Крутяк бургер"},
        {"kind": "media", "media": {"type": "photo", "media_id": mid}, "caption": "Фото: шеф"},
        {"kind": "text", "text": "Бургеры черные\nи вкусные"},
        {"kind": "quote", "text": "бургер это круто"},
        {"kind": "pullquote", "text": "Бургер — блюдо.", "author": "шеф"},
        {"kind": "code", "text": "print('hi')", "lang": "python"},
        {"kind": "formula", "text": "Q = cm(t_2 - t_1)"},
        {"kind": "list", "style": "check", "items": [{"text": "булка", "checked": True}, {"text": "котлета"}]},
        {"kind": "collapse", "text": "Рецепт", "body": "Секрет"},
        {"kind": "table", "rows": [["Блюдо", "Цена"], ["Бургер", "300"]]},
        {"kind": "button", "text": "Сайт", "url": "https://example.com", "color": "green"},
        {"kind": "unknown", "text": "x"},
    ]
    buttons = [{"text": "купить чизбургер", "url": "https://shop.example.com", "color": "white"}]
    s, b, _ = req("POST", "/v1/chats/%s/messages" % b_, ta, {"text": "", "blocks": blocks, "buttons": buttons})
    d = jbody(b) or {}
    check("статья отправлена", s == 201 and len(d.get("blocks", [])) == 11, (s, b[:300]))
    check("выжимка для списка чатов", d.get("text", "").startswith("Крутяк бургер\nБургеры"), d.get("text"))
    s, b, _ = req("GET", "/v1/chats/%s/messages" % a, tb)
    m = (jbody(b) or {}).get("messages", [])[-1]
    kinds = [x["kind"] for x in m.get("blocks", [])]
    check("читатель видит блоки по порядку", kinds[:3] == ["heading", "media", "text"], kinds)
    media = m["blocks"][1]["media"]
    check("медиа внутри статьи с подписью", media.get("type") == "photo" and media.get("width") == 8
          and m["blocks"][1]["caption"] == "Фото: шеф", m["blocks"][1])
    check("кнопка под сообщением с цветом", m.get("markup") == [[{"text": "купить чизбургер", "url": "https://shop.example.com",
                                                                  "color": "white"}]], m.get("markup"))
    check("кнопка в тексте", m["blocks"][-1] == {"kind": "button", "text": "Сайт", "url": "https://example.com", "color": "green"})
    check("таблица и список", m["blocks"][9]["rows"][1] == ["Бургер", "300"] and m["blocks"][7]["items"][0]["checked"])

    bad = req("POST", "/v1/chats/%s/messages" % b_, ta, {"blocks": [{"kind": "button", "text": "x", "url": "javascript:alert(1)"}]})
    check("кнопка с javascript: — отказ", bad[0] == 400, bad[:2])
    s, b, _ = req("POST", "/v1/media?kind=image&w=8&h=8", tb, raw=JPEG, ctype="image/jpeg")
    other = (jbody(b) or {}).get("id")
    bad = req("POST", "/v1/chats/%s/messages" % b_, ta, {"blocks": [{"kind": "media", "media": {"type": "photo", "media_id": other}}]})
    check("чужой файл в статье — отказ", bad[0] == 400)
    s, b, _ = req("POST", "/v1/chats/%s/messages" % b_, ta, {"blocks": [{"kind": "text", "text": "a‮b"}]})
    check("невидимые символы вырезаны", (jbody(b) or {}).get("blocks", [{}])[0].get("text") == "ab", b[:200])

    s, b, _ = req("POST", "/v1/groups", ta, {"title": "Блог", "type": "channel"})
    gid = (jbody(b) or {}).get("id")
    s, b, _ = req("POST", "/v1/chats/%s/messages" % gid, ta, {"blocks": blocks[:3], "buttons": buttons})
    d = jbody(b) or {}
    check("статья в канале", s == 201 and len(d.get("blocks", [])) == 3 and d.get("markup"), (s, b[:200]))
    # пересылка статьи: блоки, фото внутри и кнопки-ссылки — целиком
    c_, tc = session("Третий")
    art = next((x for x in (jbody(req("GET", "/v1/chats/%s/messages" % a, tb)[1]) or {}).get("messages", []) if x.get("blocks")), {})
    s, b, _ = req("POST", "/v1/chats/%s/forward" % c_, tb, {"ids": [art.get("id")]})
    check("статья переслана", s == 200 and (jbody(b) or {}).get("count") == 1, b[:200])
    fm = ((jbody(req("GET", "/v1/chats/%s/messages" % b_, tc)[1]) or {}).get("messages") or [{}])[-1]
    fk = [x["kind"] for x in fm.get("blocks", [])]
    check("у получателя пересылки — все блоки", fk[:3] == ["heading", "media", "text"] and len(fk) == 11, fk)
    fmedia = (fm.get("blocks") or [{}, {}])[1].get("media", {})
    check("фото в пересланной статье — своя копия", fmedia.get("media_id") and fmedia.get("media_id") != mid, fmedia)
    check("кнопки под пересланной статьёй", (fm.get("markup") or [[{}]])[0][0].get("url") == "https://shop.example.com", fm.get("markup"))
    check("пометка «Переслано»", bool(fm.get("forwarded")), fm.get("forwarded"))
    print("FAILS: %d" % fails)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
