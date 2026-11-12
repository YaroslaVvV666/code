"""Сборка клавиатур:

    kb = InlineKeyboardBuilder()
    for item in items:
        kb.button(text=item.title, callback_data=BuyCb(item_id=item.id))
    kb.button(text="Сайт", url="https://example.com")
    kb.adjust(2)                                   # по 2 кнопки в ряд
    await message.answer("Каталог", reply_markup=kb.as_markup())

    menu = ReplyKeyboardBuilder()
    menu.button(text="🛒 Корзина"); menu.button(text="ℹ️ Помощь")
    await message.answer("Меню", reply_markup=menu.as_markup(resize_keyboard=True))
"""
from __future__ import annotations

from typing import Generic, TypeVar

from .callback_data import CallbackData
from .types import (InlineKeyboardButton, InlineKeyboardMarkup, KeyboardButton, ReplyKeyboardMarkup,
                    ReplyKeyboardRemove)

B = TypeVar("B", InlineKeyboardButton, KeyboardButton)


class _Builder(Generic[B]):
    max_width = 8
    max_rows = 10

    def __init__(self, markup: list[list[B]] | None = None):
        self._rows: list[list[B]] = [list(r) for r in (markup or [])]

    def add(self, *buttons: B) -> "_Builder[B]":
        """Добавить кнопки подряд (раскладку потом задаст adjust)"""
        if not self._rows:
            self._rows.append([])
        for b in buttons:
            if len(self._rows[-1]) >= self.max_width:
                self._rows.append([])
            self._rows[-1].append(b)
        return self

    def row(self, *buttons: B, width: int | None = None) -> "_Builder[B]":
        """Новый ряд из этих кнопок"""
        width = width or self.max_width
        for i in range(0, len(buttons), width):
            self._rows.append(list(buttons[i:i + width]))
        return self

    def adjust(self, *sizes: int, repeat: bool = False) -> "_Builder[B]":
        """Разложить все кнопки по рядам: adjust(2) — по 2; adjust(3, 1) — 3 сверху, остальные по 1"""
        sizes = sizes or (self.max_width,)
        buttons = [b for r in self._rows for b in r]
        rows, i, k = [], 0, 0
        while i < len(buttons):
            if k < len(sizes):
                size = sizes[k]
            else:
                size = sizes[(k - len(sizes)) % len(sizes)] if repeat else sizes[-1]
            size = max(1, min(size, self.max_width))
            rows.append(buttons[i:i + size])
            i += size
            k += 1
        self._rows = rows
        return self

    def attach(self, other: "_Builder[B]") -> "_Builder[B]":
        self._rows.extend([list(r) for r in other._rows])
        return self

    def export(self) -> list[list[B]]:
        return [list(r) for r in self._rows if r][: self.max_rows]

    def __len__(self) -> int:
        return sum(len(r) for r in self._rows)


class InlineKeyboardBuilder(_Builder[InlineKeyboardButton]):
    def button(self, *, text: str, callback_data: str | CallbackData | None = None,
               url: str | None = None) -> "InlineKeyboardBuilder":
        if callback_data is None and url is None:
            raise ValueError("Кнопке нужна callback_data или url")
        if isinstance(callback_data, CallbackData):
            callback_data = callback_data.pack()
        return self.add(InlineKeyboardButton(text=text, callback_data=callback_data, url=url))

    def as_markup(self) -> InlineKeyboardMarkup:
        return InlineKeyboardMarkup(inline_keyboard=self.export())

    @classmethod
    def from_markup(cls, markup: InlineKeyboardMarkup) -> "InlineKeyboardBuilder":
        return cls(markup.inline_keyboard)


class ReplyKeyboardBuilder(_Builder[KeyboardButton]):
    max_rows = 12

    def button(self, *, text: str) -> "ReplyKeyboardBuilder":
        return self.add(KeyboardButton(text=text))

    def as_markup(self, *, resize_keyboard: bool = True, one_time_keyboard: bool | None = None,
                  input_field_placeholder: str | None = None) -> ReplyKeyboardMarkup:
        return ReplyKeyboardMarkup(keyboard=self.export(), resize_keyboard=resize_keyboard,
                                   one_time_keyboard=one_time_keyboard, input_field_placeholder=input_field_placeholder)


def remove_keyboard() -> ReplyKeyboardRemove:
    """Убрать клавиатуру бота у человека"""
    return ReplyKeyboardRemove()
