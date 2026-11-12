"""Обсуждение канала: пост приходит в чат обсуждения от лица канала (с фото и статьёй), закрепляется;
комментарии под постом — ответы на него в чате; счётчик «N комментариев» под постом"""
import base64
import sys
import uuid
from smoke import jbody, req, session

JPEG = base64.b64decode("/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAAIAAgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDlqKKK+NP1M//Z")
fails = 0
def check(label, cond, extra=""):
    global fails
    print(("OK   " if cond else "FAIL ") + label + ("" if cond else " " + str(extra))); fails += 0 if cond else 1

owner, to = session("Админ")
fan, tf = session("Подписчик")
ch = jbody(req("POST", "/v1/groups", to, {"title": "МЕМАЧ", "type": "channel", "kind": "open", "handle": "memach_" + uuid.uuid4().hex[:8]})[1])["id"]
dg = jbody(req("POST", "/v1/groups", to, {"title": "МЕМАЧ чат", "type": "group", "kind": "open", "handle": "memachat_" + uuid.uuid4().hex[:8]})[1])["id"]
old_post = jbody(req("POST", "/v1/chats/%s/messages" % ch, to, {"text": "старый пост до обсуждения"})[1]) or {}
check("обсуждение привязано", req("PUT", "/v1/groups/%s" % ch, to, {"discussion": dg})[0] == 200)
req("POST", "/v1/groups/%s/join" % ch, tf)
req("POST", "/v1/groups/%s/join" % dg, tf)
mid = jbody(req("POST", "/v1/media?kind=image&w=8&h=8", to, raw=JPEG, ctype="image/jpeg")[1])["id"]
s, b, _ = req("POST", "/v1/chats/%s/messages" % ch, to, {"text": "pov: выходной", "attachments": [{"type": "photo", "media_id": mid}],
                                                       "buttons": [{"text": "Сайт", "url": "https://example.com"}]})
post = jbody(b) or {}
check("пост в канале", s == 201, b[:200])
d = jbody(req("GET", "/v1/chats/%s/messages" % dg, tf)[1]) or {}
mirror = next((m for m in d.get("messages", []) if m.get("from_channel")), {})
check("пост пришёл в чат обсуждения", mirror.get("text") == "pov: выходной", d.get("messages", [])[-1:])
check("от лица канала", (mirror.get("sender") or {}).get("name") == "МЕМАЧ" and mirror["from_channel"]["id"] == ch, mirror.get("sender"))
check("с фото и кнопкой", any(a.get("type") == "photo" for a in mirror.get("attachments", [])) and mirror.get("markup"), mirror)
pinned = [p.get("id") for p in (d.get("pinned") or [])]
check("закреплён в чате", mirror.get("id") in pinned, d.get("pinned"))
s, b, _ = req("POST", "/v1/groups/%s/comments/%s" % (ch, post["id"]), tf, {"text": "И ещё столько же посуды"})
check("комментарий", s == 201, b[:200])
d = jbody(req("GET", "/v1/chats/%s/messages" % dg, to)[1]) or {}
last = d.get("messages", [])[-1]
check("комментарий в чате — ответ на пост", (last.get("reply") or {}).get("id") == mirror.get("id"), last.get("reply"))
cm = jbody(req("GET", "/v1/chats/%s/messages" % ch, tf)[1]) or {}
p = next((m for m in cm.get("messages", []) if m["id"] == post["id"]), {})
check("под постом «1 комментарий»", p.get("comments") == 1, {k: p.get(k) for k in ("comments", "commenters")})
# правка поста — копия в обсуждении тоже меняется; удаление — копия пропадает
req("PUT", "/v1/messages/%s" % post["id"], to, {"text": "pov: выходной (исправлено)"})
d = jbody(req("GET", "/v1/chats/%s/messages" % dg, tf)[1]) or {}
mm = next((m for m in d.get("messages", []) if m.get("from_channel")), {})
check("правка поста дошла до обсуждения", mm.get("text") == "pov: выходной (исправлено)", mm.get("text"))
req("DELETE", "/v1/messages/%s?all=1" % post["id"], to)
d = jbody(req("GET", "/v1/chats/%s/messages" % dg, tf)[1]) or {}
check("удалили пост — копии в обсуждении нет", not any(m.get("from_channel") for m in d.get("messages", [])) and not d.get("pinned"),
      [m.get("text") for m in d.get("messages", [])])
# старый пост (до привязки обсуждения): кнопка под ним есть, и комментарии открываются
cm = jbody(req("GET", "/v1/chats/%s/messages" % ch, tf)[1]) or {}
op = next((m for m in cm.get("messages", []) if m["id"] == old_post.get("id")), {})
check("под старым постом — «Прокомментировать»", op.get("comments") == 0, op.get("comments"))
s, b, _ = req("GET", "/v1/groups/%s/comments/%s" % (ch, old_post.get("id")), tf)
check("комментарии старого поста открываются", s == 200, b[:200])
check("комментарий к старому посту", req("POST", "/v1/groups/%s/comments/%s" % (ch, old_post.get("id")), tf, {"text": "и сюда можно"})[0] == 201)
print("FAILS: %d" % fails)
sys.exit(1 if fails else 0)
