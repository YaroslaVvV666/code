"""Router и Dispatcher — регистрация обработчиков и запуск бота.

    dp = Dispatcher()

    @dp.message(CommandStart())
    async def start(message: Message):
        await message.answer("Привет!")

    dp.run_polling(bot)
"""
from __future__ import annotations

import asyncio
import functools
import inspect
import logging
import signal
import time
from typing import Any, Callable

from .exceptions import (CancelHandler, Conflict, NetworkError, OrbitaAPIError, ServerError, SkipHandler,
                         Unauthorized)
from .filters import check
from .fsm import BaseStorage, FSMContext, MemoryStorage, StorageKey
from .types import CallbackQuery, ErrorEvent, Update

log = logging.getLogger("orbitagram")
UNHANDLED = type("Unhandled", (), {"__repr__": lambda self: "UNHANDLED", "__bool__": lambda self: False})()
EVENT_TYPES = ("message", "edited_message", "callback_query")


class HandlerObject:
    """Обработчик: функция + фильтры. В функцию попадают только те аргументы, которые она объявила"""

    def __init__(self, callback: Callable, filters: tuple, flags: dict):
        self.callback = callback
        self.filters = filters
        self.flags = flags
        sig = inspect.signature(callback)
        params = list(sig.parameters.values())
        self.var_kw = any(p.kind == p.VAR_KEYWORD for p in params)
        positional = [p for p in params if p.kind in (p.POSITIONAL_ONLY, p.POSITIONAL_OR_KEYWORD)]
        self.event_param = positional[0].name if positional else None
        self.names = {p.name for p in params if p.kind in (p.POSITIONAL_OR_KEYWORD, p.KEYWORD_ONLY)}
        self.awaitable = inspect.iscoroutinefunction(callback)

    async def check(self, event, data: dict) -> tuple[bool, dict]:
        extra: dict = {}
        for f in self.filters:
            r = await check(f, event, {**data, **extra})
            if not r:
                return False, {}
            if isinstance(r, dict):
                extra.update(r)
        return True, extra

    async def call(self, event, data: dict):
        if self.var_kw:
            kwargs = dict(data)
        else:
            kwargs = {k: v for k, v in data.items() if k in self.names}
        kwargs.pop(self.event_param, None)
        args = (event,) if self.event_param else ()
        result = self.callback(*args, **kwargs)
        if inspect.isawaitable(result):
            result = await result
        return result

    def __repr__(self):
        return f"<handler {getattr(self.callback, '__qualname__', self.callback)}>"


def _chain(middlewares: list, handler: Callable) -> Callable:
    for m in reversed(middlewares):
        handler = functools.partial(m, handler)
    return handler


class EventObserver:
    """dp.message / router.callback_query / dp.errors — сюда вешаются обработчики и middleware"""

    def __init__(self, router: "Router", name: str):
        self.router = router
        self.name = name
        self.handlers: list[HandlerObject] = []
        self.common_filters: list = []
        self.inner: list = []
        self.outer: list = []

    def register(self, callback: Callable, *filters, flags: dict | None = None, **kw) -> Callable:
        self.handlers.append(HandlerObject(callback, tuple(filters), {**(flags or {}), **kw}))
        return callback

    def __call__(self, *filters, flags: dict | None = None, **kw):
        """Декоратор: @dp.message(Command("start"))"""
        def deco(callback):
            return self.register(callback, *filters, flags=flags, **kw)
        return deco

    def filter(self, *filters) -> None:
        """Фильтры для всех обработчиков этого события в этом роутере (например, только для админов)"""
        self.common_filters.extend(filters)

    def middleware(self, m=None):
        """Внутренний middleware (после фильтров). Можно как декоратор над async def (handler, event, data)"""
        if m is None:
            return lambda f: self.middleware(f)
        self.inner.append(m)
        return m

    def outer_middleware(self, m=None):
        """Внешний middleware (до фильтров) — видит каждое событие"""
        if m is None:
            return lambda f: self.outer_middleware(f)
        self.outer.append(m)
        return m

    async def trigger(self, event, data: dict):
        for f in self.common_filters:
            r = await check(f, event, data)
            if not r:
                return UNHANDLED
            if isinstance(r, dict):
                data = {**data, **r}
        for h in self.handlers:
            ok, extra = await h.check(event, data)
            if not ok:
                continue
            payload = {**data, **extra, "handler": h}
            try:
                return await _chain(self.inner, h.call)(event, payload)
            except SkipHandler:
                continue
            except CancelHandler:
                return None
        return UNHANDLED


class Router:
    def __init__(self, *, name: str | None = None):
        self.name = name or hex(id(self))
        self.parent: Router | None = None
        self.sub_routers: list[Router] = []
        self.message = EventObserver(self, "message")
        self.edited_message = EventObserver(self, "edited_message")
        self.callback_query = EventObserver(self, "callback_query")
        self.errors = EventObserver(self, "errors")
        self.observers = {"message": self.message, "edited_message": self.edited_message,
                          "callback_query": self.callback_query, "errors": self.errors}

    def __repr__(self):
        return f"<Router {self.name}>"

    def include_router(self, router: "Router") -> "Router":
        if router.parent is not None:
            raise RuntimeError(f"{router!r} уже подключён к {router.parent!r}")
        node = self
        while node is not None:
            if node is router:
                raise RuntimeError("Циклическое подключение роутеров")
            node = node.parent
        router.parent = self
        self.sub_routers.append(router)
        return router

    def include_routers(self, *routers: "Router") -> None:
        for r in routers:
            self.include_router(r)

    async def propagate_event(self, event_type: str, event, data: dict):
        observer = self.observers[event_type]

        async def inside(ev, d):
            r = await observer.trigger(ev, d)
            if r is UNHANDLED:
                for child in self.sub_routers:
                    r = await child.propagate_event(event_type, ev, d)
                    if r is not UNHANDLED:
                        break
            return r

        try:
            return await _chain(observer.outer, inside)(event, data)
        except CancelHandler:
            return None


class _Hooks:
    """dp.startup / dp.shutdown: функции при запуске и остановке бота"""

    def __init__(self):
        self.callbacks: list[Callable] = []

    def register(self, callback: Callable) -> Callable:
        self.callbacks.append(callback)
        return callback

    def __call__(self, callback: Callable | None = None):
        if callback is None:
            return self.register
        return self.register(callback)

    async def fire(self, data: dict) -> None:
        # аргументы по именам, как в обработчиках: async def on_startup(bot: Bot, dispatcher: Dispatcher)
        for cb in self.callbacks:
            h = HandlerObject(cb, (), {})
            await h.call(data.get(h.event_param) if h.event_param else None, data)


class Dispatcher(Router):
    """Корневой роутер: получает обновления (polling или вебхук), ведёт состояния, ловит ошибки"""

    def __init__(self, *, storage: BaseStorage | None = None, name: str | None = None,
                 auto_answer_callbacks: bool = True, **workflow_data):
        super().__init__(name=name or "dispatcher")
        self.storage = storage or MemoryStorage()
        self.auto_answer_callbacks = auto_answer_callbacks
        self.workflow_data: dict[str, Any] = dict(workflow_data)
        self.startup = _Hooks()
        self.shutdown = _Hooks()
        self._stop: asyncio.Event | None = None
        self._chat_locks: dict[str, list] = {}
        self._tasks: set[asyncio.Task] = set()

    # dp["db"] = db → аргумент db в обработчиках
    def __getitem__(self, key):
        return self.workflow_data[key]

    def __setitem__(self, key, value):
        self.workflow_data[key] = value

    def fsm_context(self, bot, chat_id: str, user_id: str) -> FSMContext:
        """Состояние любого человека (например, сбросить его диалог из админки)"""
        return FSMContext(self.storage, StorageKey(bot.id, chat_id, user_id))

    # ---------------------------------------------------------------- обработка одного обновления

    async def feed_update(self, bot, update: Update, **kwargs):
        event_type = update.event_type
        if event_type not in EVENT_TYPES:
            log.debug("Пропущено обновление %s неизвестного типа", update.update_id)
            return UNHANDLED
        event = update.event
        user = getattr(event, "from_user", None)
        chat = getattr(event, "chat", None) or getattr(getattr(event, "message", None), "chat", None)
        data: dict[str, Any] = {**self.workflow_data, **kwargs, "bot": bot, "dispatcher": self,
                                "event_update": update, "event_from_user": user, "event_chat": chat}
        if user is not None:
            state = FSMContext(self.storage, StorageKey(bot.id, chat.id if chat else user.id, user.id))
            data["state"] = state
            data["raw_state"] = await state.get_state()
        started = time.monotonic()
        try:
            result = await self.propagate_event(event_type, event, data)
        except Exception as e:                                   # noqa: BLE001 — ошибки идут в dp.errors
            err = ErrorEvent(update=update, exception=e)
            result = await self.propagate_event("errors", err, {**data, "exception": e})
            if result is UNHANDLED:
                log.exception("Ошибка при обработке обновления %s", update.update_id, exc_info=e)
        finally:
            if (self.auto_answer_callbacks and isinstance(event, CallbackQuery) and not event.answered):
                try:
                    await event.answer()             # человек не ждёт крутилку, даже если обработчик не ответил
                except OrbitaAPIError:
                    pass
        log.debug("Обновление %s (%s) %s за %.0f мс", update.update_id, event_type,
                  "обработано" if result is not UNHANDLED else "без обработчика", (time.monotonic() - started) * 1000)
        return result

    async def feed_raw_update(self, bot, update: dict, **kwargs):
        return await self.feed_update(bot, Update.from_dict(update, bot), **kwargs)

    async def _process_ordered(self, bot, update: Update, **kwargs):
        """События одного чата — строго по очереди (важно для диалогов), разных чатов — параллельно"""
        ev = update.event
        chat = getattr(ev, "chat", None) or getattr(getattr(ev, "message", None), "chat", None)
        key = f"{bot.id}:{chat.id if chat else '-'}"
        entry = self._chat_locks.setdefault(key, [asyncio.Lock(), 0])
        entry[1] += 1
        try:
            async with entry[0]:
                await self.feed_update(bot, update, **kwargs)
        finally:
            entry[1] -= 1
            if entry[1] == 0:
                self._chat_locks.pop(key, None)

    # ---------------------------------------------------------------- polling

    async def start_polling(self, *bots, polling_timeout: int = 25, handle_as_tasks: bool = True,
                            drop_pending_updates: bool = False, close_bot_session: bool = True, **kwargs) -> None:
        """Получать обновления долгим опросом (getUpdates). Остановка — Ctrl+C или dp.stop_polling()"""
        if not bots:
            raise ValueError("start_polling(bot) — передайте хотя бы одного бота")
        self._stop = asyncio.Event()
        workflow = {**kwargs, "dispatcher": self, "bots": bots}
        try:
            for bot in bots:
                me = await bot.get_me()
                await bot.delete_webhook(drop_pending_updates=drop_pending_updates)
                log.info("Бот @%s (%s) запущен на %s", me.username, me.first_name, bot.server)
            await self.startup.fire({**self.workflow_data, **workflow, "bot": bots[0]})
            pollers = [asyncio.create_task(self._poll(bot, polling_timeout, handle_as_tasks, kwargs)) for bot in bots]
            stopper = asyncio.create_task(self._stop.wait())
            await asyncio.wait([stopper, *pollers], return_when=asyncio.FIRST_COMPLETED)
            for t in pollers:
                t.cancel()
            for t in pollers:
                try:
                    await t
                except (asyncio.CancelledError, Exception) as e:   # noqa: BLE001
                    if not isinstance(e, asyncio.CancelledError):
                        raise
        finally:
            if self._tasks:
                await asyncio.gather(*self._tasks, return_exceptions=True)
            await self.shutdown.fire({**self.workflow_data, **workflow, "bot": bots[0]})
            await self.storage.close()
            if close_bot_session:
                for bot in bots:
                    await bot.close()
            log.info("Бот остановлен")

    async def _poll(self, bot, timeout: int, as_tasks: bool, kwargs: dict) -> None:
        offset: int | None = None
        delay = 1.0
        while True:
            try:
                updates = await bot.get_updates(offset=offset, timeout=timeout)
                delay = 1.0
            except (NetworkError, ServerError) as e:
                log.warning("Нет связи с сервером (%s), повтор через %.0f с", e, delay)
                await asyncio.sleep(delay)
                delay = min(delay * 2, 30)
                continue
            except Unauthorized:
                log.error("Токен не подходит: возьмите новый у @botgod (/token)")
                raise
            except Conflict as e:
                log.error("Конфликт получения обновлений: %s", e)
                await asyncio.sleep(5)
                continue
            for u in updates:
                offset = u.update_id + 1
                if as_tasks:
                    t = asyncio.create_task(self._process_ordered(bot, u, **kwargs))
                    self._tasks.add(t)
                    t.add_done_callback(self._tasks.discard)
                else:
                    await self.feed_update(bot, u, **kwargs)

    def stop_polling(self) -> None:
        if self._stop is not None:
            self._stop.set()

    def run_polling(self, *bots, **kwargs) -> None:
        """Запустить бота и держать до Ctrl+C (синхронная обёртка над start_polling)"""
        if not logging.getLogger().handlers:
            logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")

        async def main():
            loop = asyncio.get_running_loop()
            for sig in (signal.SIGINT, signal.SIGTERM):
                try:
                    loop.add_signal_handler(sig, self.stop_polling)
                except (NotImplementedError, RuntimeError):     # Windows
                    pass
            await self.start_polling(*bots, **kwargs)

        try:
            asyncio.run(main())
        except KeyboardInterrupt:
            pass

    # ---------------------------------------------------------------- вебхук

    async def start_webhook(self, bot, **kwargs) -> None:
        from .webhook import serve_webhook
        await serve_webhook(self, bot, **kwargs)

    def run_webhook(self, bot, **kwargs) -> None:
        """Принимать обновления вебхуком на своём HTTP-сервере (за https-прокси). См. webhook.serve_webhook"""
        if not logging.getLogger().handlers:
            logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
        try:
            asyncio.run(self.start_webhook(bot, **kwargs))
        except KeyboardInterrupt:
            pass
