# orbitagram — боты для Orbita на Python

Асинхронная библиотека в духе **aiogram 3**: декораторы-обработчики, фильтры и магический `F`, роутеры,
состояния (FSM), сборщики клавиатур, `CallbackData`, middleware, long-polling и вебхуки.
Без внешних зависимостей — нужен только Python 3.9+.

```python
from orbitagram import Bot, Dispatcher, F
from orbitagram.filters import CommandStart
from orbitagram.types import Message

bot = Bot("12ab34cd56ef:ваш-секрет", server="https://orbita.example.com")
dp = Dispatcher()

@dp.message(CommandStart())
async def start(message: Message):
    await message.answer(f"Привет, {message.from_user.first_name}!")

@dp.message(F.text)
async def echo(message: Message):
    await message.answer(message.text)

dp.run_polling(bot)
```

---

## 1. Как создать бота

1. В Orbita откройте **@botgod** → `/newbot` → имя → username (латиница, оканчивается на `bot`).
2. BotGod пришлёт **токен** вида `12ab34cd56ef:Xy…`. Храните его в секрете (`/revoke` — выпустить новый).
3. Там же: `/setdescription` («Что умеет этот бот?»), `/setdescriptionpic` (баннер), `/setuserpic` (аватарка).
4. Установите библиотеку и запустите код:

```bash
pip install ./SDK/python          # из репозитория Orbita
export ORBITA_SERVER=https://orbita.example.com
export BOT_TOKEN=12ab34cd56ef:…
python SDK/python/examples/orbita_echo_bot.py
```

> Бот не может написать человеку первым: сначала человек должен нажать «Старт» в переписке с ботом.

## 2. Обработчики и фильтры

```python
@dp.message(Command("help"))                         # /help
@dp.message(Command("buy", "order"))                 # любая из команд
@dp.message(CommandStart(deep_link=True))            # пришёл по ссылке ?start=… (command.args)
@dp.message(F.text == "Привет")
@dp.message(F.photo)                                 # фото / F.document / F.voice / F.video / F.sticker / F.location
@dp.message(F.text.lower().contains("цена"))
@dp.message(F.text.regexp(r"^\d{4}$").as_("code"))   # match придёт аргументом code
@dp.message(F.from_user.id.in_(ADMINS))
@dp.message(F.text.cast(int) > 18)                   # не число — фильтр просто не пройдёт
@dp.callback_query(F.data == "yes")
@dp.callback_query(F.data.startswith("page:"))
```

Фильтры через запятую — это «И». Комбинации: `F.photo | F.document`, `~F.text`, `Command("ban") & IsAdmin()`.
Свой фильтр — функция или класс:

```python
from orbitagram import Filter

class IsAdmin(Filter):
    async def __call__(self, message, **data) -> bool:
        return message.from_user.id in ADMINS

@dp.message(Command("stats"), IsAdmin())
```

Фильтр может вернуть словарь — его ключи придут в обработчик аргументами.

**Аргументы обработчика** подставляются по именам — объявите только нужные:

| имя | что это |
|---|---|
| первый аргумент | событие: `Message` или `CallbackQuery` |
| `bot` | `Bot` |
| `state` | `FSMContext` — состояние этого человека |
| `raw_state` | имя текущего состояния (строка или `None`) |
| `command` | `CommandObject` (`command.args`, `command.command`) — от `Command`/`CommandStart` |
| `callback_data` | распакованный `CallbackData` — от `MyCb.filter()` |
| `event_from_user`, `event_chat`, `event_update` | кто, где, исходное обновление |
| ваши | `dp["db"] = db` → аргумент `db`; ключи из middleware и фильтров |

Обработчики проверяются по порядку регистрации, срабатывает первый подошедший.
`raise SkipHandler` — отдать событие следующему.

## 3. Ответы и методы

```python
await message.answer("текст", reply_markup=kb)        # в тот же чат
await message.reply("цитатой")
await message.answer_photo(FSInputFile("cat.jpg"), caption="Кот")
await message.answer_document(BufferedInputFile(pdf_bytes, "report.pdf"))
await message.answer_photo("https://example.com/a.jpg") # сервер скачает сам (только публичные адреса)
await message.answer_photo(message.photo[-1].file_id)   # переслать полученный файл
await message.answer_voice(...) / answer_video / answer_animation / answer_audio / answer_video_note / answer_sticker
await message.answer_chat_action("typing")             # «печатает…»
await message.edit_text("новый текст", reply_markup=None)   # своё сообщение
await message.delete()
data = await message.download()                        # байты файла из сообщения
await message.download("downloads/")                    # или сохранить на диск

await call.answer("Готово")                             # подсказка на нажатие
await call.answer("Внимание!", show_alert=True)          # окно
await call.message.edit_text("Выбрано ✅")
```

Те же методы есть у `bot`: `send_message`, `send_photo`, `send_document`, `send_video`, `send_animation`,
`send_audio`, `send_voice`, `send_video_note`, `send_sticker`, `send_chat_action`, `edit_message_text`,
`edit_message_caption`, `edit_message_reply_markup`, `delete_message`, `answer_callback_query`, `get_file`,
`download`, `get_chat`, `get_me`, `set_my_commands`, `get_my_commands`, `set_my_description`, `set_webhook`,
`delete_webhook`, `get_webhook_info`. Любой метод Bot API: `await bot.request("methodName", **params)`.

Ссылка на бота с параметром: `bot.start_link("ref_42")` → `https://…/u/my_bot?start=ref_42`.

> Если обработчик не ответил на нажатие кнопки, библиотека сама отправит пустой ответ, поэтому
> у человека не будет висеть «ожидание». Отключить: `Dispatcher(auto_answer_callbacks=False)`.

## 4. Клавиатуры

```python
from orbitagram import InlineKeyboardBuilder, ReplyKeyboardBuilder
from orbitagram.keyboards import remove_keyboard

kb = InlineKeyboardBuilder()
kb.button(text="Да", callback_data="yes")
kb.button(text="Нет", callback_data="no")
kb.button(text="Сайт", url="https://example.com")
kb.adjust(2, 1)                       # 2 кнопки в первом ряду, дальше по 1
await message.answer("Продолжить?", reply_markup=kb.as_markup())

menu = ReplyKeyboardBuilder()         # кнопки вместо клавиатуры: нажатие отправляет текст кнопки
for t in ("🛒 Корзина", "📦 Заказы", "ℹ️ Помощь"):
    menu.button(text=t)
await message.answer("Меню", reply_markup=menu.adjust(2).as_markup(one_time_keyboard=False))
await message.answer("Убрал меню", reply_markup=remove_keyboard())
```

## 5. CallbackData — данные кнопок без ручных строк

```python
from orbitagram import CallbackData

class ProductCb(CallbackData, prefix="product"):
    id: int
    action: str = "view"

kb.button(text="Купить", callback_data=ProductCb(id=42, action="buy"))

@dp.callback_query(ProductCb.filter(F.action == "buy"))
async def buy(call: CallbackQuery, callback_data: ProductCb):
    await call.answer(f"Товар {callback_data.id} в корзине")
```

Типы полей: `str`, `int`, `float`, `bool`, `Enum`, `Optional[...]`. Предел — 64 байта после упаковки.

## 6. Состояния (FSM): пошаговые диалоги

```python
from orbitagram import State, StatesGroup, FSMContext

class Signup(StatesGroup):
    name = State()
    age = State()

@dp.message(Command("signup"))
async def begin(message: Message, state: FSMContext):
    await state.set_state(Signup.name)
    await message.answer("Как вас зовут?")

@dp.message(Signup.name)
async def name(message: Message, state: FSMContext):
    await state.update_data(name=message.text)
    await state.set_state(Signup.age)
    await message.answer("Сколько вам лет?")

@dp.message(Signup.age, F.text.cast(int) > 0)
async def age(message: Message, state: FSMContext):
    data = await state.update_data(age=int(message.text))
    await state.clear()
    await message.answer(f"Готово: {data['name']}, {data['age']}")

@dp.message(Signup.age)
async def age_wrong(message: Message):
    await message.answer("Введите число")
```

Фильтр по состоянию: `Signup.name`, вся группа `Signup`, `StateFilter(None)` — вне диалога, `StateFilter("*")` — в любом.
Хранилище: `MemoryStorage` (по умолчанию) или `JSONFileStorage("fsm.json")` — переживает перезапуск.
Своё хранилище (Redis, БД) — наследник `BaseStorage` с четырьмя методами.

## 7. Роутеры — большой бот по файлам

```python
# handlers/admin.py
router = Router(name="admin")
router.message.filter(F.from_user.id.in_(ADMINS))     # все обработчики роутера — только для админов

@router.message(Command("stats"))
async def stats(message: Message): ...

# main.py
dp.include_routers(admin.router, shop.router)
```

Порядок: сначала обработчики самого роутера, потом подключённых, в порядке подключения.

## 8. Middleware

```python
from orbitagram import BaseMiddleware, ThrottlingMiddleware

class DbMiddleware(BaseMiddleware):
    async def __call__(self, handler, event, data):
        async with pool.acquire() as conn:
            data["db"] = conn                  # аргумент db во всех обработчиках
            return await handler(event, data)

dp.message.middleware(DbMiddleware())                     # после фильтров, только для подошедших
dp.message.outer_middleware(ThrottlingMiddleware(0.5))    # до фильтров: антиспам, не чаще раза в 0,5 с
```

Не вызвали `handler` — событие дальше не идёт.

## 9. Ошибки

```python
from orbitagram.exceptions import Forbidden, RetryAfter
from orbitagram.filters import ExceptionTypeFilter

@dp.errors(ExceptionTypeFilter(Forbidden))
async def blocked(event):                       # event.update, event.exception
    log.info("Человек заблокировал бота")

@dp.errors()
async def any_error(event):
    log.exception("Ошибка", exc_info=event.exception)
```

Классы: `BadRequest` (400), `Unauthorized` (401, неверный токен), `Forbidden` (403, «Старт» не нажат или бот заблокирован),
`NotFound`, `Conflict`, `RetryAfter` (429, повторяется автоматически), `ServerError`, `NetworkError`.

## 10. Запуск и вебхук

```python
dp.run_polling(bot)                                   # синхронно, до Ctrl+C
await dp.start_polling(bot, polling_timeout=25)       # внутри своего asyncio
dp.startup.register(on_startup)                       # async def on_startup(bot): await bot.set_my_commands(...)
dp.shutdown.register(on_shutdown)
```

События одного чата обрабатываются строго по очереди (диалоги не путаются), разных чатов — параллельно.

**Вебхук** (сервер Orbita сам присылает обновления; нужен публичный https-адрес и прокси перед процессом):

```python
dp.run_webhook(bot, url="https://bot.example.com/orbita", path="/orbita",
               host="127.0.0.1", port=8081, secret_token="длинный-секрет")
```

Свой веб-фреймворк (FastAPI/aiohttp/Django):

```python
from orbitagram.webhook import handle_webhook_request

@app.post("/orbita")
async def hook(request: Request):
    code = await handle_webhook_request(dp, bot, await request.body(), request.headers, secret_token=SECRET)
    return Response(status_code=code)
```

Сервер подписывает запросы заголовком `X-Orbita-Bot-Api-Secret-Token`.

**Как держать бота запущенным** (systemd):

```ini
[Service]
Environment=ORBITA_SERVER=https://orbita.example.com BOT_TOKEN=…
ExecStart=/usr/bin/python3 /opt/mybot/bot.py
Restart=always
```

## 11. Отличия от Telegram и aiogram

- Идентификаторы (`chat.id`, `from_user.id`, `message_id`, `file_id`) — **строки**, не числа.
- Сейчас боты работают в личных чатах (`chat.type == "private"`).
- `parse_mode` (HTML/Markdown) пока нет: текст уходит как есть.
- Нажатие кнопки ждёт ответа бота около 6 секунд, поэтому `call.answer()` стоит вызывать первым.
- Внешних зависимостей нет: запросы идут через `urllib` в потоках. Свой транспорт — наследник `session.BaseSession`.

## 12. Примеры и тесты

- `examples/orbita_echo_bot.py` — эхо и фото;
- `examples/orbita_shop_bot.py` — магазин: каталог на кнопках, корзина, оформление по шагам, роутеры, антиспам, админка;
- `examples/orbita_webhook_bot.py` — вебхук.

Тесты:

```bash
cd SDK/python
python3 -m unittest tests/test_orbitagram_unit.py   # без сервера
python3 tests/test_orbitagram_live.py               # с запущенным Server/server.py (ORBITA_SERVER)
```
