"""Магазин: каталог на кнопках (CallbackData), корзина в FSM, оформление заказа по шагам,
команды в меню «/», роутеры, антиспам и админская команда.

    ORBITA_SERVER=… BOT_TOKEN=… ADMIN_ID=<ваш id> python orbita_shop_bot.py

Чтобы получать уведомления о заказах, админ тоже должен один раз нажать «Старт» у бота:
бот не может написать человеку первым.
"""
import os

from orbitagram import (Bot, CallbackData, Dispatcher, F, FSMContext, InlineKeyboardBuilder, JSONFileStorage,
                        ReplyKeyboardBuilder, Router, State, StatesGroup, ThrottlingMiddleware)
from orbitagram.exceptions import Forbidden
from orbitagram.filters import Command, CommandStart, ExceptionTypeFilter
from orbitagram.keyboards import remove_keyboard
from orbitagram.types import BotCommand, CallbackQuery, ErrorEvent, Message

CATALOG = {1: ("🍎 Яблоки", 120), 2: ("🍐 Груши", 150), 3: ("🍌 Бананы", 90), 4: ("🍇 Виноград", 300)}
ADMIN_ID = os.environ.get("ADMIN_ID", "")
ORDERS: list[dict] = []


class Item(CallbackData, prefix="item"):
    id: int


class Cart(CallbackData, prefix="cart"):
    action: str            # add | remove | checkout


class Checkout(StatesGroup):
    name = State()
    phone = State()
    confirm = State()


shop = Router(name="shop")
admin = Router(name="admin")
admin.message.filter(F.from_user.id == ADMIN_ID)


def catalog_kb():
    kb = InlineKeyboardBuilder()
    for item_id, (title, price) in CATALOG.items():
        kb.button(text=f"{title} — {price} ₽", callback_data=Item(id=item_id))
    kb.button(text="🛒 Корзина", callback_data=Cart(action="show"))
    return kb.adjust(1).as_markup()


@shop.message(CommandStart())
async def start(message: Message, command):
    text = f"Здравствуйте, {message.from_user.first_name}! Выберите товар:"
    if command.args:
        text = f"Вас пригласил друг (код {command.args}) — скидка 10%!\n\n" + text
    await message.answer(text, reply_markup=catalog_kb())


@shop.message(Command("catalog"))
async def catalog(message: Message):
    await message.answer("Каталог:", reply_markup=catalog_kb())


@shop.callback_query(Item.filter())
async def add_item(call: CallbackQuery, callback_data: Item, state: FSMContext):
    data = await state.get_data()
    cart = data.get("cart", {})
    key = str(callback_data.id)
    cart[key] = cart.get(key, 0) + 1
    await state.update_data(cart=cart)
    title, _ = CATALOG[callback_data.id]
    await call.answer(f"{title}: в корзине {cart[key]} шт.")


def cart_text(cart: dict) -> tuple[str, int]:
    lines, total = [], 0
    for key, qty in cart.items():
        title, price = CATALOG[int(key)]
        lines.append(f"{title} × {qty} = {price * qty} ₽")
        total += price * qty
    return "\n".join(lines), total


@shop.callback_query(Cart.filter(F.action == "show"))
async def show_cart(call: CallbackQuery, state: FSMContext):
    cart = (await state.get_data()).get("cart", {})
    if not cart:
        await call.answer("Корзина пуста", show_alert=True)
        return
    text, total = cart_text(cart)
    kb = InlineKeyboardBuilder()
    kb.button(text="✅ Оформить", callback_data=Cart(action="checkout"))
    kb.button(text="🗑 Очистить", callback_data=Cart(action="clear"))
    kb.button(text="← Каталог", callback_data=Cart(action="back"))
    await call.message.edit_text(f"Корзина:\n{text}\n\nИтого: {total} ₽", reply_markup=kb.adjust(2, 1).as_markup())


@shop.callback_query(Cart.filter(F.action == "clear"))
async def clear_cart(call: CallbackQuery, state: FSMContext):
    await state.update_data(cart={})
    await call.message.edit_text("Корзина очищена. Каталог:", reply_markup=catalog_kb())


@shop.callback_query(Cart.filter(F.action == "back"))
async def back(call: CallbackQuery):
    await call.message.edit_text("Каталог:", reply_markup=catalog_kb())


@shop.callback_query(Cart.filter(F.action == "checkout"))
async def checkout(call: CallbackQuery, state: FSMContext):
    await state.set_state(Checkout.name)
    await call.message.edit_reply_markup(None)
    await call.message.answer("Как вас зовут?")


@shop.message(Command("cancel"), Checkout)          # Checkout — любой шаг этого диалога
async def cancel(message: Message, state: FSMContext):
    cart = (await state.get_data()).get("cart", {})
    await state.set_state(None)
    await state.set_data({"cart": cart})
    await message.answer("Оформление отменено, корзина сохранена.", reply_markup=remove_keyboard())


@shop.message(Checkout.name, F.text.len() >= 2)
async def got_name(message: Message, state: FSMContext):
    await state.update_data(name=message.text)
    await state.set_state(Checkout.phone)
    await message.answer("Ваш телефон? (например, +79991234567)")


@shop.message(Checkout.phone, F.text.regexp(r"^\+?\d{10,15}$"))
async def got_phone(message: Message, state: FSMContext):
    data = await state.update_data(phone=message.text)
    text, total = cart_text(data["cart"])
    await state.set_state(Checkout.confirm)
    kb = ReplyKeyboardBuilder()
    kb.button(text="Подтвердить"); kb.button(text="Отмена")
    await message.answer(f"{data['name']}, {data['phone']}\n{text}\nИтого: {total} ₽\n\nВсё верно?",
                         reply_markup=kb.as_markup(one_time_keyboard=True))


@shop.message(Checkout.phone)
async def bad_phone(message: Message):
    await message.answer("Это не похоже на номер. Попробуйте ещё раз или /cancel")


@shop.message(Checkout.confirm, F.text == "Подтвердить")
async def confirm(message: Message, state: FSMContext, bot: Bot):
    data = await state.get_data()
    ORDERS.append({"user": message.from_user.id, **data})
    await state.clear()
    await message.answer(f"Заказ №{len(ORDERS)} принят! Мы позвоним в течение часа.", reply_markup=remove_keyboard())
    if ADMIN_ID:
        await bot.send_message(ADMIN_ID, f"🆕 Заказ №{len(ORDERS)} от {data['name']} ({data['phone']})")


@shop.message(Checkout.confirm)
async def not_confirmed(message: Message, state: FSMContext):
    await cancel(message, state)


@admin.message(Command("orders"))
async def orders(message: Message):
    await message.answer("\n".join(f"№{i + 1}: {o['name']}, {o['phone']}" for i, o in enumerate(ORDERS)) or "Заказов нет")


async def on_startup(bot: Bot):
    await bot.set_my_commands([BotCommand(command="start", description="Начать"),
                               ("catalog", "Каталог"), ("cancel", "Отменить оформление")])
    await bot.set_my_description("Магазин фруктов: выбирайте товары кнопками и оформляйте заказ прямо в чате.")


def main():
    bot = Bot(os.environ["BOT_TOKEN"])
    dp = Dispatcher(storage=JSONFileStorage("shop_fsm.json"))   # корзины переживают перезапуск
    dp.message.outer_middleware(ThrottlingMiddleware(rate=0.4))
    dp.include_routers(admin, shop)
    dp.startup.register(on_startup)

    @dp.errors(ExceptionTypeFilter(Forbidden))
    async def blocked(event: ErrorEvent):
        print("Не могу написать (человек не нажимал «Старт» или заблокировал бота):", event.exception)

    dp.run_polling(bot)


if __name__ == "__main__":
    main()
