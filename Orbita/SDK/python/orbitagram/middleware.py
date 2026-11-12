"""Middleware — код вокруг обработчиков: логирование, антиспам, доступ к базе, проверка прав.

    class Throttling(BaseMiddleware):
        async def __call__(self, handler, event, data):
            if too_often(data["event_from_user"].id):
                return                           # обработчик не вызовется
            return await handler(event, data)

    dp.message.middleware(Throttling())          # внутренний: после фильтров, только для подошедших обработчиков
    dp.message.outer_middleware(Throttling())    # внешний: до фильтров, для каждого сообщения
"""
from __future__ import annotations

import time
from typing import Any, Awaitable, Callable

Handler = Callable[[Any, dict], Awaitable[Any]]


class BaseMiddleware:
    async def __call__(self, handler: Handler, event: Any, data: dict[str, Any]) -> Any:
        return await handler(event, data)


class ThrottlingMiddleware(BaseMiddleware):
    """Готовый антиспам: не чаще одного события в `rate` секунд от одного человека.
    Лишние события молча отбрасываются (или вызывается on_throttled(event, data))"""

    def __init__(self, rate: float = 0.5, on_throttled: Callable | None = None):
        self.rate = rate
        self.on_throttled = on_throttled
        self._last: dict[str, float] = {}

    async def __call__(self, handler, event, data):
        user = data.get("event_from_user")
        if user is not None:
            now = time.monotonic()
            last = self._last.get(user.id, 0.0)
            if now - last < self.rate:
                if self.on_throttled:
                    r = self.on_throttled(event, data)
                    if hasattr(r, "__await__"):
                        await r
                return None
            self._last[user.id] = now
            if len(self._last) > 50000:
                self._last.clear()
        return await handler(event, data)
