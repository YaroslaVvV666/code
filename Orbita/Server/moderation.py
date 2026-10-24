"""Проверка загружаемых фото и видео нейросетью (обнажёнка и т.п.).

Сервер достаёт из файла несколько кадров через ffmpeg и отправляет их в отдельный сервис моделей
(moderation_service/service.py). Тяжёлые модели живут там, поэтому сам server.py остаётся на стандартной библиотеке.

Настройка (переменные окружения):
  ORBITA_MOD_URL            адрес сервиса моделей, например http://127.0.0.1:8090 (пусто — проверка выключена)
  ORBITA_MOD_FAIL_CLOSED    1 — если сервис недоступен, загрузки отклоняются (по умолчанию пропускаем и пишем в лог)
  ORBITA_MOD_CONCURRENCY    сколько проверок одновременно (по умолчанию 4)
  ORBITA_MOD_FRAMES         сколько кадров брать из видео (по умолчанию 5)
"""
import json
import os
import subprocess
import threading
import urllib.request

MOD_URL = os.environ.get("ORBITA_MOD_URL", "").rstrip("/")
FAIL_CLOSED = os.environ.get("ORBITA_MOD_FAIL_CLOSED", "0") == "1"
TIMEOUT = float(os.environ.get("ORBITA_MOD_TIMEOUT", "30"))
CONCURRENCY = max(1, int(os.environ.get("ORBITA_MOD_CONCURRENCY", "4")))
VIDEO_FRAMES = max(1, min(12, int(os.environ.get("ORBITA_MOD_FRAMES", "5"))))
_slots = threading.BoundedSemaphore(CONCURRENCY)

RANK = {"ok": 0, "review": 1, "block": 2}


def enabled():
    return bool(MOD_URL)


def _probe_duration(path):
    try:
        out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
                             capture_output=True, timeout=10).stdout.decode().strip()
        return float(out)
    except Exception:
        return 0.0


def _frame(path, at=None):
    """Один кадр как JPEG (ширина до 384 px — для моделей этого достаточно)"""
    cmd = ["ffmpeg", "-v", "error"]
    if at is not None:
        cmd += ["-ss", "%.2f" % at]
    cmd += ["-i", path, "-frames:v", "1", "-vf", "scale='min(384,iw)':-2", "-q:v", "5", "-f", "image2", "-c:v", "mjpeg", "pipe:1"]
    data = subprocess.run(cmd, capture_output=True, timeout=20).stdout
    return data or None


def frames_of(path, kind, duration=0.0):
    if kind == "image":
        f = _frame(path)
        return [f] if f else []
    dur = duration if duration > 0 else _probe_duration(path)
    if dur <= 0.5:
        marks = [0.0]
    else:
        n = VIDEO_FRAMES
        marks = [dur * (0.04 + 0.92 * i / max(1, n - 1)) for i in range(n)] if n > 1 else [dur / 2]
    out = []
    for t in marks:
        f = _frame(path, t)
        if f:
            out.append(f)
    return out


def _ask(jpeg):
    req = urllib.request.Request(MOD_URL + "/check", data=jpeg, method="POST", headers={"Content-Type": "image/jpeg"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.loads(r.read().decode())


def check(path, kind, duration=0.0):
    """Возвращает (вердикт, подробности). Вердикт: ok | review | block | error"""
    if not enabled() or kind not in ("image", "video"):
        return "ok", {}
    with _slots:                                    # не больше CONCURRENCY проверок разом — процессор не захлёбывается
        try:
            shots = frames_of(path, kind, duration)
            if not shots:
                return ("error", {"why": "no_frames"}) if FAIL_CLOSED else ("ok", {"why": "no_frames"})
            worst, detail = "ok", {}
            for jpeg in shots:
                r = _ask(jpeg)
                v = r.get("verdict", "ok")
                if RANK.get(v, 0) > RANK[worst]:
                    worst, detail = v, r
                if worst == "block":
                    break                           # дальше смотреть незачем
            print("moderation: %s, кадров %d, оценка %s" % (worst, len(shots), detail.get("score", "-")))
            return worst, detail
        except Exception as e:
            print("moderation: ошибка проверки:", e)
            return ("error", {"why": str(e)}) if FAIL_CLOSED else ("ok", {"why": "unavailable"})


# ---- Поисковые запросы: недопустимые не ищем (порно, насилие над детьми, жестокость, наркотики и т.п.) ----
# Простой список основ слов; расширяется переменной ORBITA_QUERY_BLOCK="слово1,слово2"
import re as _re

_BAD_STEMS = (
    "порно", "porn", "xxx", "хxх", "секс видео", "sex video", "sexvideo", "голая", "голые", "голый", "обнажённ", "обнажен",
    "nude", "naked", "nsfw", "hentai", "хентай", "эротик", "erotic", "минет", "blowjob", " анал ", "анальн", "сиськ", "титьк", "хуй", "хуи", "пизд",
    "детское порно", "детское пор", " cp ", "pedo", "педофил", "child porn", "lolicon", " лоли ",
    "изнасилов", " rape ", "расчленен", "гор видео", " gore ", "убийство видео", "казнь видео", "execution video",
    "самоубийств как", "как покончить", "how to kill myself", "как убить", "купить наркот", "mdma", "мефедрон", "кокаин купить",
    "как сделать бомбу", "how to make a bomb", "изготовить взрывчат",
)
_EXTRA = [w.strip().lower() for w in os.environ.get("ORBITA_QUERY_BLOCK", "").split(",") if w.strip()]


def query_blocked(text):
    """True, если поисковый запрос недопустим"""
    t = " " + _re.sub(r"\s+", " ", (text or "").lower().replace("ё", "е")) + " "
    flat = _re.sub(r"[\s\W_]+", "", t)
    for stem in _BAD_STEMS + tuple(_EXTRA):
        s = stem.replace("ё", "е")
        if s.endswith(" ") or s.startswith(" "):
            if s in t:
                return True
        elif s in t or (len(s) > 4 and _re.sub(r"[\s\W_]+", "", s) in flat):
            return True
    return False
