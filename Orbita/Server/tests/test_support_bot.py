"""Поддержка: числовой ID у всех, бот @support, владелец назначает волонтёров, ответы доходят до человека."""
import sys

from smoke import jbody, req, session

SUPPORT = "5c0ff0e0-0000-4000-8000-00000005c0ff"


def main():
    fails = 0

    def check(label, cond, extra=""):
        nonlocal fails
        print(("OK   " if cond else "FAIL ") + label + (" " + str(extra) if extra and not cond else ""))
        fails += 0 if cond else 1

    def me(t):
        return jbody(req("GET", "/v1/me", t)[1]) or {}

    def msgs(t):
        return (jbody(req("GET", "/v1/chats/%s/messages" % SUPPORT, t)[1]) or {}).get("messages", [])

    def send(t, text, reply_to=None):
        body = {"text": text}
        if reply_to:
            body["reply_to"] = reply_to
        return req("POST", "/v1/chats/%s/messages" % SUPPORT, t, body)

    owner_id, t_owner = session("Владелец")
    vol_id, t_vol = session("Волонтёр")
    user_id, t_user = session("Пользователь")
    n_owner, n_vol, n_user = me(t_owner).get("num_id"), me(t_vol).get("num_id"), me(t_user).get("num_id")
    check("у всех числовой ID", all(isinstance(x, int) and x > 100000 for x in (n_owner, n_vol, n_user)), (n_owner, n_vol, n_user))
    check("ID разные", len({n_owner, n_vol, n_user}) == 3)

    s, b, _ = req("POST", "/v1/admin/support/owner", None, {"user": str(n_owner)}, headers={"X-Admin-Token": "testadmin"})
    if s != 200:
        s, b, _ = req("POST", "/v1/admin/support/owner", None, {"user": str(n_owner)}, headers={"Authorization": "Bearer testadmin"})
    check("владелец назначен (админ)", s == 200, b[:200])
    check("без токена — нельзя", req("POST", "/v1/admin/support/owner", None, {"user": str(n_user)})[0] in (401, 403))

    # обычный человек не может назначать
    send(t_user, "/add %s" % n_vol)
    send(t_owner, "/add %s" % n_vol)
    check("владелец добавил волонтёра", any("Волонтёр добавлен" in m["text"] for m in msgs(t_owner)))
    check("волонтёру пришло приветствие", any("назначили волонтёром" in m["text"] for m in msgs(t_vol)))

    # пользователь пишет в поддержку — у волонтёра копия с ID
    s, b, _ = send(t_user, "Не приходят уведомления")
    check("сообщение в поддержку отправлено", s == 201, b[:200])
    copies = [m for m in msgs(t_vol) if "Не приходят уведомления" in m["text"]]
    check("волонтёр видит обращение с ID", copies and ("ID %s" % n_user) in copies[-1]["text"], copies[-1:])
    check("у обращения кнопки «Беру/Закрыть»", copies and copies[-1].get("markup"))
    check("пользователь получил подтверждение", any("передано волонтёрам" in m["text"] for m in msgs(t_user)))
    check("пользователь НЕ стал волонтёром (его /add проигнорирован)",
          not any("Волонтёр добавлен" in m["text"] for m in msgs(t_user)))

    # «Беру»
    c = copies[-1]
    data = c["markup"][0][0]["callback_data"]
    s, b, _ = req("POST", "/v1/messages/%s/callback" % c["id"], t_vol, {"data": data})
    check("«Беру» сработало", s == 200 and "за вами" in (jbody(b) or {}).get("text", ""), b[:200])

    # ответ смахиванием
    s, b, _ = send(t_vol, "Проверьте, включены ли уведомления в настройках iPhone", reply_to=c["id"])
    check("ответ волонтёра принят", s == 201, b[:200])
    um = msgs(t_user)
    check("ответ пришёл человеку от поддержки", any("включены ли уведомления" in m["text"] and not m.get("mine") for m in um), um[-2:])

    # /reply по ID и /open, /stats
    send(t_owner, "/reply %s Ещё вопрос остался?" % n_user)
    check("/reply по ID доходит", any("Ещё вопрос остался" in m["text"] for m in msgs(t_user)))
    send(t_owner, "/open")
    check("/open показывает обращение", any("Открытые обращения" in m["text"] and str(n_user) in m["text"] for m in msgs(t_owner)))
    send(t_owner, "/stats")
    check("/stats работает", any("Ответов за сутки" in m["text"] for m in msgs(t_owner)))

    # закрыть
    send(t_vol, "/close %s" % n_user)
    check("закрыто — человек уведомлён", any("Обращение закрыто" in m["text"] for m in msgs(t_user)))
    send(t_owner, "/remove %s" % n_vol)
    check("волонтёр снят", any("больше не волонтёр" in m["text"] for m in msgs(t_vol)))
    print("FAILS: %d" % fails)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
