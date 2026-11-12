"""Вход с нового устройства: сообщение от «Orbita» с кнопкой «Это не я», которая завершает тот сеанс."""
import sys

from smoke import jbody, req, session

SERVICE = "0e1b17a0-0000-4000-8000-0000000005e7"


def main():
    fails = 0

    def check(label, cond, extra=""):
        nonlocal fails
        print(("OK   " if cond else "FAIL ") + label + (" " + str(extra) if extra and not cond else ""))
        fails += 0 if cond else 1

    uid, t1 = session("Хозяин")
    s, b, _ = req("GET", "/v1/chats/%s/messages" % SERVICE, t1)
    check("при первом входе уведомления нет", not (jbody(b) or {}).get("messages"), b[:200])
    # второй вход в тот же аккаунт — по QR-коду с «нового устройства»
    s, b, _ = req("POST", "/v1/qr", body={"device": "iPad Pro", "system": "iPadOS 18", "app": "Orbita"})
    qr = jbody(b) or {}
    req("POST", "/v1/qr/%s/approve" % qr["id"], t1, {})
    s, b, _ = req("GET", "/v1/qr/%s?secret=%s" % (qr["id"], qr["secret"]))
    t2 = (jbody(b) or {}).get("token")
    check("вход по QR", bool(t2), b[:200])
    s, b, _ = req("GET", "/v1/chats/%s/messages" % SERVICE, t1)
    msgs = (jbody(b) or {}).get("messages", [])
    check("пришло «Вход с нового устройства»", msgs and "нового устройства" in msgs[-1]["text"] and msgs[-1].get("markup"), msgs[-1:] )
    if msgs:
        data = msgs[-1]["markup"][0][0]["callback_data"]
        s, b, _ = req("POST", "/v1/messages/%s/callback" % msgs[-1]["id"], t1, {"data": data})
        check("«Это не я» → сеанс завершён", s == 200 and "завершён" in (jbody(b) or {}).get("text", ""), b[:200])
        check("второй токен больше не работает", req("GET", "/v1/sessions", t2)[0] == 401)

    # тот же телефон входит снова (обновили приложение) — старый его сеанс заменяется, уведомления нет
    def qr_login(device_id):
        s, b, _ = req("POST", "/v1/qr", body={"device": "iPhone 14 Pro", "system": "iOS 26", "app": "Orbita iOS 1.1",
                                              "device_id": device_id})
        qr = jbody(b) or {}
        req("POST", "/v1/qr/%s/approve" % qr["id"], t1, {})
        s, b, _ = req("GET", "/v1/qr/%s?secret=%s" % (qr["id"], qr["secret"]))
        return (jbody(b) or {}).get("token")

    def alerts():
        s, b, _ = req("GET", "/v1/chats/%s/messages" % SERVICE, t1)
        return len([m for m in (jbody(b) or {}).get("messages", []) if "нового устройства" in m.get("text", "")])

    before = alerts()
    a1 = qr_login("PHONE-A")
    check("новое устройство — уведомление есть", alerts() == before + 1)
    a2 = qr_login("PHONE-A")
    check("тот же телефон после обновления — уведомления нет", alerts() == before + 1)
    check("старый сеанс этого телефона заменён", req("GET", "/v1/sessions", a1)[0] == 401 and req("GET", "/v1/sessions", a2)[0] == 200)
    s, b, _ = req("GET", "/v1/sessions", t1)
    lst = jbody(b) or {}
    check("в списке телефон один раз", sum(1 for x in lst.get("sessions", []) if x["device"] == "iPhone 14 Pro") == 1, b[:300])
    check("срок по умолчанию — 6 месяцев", lst.get("ttl_days") == 180, b[:200])
    check("срок меняется", req("PUT", "/v1/sessions/ttl", t1, {"days": 7})[0] == 200
          and (jbody(req("GET", "/v1/sessions", t1)[1]) or {}).get("ttl_days") == 7)
    check("неверный срок не принимается", req("PUT", "/v1/sessions/ttl", t1, {"days": 5})[0] == 400)
    print("FAILS: %d" % fails)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
