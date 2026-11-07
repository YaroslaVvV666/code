"""Тот же эхо-бот, но на вебхуке: сервер Orbita сам присылает обновления.
Перед процессом нужен https-прокси (nginx/caddy) с публичным адресом WEBHOOK_URL → 127.0.0.1:8081.

    ORBITA_SERVER=… BOT_TOKEN=… WEBHOOK_URL=https://bot.example.com/orbita python orbita_webhook_bot.py
"""
import os
import secrets

from orbitagram import Bot, Dispatcher, F
from orbitagram.types import Message

dp = Dispatcher()


@dp.message(F.text)
async def echo(message: Message):
    await message.answer("Вебхук: " + message.text)


if __name__ == "__main__":
    dp.run_webhook(Bot(os.environ["BOT_TOKEN"]), url=os.environ["WEBHOOK_URL"], path="/orbita",
                   host="127.0.0.1", port=8081, secret_token=os.environ.get("WEBHOOK_SECRET") or secrets.token_hex(16))
