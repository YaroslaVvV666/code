"""Эфемерное состояние реального времени, общее для всех воркеров: сигналинг звонков, индикатор набора
(«печатает…»), заявки на вход по QR-коду. Это НЕ основная база — тут короткоживущие данные, которые
не нужно хранить на диске, но нужно видеть всем процессам-воркерам сразу.

Два бэкенда, одинаковый интерфейс:
  • MemoryShared — в памяти процесса (по умолчанию, один воркер). Поведение ровно как раньше.
  • RedisShared  — в Redis (если задан REDIS_URL). Тогда, например, звонок соединяет абонентов,
    которых «липкие» сессии развели по разным воркерам.

Выбор — переменная окружения REDIS_URL (redis://host:port/db). При нескольких воркерах (ORBITA_WORKERS>1)
Redis обязателен для звонков/набора/QR между разными пользователями и устройствами.
"""

import json
import os
import threading
import time


def make_shared():
    url = os.environ.get("REDIS_URL", "").strip()
    if url:
        return RedisShared(url)
    return MemoryShared()


# ======================= в памяти (один воркер) =======================

class MemoryShared:
    backend = "memory"

    def __init__(self):
        self._lock = threading.RLock()
        self.calls = {}            # cid -> объект звонка (dict)
        self.user_call = {}        # uid -> cid
        self.signals = {}          # uid -> [сигналы]
        self.typing = {}           # (frm, to) -> (ts, action)
        self.qr = {}               # qid -> запись (dict)
        self.blob = {}             # ключ -> (срок, bytes) — кэш (сессии, ленты)
        self.vers = {}             # ключ -> int — счётчик версий для инвалидации кэша

    # --- кэш: двоичные значения с TTL + счётчики версий ---

    def cache_get(self, key):
        with self._lock:
            e = self.blob.get(key)
            if not e:
                return None
            if e[0] < time.time():
                self.blob.pop(key, None)
                return None
            return e[1]

    def cache_set(self, key, value, ttl):
        with self._lock:
            if len(self.blob) > 20000:
                self.blob.clear()
            self.blob[key] = (time.time() + ttl, value)

    def cache_del(self, key):
        with self._lock:
            self.blob.pop(key, None)

    def ver_get(self, key):
        with self._lock:
            return self.vers.get(key, 0)

    def ver_bump(self, key):
        with self._lock:
            v = self.vers.get(key, 0) + 1
            self.vers[key] = v
            return v

    # --- звонки ---

    def call_put(self, cid, obj, ttl=None):
        with self._lock:
            self.calls[cid] = obj

    def call_get(self, cid):
        with self._lock:
            c = self.calls.get(cid)
            return dict(c) if c else None

    def call_update(self, cid, fields):
        with self._lock:
            c = self.calls.get(cid)
            if c:
                c.update(fields)
                return dict(c)
            return None

    def call_seen(self, cid, uid, ts):
        with self._lock:
            c = self.calls.get(cid)
            if c:
                c["seen"][uid] = ts

    def call_pop(self, cid):
        with self._lock:
            return self.calls.pop(cid, None)

    def call_ids(self):
        with self._lock:
            return list(self.calls.keys())

    def user_call_get(self, uid):
        with self._lock:
            return self.user_call.get(uid)

    def user_call_claim(self, uid, cid, ttl=None):
        """Занять пользователя под звонок, если он свободен. True — заняли."""
        with self._lock:
            if uid in self.user_call:
                return False
            self.user_call[uid] = cid
            return True

    def user_call_set(self, uid, cid, ttl=None):
        with self._lock:
            self.user_call[uid] = cid

    def user_call_clear(self, uid, cid=None):
        with self._lock:
            if cid is None or self.user_call.get(uid) == cid:
                self.user_call.pop(uid, None)

    def signals_push(self, uid, sig, cap=400):
        with self._lock:
            q = self.signals.setdefault(uid, [])
            if len(q) > cap:
                del q[:cap // 2]
            q.append(sig)

    def signals_drain(self, uid):
        with self._lock:
            return self.signals.pop(uid, [])

    # --- индикатор набора ---

    def typing_set(self, frm, to, action, ttl):
        with self._lock:
            if len(self.typing) > 5000:
                self.typing.clear()
            self.typing[(frm, to)] = (time.time(), action)

    def typing_dm(self, frm, to, ttl):
        with self._lock:
            t = self.typing.get((frm, to))
        return t[1] if t and time.time() - t[0] < ttl else None

    def typing_group(self, gid, me_id, ttl):
        now = time.time()
        with self._lock:
            items = list(self.typing.items())
        for (frm, to), (t, action) in items:
            if to == gid and frm != me_id and now - t < ttl:
                return action
        return None

    def typing_clear(self, frm, to):
        with self._lock:
            self.typing.pop((frm, to), None)

    # --- вход по QR: универсальное JSON-хранилище с блокировкой по ключу ---

    def qr_lock(self, qid):
        return self._lock            # в одном процессе общий замок достаточен

    def qr_get(self, qid):
        with self._lock:
            e = self.qr.get(qid)
            return dict(e) if e else None

    def qr_put(self, qid, obj, ttl=None):
        with self._lock:
            self.qr[qid] = obj

    def qr_del(self, qid):
        with self._lock:
            self.qr.pop(qid, None)

    def qr_count_ip(self, ip, window):
        now = time.time()
        with self._lock:
            return sum(1 for e in self.qr.values()
                       if e.get("info", {}).get("ip") == ip and now - e.get("created", 0) < window)

    def qr_total(self):
        with self._lock:
            return len(self.qr)

    def qr_cleanup(self, now):
        with self._lock:
            for k in [k for k, e in self.qr.items() if e.get("expires", 0) + 60 < now]:
                del self.qr[k]


# ======================= Redis (несколько воркеров) =======================

class RedisShared:
    backend = "redis"

    def __init__(self, url):
        import redis
        self.r = redis.Redis.from_url(url, decode_responses=True)
        self.rb = redis.Redis.from_url(url, decode_responses=False)   # для двоичного кэша (pickle/тела ответов)
        self.r.ping()
        self._tls = threading.local()

    # --- кэш: двоичные значения с TTL + счётчики версий ---

    def cache_get(self, key):
        return self.rb.get("c:" + key)

    def cache_set(self, key, value, ttl):
        self.rb.set("c:" + key, value, ex=max(1, int(ttl)))

    def cache_del(self, key):
        self.rb.delete("c:" + key)

    def ver_get(self, key):
        v = self.r.get("ver:" + key)
        return int(v) if v else 0

    def ver_bump(self, key):
        v = self.r.incr("ver:" + key)
        self.r.expire("ver:" + key, 86400)
        return int(v)

    # ключи
    @staticmethod
    def _k_call(cid): return "call:" + cid
    @staticmethod
    def _k_user(uid): return "ucall:" + uid
    @staticmethod
    def _k_sig(uid): return "csig:" + uid
    @staticmethod
    def _k_typing(frm, to): return "typ:%s:%s" % (frm, to)
    @staticmethod
    def _k_tgroup(gid): return "typg:" + gid
    @staticmethod
    def _k_qr(qid): return "qr:" + qid
    @staticmethod
    def _k_qrip(ip): return "qrip:" + ip

    # --- звонки ---
    # звонок хранится как JSON-строка; изменения — под коротким замком по cid (звонков немного, частота низкая)

    def call_put(self, cid, obj, ttl=120):
        self.r.set(self._k_call(cid), json.dumps(obj), ex=ttl)
        self.r.sadd("calls:active", cid)
        self.r.expire("calls:active", 3600)

    def call_get(self, cid):
        raw = self.r.get(self._k_call(cid))
        return json.loads(raw) if raw else None

    def _call_ttl(self):
        return 120

    def call_update(self, cid, fields):
        with self._lock(self._k_call(cid)):
            raw = self.r.get(self._k_call(cid))
            if not raw:
                return None
            c = json.loads(raw)
            c.update(fields)
            self.r.set(self._k_call(cid), json.dumps(c), ex=self._call_ttl())
            return c

    def call_seen(self, cid, uid, ts):
        with self._lock(self._k_call(cid)):
            raw = self.r.get(self._k_call(cid))
            if not raw:
                return
            c = json.loads(raw)
            c.setdefault("seen", {})[uid] = ts
            self.r.set(self._k_call(cid), json.dumps(c), ex=self._call_ttl())

    def call_pop(self, cid):
        with self._lock(self._k_call(cid)):
            raw = self.r.get(self._k_call(cid))
            self.r.delete(self._k_call(cid))
            self.r.srem("calls:active", cid)
            return json.loads(raw) if raw else None

    def call_ids(self):
        return list(self.r.smembers("calls:active"))

    def user_call_get(self, uid):
        return self.r.get(self._k_user(uid))

    def user_call_claim(self, uid, cid, ttl=120):
        return bool(self.r.set(self._k_user(uid), cid, nx=True, ex=ttl))

    def user_call_set(self, uid, cid, ttl=120):
        self.r.set(self._k_user(uid), cid, ex=ttl)

    def user_call_clear(self, uid, cid=None):
        if cid is None:
            self.r.delete(self._k_user(uid))
        else:
            # удалить только если значение всё ещё наше (без гонки) — через Lua
            self.r.eval("if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) end",
                        1, self._k_user(uid), cid)

    def signals_push(self, uid, sig, cap=400):
        key = self._k_sig(uid)
        p = self.r.pipeline()
        p.rpush(key, json.dumps(sig))
        p.ltrim(key, -cap, -1)
        p.expire(key, 120)
        p.execute()

    def signals_drain(self, uid):
        key = self._k_sig(uid)
        # LPOP с count атомарно забирает и удаляет пачку (Redis 6.2+)
        items = self.r.lpop(key, 1000) or []
        if isinstance(items, str):
            items = [items]
        return [json.loads(x) for x in items]

    # --- индикатор набора: ключ сам протухает через ttl, ручная чистка не нужна ---

    def typing_set(self, frm, to, action, ttl):
        self.r.set(self._k_typing(frm, to), action, ex=ttl)
        # индекс печатающих в группе/чате: отсортированное множество по времени
        now = time.time()
        gkey = self._k_tgroup(to)
        p = self.r.pipeline()
        p.zadd(gkey, {frm: now})
        p.zremrangebyscore(gkey, 0, now - ttl)
        p.expire(gkey, ttl + 2)
        p.execute()

    def typing_dm(self, frm, to, ttl):
        return self.r.get(self._k_typing(frm, to))

    def typing_group(self, gid, me_id, ttl):
        now = time.time()
        members = self.r.zrevrangebyscore(self._k_tgroup(gid), now, now - ttl)
        for frm in members:
            if frm != me_id:
                action = self.r.get(self._k_typing(frm, gid))
                if action:
                    return action
        return None

    def typing_clear(self, frm, to):
        self.r.delete(self._k_typing(frm, to))
        self.r.zrem(self._k_tgroup(to), frm)

    # --- вход по QR ---

    def qr_lock(self, qid):
        return self._lock("qrlock:" + qid)

    def qr_get(self, qid):
        raw = self.r.get(self._k_qr(qid))
        return json.loads(raw) if raw else None

    def qr_put(self, qid, obj, ttl=600):
        ex = ttl
        exp = obj.get("expires")
        if exp:
            ex = max(5, int(exp + 120 - time.time()))
        self.r.set(self._k_qr(qid), json.dumps(obj), ex=ex)

    def qr_del(self, qid):
        self.r.delete(self._k_qr(qid))

    def qr_count_ip(self, ip, window):
        # счётчик заявок с одного IP: инкремент с TTL=window, читаем текущее значение
        key = self._k_qrip(ip)
        n = self.r.incr(key)
        if n == 1:
            self.r.expire(key, int(window))
        return n - 1    # не считаем текущую (её ещё не создали) — как в прежней логике sum(...)

    def qr_total(self):
        return 0        # в Redis нет лимита 2000 из памяти — ограничение не нужно

    def qr_cleanup(self, now):
        pass            # ключи протухают по TTL сами

    # --- короткий распределённый замок по ключу ---

    class _KeyLock:
        def __init__(self, r, key, ttl=5):
            self.r, self.key, self.ttl = r, "lock:" + key, ttl
            self.token = None

        def __enter__(self):
            import secrets
            self.token = secrets.token_hex(8)
            deadline = time.time() + 5
            while time.time() < deadline:
                if self.r.set(self.key, self.token, nx=True, ex=self.ttl):
                    return self
                time.sleep(0.01)
            return self            # не смогли за 5с — продолжаем без замка, чтобы не зависнуть

        def __exit__(self, *a):
            # освобождаем только свой замок
            self.r.eval("if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) end",
                        1, self.key, self.token or "")
            return False

    def _lock(self, key):
        return self._KeyLock(self.r, key)
