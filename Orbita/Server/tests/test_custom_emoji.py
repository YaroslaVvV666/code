"""Свои эмодзи: набор эмодзи только через @stickers, анимированный (только Lottie .json) и статичный
(картинка → обрезка по центру → PNG 100×100), проверки Lottie, эмодзи в тексте сообщения (custom_emoji), поиск по id."""
import gzip
import io
import json
import sys

from smoke import jbody, req, session

BOT = "5717c4e5-0000-4000-8000-00000000057c"


def lottie(seconds=2, w=100, extra_layer=None):
    layer = {"ty": 4, "ip": 0, "op": 60 * seconds, "st": 0, "ks": {}, "shapes": [{"ty": "rc", "s": {"a": 0, "k": [50, 50]}}]}
    if extra_layer:
        layer.update(extra_layer)
    return {"v": "5.7.4", "fr": 60, "ip": 0, "op": 60 * seconds, "w": w, "h": w, "layers": [layer], "meta": {"g": "LottieFiles"}}


def png(w, h=None):
    from PIL import Image
    out = io.BytesIO()
    Image.new("RGBA", (w, h or w), (255, 0, 0, 128)).save(out, "PNG")
    return out.getvalue()


def main():
    fails = 0

    def check(label, cond, extra=""):
        nonlocal fails
        print(("OK   " if cond else "FAIL ") + label + (" " + str(extra) if extra and not cond else ""))
        fails += 0 if cond else 1

    me, t = session("Дизайнер")
    friend, tf = session("Друг")

    def say(text="", atts=None):
        req("POST", "/v1/chats/%s/messages" % BOT, t, {"text": text, "attachments": atts or []})
        msgs = (jbody(req("GET", "/v1/chats/%s/messages?peek=1" % BOT, t)[1]) or {}).get("messages", [])
        return msgs[-1]

    def upload_file(data, name, mime):
        s, b, _ = req("POST", "/v1/media?kind=file", t, raw=data, ctype=mime)
        return {"type": "file", "media_id": (jbody(b) or {}).get("id"), "name": name}

    check("/newemojipack", "набор эмодзи" in say("/newemojipack")["text"].lower())
    check("набор создан", "создан" in say("Мои котики")["text"])
    r = say("", [upload_file(json.dumps(lottie()).encode(), "cat.json", "application/json")])
    check(".json Lottie принят", "Анимация принята" in r["text"], r["text"])
    r = say("😺")
    msgs = (jbody(req("GET", "/v1/chats/%s/messages?peek=1" % BOT, t)[1]) or {}).get("messages", [])
    done = [m for m in msgs if m["text"].startswith("Готово")][-1]
    ent = [e for e in done["entities"] if e["type"] == "custom_emoji"]
    check("бот показал свой эмодзи (custom_emoji)", ent and ent[0]["url"].startswith("u:"), done)
    emoji_id = ent[0]["url"] if ent else ""

    r = say("", [upload_file(json.dumps(lottie(1)).encode(), "heart.json", "application/json")])
    check("второй .json Lottie принят", "Анимация принята" in r["text"], r["text"])
    say("❤️")
    s, b, _ = req("POST", "/v1/media?kind=image&w=300&h=180", t, raw=png(300, 180), ctype="image/png")
    r = say("", [{"type": "photo", "media_id": (jbody(b) or {}).get("id")}])
    check("фото 300×180 → статичный (обрезан до 100×100)", "Картинка принята" in r["text"], r["text"])
    say("⭐")

    r = say("", [upload_file(json.dumps(lottie(5)).encode(), "long.json", "application/json")])
    check("длиннее 3 секунд — отказ", "не дольше" in r["text"], r["text"])
    bad = lottie()
    bad["assets"] = [{"id": "img", "p": "data:image/png;base64,AAAA"}]
    r = say("", [upload_file(json.dumps(bad).encode(), "bad.json", "application/json")])
    check("картинка внутри Lottie — отказ", "Картинки внутри" in r["text"], r["text"])
    r = say("", [upload_file(json.dumps(lottie(2, extra_layer={"ks": {"o": {"x": "var $bm_rt = 1"}}})).encode(),
                             "expr.json", "application/json")])
    check("выражения (скрипты) — отказ", "Выражения" in r["text"], r["text"])
    r = say("", [upload_file(gzip.compress(json.dumps(lottie()).encode()), "x.tgs", "application/octet-stream")])
    check("чужой формат анимации — отказ", "не поддерживается" in r["text"], r["text"])
    r = say("", [upload_file(gzip.compress(json.dumps(lottie()).encode()), "x.json", "application/json")])
    check("сжатый JSON — отказ", "не поддерживается" in r["text"], r["text"])
    say("/done")

    s, b, _ = req("GET", "/v1/stickers", t)
    packs = (jbody(b) or {}).get("packs", [])
    ep = [p for p in packs if p.get("kind") == "emoji"]
    check("в списке наборов — эмодзи-пак (kind=emoji), 3 шт.", ep and len(ep[0]["stickers"]) == 3, [p.get("kind") for p in packs][:5])
    if ep:
        st = ep[0]["stickers"]
        check("анимированные помечены lottie", st[0]["lottie"] and st[1]["lottie"] and not st[2]["lottie"], st)
        s, raw, h = req("GET", "/media/%s" % st[0]["media_id"])
        check("анимация хранится сжатой (gzip, ≤64 КБ)", raw[:2] == b"\x1f\x8b" and len(raw) <= 64 * 1024, raw[:4])
        j = json.loads(gzip.decompress(raw))
        check("метаданные вырезаны", "meta" not in j)
        from PIL import Image
        s, raw, h = req("GET", "/media/%s" % st[2]["media_id"])
        check("статичный эмодзи — ровно 100×100", Image.open(io.BytesIO(raw)).size == (100, 100))

    # эмодзи в тексте сообщения другу
    text = "Привет 😺!"
    s, b, _ = req("POST", "/v1/chats/%s/messages" % friend, t, {"text": text, "entities": [
        {"type": "custom_emoji", "offset": 7, "length": 2, "url": emoji_id},
        {"type": "custom_emoji", "offset": 0, "length": 2, "url": "u:" + "0" * 32}]})
    m = jbody(b) or {}
    ents = [e for e in m.get("entities", []) if e["type"] == "custom_emoji"]
    check("custom_emoji в тексте сохранён, несуществующий отброшен", len(ents) == 1 and ents[0]["url"] == emoji_id, m.get("entities"))
    s, b, _ = req("GET", "/v1/custom-emoji?ids=%s,u:%s" % (emoji_id, "0" * 32), tf)
    found = (jbody(b) or {}).get("emoji", [])
    check("друг получает эмодзи по id (даже без набора)", len(found) == 1 and found[0]["lottie"] and found[0]["emoji"] == "😺", found)
    check("эмодзи нельзя отправить стикером", req("POST", "/v1/chats/%s/messages" % friend, t,
                                                  {"attachments": [{"type": "sticker", "sticker": emoji_id}]})[0] == 400)
    # реакция своим эмодзи
    mid = m.get("id")
    s, b, _ = req("PUT", "/v1/messages/%s/reaction" % mid, tf, {"emoji": emoji_id})
    reacts = (jbody(b) or {}).get("reactions", [])
    check("реакция своим эмодзи", s == 200 and reacts and reacts[0]["emoji"] == emoji_id, (s, reacts))
    check("несуществующее своё эмодзи в реакции — отказ",
          req("PUT", "/v1/messages/%s/reaction" % mid, tf, {"emoji": "u:" + "1" * 32})[0] == 400)

    # из приложения наборы эмодзи не создаются — только в боте
    s, b, _ = req("POST", "/v1/stickers/packs", tf, {"title": "Из приложения", "kind": "emoji"})
    pack = jbody(b) or {}
    check("из приложения kind=emoji не создаёт набор эмодзи", s == 201 and pack.get("kind") != "emoji", b[:200])
    s, b, _ = req("POST", "/v1/media?kind=image&w=64&h=64", tf, raw=png(64), ctype="image/png")
    mid64 = (jbody(b) or {}).get("id")
    s, b, _ = req("POST", "/v1/stickers/packs/%s/emoji" % ep[0]["id"], t, {"media_id": mid64, "emoji": "🔥"})
    check("добавить эмодзи из приложения нельзя", s == 404, (s, b[:120]))
    check("в эмодзи-пак стикер не добавить", req("POST", "/v1/stickers/packs/%s/stickers" % ep[0]["id"], t,
                                                {"media_id": mid64, "emoji": "🔥"})[0] in (400, 404))
    s, b, _ = req("PUT", "/v1/stickers/packs/%s/install" % ep[0]["id"], tf)
    check("друг добавил чужой набор эмодзи", s == 200 and (jbody(b) or {}).get("installed"))
    print("FAILS: %d" % fails)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
