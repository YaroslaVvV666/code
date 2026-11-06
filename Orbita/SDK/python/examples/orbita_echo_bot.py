"""Самый простой бот: приветствие и эхо.

    pip install ./SDK/python
    ORBITA_SERVER=https://orbita.example.com BOT_TOKEN=12ab34cd56ef:… python orbita_echo_bot.py
"""
import os

from orbitagram import Bot, Dispatcher, F
from orbitagram.filters import CommandStart
from orbitagram.types import Message

bot = Bot(os.environ["BOT_TOKEN"])            # адрес сервера — из ORBITA_SERVER
dp = Dispatcher()


@dp.message(CommandStart())
async def start(message: Message):
    await message.answer(f"Привет, {message.from_user.first_name}! Напиши что-нибудь — я повторю.")


@dp.message(F.text)
async def echo(message: Message):
    await message.answer(message.text)


@dp.message(F.photo)
async def photo(message: Message):
    await message.reply("Красивое фото! Возвращаю 🙂")
    await message.answer_photo(message.photo[-1].file_id)


@dp.message()
async def other(message: Message):
    await message.answer(f"Пока я понимаю только текст и фото (пришло: {message.content_type})")


if __name__ == "__main__":
    dp.run_polling(bot)
