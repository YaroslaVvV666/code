"""Состояния (FSM): пошаговые диалоги — анкета, оформление заказа и т.п.

    class Order(StatesGroup):
        name = State()
        phone = State()

    @dp.message(Command("order"))
    async def start(message, state: FSMContext):
        await state.set_state(Order.name)
        await message.answer("Как вас зовут?")

    @dp.message(Order.name)
    async def got_name(message, state: FSMContext):
        await state.update_data(name=message.text)
        await state.set_state(Order.phone)
"""
from __future__ import annotations

import asyncio
import json
import os
from dataclasses import dataclass
from typing import Any, Optional, Union


class State:
    """Одно состояние. Внутри StatesGroup получает имя «Группа:поле»"""

    def __init__(self, state: str | None = None, group_name: str | None = None):
        self._state = state
        self._group_name = group_name
        self.group: type["StatesGroup"] | None = None

    @property
    def state(self) -> str | None:
        if self._state == "*":
            return "*"
        if self._group_name:
            return f"{self._group_name}:{self._state}"
        return self._state

    def __set_name__(self, owner, name):
        if self._state is None:
            self._state = name

    def __str__(self) -> str:
        return str(self.state)

    __repr__ = __str__

    def __eq__(self, other) -> bool:
        if isinstance(other, State):
            return self.state == other.state
        return self.state == other

    def __hash__(self) -> int:
        return hash(self.state)


class _StatesGroupMeta(type):
    def __new__(mcs, name, bases, ns, **kw):
        cls = super().__new__(mcs, name, bases, ns)
        states, groups = [], []
        for key, value in ns.items():
            if isinstance(value, State):
                value._group_name = cls.__qualname__
                value.group = cls
                states.append(value)
            elif isinstance(value, type) and issubclass(value, StatesGroup):
                groups.append(value)
        cls.__states__ = tuple(states)
        cls.__child_groups__ = tuple(groups)
        return cls

    def __contains__(cls, item) -> bool:
        name = item.state if isinstance(item, State) else item
        return any(s.state == name for s in cls.__all_states__)

    @property
    def __all_states__(cls) -> tuple:
        out = list(cls.__states__)
        for g in cls.__child_groups__:
            out.extend(g.__all_states__)
        return tuple(out)

    @property
    def __all_states_names__(cls) -> tuple:
        return tuple(s.state for s in cls.__all_states__)


class StatesGroup(metaclass=_StatesGroupMeta):
    """Набор состояний одного диалога"""


default_state = State(None)
any_state = State("*")

StateType = Optional[Union[str, State]]


@dataclass(frozen=True)
class StorageKey:
    bot_id: str
    chat_id: str
    user_id: str

    def __str__(self) -> str:
        return f"{self.bot_id}:{self.chat_id}:{self.user_id}"


class BaseStorage:
    async def get_state(self, key: StorageKey) -> str | None: raise NotImplementedError
    async def set_state(self, key: StorageKey, state: StateType) -> None: raise NotImplementedError
    async def get_data(self, key: StorageKey) -> dict[str, Any]: raise NotImplementedError
    async def set_data(self, key: StorageKey, data: dict[str, Any]) -> None: raise NotImplementedError
    async def close(self) -> None: pass


def _state_name(state: StateType) -> str | None:
    return state.state if isinstance(state, State) else state


class MemoryStorage(BaseStorage):
    """В памяти процесса — для разработки. После перезапуска состояния пропадут"""

    def __init__(self):
        self._states: dict[StorageKey, str | None] = {}
        self._data: dict[StorageKey, dict] = {}

    async def get_state(self, key):
        return self._states.get(key)

    async def set_state(self, key, state):
        name = _state_name(state)
        if name is None:
            self._states.pop(key, None)
        else:
            self._states[key] = name

    async def get_data(self, key):
        return dict(self._data.get(key, {}))

    async def set_data(self, key, data):
        if data:
            self._data[key] = dict(data)
        else:
            self._data.pop(key, None)


class JSONFileStorage(MemoryStorage):
    """Как MemoryStorage, но сохраняется в JSON-файл — переживает перезапуск бота"""

    def __init__(self, path: str | os.PathLike = "orbitagram_fsm.json"):
        super().__init__()
        self.path = os.fspath(path)
        self._lock = asyncio.Lock()
        if os.path.exists(self.path):
            try:
                with open(self.path, encoding="utf-8") as f:
                    raw = json.load(f)
                for k, v in raw.items():
                    b, c, u = k.split(":", 2)
                    key = StorageKey(b, c, u)
                    if v.get("state"):
                        self._states[key] = v["state"]
                    if v.get("data"):
                        self._data[key] = v["data"]
            except (OSError, ValueError):
                pass

    async def _save(self):
        async with self._lock:
            keys = set(self._states) | set(self._data)
            raw = {str(k): {"state": self._states.get(k), "data": self._data.get(k, {})} for k in keys}
            tmp = self.path + ".tmp"
            await asyncio.to_thread(_dump_json, tmp, raw)
            os.replace(tmp, self.path)

    async def set_state(self, key, state):
        await super().set_state(key, state)
        await self._save()

    async def set_data(self, key, data):
        await super().set_data(key, data)
        await self._save()


def _dump_json(path, raw):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(raw, f, ensure_ascii=False)


class FSMContext:
    """Состояние и данные текущего собеседника — приходит в обработчик аргументом `state`"""

    def __init__(self, storage: BaseStorage, key: StorageKey):
        self.storage = storage
        self.key = key

    async def get_state(self) -> str | None:
        return await self.storage.get_state(self.key)

    async def set_state(self, state: StateType = None) -> None:
        await self.storage.set_state(self.key, state)

    async def get_data(self) -> dict[str, Any]:
        return await self.storage.get_data(self.key)

    async def set_data(self, data: dict[str, Any]) -> None:
        await self.storage.set_data(self.key, data)

    async def update_data(self, data: dict[str, Any] | None = None, **kwargs) -> dict[str, Any]:
        current = await self.get_data()
        current.update(data or {}, **kwargs)
        await self.set_data(current)
        return current

    async def clear(self) -> None:
        """Выйти из диалога: сбросить и состояние, и данные"""
        await self.set_state(None)
        await self.set_data({})
