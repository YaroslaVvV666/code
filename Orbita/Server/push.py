"""
Настоящие push-уведомления iPhone через Apple Push Notification service (APNs).

Нужен платный аккаунт Apple Developer Program и ключ APNs (.p8):
    developer.apple.com → Certificates, Identifiers & Profiles → Keys → «+» → Apple Push Notifications service (APNs)

Переменные окружения сервера:
    ORBITA_APNS_KEY_FILE   путь к AuthKey_XXXXXXXXXX.p8
    ORBITA_APNS_KEY_ID     10 символов Key ID (из имени файла ключа)
    ORBITA_APNS_TEAM_ID    10 символов Team ID (Membership в аккаунте разработчика)
    ORBITA_APNS_TOPIC      Bundle Identifier приложения (как в Xcode)
    ORBITA_PUSH_PREVIEW=0  не показывать текст сообщения в уведомлении (по умолчанию показывается)

Зависимость: httpx[http2] (APNs работает только по HTTP/2).
"""
import base64
import json
import os
import queue
import threading
import time

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

HOSTS = {"production": "https://api.push.apple.com", "sandbox": "https://api.sandbox.push.apple.com"}


def env(name, default=""):
    return os.environ.get(name, default).strip()


def configured():
    return bool(env("ORBITA_APNS_KEY_FILE") and env("ORBITA_APNS_KEY_ID") and env("ORBITA_APNS_TEAM_ID")
                and env("ORBITA_APNS_TOPIC") and os.path.exists(env("ORBITA_APNS_KEY_FILE")))


def _b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


_jwt = {"value": None, "at": 0}
_jwt_lock = threading.Lock()


def provider_token(now=None):
    """JWT провайдера (ES256). Apple разрешает обновлять не чаще раза в 20 минут и не реже раза в час."""
    now = now or time.time()
    with _jwt_lock:
        if _jwt["value"] and now - _jwt["at"] < 40 * 60:
            return _jwt["value"]
        with open(env("ORBITA_APNS_KEY_FILE"), "rb") as f:
            key = serialization.load_pem_private_key(f.read(), password=None)
        header = _b64(json.dumps({"alg": "ES256", "kid": env("ORBITA_APNS_KEY_ID")}).encode())
        claims = _b64(json.dumps({"iss": env("ORBITA_APNS_TEAM_ID"), "iat": int(now)}).encode())
        signing = ("%s.%s" % (header, claims)).encode()
        r, s = decode_dss_signature(key.sign(signing, ec.ECDSA(hashes.SHA256())))
        _jwt["value"] = "%s.%s" % (signing.decode(), _b64(r.to_bytes(32, "big") + s.to_bytes(32, "big")))
        _jwt["at"] = now
        return _jwt["value"]


def build_payload(title, body, badge, thread, data):
    payload = {"aps": {"alert": {"title": title, "body": body}, "sound": "default", "badge": badge,
                       "thread-id": thread}}
    payload.update(data)
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()


# ---------- отправка ----------

_clients = {}
_clients_lock = threading.Lock()


def _client(environment):
    with _clients_lock:
        c = _clients.get(environment)
        if c is None:
            import httpx                                      # ленивый импорт: без push сервер работает и без него
            c = httpx.Client(http2=True, base_url=HOSTS[environment], timeout=10)
            _clients[environment] = c
        return c


def transport(environment, device_token, payload, collapse_id=None):
    """Один запрос к APNs. Возвращает (HTTP-статус, причина). В тестах подменяется."""
    headers = {"authorization": "bearer " + provider_token(), "apns-topic": env("ORBITA_APNS_TOPIC"),
               "apns-push-type": "alert", "apns-priority": "10"}
    if collapse_id:
        headers["apns-collapse-id"] = collapse_id
    r = _client(environment).post("/3/device/" + device_token, content=payload, headers=headers)
    reason = ""
    if r.status_code != 200:
        try:
            reason = r.json().get("reason", "")
        except ValueError:
            pass
    return r.status_code, reason


_queue = queue.Queue(maxsize=2000)
_started = False


def start(on_dead_token):
    """Фоновый поток: отправка не задерживает ответ API. on_dead_token(token) — удалить недействительный токен."""
    global _started
    if _started:
        return
    _started = True

    def worker():
        while True:
            environment, token, payload = _queue.get()
            try:
                status, reason = transport(environment, token, payload)
                if status in (400, 410) and reason in ("BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"):
                    on_dead_token(token)
                elif status != 200:
                    print("APNs: %s %s" % (status, reason))
            except Exception as e:                            # сеть, ключ, отсутствие httpx
                print("APNs: ошибка отправки: %s" % e.__class__.__name__)

    threading.Thread(target=worker, daemon=True, name="apns").start()


def enqueue(environment, device_token, payload):
    try:
        _queue.put_nowait((environment if environment in HOSTS else "production", device_token, payload))
    except queue.Full:
        pass
