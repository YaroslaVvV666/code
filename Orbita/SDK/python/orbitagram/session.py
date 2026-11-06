"""HTTP-слой без внешних зависимостей: запросы идут в пуле потоков, а код бота остаётся асинхронным.
Если хочется своего транспорта (aiohttp, httpx) — унаследуйтесь от BaseSession и передайте в Bot(session=...)."""
from __future__ import annotations

import asyncio
import json
import mimetypes
import os
import ssl
import threading
import urllib.error
import urllib.request
import uuid
from typing import Any

from .exceptions import NetworkError

USER_AGENT = "orbitagram/1.0 (+python)"


class BaseSession:
    async def post(self, url: str, data: dict[str, Any], files: dict[str, tuple[str, bytes, str]] | None,
                   timeout: float) -> tuple[int, bytes]:
        raise NotImplementedError

    async def get_bytes(self, url: str, timeout: float) -> bytes:
        raise NotImplementedError

    async def close(self) -> None:
        pass


class UrllibSession(BaseSession):
    """Стандартный транспорт: urllib в потоках. Уважает HTTPS_PROXY и системные сертификаты."""

    def __init__(self, verify_ssl: bool = True):
        self._ctx = ssl.create_default_context()
        if not verify_ssl:                       # только для локальной разработки с самоподписанным сертификатом
            self._ctx.check_hostname = False
            self._ctx.verify_mode = ssl.CERT_NONE

    async def post(self, url, data, files, timeout):
        return await _in_thread(self._post_sync, url, data, files, timeout)

    async def get_bytes(self, url, timeout):
        return await _in_thread(self._get_sync, url, timeout)

    # --- синхронная часть (в потоке) ---

    def _open(self, req: urllib.request.Request, timeout: float) -> tuple[int, bytes]:
        try:
            with urllib.request.urlopen(req, timeout=timeout, context=self._ctx) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()
        except (urllib.error.URLError, OSError, TimeoutError) as e:
            raise NetworkError(f"{req.full_url.split('/bot')[0]}: {e}") from e

    def _post_sync(self, url, data, files, timeout):
        if files:
            body, ctype = encode_multipart(data, files)
        else:
            body, ctype = json.dumps(data, ensure_ascii=False).encode(), "application/json"
        req = urllib.request.Request(url, data=body, method="POST",
                                     headers={"Content-Type": ctype, "User-Agent": USER_AGENT})
        return self._open(req, timeout)

    def _get_sync(self, url, timeout):
        status, body = self._open(urllib.request.Request(url, headers={"User-Agent": USER_AGENT}), timeout)
        if status != 200:
            raise NetworkError(f"download failed: HTTP {status}")
        return body


def _in_thread(fn, *args):
    """Запрос в фоновом (daemon) потоке: висящий long-poll не задерживает остановку бота"""
    loop = asyncio.get_running_loop()
    fut = loop.create_future()

    def done(result, error):
        if fut.done():
            return
        if error is not None:
            fut.set_exception(error)
        else:
            fut.set_result(result)

    def work():
        try:
            result, error = fn(*args), None
        except BaseException as e:                     # noqa: BLE001 — передаём в корутину
            result, error = None, e
        try:
            loop.call_soon_threadsafe(done, result, error)
        except RuntimeError:                           # цикл уже закрыт — бот остановлен
            pass

    threading.Thread(target=work, name="orbitagram-http", daemon=True).start()
    return fut


def encode_multipart(fields: dict[str, Any], files: dict[str, tuple[str, bytes, str]]) -> tuple[bytes, str]:
    boundary = "orbitagram-" + uuid.uuid4().hex
    out = bytearray()
    for name, value in fields.items():
        if not isinstance(value, str):
            value = json.dumps(value, ensure_ascii=False)
        out += f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n".encode()
        out += value.encode() + b"\r\n"
    for name, (filename, content, ctype) in files.items():
        safe = os.path.basename(filename).replace('"', "_").replace("\r", "").replace("\n", "") or "file"
        out += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"; filename=\"{safe}\"\r\n"
                f"Content-Type: {ctype}\r\n\r\n").encode()
        out += content + b"\r\n"
    out += f"--{boundary}--\r\n".encode()
    return bytes(out), f"multipart/form-data; boundary={boundary}"


def guess_mime(filename: str, default: str = "application/octet-stream") -> str:
    return mimetypes.guess_type(filename)[0] or default
