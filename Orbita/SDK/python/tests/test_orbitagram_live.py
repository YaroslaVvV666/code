"""Живая проверка библиотеки с настоящим сервером Orbita (Server/server.py должен быть запущен на ORBITA_SERVER,
по умолчанию http://127.0.0.1:8080). Бот создаётся через @botgod, человек — обычный аккаунт."""
import asyncio
import base64
import os
import re
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "Server", "tests"))

from smoke import jbody, req, session  # noqa: E402  (помощники серверных тестов)

from orbitagram import (Bot, CallbackData, Command, CommandStart, Dispatcher, F, FSMContext,  # noqa: E402
                        InlineKeyboardBuilder, ReplyKeyboardBuilder, State, StatesGroup)
from orbitagram.types import BufferedInputFile, CallbackQuery, Message  # noqa: E402

SERVER = os.environ.get("ORBITA_SERVER", "http://127.0.0.1:8080")
BOTGOD = "b0790d00-0000-4000-8000-00000000b070"
JPEG = base64.b64decode(
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAAIAAgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDlqKKK+NP1M//Z")


class Shop(StatesGroup):
    qty = State()


class BuyCb(CallbackData, prefix="buy"):
    item: int


def build_dispatcher() -> Dispatcher:
    dp = Dispatcher()

    @dp.message(CommandStart())
    async def start(message: Message, command):
        kb = InlineKeyboardBuilder()
        kb.button(text="🍎 Яблоко", callback_data=BuyCb(item=1))
        kb.button(text="🍐 Груша", callback_data=BuyCb(item=2))
        kb.adjust(2)
        hello = f"Привет, {message.from_user.first_name}!" + (f" Промокод: {command.args}" if command.args else "")
        await message.answer(hello, reply_markup=kb.as_markup())

    @dp.callback_query(BuyCb.filter())
    async def buy(call: CallbackQuery, callback_data: BuyCb, state: FSMContext):
        await state.set_state(Shop.qty)
        await state.update_data(item=callback_data.item)
        await call.answer("Сколько штук?")
        await call.message.edit_text(f"Выбран товар {callback_data.item}")

    @dp.message(Shop.qty, F.text.regexp(r"^\d+$"))
    async def qty(message: Message, state: FSMContext):
        data = await state.update_data(qty=int(message.text))
        await state.clear()
        menu = ReplyKeyboardBuilder()
        menu.button(text="Ещё"); menu.button(text="Хватит")
        await message.answer(f"Заказ: товар {data['item']} × {data['qty']}", reply_markup=menu.as_markup())

    @dp.message(F.photo)
    async def photo(message: Message, bot: Bot):
        data = await message.download()
        await message.answer_chat_action("upload_photo")
        await message.answer_photo(message.photo[-1].file_id, caption=f"Получил {len(data)} байт")

    @dp.message(Command("pic"))
    async def pic(message: Message):
        await message.answer_photo(BufferedInputFile(JPEG, "dot.jpg"), caption="Картинка из памяти")

    @dp.message(F.text)
    async def echo(message: Message):
        await message.answer("Эхо: " + message.text)

    return dp


def main():
    fails = 0

    def check(label, cond, extra=""):
        nonlocal fails
        print(("OK   " if cond else "FAIL ") + label + (" " + str(extra) if extra and not cond else ""))
        fails += 0 if cond else 1

    owner, to = session("Разработчик")
    user, tu = session("Покупатель")

    def god(text):
        req("POST", "/v1/chats/%s/messages" % BOTGOD, to, {"text": text})
        return (jbody(req("GET", "/v1/chats/%s/messages?peek=1" % BOTGOD, to)[1]) or {}).get("messages", [])[-1]["text"]

    god("/newbot"); god("Магазин")
    m = re.search(r"\n([0-9a-f]{12}:[A-Za-z0-9_\-]+)\n", god("lib_shop_bot"))
    token = m.group(1) if m else ""
    check("бот создан в BotGod", bool(token))

    bot = Bot(token, server=SERVER)
    dp = build_dispatcher()
    loop = asyncio.new_event_loop()
    th = threading.Thread(target=lambda: loop.run_until_complete(dp.start_polling(bot, polling_timeout=3)), daemon=True)
    th.start()
    bot_id = None
    for _ in range(50):
        if bot._me:
            bot_id = bot._me.id
            break
        time.sleep(0.1)
    check("start_polling: get_me", bool(bot_id))

    def last_from_bot(n=1, wait=6.0, pred=None):
        end = time.time() + wait
        while time.time() < end:
            msgs = (jbody(req("GET", "/v1/chats/%s/messages" % bot_id, tu)[1]) or {}).get("messages", [])
            mine = [x for x in msgs if not x["mine"]]
            if mine and (pred is None or pred(mine[-1])):
                return mine[-1], msgs
            time.sleep(0.2)
        return None, []

    req("POST", "/v1/chats/%s/messages" % bot_id, tu, {"text": "/start promo7"})
    reply, _ = last_from_bot(pred=lambda x: x["text"].startswith("Привет"))
    check("/start с параметром → приветствие с кнопками",
          reply and "Промокод: promo7" in reply["text"] and len(reply.get("markup", [[]])[0]) == 2, reply)

    if reply:
        s, b, _ = req("POST", "/v1/messages/%s/callback" % reply["id"], tu, {"data": reply["markup"][0][0]["callback_data"]})
        check("нажатие кнопки → ответ «Сколько штук?»", (jbody(b) or {}).get("text") == "Сколько штук?", b[:200])
        edited, _ = last_from_bot(pred=lambda x: x["text"].startswith("Выбран"))
        check("сообщение изменено, кнопки убраны", edited and not edited.get("markup"), edited)

    req("POST", "/v1/chats/%s/messages" % bot_id, tu, {"text": "3"})
    order, _ = last_from_bot(pred=lambda x: x["text"].startswith("Заказ"))
    check("FSM: «Заказ: товар 1 × 3»", order and order["text"] == "Заказ: товар 1 × 3", order)
    s, b, _ = req("GET", "/v1/chats/%s/messages" % bot_id, tu)
    kb = (jbody(b) or {}).get("bot_keyboard") or {}
    check("клавиатура бота пришла", [k["text"] for k in (kb.get("keyboard") or [[]])[0]] == ["Ещё", "Хватит"], kb)

    req("POST", "/v1/chats/%s/messages" % bot_id, tu, {"text": "как дела"})
    echo, _ = last_from_bot(pred=lambda x: x["text"].startswith("Эхо"))
    check("эхо вне диалога", echo and echo["text"] == "Эхо: как дела", echo)

    # человек присылает фото — бот скачивает его (getFile) и пересылает по file_id
    s, b, _ = req("POST", "/v1/media?kind=image&w=8&h=8", tu, raw=JPEG, ctype="image/jpeg")
    mid = (jbody(b) or {}).get("id")
    req("POST", "/v1/chats/%s/messages" % bot_id, tu, {"text": "", "attachments": [{"type": "photo", "media_id": mid}]})
    got, _ = last_from_bot(wait=8, pred=lambda x: x["text"].startswith("Получил"))
    check("фото: скачал и прислал обратно", got and got["text"] == f"Получил {len(JPEG)} байт"
          and got["attachments"][0]["type"] == "photo", got)

    req("POST", "/v1/chats/%s/messages" % bot_id, tu, {"text": "/pic"})
    pic, _ = last_from_bot(pred=lambda x: x["text"] == "Картинка из памяти")
    check("send_photo(BufferedInputFile)", pic and pic["attachments"][0]["type"] == "photo", pic)

    loop.call_soon_threadsafe(dp.stop_polling)
    th.join(10)
    check("остановка polling", not th.is_alive())
    print("FAILS: %d" % fails)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
