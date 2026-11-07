"""Ошибки Bot API. Ловить можно по типу: `except Forbidden:` — человек заблокировал бота и т.п."""
from __future__ import annotations


class OrbitagramError(Exception):
    """Базовая ошибка библиотеки"""


class NetworkError(OrbitagramError):
    """Сервер недоступен: нет сети, таймаут, обрыв соединения"""


class OrbitaAPIError(OrbitagramError):
    """Сервер ответил ошибкой. `code` — HTTP-код, `description` — текст от сервера"""

    def __init__(self, method: str, code: int, description: str, payload: dict | None = None):
        self.method = method
        self.code = code
        self.description = description
        self.payload = payload or {}
        super().__init__(f"{method}: [{code}] {description}")


class BadRequest(OrbitaAPIError):
    """400 — неверные параметры (пустой текст, не тот file_id, слишком длинная callback_data…)"""


class Unauthorized(OrbitaAPIError):
    """401 — неверный токен (его отозвали в BotGod через /revoke?)"""


class Forbidden(OrbitaAPIError):
    """403 — писать нельзя: человек не нажимал «Старт» или заблокировал бота"""


class NotFound(OrbitaAPIError):
    """404 — нет такого метода или объекта"""


class Conflict(OrbitaAPIError):
    """409 — конфликт (например, getUpdates при включённом вебхуке)"""


class RetryAfter(OrbitaAPIError):
    """429 — слишком часто. Подождите `retry_after` секунд"""

    def __init__(self, method: str, code: int, description: str, payload: dict | None = None):
        super().__init__(method, code, description, payload)
        params = (payload or {}).get("parameters") or {}
        self.retry_after = int(params.get("retry_after") or (payload or {}).get("retry_after") or 1)


class ServerError(OrbitaAPIError):
    """5xx — временная ошибка сервера, стоит повторить позже"""


class SkipHandler(Exception):
    """Бросьте внутри обработчика, чтобы событие пошло к следующему подходящему обработчику"""


class CancelHandler(Exception):
    """Бросьте в middleware, чтобы событие дальше не обрабатывалось вообще"""


def error_for(method: str, code: int, description: str, payload: dict | None = None) -> OrbitaAPIError:
    cls = {400: BadRequest, 401: Unauthorized, 403: Forbidden, 404: NotFound, 409: Conflict, 429: RetryAfter}.get(code)
    if cls is None:
        cls = ServerError if code >= 500 else OrbitaAPIError
    return cls(method, code, description, payload)
