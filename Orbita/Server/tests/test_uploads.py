"""Загрузка частями с докачкой: обрыв посередине, продолжение с места, проверка содержимого."""
import base64
import os
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

    uid, t = session("Загрузчик")
    data = os.urandom(2_500_000 + 123)
    s, b, _ = req("POST", "/v1/uploads", t, {"kind": "file", "mime": "application/zip", "size": len(data)})
    up = jbody(b) or {}
    check("загрузка создана", s == 201 and up.get("received") == 0, b[:200])
    chunk = 1024 * 1024
    req("PUT", "/v1/uploads/%s?offset=0" % up["id"], t, raw=data[:chunk], ctype="application/octet-stream")
    # «обрыв»: повторно шлём тот же кусок — сервер говорит, сколько уже есть
    s, b, _ = req("PUT", "/v1/uploads/%s?offset=0" % up["id"], t, raw=data[:chunk], ctype="application/octet-stream")
    check("повтор куска → 409 и сколько уже дошло", s == 409 and (jbody(b) or {}).get("received") == chunk, (s, b[:100]))
    s, b, _ = req("GET", "/v1/uploads/%s" % up["id"], t)
    off = (jbody(b) or {}).get("received")
    check("статус: сколько дошло", off == chunk)
    while off < len(data):
        s, b, _ = req("PUT", "/v1/uploads/%s?offset=%d" % (up["id"], off), t, raw=data[off:off + chunk], ctype="application/octet-stream")
        off = (jbody(b) or {}).get("received", len(data))
    s, b, _ = req("POST", "/v1/uploads/%s/finish" % up["id"], t, {})
    mid = (jbody(b) or {}).get("id")
    check("файл собран", s == 201 and mid, (s, b[:200]))
    s, got, _ = req("GET", "/media/%s" % mid)
    check("содержимое байт-в-байт", got == data, len(got or b""))

    # картинка частями проходит ту же проверку по содержимому
    s, b, _ = req("POST", "/v1/uploads", t, {"kind": "image", "mime": "image/png", "size": 300})
    up2 = jbody(b) or {}
    req("PUT", "/v1/uploads/%s?offset=0" % up2["id"], t, raw=b"<html><script>x</script>" + b" " * 276, ctype="application/octet-stream")
    s, b, _ = req("POST", "/v1/uploads/%s/finish" % up2["id"], t, {})
    check("HTML под видом картинки частями — 415", s == 415, (s, b[:200]))
    s, b, _ = req("POST", "/v1/uploads", t, {"kind": "image", "mime": "image/jpeg", "size": len(JPEG), "w": 8, "h": 8})
    up3 = jbody(b) or {}
    req("PUT", "/v1/uploads/%s?offset=0" % up3["id"], t, raw=JPEG, ctype="application/octet-stream")
    s, b, _ = req("POST", "/v1/uploads/%s/finish" % up3["id"], t, {})
    check("настоящая картинка частями", s == 201 and (jbody(b) or {}).get("width") == 8, (s, b[:200]))
    _, other = session("Чужой")
    check("чужую загрузку не видно", req("GET", "/v1/uploads/%s" % up["id"], other)[0] == 404)
    print("FAILS: %d" % fails)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
