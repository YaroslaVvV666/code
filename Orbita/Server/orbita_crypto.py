"""
Криптография Orbita: AES-256-GCM и иерархия ключей.

    мастер-ключ (32 байта, лежит только у оператора сервера)
      ├─ индексный ключ ........ слепые индексы (поиск @username без хранения его открытым)
      └─ ключ пользователя  = HKDF(мастер, "orbita/user/v1/<id>")
            ├─ profile  ...... имя, @username, о себе, телефон
            ├─ posts    ...... тексты публикаций
            ├─ comments ...... комментарии
            └─ media    ...... ключ → отдельный ключ для каждого файла

HKDF — односторонняя функция: по ключу пользователя или категории НЕЛЬЗЯ восстановить
мастер-ключ, ключ другого пользователя или соседнюю категорию. Поэтому можно выдать
ключи одного пользователя (или одной категории), не раскрывая всё остальное.
"""
import base64
import hashlib
import hmac
import json
import os
import struct
import time

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

KDF_SALT = b"orbita-kdf-v1"
SCOPES = ("profile", "posts", "comments", "media", "messages")

# колонки базы (входят в AAD: шифртекст нельзя переставить в другую запись или поле)
COL = {
    "name": "users.name", "username": "users.username", "bio": "users.bio", "phone": "users.phone",
    "last_name": "users.last_name", "birthday": "users.birthday", "session": "sessions.info",
    "privacy": "users.privacy", "track_title": "tracks.title", "track_artist": "tracks.artist",
    "post_text": "posts.text", "post_music": "posts.music", "post_entities": "posts.entities", "comment_text": "comments.text",
    "push_token": "push_tokens.token", "msg_attach": "messages.attachments", "msg_text": "messages.text", "msg_entities": "messages.entities",
    "contact_name": "contacts.name", "style": "users.style", "group_title": "groups.title", "group_about": "groups.about",
}

CHUNK = 64 * 1024          # размер блока шифрования файлов
TAG = 16
MAGIC = b"OMED1"
HEADER = len(MAGIC) + 4    # магическая строка + 4 байта префикса nonce


def hkdf(ikm, info, length=32):
    """HKDF-SHA256 (RFC 5869)"""
    prk = hmac.new(KDF_SALT, ikm, hashlib.sha256).digest()
    okm, block, counter = b"", b"", 1
    while len(okm) < length:
        block = hmac.new(prk, block + info + bytes([counter]), hashlib.sha256).digest()
        okm += block
        counter += 1
    return okm[:length]


# ---------- поля ----------

def field_aad(column, record_id):
    return ("%s|%s" % (column, record_id)).encode("utf-8")


def seal(key, plaintext, aad):
    """формат: 0x01 | nonce(12) | шифртекст+тег"""
    nonce = os.urandom(12)
    return b"\x01" + nonce + AESGCM(key).encrypt(nonce, plaintext, aad)


def unseal(key, blob, aad):
    blob = bytes(blob)
    if len(blob) < 1 + 12 + TAG or blob[0] != 1:
        raise ValueError("неизвестный формат")
    return AESGCM(key).decrypt(blob[1:13], blob[13:], aad)


# ---------- файлы (блоками: работает перемотка видео) ----------

def file_key(media_scope_key, media_id):
    """Для каждого файла свой ключ, выведенный из ключа категории media"""
    return hkdf(media_scope_key, b"file/" + media_id.encode())


def _read_exact(read, n):
    buf = b""
    while len(buf) < n:
        part = read(n - len(buf))
        if not part:
            raise EOFError("тело запроса оборвалось")
        buf += part
    return buf


def _chunk_aad(media_id, index, is_last):
    return media_id.encode() + struct.pack(">QB", index, 1 if is_last else 0)


def encrypt_stream(key, media_id, read, total, write):
    """Читает ровно total байт из read() и пишет зашифрованный файл через write()"""
    aes = AESGCM(key)
    prefix = os.urandom(4)
    write(MAGIC + prefix)
    count = max(1, -(-total // CHUNK))
    for i in range(count):
        data = _read_exact(read, min(CHUNK, total - i * CHUNK))
        write(aes.encrypt(prefix + struct.pack(">Q", i), data, _chunk_aad(media_id, i, i == count - 1)))


def decrypt_range(key, media_id, f, size, start, end):
    """Генератор открытых байт [start..end] из зашифрованного файла f (size — длина открытого файла)"""
    aes = AESGCM(key)
    f.seek(0)
    head = f.read(HEADER)
    if head[:len(MAGIC)] != MAGIC:
        raise ValueError("это не файл Orbita")
    prefix = head[len(MAGIC):]
    count = max(1, -(-size // CHUNK))
    for i in range(start // CHUNK, end // CHUNK + 1):
        plain_len = min(CHUNK, size - i * CHUNK)
        f.seek(HEADER + i * (CHUNK + TAG))
        blob = f.read(plain_len + TAG)
        plain = aes.decrypt(prefix + struct.pack(">Q", i), blob, _chunk_aad(media_id, i, i == count - 1))
        lo = start - i * CHUNK if i == start // CHUNK else 0
        hi = end - i * CHUNK + 1 if i == end // CHUNK else len(plain)
        yield plain[lo:hi]


# ---------- связка ключей ----------

class KeyRing:
    """Хранит мастер-ключ и выводит из него ключи. Мастер-ключ нужен только здесь."""

    def __init__(self, master):
        if len(master) != 32:
            raise ValueError("мастер-ключ должен быть 32 байта")
        self._master = master
        self._index = hkdf(master, b"orbita/index/v1")
        self._cache = {}

    @classmethod
    def load(cls, base_dir):
        """Источник мастер-ключа, по приоритету (от самого защищённого к запасному):
          1. ORBITA_MASTER_KEY_CMD  — команда, печатающая ключ (base64) в stdout. Так ключ берётся из
             внешнего хранилища секретов и НЕ лежит на диске рядом с кодом/данными. Примеры:
               AWS KMS:   ORBITA_MASTER_KEY_CMD='aws kms decrypt --ciphertext-blob fileb:///etc/orbita.key.enc \
                                                  --query Plaintext --output text'
               Vault:     ORBITA_MASTER_KEY_CMD='vault kv get -field=master_key secret/orbita'
               GCP KMS:   ORBITA_MASTER_KEY_CMD='gcloud kms decrypt --ciphertext-file=/etc/orbita.key.enc \
                                                  --plaintext-file=- --key=... | base64'
          2. ORBITA_MASTER_KEY       — сам ключ (base64) в переменной окружения (её подставляет оркестратор).
          3. ORBITA_MASTER_KEY_FILE / keys/master.key — файл на диске (создаётся при первом запуске; для разработки).
        Если задан ORBITA_MASTER_KEY_FINGERPRINT — проверяем, что загруженный ключ именно тот (защита от
        тихой подмены ключа: с чужим ключом данные стали бы «нечитаемыми», а это легко не заметить)."""
        cmd = os.environ.get("ORBITA_MASTER_KEY_CMD")
        if cmd:
            import subprocess
            out = subprocess.run(cmd, shell=True, capture_output=True, timeout=30)
            if out.returncode != 0:
                raise RuntimeError("ORBITA_MASTER_KEY_CMD завершилась с ошибкой %d: %s"
                                   % (out.returncode, out.stderr.decode("utf-8", "replace")[:300]))
            ring = cls(cls._decode_key(out.stdout.decode("utf-8", "replace")))
            return cls._verify(ring)
        env = os.environ.get("ORBITA_MASTER_KEY")
        if env:
            return cls._verify(cls(cls._decode_key(env)))
        path = os.environ.get("ORBITA_MASTER_KEY_FILE") or os.path.join(base_dir, "keys", "master.key")
        if os.path.exists(path):
            with open(path, "r") as f:
                return cls._verify(cls(cls._decode_key(f.read())))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        key = os.urandom(32)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(base64.b64encode(key).decode() + "\n")
        print("СОЗДАН мастер-ключ: %s\n  Сохраните его копию в безопасном месте отдельно от данных. "
              "Без него данные не расшифровать. В проде лучше брать ключ из KMS/Vault "
              "(см. ORBITA_MASTER_KEY_CMD)." % path)
        return cls._verify(cls(key))

    @staticmethod
    def _decode_key(text):
        """Принимаем ключ как base64 (стандартный путь) либо как 64 hex-символа — так удобнее разным KMS."""
        s = (text or "").strip()
        if not s:
            raise ValueError("пустой мастер-ключ")
        try:
            raw = base64.b64decode(s, validate=True)
            if len(raw) == 32:
                return raw
        except Exception:                          # не base64 — пробуем hex ниже
            pass
        try:
            raw = bytes.fromhex(s)
            if len(raw) == 32:
                return raw
        except ValueError:
            pass
        raise ValueError("мастер-ключ должен быть 32 байта (base64 или hex)")

    @classmethod
    def _verify(cls, ring):
        want = os.environ.get("ORBITA_MASTER_KEY_FINGERPRINT", "").strip().lower()
        if want and ring.fingerprint().lower() != want:
            raise RuntimeError("отпечаток мастер-ключа не совпал с ORBITA_MASTER_KEY_FINGERPRINT — "
                               "загружен НЕ тот ключ, запуск остановлен во избежание порчи данных")
        return ring

    def fingerprint(self):
        """Короткий отпечаток для сверки (по нему мастер-ключ не восстановить)"""
        return hkdf(self._master, b"orbita/fingerprint/v1", 8).hex()

    def blind_index(self, value, context):
        mac = hmac.new(self._index, ("%s|%s" % (context, value)).encode("utf-8"), hashlib.sha256)
        return mac.hexdigest()

    def user_key(self, user_id):
        return hkdf(self._master, ("orbita/user/v1/%s" % user_id).encode())

    def scope_key(self, user_id, scope):
        cache_key = (user_id, scope)
        key = self._cache.get(cache_key)
        if key is None:
            if len(self._cache) > 4096:
                self._cache.clear()
            key = hkdf(self.user_key(user_id), ("scope/%s" % scope).encode())
            self._cache[cache_key] = key
        return key

    def bundle(self, user_id, scopes, reason=""):
        """Пакет ключей для выдачи: только производные ключи выбранных категорий одного пользователя"""
        return {
            "format": "orbita-key-bundle/1",
            "user_id": user_id,
            "scopes": {s: base64.b64encode(self.scope_key(user_id, s)).decode() for s in scopes},
            "master_fingerprint": self.fingerprint(),
            "issued_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "reason": reason,
            "note": "Содержит только производные ключи указанного пользователя. "
                    "Мастер-ключ и данные других пользователей из них не восстановить.",
        }
