"""Вредоносные файлы и ссылки: подмена типа, «../» в имени, SSRF через вебхук бота и превью ссылок.
Сервер должен быть запущен."""
import re
import sys

from smoke import jbody, req, session

BOTGOD = "b0790d00-0000-4000-8000-00000000b070"


def main():
    fails = 0

    def check(label, cond, extra=""):
        nonlocal fails
        print(("OK   " if cond else "FAIL ") + label + (" " + str(extra) if extra and not cond else ""))
        fails += 0 if cond else 1

    a, ta = session("Атакующий")
    v, tv = session("Жертва")

    html = b"<html><script>alert(1)</script></html>" + b" " * 200
    check("HTML под видом картинки — 415",
          req("POST", "/v1/media?kind=image&w=8&h=8", ta, raw=html, ctype="image/png")[0] == 415)
    check("HTML под видом голосового — 415",
          req("POST", "/v1/media?kind=audio&dur=1", ta, raw=html, ctype="audio/mp4")[0] == 415)
    check("SVG под видом видео — 415",
          req("POST", "/v1/media?kind=video", ta, raw=b"<svg onload=alert(1)>" + b" " * 64, ctype="video/mp4")[0] == 415)
    check("mp3 (ID3) как голосовое — принимается",
          req("POST", "/v1/media?kind=audio&dur=1", ta, raw=b"ID3\x03\x00\x00\x00\x00\x00\x00" + b"\x00" * 500,
              ctype="audio/mpeg")[0] == 201)

    # файл с опасным именем: путь, невидимый символ направления текста
    s, b, _ = req("POST", "/v1/media?kind=file", ta, raw=b"<html><script>steal()</script></html>", ctype="text/html")
    check("файл загружен", s == 201, (s, b[:200]))
    fid = (jbody(b) or {}).get("id")
    s, _, h = req("GET", "/media/%s" % fid)
    check("файл отдаётся как скачивание, не как страница",
          h.get("Content-Type") == "application/octet-stream" and "attachment" in (h.get("Content-Disposition") or "")
          and h.get("X-Content-Type-Options") == "nosniff" and "sandbox" in (h.get("Content-Security-Policy") or ""), h)
    s, b, _ = req("POST", "/v1/chats/%s/messages" % v, ta, {
        "text": "", "attachments": [{"type": "file", "media_id": fid, "name": "../../Library/фото‮gnp.exe"}]})
    check("сообщение с файлом", s in (200, 201), (s, b[:200]))
    s, b, _ = req("GET", "/v1/chats/%s/messages" % a, tv)
    msgs = (jbody(b) or {}).get("messages", [])
    names = [x.get("name") for m in msgs for x in (m.get("attachments") or [])]
    check("имя файла очищено от «../» и невидимых символов",
          names and "/" not in names[-1] and "‮" not in names[-1] and not names[-1].startswith("."), names)

    # SSRF: превью ссылки на внутренние адреса
    for url in ("http://127.0.0.1:8080/v1/ping", "http://169.254.169.254/latest/meta-data/",
                "http://[::ffff:127.0.0.1]:8080/", "http://localhost:8080/", "file:///etc/passwd"):
        s = req("GET", "/v1/link_preview?url=" + url, ta)[0]
        check("превью не ходит на %s" % url, s in (400, 404), s)

    # SSRF: вебхук бота во внутреннюю сеть
    def god(text):
        req("POST", "/v1/chats/%s/messages" % BOTGOD, ta, {"text": text})
        s, b, _ = req("GET", "/v1/chats/%s/messages?peek=1" % BOTGOD, ta)
        return (jbody(b) or {}).get("messages", [])[-1]["text"]

    god("/newbot"); god("Сек Бот")
    m = re.search(r"\n([0-9a-f]{12}:[A-Za-z0-9_\-]+)\n", god("sec_check_bot"))
    token = m.group(1) if m else ""
    check("бот создан", bool(token))
    for url in ("https://127.0.0.1/hook", "https://10.0.0.5/hook", "https://169.254.169.254/x",
                "https://localhost:8443/", "https://user:pass@example.com/", "http://example.com/"):
        s = req("POST", "/bot%s/setWebhook" % token, body={"url": url})[0]
        check("вебхук %s отклонён" % url, s == 400, s)

    print("FAILS: %d" % fails)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
