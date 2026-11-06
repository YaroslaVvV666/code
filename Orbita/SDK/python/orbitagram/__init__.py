"""orbitagram — асинхронная библиотека для ботов Orbita (в духе aiogram).

    import asyncio
    from orbitagram import Bot, Dispatcher, F
    from orbitagram.filters import CommandStart
    from orbitagram.types import Message

    bot = Bot("ТОКЕН", server="https://orbita.example.com")
    dp = Dispatcher()

    @dp.message(CommandStart())
    async def start(message: Message):
        await message.answer(f"Привет, {message.from_user.first_name}!")

    @dp.message(F.text)
    async def echo(message: Message):
        await message.answer(message.text)

    dp.run_polling(bot)
"""
from .bot import Bot
from .callback_data import CallbackData
from .dispatcher import Dispatcher, Router
from .exceptions import (BadRequest, CancelHandler, Forbidden, NetworkError, OrbitaAPIError, RetryAfter,
                         SkipHandler, Unauthorized)
from .filters import Command, CommandObject, CommandStart, Filter, StateFilter
from .fsm import FSMContext, JSONFileStorage, MemoryStorage, State, StatesGroup
from .keyboards import InlineKeyboardBuilder, ReplyKeyboardBuilder
from .magic import F
from .middleware import BaseMiddleware, ThrottlingMiddleware
from . import types

__version__ = "1.0.0"
__all__ = ["Bot", "Dispatcher", "Router", "F", "CallbackData", "Command", "CommandStart", "CommandObject", "Filter",
           "StateFilter", "State", "StatesGroup", "FSMContext", "MemoryStorage", "JSONFileStorage",
           "InlineKeyboardBuilder", "ReplyKeyboardBuilder", "BaseMiddleware", "ThrottlingMiddleware", "types",
           "OrbitaAPIError", "BadRequest", "Forbidden", "Unauthorized", "RetryAfter", "NetworkError",
           "SkipHandler", "CancelHandler"]
