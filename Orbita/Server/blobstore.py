"""Хранилище медиа-файлов (уже зашифрованных). Два бэкенда, одинаковый интерфейс:

  • LocalBlobStore — файлы на диске сервера (по умолчанию). Как было.
  • S3BlobStore    — объектное хранилище, совместимое с S3 (AWS S3, MinIO, Yandex Object Storage и т. п.).
    Нужно при росте: диск одной машины не ограничивает объём, файлы доступны всем воркерам и переживают
    пересоздание контейнера.

Выбор — переменная окружения ORBITA_S3_BUCKET (если задана — S3, иначе диск).

Важно: файлы здесь ХРАНЯТСЯ ЗАШИФРОВАННЫМИ (ключом сервера). Сервер остаётся точкой расшифровки и отдачи, то
есть это приватное хранилище, а не публичная раздача через CDN. Для публичных ассетов CDN можно поставить
отдельно перед /media (ответы уже помечены Cache-Control: immutable).

Интерфейс:
  exists(mid) -> bool
  remove(mid)                 удалить готовый файл
  reader(mid, size)           контекст-менеджер: объект с seek()/read() (для отдачи и перешифровки)
  stage(mid) -> local_path    локальный путь, куда писать зашифрованные байты
  commit(mid)                 зафиксировать записанное в stage(mid)
  discard(mid)                отменить незафиксированную запись
"""

import json
import os


def make_blobstore(media_dir):
    # Несколько хранилищ-пулов (арендовал одно — заполнилось — добавил следующее — потом свой ЦОД):
    # ORBITA_POOLS = JSON-список пулов, новые файлы пишутся в активный, старые читаются из своего.
    pools = os.environ.get("ORBITA_POOLS", "").strip()
    if pools:
        return PooledBlobStore(media_dir, pools)
    if os.environ.get("ORBITA_S3_BUCKET", "").strip():
        return S3BlobStore(media_dir)
    return LocalBlobStore(media_dir)


class LocalBlobStore:
    backend = "local"

    def __init__(self, media_dir):
        self.dir = media_dir
        os.makedirs(media_dir, exist_ok=True)

    def _p(self, mid):
        return os.path.join(self.dir, mid)

    def exists(self, mid):
        return os.path.isfile(self._p(mid))

    def remove(self, mid):
        try:
            os.remove(self._p(mid))
        except FileNotFoundError:
            pass

    def stage(self, mid):
        os.makedirs(self.dir, exist_ok=True)
        return self._p(mid)          # на диске пишем сразу в финальное место

    def commit(self, mid):
        pass                          # уже на месте

    def discard(self, mid):
        self.remove(mid)

    def reader(self, mid, size):
        return open(self._p(mid), "rb")


class S3BlobStore:
    backend = "s3"

    def __init__(self, media_dir, cfg=None):
        import boto3
        cfg = cfg or {}            # cfg — настройки одного пула (для PooledBlobStore); иначе берём из окружения
        self.bucket = (cfg.get("bucket") or os.environ.get("ORBITA_S3_BUCKET", "")).strip()
        self.prefix = cfg.get("prefix") or os.environ.get("ORBITA_S3_PREFIX", "media/")
        kw = {}
        ep = cfg.get("endpoint") or os.environ.get("ORBITA_S3_ENDPOINT")   # для MinIO/совместимых; для AWS не нужен
        if ep:
            kw["endpoint_url"] = ep
        region = cfg.get("region") or os.environ.get("ORBITA_S3_REGION")
        if region:
            kw["region_name"] = region
        # ключи: индивидуальные для пула, иначе AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (стандартно для boto3)
        if cfg.get("access_key"):
            kw["aws_access_key_id"] = cfg["access_key"]
        if cfg.get("secret_key"):
            kw["aws_secret_access_key"] = cfg["secret_key"]
        self.c = boto3.client("s3", **kw)
        self.tmp = cfg.get("tmp") or os.environ.get("ORBITA_S3_TMP") or os.path.join(media_dir, "staging")
        os.makedirs(self.tmp, exist_ok=True)

    def _key(self, mid):
        return self.prefix + mid

    def _staging(self, mid):
        return os.path.join(self.tmp, "stage-" + mid)

    def exists(self, mid):
        try:
            self.c.head_object(Bucket=self.bucket, Key=self._key(mid))
            return True
        except Exception:
            return False

    def remove(self, mid):
        try:
            self.c.delete_object(Bucket=self.bucket, Key=self._key(mid))
        except Exception:
            pass
        try:
            os.remove(self._staging(mid))
        except OSError:
            pass

    def stage(self, mid):
        return self._staging(mid)     # пишем во временный файл, заливаем при commit

    def commit(self, mid):
        path = self._staging(mid)
        with open(path, "rb") as f:
            self.c.upload_fileobj(f, self.bucket, self._key(mid))   # сам разобьёт на части, если большой
        try:
            os.remove(path)
        except OSError:
            pass

    def discard(self, mid):
        try:
            os.remove(self._staging(mid))
        except OSError:
            pass

    def reader(self, mid, size):
        return _S3Reader(self.c, self.bucket, self._key(mid))


def _make_pool(cfg, media_dir):
    if cfg.get("type", "local") == "s3":
        return S3BlobStore(media_dir, cfg)
    return LocalBlobStore(cfg.get("dir") or media_dir)


class PooledBlobStore:
    """Маршрутизатор по нескольким хранилищам. Новые файлы пишутся в активный пул (по умолчанию последний),
    старые читаются из того пула, где лежат — поэтому можно добавлять хранилища по мере заполнения, не трогая
    уже загруженное. Интерфейс тот же (mid), сервер ничего не меняет. Где лежит каждый файл — помнит локатор
    (таблица в основной БД), привязывается через bind_locator() на старте. Неизвестный файл (загружен до
    пулов) читается из первого пула — им делают исходное хранилище, так что миграция не нужна.

    Пример ORBITA_POOLS:
      [{"id":"p0","type":"s3","bucket":"orbita-1","endpoint":"https://storage.yandexcloud.net","region":"ru-central1"},
       {"id":"p1","type":"s3","bucket":"orbita-2","endpoint":"https://storage.yandexcloud.net","region":"ru-central1"},
       {"id":"dc0","type":"local","dir":"/mnt/dc1/media"}]
    Активный пул — последний, либо ORBITA_ACTIVE_POOL=<id>.
    """
    backend = "pooled"

    def __init__(self, media_dir, pools_json):
        cfgs = json.loads(pools_json)
        if not cfgs:
            raise ValueError("ORBITA_POOLS пуст")
        self.pools, self.order = {}, []
        for c in cfgs:
            pid = str(c["id"])
            self.pools[pid] = _make_pool(c, media_dir)
            self.order.append(pid)
        active = os.environ.get("ORBITA_ACTIVE_POOL", "").strip()
        self.active_id = active if active in self.pools else self.order[-1]
        # до bind_locator (на старте, до приёма запросов) — временная память
        mem = {}
        self._get = mem.get
        self._set = lambda mid, pool: mem.__setitem__(mid, pool)
        self._del = lambda mid: mem.pop(mid, None)

    def bind_locator(self, get, set_, delete):
        self._get, self._set, self._del = get, set_, delete

    def _pool_for(self, mid):
        return self.pools.get(self._get(mid)) or self.pools[self.order[0]]

    def exists(self, mid):
        return self._pool_for(mid).exists(mid)

    def reader(self, mid, size):
        return self._pool_for(mid).reader(mid, size)

    def remove(self, mid):
        self._pool_for(mid).remove(mid)
        self._del(mid)

    def stage(self, mid):
        return self.pools[self.active_id].stage(mid)

    def commit(self, mid):
        self.pools[self.active_id].commit(mid)
        self._set(mid, self.active_id)          # запоминаем пул именно после успешной заливки

    def discard(self, mid):
        self.pools[self.active_id].discard(mid)


class _S3Reader:
    """Файлоподобный объект над объектом S3 с seek()/read(). Читает диапазонами (Range), с упреждающим
    окном, чтобы последовательные чтения зашифрованных кусков (decrypt_range) шли одним-двумя запросами,
    а не по запросу на кусок. Поддерживает только то, что нужно decrypt_range: seek(SET/CUR) + read(n)."""

    def __init__(self, client, bucket, key, window=4 * 1024 * 1024):
        self.c, self.b, self.k, self.window = client, bucket, key, window
        self.pos = 0
        self._buf = b""
        self._start = -1

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def seek(self, pos, whence=0):
        if whence == 1:
            self.pos += pos
        elif whence == 2:
            raise ValueError("SEEK_END не поддерживается")
        else:
            self.pos = pos
        return self.pos

    def tell(self):
        return self.pos

    def read(self, n=-1):
        if n is None or n < 0:
            obj = self.c.get_object(Bucket=self.b, Key=self.k, Range="bytes=%d-" % self.pos)
            data = obj["Body"].read()
            self.pos += len(data)
            return data
        if n == 0:
            return b""
        if not (self._start >= 0 and self._start <= self.pos and self.pos + n <= self._start + len(self._buf)):
            start = self.pos
            length = max(n, self.window)
            obj = self.c.get_object(Bucket=self.b, Key=self.k, Range="bytes=%d-%d" % (start, start + length - 1))
            self._buf = obj["Body"].read()
            self._start = start
        off = self.pos - self._start
        chunk = self._buf[off:off + n]
        self.pos += len(chunk)
        return chunk

    def close(self):
        self._buf = b""
