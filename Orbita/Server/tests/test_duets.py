"""Дуэты: шортс, снятый рядом с чужим, и запрет автора."""
import io
import sys

from smoke import jbody, req, session


def main():
    fails = 0

    def check(label, cond, extra=""):
        nonlocal fails
        print(("OK   " if cond else "FAIL ") + label + (" " + str(extra) if extra and not cond else ""))
        fails += 0 if cond else 1

    a, ta = session("Автор")
    b, tb = session("Дуэтист")

    import os
    import subprocess
    import tempfile
    path = os.path.join(tempfile.gettempdir(), "orbita_duet_test.mp4")
    if not os.path.exists(path):
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=red:s=360x640:d=2",
                        "-pix_fmt", "yuv420p", path], check=True)
    clip = open(path, "rb").read()

    def video(token):
        s, body, _ = req("POST", "/v1/media?kind=video&w=360&h=640&dur=2", token, raw=clip, ctype="video/mp4")
        return (jbody(body) or {}).get("id")

    s, body, _ = req("POST", "/v1/posts", ta, {"text": "Оригинал", "media": [{"id": video(ta)}], "reel": True})
    orig = jbody(body) or {}
    check("оригинал опубликован", s == 201, body[:200])
    s, body, _ = req("POST", "/v1/posts", tb, {"text": "Мой дуэт", "media": [{"id": video(tb)}], "reel": True, "duet_of": orig.get("id")})
    duet = jbody(body) or {}
    check("дуэт опубликован со ссылкой", s == 201 and duet.get("duet", {}).get("id") == orig.get("id")
          and duet["duet"]["author"]["name"] == "Автор", body[:300])
    s, body, _ = req("POST", "/v1/posts", ta, {"text": "Без дуэтов", "media": [{"id": video(ta)}], "reel": True, "no_repost": True})
    closed = jbody(body) or {}
    s, body, _ = req("POST", "/v1/posts", tb, {"text": "x", "media": [{"id": video(tb)}], "reel": True, "duet_of": closed.get("id")})
    check("автор запретил — дуэт нельзя", s == 400, (s, body[:120]))
    # вкладка «Подписки»: шортсы только тех, на кого подписан
    c, tc = session("Зритель")
    rs = lambda: [r["id"] for r in (jbody(req("GET", "/v1/reels?feed=following", tc)[1]) or {}).get("reels", [])]
    check("без подписок — пусто", rs() == [])
    req("POST", "/v1/follow/%s" % a, tc)
    got = rs()
    check("подписался — видны шортсы автора", orig.get("id") in got and all(x != "" for x in got))
    check("чужие (не подписан) не видны", not any(r["author"]["id"] == b for r in (jbody(req("GET", "/v1/reels?feed=following", tc)[1]) or {}).get("reels", [])))
    print("FAILS: %d" % fails)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
