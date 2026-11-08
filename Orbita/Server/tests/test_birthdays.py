"""Дни рождения контактов: GET /v1/me/birthdays?today=MM-DD"""
import sys

from smoke import jbody, req, session


def main():
    fails = 0

    def check(label, cond, extra=""):
        nonlocal fails
        print(("OK   " if cond else "FAIL ") + label + (" " + str(extra) if extra and not cond else ""))
        fails += 0 if cond else 1

    a, ta = session("Именинник")
    b, tb = session("Друг")
    s, body, _ = req("PUT", "/v1/me", ta, {"birthday": "2000-11-08", "privacy": {"birthday": "all"}})
    check("дата сохранена", s < 400, body[:150])
    get = lambda day: (jbody(req("GET", "/v1/me/birthdays?today=" + day, tb)[1]) or {}).get("birthdays", [])
    check("не в контактах — не видно", get("11-08") == [])
    req("PUT", "/v1/contacts/%s" % a, tb, {"name": "Именинник"})
    got = get("11-08")
    check("в контактах и сегодня — видно", len(got) == 1 and got[0]["id"] == a and got[0].get("age"), got)
    check("в другой день — нет", get("11-09") == [])
    print("FAILS: %d" % fails)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
