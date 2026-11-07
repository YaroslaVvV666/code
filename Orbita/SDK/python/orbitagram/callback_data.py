"""Типизированные данные кнопок — вместо ручной склейки строк «buy:42:2»:

    class BuyCb(CallbackData, prefix="buy"):
        item_id: int
        qty: int = 1

    builder.button(text="Купить", callback_data=BuyCb(item_id=42))

    @dp.callback_query(BuyCb.filter(F.qty > 0))
    async def buy(call: CallbackQuery, callback_data: BuyCb): ...
"""
from __future__ import annotations

import enum
import typing
from typing import Any, ClassVar

MAX_CALLBACK_LENGTH = 64
_NONE = ""


class CallbackDataError(ValueError):
    pass


class CallbackData:
    __prefix__: ClassVar[str]
    __separator__: ClassVar[str]
    __fields__: ClassVar[dict[str, Any]]

    def __init_subclass__(cls, prefix: str | None = None, sep: str = ":", **kw):
        super().__init_subclass__(**kw)
        if not prefix:
            raise TypeError(f"{cls.__name__}: укажите prefix — class {cls.__name__}(CallbackData, prefix='…')")
        if sep in prefix:
            raise TypeError("prefix не должен содержать разделитель")
        cls.__prefix__, cls.__separator__ = prefix, sep
        hints = typing.get_type_hints(cls)
        cls.__fields__ = {k: v for k, v in hints.items() if not k.startswith("_") and typing.get_origin(v) is not ClassVar}

    def __init__(self, **kwargs):
        for name in self.__fields__:
            if name in kwargs:
                value = kwargs.pop(name)
            elif hasattr(type(self), name):
                value = getattr(type(self), name)
            else:
                raise TypeError(f"{type(self).__name__}: не задано поле {name}")
            setattr(self, name, value)
        if kwargs:
            raise TypeError(f"{type(self).__name__}: лишние поля {', '.join(kwargs)}")

    def __repr__(self) -> str:
        return f"{type(self).__name__}(" + ", ".join(f"{k}={getattr(self, k)!r}" for k in self.__fields__) + ")"

    def __eq__(self, other) -> bool:
        return type(self) is type(other) and all(getattr(self, k) == getattr(other, k) for k in self.__fields__)

    def _encode(self, value) -> str:
        if value is None:
            return _NONE
        if isinstance(value, bool):
            return "1" if value else "0"
        if isinstance(value, enum.Enum):
            value = value.value
        text = str(value)
        if self.__separator__ in text:
            raise CallbackDataError(f"Значение «{text}» содержит разделитель «{self.__separator__}»")
        return text

    def pack(self) -> str:
        parts = [self.__prefix__] + [self._encode(getattr(self, k)) for k in self.__fields__]
        packed = self.__separator__.join(parts)
        if len(packed.encode()) > MAX_CALLBACK_LENGTH:
            raise CallbackDataError(f"callback_data длиннее {MAX_CALLBACK_LENGTH} байт: {packed!r}")
        return packed

    @classmethod
    def unpack(cls, value: str):
        parts = value.split(cls.__separator__)
        if parts[0] != cls.__prefix__ or len(parts) - 1 != len(cls.__fields__):
            raise CallbackDataError(f"Это не {cls.__name__}: {value!r}")
        kwargs = {}
        for (name, tp), raw in zip(cls.__fields__.items(), parts[1:]):
            kwargs[name] = _decode(tp, raw)
        return cls(**kwargs)

    @classmethod
    def filter(cls, rule=None):
        """Фильтр для callback_query: распаковывает данные и передаёт их в обработчик аргументом callback_data"""
        from .filters import CallbackDataFilter
        return CallbackDataFilter(cls, rule)


def _decode(tp, raw: str):
    origin = typing.get_origin(tp)
    if origin is typing.Union:
        args = [a for a in typing.get_args(tp) if a is not type(None)]
        if raw == _NONE:
            return None
        tp = args[0] if args else str
    if tp is bool:
        return raw in ("1", "true", "True")
    if tp is int:
        return int(raw)
    if tp is float:
        return float(raw)
    if isinstance(tp, type) and issubclass(tp, enum.Enum):
        for m in tp:
            if str(m.value) == raw:
                return m
        raise CallbackDataError(f"Нет значения {raw!r} в {tp.__name__}")
    return raw
