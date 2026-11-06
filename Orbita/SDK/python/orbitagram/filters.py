"""Фильтры обработчиков. Любой фильтр — это объект с `async __call__(event, **data)`, который возвращает
True/False или словарь (он добавится к аргументам обработчика). Подходят и обычные функции, и F-условия.

    @dp.message(Command("start", "help"))
    @dp.message(CommandStart(deep_link=True))
    @dp.message(Order.phone, F.text.regexp(r"^\\+?\\d{10,15}$"))
    @dp.message(Command("ban") & IsAdmin())
"""
from __future__ import annotations

import inspect
import re
from dataclasses import dataclass, field
from typing import Any, Callable, Iterable, Sequence

from .fsm import State, StatesGroup, any_state
from .magic import MagicFilter
from .types import BotCommand, CallbackQuery, Message


class Filter:
    """База для своих фильтров: переопределите __call__"""

    async def __call__(self, event, **data) -> bool | dict[str, Any]:
        raise NotImplementedError

    def __and__(self, other) -> "Filter":
        return _And(self, other)

    def __or__(self, other) -> "Filter":
        return _Or(self, other)

    def __invert__(self) -> "Filter":
        return _Not(self)


async def check(flt, event, data: dict) -> bool | dict:
    """Проверить любой фильтр: Filter, MagicFilter, State/StatesGroup, функцию (в т.ч. async)"""
    if isinstance(flt, MagicFilter):
        result = flt.resolve(event)
        return result if isinstance(result, dict) else bool(result) if not isinstance(result, re.Match) else True
    if isinstance(flt, (State, str)) or flt is None or (isinstance(flt, type) and issubclass(flt, StatesGroup)):
        return await StateFilter(flt)(event, **data)
    if isinstance(flt, Filter):
        return await flt(event, **data)
    if callable(flt):
        params = inspect.signature(flt).parameters
        if any(p.kind == p.VAR_KEYWORD for p in params.values()):
            result = flt(event, **data)
        else:
            result = flt(event, **{k: v for k, v in data.items() if k in params})
        if inspect.isawaitable(result):
            result = await result
        return result if isinstance(result, dict) else bool(result)
    if isinstance(flt, bool):
        return flt
    raise TypeError(f"Не понимаю фильтр {flt!r}")


class _And(Filter):
    def __init__(self, *filters):
        self.filters = filters

    async def __call__(self, event, **data):
        extra: dict = {}
        for f in self.filters:
            r = await check(f, event, {**data, **extra})
            if not r:
                return False
            if isinstance(r, dict):
                extra.update(r)
        return extra or True


class _Or(Filter):
    def __init__(self, *filters):
        self.filters = filters

    async def __call__(self, event, **data):
        for f in self.filters:
            r = await check(f, event, data)
            if r:
                return r
        return False


class _Not(Filter):
    def __init__(self, inner):
        self.inner = inner

    async def __call__(self, event, **data):
        return not await check(self.inner, event, data)


def and_f(*filters) -> Filter:
    return _And(*filters)


def or_f(*filters) -> Filter:
    return _Or(*filters)


def invert_f(f) -> Filter:
    return _Not(f)


# ---------------------------------------------------------------- команды

@dataclass
class CommandObject:
    """Разобранная команда: /buy@shop_bot 3 яблока → command="buy", mention="shop_bot", args="3 яблока" """
    prefix: str = "/"
    command: str = ""
    mention: str | None = None
    args: str | None = None
    regexp_match: re.Match | None = field(default=None, repr=False)

    @property
    def text(self) -> str:
        line = self.prefix + self.command + (f"@{self.mention}" if self.mention else "")
        return line + (f" {self.args}" if self.args else "")


class Command(Filter):
    def __init__(self, *commands: str | re.Pattern | BotCommand | Iterable, prefix: str = "/",
                 ignore_case: bool = False, ignore_mention: bool = False, magic: MagicFilter | None = None):
        flat: list = []
        for c in commands:
            if isinstance(c, (list, tuple, set)):
                flat.extend(c)
            else:
                flat.append(c)
        if not flat:
            raise ValueError("Command(...) без команд")
        self.commands = [c.command if isinstance(c, BotCommand) else c for c in flat]
        self.commands = [c.lstrip(prefix) if isinstance(c, str) else c for c in self.commands]
        self.prefix = prefix
        self.ignore_case = ignore_case
        self.ignore_mention = ignore_mention
        self.magic = magic

    def __repr__(self):
        return f"Command({', '.join(map(str, self.commands))})"

    @staticmethod
    def parse(text: str, prefix: str = "/") -> CommandObject | None:
        if not text or text[0] not in prefix:
            return None
        head, _, args = text.partition(" ")
        cmd, _, mention = head[1:].partition("@")
        if not cmd:
            return None
        return CommandObject(prefix=head[0], command=cmd, mention=mention or None, args=args.strip() or None)

    async def __call__(self, event, bot=None, **data):
        text = event.text if isinstance(event, Message) else None
        obj = self.parse(text or "", self.prefix)
        if obj is None:
            return False
        if obj.mention and not self.ignore_mention and bot is not None:
            me = await bot.me()
            if (me.username or "").lower() != obj.mention.lower():
                return False
        name = obj.command.lower() if self.ignore_case else obj.command
        for c in self.commands:
            if isinstance(c, re.Pattern):
                m = c.match(obj.command)
                if m:
                    obj.regexp_match = m
                    break
            elif name == (c.lower() if self.ignore_case else c):
                break
        else:
            return False
        if self.magic is not None:
            r = self.magic.resolve(obj)
            if not r:
                return False
        return {"command": obj}


class CommandStart(Command):
    """/start. deep_link=True — только если пришли по ссылке с параметром (?start=…)"""

    def __init__(self, deep_link: bool = False, ignore_case: bool = False, magic: MagicFilter | None = None):
        super().__init__("start", ignore_case=ignore_case, magic=magic)
        self.deep_link = deep_link

    async def __call__(self, event, bot=None, **data):
        r = await super().__call__(event, bot=bot, **data)
        if not r:
            return False
        if self.deep_link and not r["command"].args:
            return False
        return r


# ---------------------------------------------------------------- состояния

class StateFilter(Filter):
    """Обработчик сработает только в этих состояниях. StateFilter(None) — вне диалога, StateFilter("*") — в любом"""

    def __init__(self, *states):
        self.states = states or (None,)

    async def __call__(self, event, raw_state: str | None = None, **data):
        for s in self.states:
            if s == "*" or s is any_state or (isinstance(s, State) and s.state == "*"):
                return True
            if isinstance(s, type) and issubclass(s, StatesGroup):
                if raw_state in s.__all_states_names__:
                    return True
                continue
            name = s.state if isinstance(s, State) else s
            if name == raw_state:
                return True
        return False


# ---------------------------------------------------------------- кнопки

class CallbackDataFilter(Filter):
    def __init__(self, cls, rule: MagicFilter | None = None):
        self.cls = cls
        self.rule = rule

    async def __call__(self, event, **data):
        if not isinstance(event, CallbackQuery) or not event.data:
            return False
        try:
            obj = self.cls.unpack(event.data)
        except (ValueError, TypeError):
            return False
        if self.rule is not None and not self.rule.resolve(obj):
            return False
        return {"callback_data": obj}


class ChatType(Filter):
    def __init__(self, *types: str):
        self.types = set(types)

    async def __call__(self, event, event_chat=None, **data):
        return bool(event_chat) and event_chat.type in self.types


class ExceptionTypeFilter(Filter):
    """Для обработчиков ошибок: @dp.errors(ExceptionTypeFilter(Forbidden))"""

    def __init__(self, *types: type[BaseException]):
        self.types = types

    async def __call__(self, event, **data):
        return isinstance(getattr(event, "exception", None), self.types)


class ExceptionMessageFilter(Filter):
    def __init__(self, pattern: str):
        self.rx = re.compile(pattern)

    async def __call__(self, event, **data):
        exc = getattr(event, "exception", None)
        m = self.rx.search(str(exc)) if exc else None
        return {"match_exception": m} if m else False
