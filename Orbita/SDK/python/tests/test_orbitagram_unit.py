"""Тесты библиотеки без сервера: роутинг, фильтры, FSM, CallbackData, клавиатуры, middleware, ошибки, вебхук.
Запуск: python3 -m unittest tests/test_orbitagram_unit.py (из папки SDK/python)"""
import asyncio
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from orbitagram import (BaseMiddleware, Bot, CallbackData, Command, CommandStart, Dispatcher, F, FSMContext,
                        InlineKeyboardBuilder, ReplyKeyboardBuilder, Router, SkipHandler, State, StatesGroup)
from orbitagram.exceptions import Forbidden, NetworkError
from orbitagram.filters import ExceptionTypeFilter
from orbitagram.session import BaseSession
from orbitagram.types import BufferedInputFile, CallbackQuery, Message
from orbitagram.webhook import handle_webhook_request


class FakeSession(BaseSession):
    def __init__(self):
        self.calls = []
        self.fail = {}

    async def post(self, url, data, files, timeout):
        method = url.rsplit("/", 1)[-1]
        self.calls.append((method, data, files))
        if method in self.fail:
            code, desc = self.fail[method]
            return code, json.dumps({"ok": False, "description": desc}).encode()
        if method == "getMe":
            result = {"id": "bot1", "is_bot": True, "first_name": "Test", "username": "test_bot"}
        elif method.startswith("send") and method != "sendChatAction":
            result = {"message_id": "m%d" % len(self.calls), "date": 1, "chat": {"id": data["chat_id"]},
                      "text": data.get("text")}
        else:
            result = True
        return 200, json.dumps({"ok": True, "result": result}).encode()

    def sent(self, method="sendMessage"):
        return [d for m, d, _ in self.calls if m == method]


def msg(text, uid="u1", mid="1"):
    return {"update_id": 1, "message": {"message_id": mid, "date": 1, "chat": {"id": uid, "type": "private"},
                                        "from": {"id": uid, "first_name": "Ann"}, "text": text}}


def cb(data, uid="u1"):
    return {"update_id": 2, "callback_query": {"id": "q1", "from": {"id": uid, "first_name": "Ann"}, "data": data,
                                               "message": {"message_id": "m0", "date": 1, "chat": {"id": uid}}}}


class Form(StatesGroup):
    name = State()
    age = State()


class BuyCb(CallbackData, prefix="buy"):
    item: int
    qty: int = 1


def run(coro):
    return asyncio.run(coro)


class Base(unittest.TestCase):
    def setUp(self):
        self.session = FakeSession()
        self.bot = Bot("abc:def", server="http://srv", session=self.session)
        self.dp = Dispatcher()

    def feed(self, update):
        return run(self.dp.feed_raw_update(self.bot, update))


class TestRouting(Base):
    def test_command_and_echo(self):
        @self.dp.message(CommandStart())
        async def start(message: Message, command):
            await message.answer("start:" + (command.args or ""))

        @self.dp.message(Command("help", "info"))
        async def help_(message: Message):
            await message.answer("help")

        @self.dp.message(F.text)
        async def echo(message: Message):
            await message.reply(message.text)

        self.feed(msg("/start"))
        self.feed(msg("/start promo42"))
        self.feed(msg("/info"))
        self.feed(msg("привет"))
        texts = [d["text"] for d in self.session.sent()]
        self.assertEqual(texts, ["start:", "start:promo42", "help", "привет"])
        self.assertEqual(self.session.sent()[-1]["reply_to_message_id"], "1")

    def test_deep_link_and_mention(self):
        @self.dp.message(CommandStart(deep_link=True))
        async def deep(message, command):
            await message.answer("deep " + command.args)

        @self.dp.message(Command("start"))
        async def plain(message):
            await message.answer("plain")

        self.feed(msg("/start"))
        self.feed(msg("/start ref_7"))
        self.feed(msg("/start@other_bot"))           # не нам — не срабатывает
        self.assertEqual([d["text"] for d in self.session.sent()], ["plain", "deep ref_7"])

    def test_magic_as_and_routers(self):
        admin = Router(name="admin")
        admin.message.filter(F.from_user.id == "boss")

        @admin.message(Command("stats"))
        async def stats(message):
            await message.answer("stats")

        @self.dp.message(F.text.regexp(r"^(\d{4})$").as_("code"))
        async def code(message, code):
            await message.answer("code " + code.group(1))

        @self.dp.message()
        async def fallback(message):
            await message.answer("?")

        self.dp.include_router(admin)
        self.feed(msg("1234"))
        self.feed(msg("/stats", uid="boss"))
        self.feed(msg("/stats", uid="nobody"))
        # обработчик dp «fallback» ловит всё раньше роутера — порядок как в aiogram
        self.assertEqual([d["text"] for d in self.session.sent()], ["code 1234", "?", "?"])

    def test_router_order_and_skip(self):
        r = Router()

        @r.message(Command("stats"))
        async def first(message):
            raise SkipHandler

        @r.message(Command("stats"))
        async def second(message):
            await message.answer("second")

        self.dp.include_router(r)
        self.feed(msg("/stats"))
        self.assertEqual([d["text"] for d in self.session.sent()], ["second"])

    def test_dependency_injection(self):
        self.dp["db"] = {"users": 5}

        @self.dp.message(Command("count"))
        async def count(message, db, bot, event_from_user):
            await bot.send_message(message.chat.id, f"{db['users']} {event_from_user.first_name}")

        self.feed(msg("/count"))
        self.assertEqual(self.session.sent()[0]["text"], "5 Ann")


class TestFSM(Base):
    def test_dialog(self):
        @self.dp.message(Command("form"))
        async def start(message, state: FSMContext):
            await state.set_state(Form.name)
            await message.answer("name?")

        @self.dp.message(Form.name)
        async def name(message, state: FSMContext):
            await state.update_data(name=message.text)
            await state.set_state(Form.age)
            await message.answer("age?")

        @self.dp.message(Form.age, F.text.cast(int) > 0)
        async def age(message, state: FSMContext):
            data = await state.update_data(age=int(message.text))
            await state.clear()
            await message.answer(f"{data['name']} {data['age']}")

        @self.dp.message(Form.age)
        async def bad_age(message):
            await message.answer("number!")

        @self.dp.message()
        async def other(message):
            await message.answer("other")

        for t in ["/form", "Ann", "abc", "30", "hi"]:
            self.feed(msg(t))
        self.assertEqual([d["text"] for d in self.session.sent()], ["name?", "age?", "number!", "Ann 30", "other"])

    def test_states_group_contains(self):
        self.assertIn(Form.name, Form)
        self.assertEqual(Form.name.state, "Form:name")


class TestCallbacks(Base):
    def test_callback_data_and_auto_answer(self):
        @self.dp.callback_query(BuyCb.filter(F.qty > 1))
        async def many(call: CallbackQuery, callback_data: BuyCb):
            await call.answer(f"много {callback_data.item}", show_alert=True)

        @self.dp.callback_query(BuyCb.filter())
        async def one(call: CallbackQuery, callback_data: BuyCb):
            await call.message.answer(f"one {callback_data.item}")           # не ответили на нажатие

        self.feed(cb(BuyCb(item=7, qty=3).pack()))
        self.feed(cb(BuyCb(item=8).pack()))
        answers = self.session.sent("answerCallbackQuery")
        self.assertEqual(answers[0]["text"], "много 7")
        self.assertTrue(answers[0]["show_alert"])
        self.assertEqual(len(answers), 2)                                  # второй — автоответ библиотеки
        self.assertEqual(self.session.sent()[0]["text"], "one 8")

    def test_pack_unpack(self):
        p = BuyCb(item=5, qty=2).pack()
        self.assertEqual(p, "buy:5:2")
        self.assertEqual(BuyCb.unpack(p), BuyCb(item=5, qty=2))
        with self.assertRaises(ValueError):
            BuyCb.unpack("sell:1:1")


class TestKeyboards(unittest.TestCase):
    def test_inline_adjust(self):
        kb = InlineKeyboardBuilder()
        for i in range(5):
            kb.button(text=str(i), callback_data=BuyCb(item=i))
        kb.button(text="site", url="https://example.com")
        kb.adjust(2, 3, 1)
        rows = kb.as_markup().to_dict()["inline_keyboard"]
        self.assertEqual([len(r) for r in rows], [2, 3, 1])
        self.assertEqual(rows[0][0]["callback_data"], "buy:0:1")
        self.assertEqual(rows[2][0], {"text": "site", "url": "https://example.com"})

    def test_reply(self):
        kb = ReplyKeyboardBuilder()
        for t in ("a", "b", "c"):
            kb.button(text=t)
        m = kb.adjust(2).as_markup(one_time_keyboard=True).to_dict()
        self.assertEqual(m["keyboard"], [[{"text": "a"}, {"text": "b"}], [{"text": "c"}]])
        self.assertTrue(m["one_time_keyboard"] and m["resize_keyboard"])


class TestMiddlewareErrors(Base):
    def test_middlewares(self):
        log = []

        class Outer(BaseMiddleware):
            async def __call__(self, handler, event, data):
                log.append("outer")
                if event.text == "spam":
                    return None
                data["user_role"] = "vip"
                return await handler(event, data)

        @self.dp.message.middleware()
        async def inner(handler, event, data):
            log.append("inner")
            return await handler(event, data)

        self.dp.message.outer_middleware(Outer())

        @self.dp.message()
        async def h(message, user_role):
            await message.answer(user_role)

        self.feed(msg("hi"))
        self.feed(msg("spam"))
        self.assertEqual(log, ["outer", "inner", "outer"])
        self.assertEqual([d["text"] for d in self.session.sent()], ["vip"])

    def test_errors(self):
        self.session.fail["sendMessage"] = (403, "Forbidden: bot was blocked by the user")
        caught = []

        @self.dp.message()
        async def h(message):
            await message.answer("x")

        @self.dp.errors(ExceptionTypeFilter(Forbidden))
        async def on_forbidden(event):
            caught.append(type(event.exception).__name__)

        self.feed(msg("hi"))
        self.assertEqual(caught, ["Forbidden"])

    def test_files_multipart(self):
        @self.dp.message(F.text == "pic")
        async def h(message):
            await message.answer_photo(BufferedInputFile(b"\x89PNG....", "a.png"), caption="cap")

        self.feed(msg("pic"))
        method, data, files = self.session.calls[-1]
        self.assertEqual(method, "sendPhoto")
        self.assertEqual(files["photo"][0], "a.png")
        self.assertEqual(files["photo"][2], "image/png")


class TestWebhook(Base):
    def test_secret(self):
        got = []

        @self.dp.message()
        async def h(message):
            got.append(message.text)

        async def go():
            body = json.dumps(msg("via hook")).encode()
            bad = await handle_webhook_request(self.dp, self.bot, body, {}, "s3", background=False)
            ok = await handle_webhook_request(self.dp, self.bot, body, {"X-Orbita-Bot-Api-Secret-Token": "s3"}, "s3",
                                              background=False)
            return bad, ok

        self.assertEqual(run(go()), (401, 200))
        self.assertEqual(got, ["via hook"])


class TestPolling(Base):
    def test_polling_and_stop(self):
        updates = [[msg("/start")], []]

        class PollSession(FakeSession):
            async def post(s, url, data, files, timeout):
                if url.endswith("/getUpdates"):
                    s.calls.append(("getUpdates", data, None))
                    batch = updates.pop(0) if updates else []
                    if not batch:
                        await asyncio.sleep(0.05)
                    return 200, json.dumps({"ok": True, "result": batch}).encode()
                return await FakeSession.post(s, url, data, files, timeout)

        self.session = PollSession()
        self.bot = Bot("abc:def", server="http://srv", session=self.session)
        started = []

        @self.dp.startup()
        async def on_start(bot):
            started.append(bot)

        @self.dp.message(CommandStart())
        async def start(message):
            await message.answer("hi")
            self.dp.stop_polling()

        run(asyncio.wait_for(self.dp.start_polling(self.bot, polling_timeout=1), 5))
        self.assertEqual(started, [self.bot])
        self.assertEqual(self.session.sent()[0]["text"], "hi")
        offsets = [d.get("offset") for m, d, _ in self.session.calls if m == "getUpdates"]
        self.assertIn(2, offsets)                                        # update_id 1 + 1


class TestErrorsMapping(unittest.TestCase):
    def test_network(self):
        class Down(BaseSession):
            async def post(self, *a):
                raise NetworkError("down")
        bot = Bot("a:b", server="http://x", session=Down(), retries=0)
        with self.assertRaises(NetworkError):
            run(bot.get_me())

    def test_bad_token(self):
        with self.assertRaises(ValueError):
            Bot("nocolon", server="http://x")


if __name__ == "__main__":
    unittest.main(verbosity=1)
