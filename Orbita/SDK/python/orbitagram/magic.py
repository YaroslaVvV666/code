"""Магический фильтр F — короткие условия на поля события:

    @dp.message(F.text == "Привет")
    @dp.message(F.photo)                              # пришло фото
    @dp.message(F.text.lower().contains("цена"))
    @dp.callback_query(F.data.startswith("buy:"))
    @dp.message(F.from_user.id.in_({ADMIN_ID}))
    @dp.message(F.text.regexp(r"^\\d{4}$").as_("code"))  # совпадение придёт в обработчик аргументом code
"""
from __future__ import annotations

import operator
import re
from typing import Any, Callable

_MISSING = object()


class MagicFilter:
    __slots__ = ("_ops",)

    def __init__(self, ops: tuple = ()):
        self._ops = ops

    def _add(self, op) -> "MagicFilter":
        return MagicFilter(self._ops + (op,))

    # --- навигация по полям ---

    def __getattr__(self, name: str) -> "MagicFilter":
        if name.startswith("__") and name.endswith("__"):
            raise AttributeError(name)
        return self._add(("attr", name))

    def __getitem__(self, key) -> "MagicFilter":
        return self._add(("item", key))

    def __call__(self, *args, **kwargs) -> "MagicFilter":
        # F.text.lower() — вызов метода значения
        return self._add(("call", args, kwargs))

    # --- сравнения ---

    def __eq__(self, other) -> "MagicFilter":  # type: ignore[override]
        return self._add(("cmp", operator.eq, other))

    def __ne__(self, other) -> "MagicFilter":  # type: ignore[override]
        return self._add(("cmp", operator.ne, other))

    def __lt__(self, other): return self._add(("cmp", operator.lt, other))
    def __le__(self, other): return self._add(("cmp", operator.le, other))
    def __gt__(self, other): return self._add(("cmp", operator.gt, other))
    def __ge__(self, other): return self._add(("cmp", operator.ge, other))

    __hash__ = None  # type: ignore[assignment]

    def in_(self, container) -> "MagicFilter":
        return self._add(("fn", lambda v: v in container))

    def not_in(self, container) -> "MagicFilter":
        return self._add(("fn", lambda v: v not in container))

    def contains(self, item) -> "MagicFilter":
        return self._add(("fn", lambda v: v is not None and item in v))

    def startswith(self, prefix) -> "MagicFilter":
        return self._add(("fn", lambda v: isinstance(v, str) and v.startswith(prefix)))

    def endswith(self, suffix) -> "MagicFilter":
        return self._add(("fn", lambda v: isinstance(v, str) and v.endswith(suffix)))

    def regexp(self, pattern: str | re.Pattern, mode: str = "search") -> "MagicFilter":
        rx = re.compile(pattern) if isinstance(pattern, str) else pattern
        method = {"search": rx.search, "match": rx.match, "fullmatch": rx.fullmatch}[mode]
        return self._add(("map", lambda v: method(v) if isinstance(v, str) else None))

    def len(self) -> "MagicFilter":
        return self._add(("map", lambda v: len(v) if v is not None else None))

    def func(self, fn: Callable[[Any], Any]) -> "MagicFilter":
        """Любая своя функция над значением: F.text.func(str.isdigit)"""
        return self._add(("map", fn))

    def cast(self, fn: Callable[[Any], Any]) -> "MagicFilter":
        """Привести тип (ошибка приведения = фильтр не прошёл): F.text.cast(int) > 18"""
        return self._add(("cast", fn))

    def as_(self, name: str) -> "MagicFilter":
        """Если условие выполнено, его значение придёт в обработчик аргументом name"""
        return self._add(("as", name))

    # --- логика ---

    def __and__(self, other) -> "MagicFilter":
        return MagicFilter((("and", self, other),))

    def __or__(self, other) -> "MagicFilter":
        return MagicFilter((("or", self, other),))

    def __invert__(self) -> "MagicFilter":
        return MagicFilter((("not", self),))

    # --- вычисление ---

    def resolve(self, obj) -> Any:
        value = obj
        for op in self._ops:
            kind = op[0]
            if kind in ("and", "or", "not"):
                if kind == "not":
                    return not _truthy(_eval(op[1], obj))
                left = _eval(op[1], obj)
                if kind == "and":
                    return _eval(op[2], obj) if _truthy(left) else left
                return left if _truthy(left) else _eval(op[2], obj)
            if value is None or value is _MISSING:
                if kind in ("cmp",):
                    value = op[1](None, op[2])
                    continue
                return None
            try:
                if kind == "attr":
                    value = getattr(value, op[1], None) if not isinstance(value, dict) else value.get(op[1])
                elif kind == "item":
                    value = value[op[1]]
                elif kind == "call":
                    value = value(*op[1], **op[2])
                elif kind == "cmp":
                    value = op[1](value, op[2])
                elif kind in ("fn", "map"):
                    value = op[1](value)
                elif kind == "cast":
                    value = op[1](value)
                elif kind == "as":
                    if not _truthy(value):
                        return None
                    return {op[1]: value}
            except (LookupError, TypeError, ValueError, AttributeError):
                return None
        return value

    def __repr__(self) -> str:
        return "F" + "".join(f".{o[1]}" if o[0] == "attr" else f"<{o[0]}>" for o in self._ops)


def _eval(x, obj):
    return x.resolve(obj) if isinstance(x, MagicFilter) else x


def _truthy(v) -> bool:
    return bool(v) if not isinstance(v, re.Match) else True


F = MagicFilter()
