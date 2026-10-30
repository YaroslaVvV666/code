"""Сервис моделей для проверки изображений. Запускается отдельно от server.py:

    pip install -r moderation_service/requirements-moderation.txt
    ORBITA_MOD_BACKEND=both python3 moderation_service/service.py        # порт 8090

POST /check   тело — JPEG/PNG, ответ: {"verdict": "ok|review|block", "score": 0..1, "labels": {...}}
GET  /health  {"ok": true, "backend": "..."}

Бэкенды (ORBITA_MOD_BACKEND):
  nudenet    детектор частей тела (быстрый, CPU)
  falconsai  классификатор nsfw/normal (ViT)
  both       сначала NudeNet; Falconsai — только когда NudeNet не уверен (экономит процессор)
  stub       всегда «ok» — для проверки подключения без моделей

Пороги (можно менять переменными): ORBITA_MOD_BLOCK (0.60), ORBITA_MOD_REVIEW (0.35), ORBITA_MOD_FALCON_BLOCK (0.90)
"""
import io
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BACKEND = os.environ.get("ORBITA_MOD_BACKEND", "both")
BLOCK = float(os.environ.get("ORBITA_MOD_BLOCK", "0.60"))
REVIEW = float(os.environ.get("ORBITA_MOD_REVIEW", "0.35"))
FALCON_BLOCK = float(os.environ.get("ORBITA_MOD_FALCON_BLOCK", "0.90"))
PORT = int(os.environ.get("ORBITA_MOD_PORT", "8090"))

# открытые части тела — основание для блокировки; закрытые (COVERED) и лицо/руки/ноги не считаем
EXPOSED = {"FEMALE_BREAST_EXPOSED", "FEMALE_GENITALIA_EXPOSED", "MALE_GENITALIA_EXPOSED", "ANUS_EXPOSED", "BUTTOCKS_EXPOSED"}
SOFT = {"MALE_BREAST_EXPOSED", "BELLY_EXPOSED", "ARMPITS_EXPOSED"}          # только для очереди проверки, если очень уверен

_detector = _falcon = None
_lock = threading.Lock()


def _nudenet(jpeg):
    global _detector
    from nudenet import NudeDetector
    if _detector is None:
        _detector = NudeDetector()
    import tempfile
    with tempfile.NamedTemporaryFile(suffix=".jpg") as f:           # NudeNet читает с диска
        f.write(jpeg)
        f.flush()
        found = _detector.detect(f.name)
    labels = {}
    for d in found:
        labels[d["class"]] = max(labels.get(d["class"], 0), float(d["score"]))
    score = max([s for c, s in labels.items() if c in EXPOSED] or [0.0])
    return score, labels


def _falconsai(jpeg):
    global _falcon
    from PIL import Image
    if _falcon is None:
        from transformers import pipeline
        _falcon = pipeline("image-classification", model="Falconsai/nsfw_image_detection")
    image = Image.open(io.BytesIO(jpeg)).convert("RGB")
    res = _falcon(image)
    return max([float(r["score"]) for r in res if r["label"].lower() == "nsfw"] or [0.0])


def classify(jpeg):
    if BACKEND == "stub":
        return {"verdict": "ok", "score": 0.0, "labels": {}}
    score, labels = 0.0, {}
    if BACKEND in ("nudenet", "both"):
        score, labels = _nudenet(jpeg)
        if BACKEND == "both" and score < REVIEW:
            # NudeNet ничего не нашёл — подстрахуемся второй моделью (она ловит то, что не «части тела»)
            fs = _falconsai(jpeg)
            labels["falconsai_nsfw"] = fs
            if fs >= FALCON_BLOCK:
                return {"verdict": "block", "score": fs, "labels": labels}
            if fs >= 0.6:
                return {"verdict": "review", "score": fs, "labels": labels}
    elif BACKEND == "falconsai":
        fs = _falconsai(jpeg)
        labels["falconsai_nsfw"] = fs
        score = fs
        if fs >= FALCON_BLOCK:
            return {"verdict": "block", "score": fs, "labels": labels}
        return {"verdict": "review" if fs >= 0.6 else "ok", "score": fs, "labels": labels}
    verdict = "block" if score >= BLOCK else ("review" if score >= REVIEW else "ok")
    return {"verdict": verdict, "score": round(score, 3), "labels": {k: round(v, 3) for k, v in labels.items()}}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._send(200, {"ok": True, "backend": BACKEND})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0 or n > 8 * 1024 * 1024:
            return self._send(400, {"error": "bad_size"})
        data = self.rfile.read(n)
        try:
            self._send(200, classify(data))
        except Exception as e:
            print("service error:", e)
            self._send(500, {"error": str(e)})


def warmup():
    """Загружаем модели заранее, иначе первая проверка идёт десятки секунд и сервер её не дожидается"""
    if BACKEND == "stub":
        return
    from PIL import Image
    buf = io.BytesIO()
    Image.new("RGB", (96, 96), (120, 120, 120)).save(buf, "JPEG")
    classify(buf.getvalue())
    if BACKEND == "both":
        _falconsai(buf.getvalue())       # вторая модель тоже грузится сразу, даже если NudeNet ничего не нашёл


if __name__ == "__main__":
    print("Сервис проверки изображений: бэкенд %s, порт %d. Загружаю модели (первый раз — несколько минут)..." % (BACKEND, PORT))
    warmup()
    print("Модели готовы, сервис принимает запросы.")
    ThreadingHTTPServer.request_queue_size = 128
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
