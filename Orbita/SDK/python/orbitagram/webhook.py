"""Вебхук: сервер Orbita сам присылает обновления POST-запросом. Нужен публичный https-адрес
(обычно nginx/caddy с сертификатом проксирует на этот процесс).

    dp.run_webhook(bot, url="https://bot.example.com/orbita", path="/orbita", port=8081, secret_token="s3cret")

Есть свой FastAPI/aiohttp/Django? Используйте handle_webhook_request(dp, bot, body, headers, secret_token)."""
from __future__ import annotations

import asyncio
import hmac
import json
import logging
from typing import Mapping

log = logging.getLogger("orbitagram.webhook")
SECRET_HEADER = "X-Orbita-Bot-Api-Secret-Token"
MAX_BODY = 1024 * 1024


async def handle_webhook_request(dp, bot, body: bytes, headers: Mapping[str, str], secret_token: str | None = None,
                                 background: bool = True) -> int:
    """Обработать тело вебхука из любого веб-фреймворка. Возвращает HTTP-код для ответа серверу Orbita"""
    if secret_token:
        got = next((v for k, v in headers.items() if k.lower() == SECRET_HEADER.lower()), "")
        if not hmac.compare_digest(got, secret_token):
            return 401
    try:
        update = json.loads(body or b"{}")
    except ValueError:
        return 400
    if not isinstance(update, dict):
        return 400
    if background:
        # отвечаем серверу сразу, а обработка идёт своим чередом (с порядком внутри чата)
        from .types import Update
        task = asyncio.create_task(dp._process_ordered(bot, Update.from_dict(update, bot)))
        dp._tasks.add(task)
        task.add_done_callback(dp._tasks.discard)
    else:
        await dp.feed_raw_update(bot, update)
    return 200


async def serve_webhook(dp, bot, *, url: str | None = None, host: str = "0.0.0.0", port: int = 8081,
                        path: str = "/webhook", secret_token: str | None = None,
                        drop_pending_updates: bool = False) -> None:
    """Маленький HTTP-сервер без зависимостей. url — публичный https-адрес, который увидит сервер Orbita"""
    me = await bot.get_me()
    if url:
        await bot.set_webhook(url, secret_token=secret_token, drop_pending_updates=drop_pending_updates)
    await dp.startup.fire({**dp.workflow_data, "bot": bot, "dispatcher": dp})

    async def client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        code = 500
        try:
            head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), timeout=15)
            lines = head.decode("latin-1").split("\r\n")
            method, target, _ = (lines[0].split(" ") + ["", "", ""])[:3]
            headers = {}
            for line in lines[1:]:
                if ":" in line:
                    k, v = line.split(":", 1)
                    headers[k.strip()] = v.strip()
            length = int(headers.get("Content-Length") or headers.get("content-length") or 0)
            if method != "POST" or target.split("?")[0] != path:
                code = 404
            elif length > MAX_BODY:
                code = 413
            else:
                body = await asyncio.wait_for(reader.readexactly(length), timeout=15) if length else b""
                code = await handle_webhook_request(dp, bot, body, headers, secret_token)
        except (asyncio.IncompleteReadError, asyncio.TimeoutError, asyncio.LimitOverrunError, ValueError):
            code = 400
        except Exception:                                     # noqa: BLE001
            log.exception("Ошибка вебхука")
        reason = {200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 413: "Too Large"}.get(code, "Error")
        payload = b'{"ok":true}' if code == 200 else b'{"ok":false}'
        writer.write(f"HTTP/1.1 {code} {reason}\r\nContent-Type: application/json\r\nContent-Length: {len(payload)}\r\n"
                     f"Connection: close\r\n\r\n".encode() + payload)
        try:
            await writer.drain()
        finally:
            writer.close()

    server = await asyncio.start_server(client, host, port)
    log.info("Вебхук бота @%s слушает http://%s:%d%s%s", me.username, host, port, path,
             f" (публичный адрес {url})" if url else "")
    try:
        async with server:
            await server.serve_forever()
    finally:
        await dp.shutdown.fire({**dp.workflow_data, "bot": bot, "dispatcher": dp})
        await bot.close()
