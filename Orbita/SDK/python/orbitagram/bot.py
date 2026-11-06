"""Bot — клиент Bot API Orbita. Все методы асинхронные:

    bot = Bot("12ab34cd56ef:секрет", server="https://orbita.example.com")
    await bot.send_message(chat_id, "Привет!")
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
from typing import Any, Iterable, Optional

from .exceptions import NetworkError, RetryAfter, error_for
from .session import BaseSession, UrllibSession
from .types import (BotCommand, File, InlineKeyboardMarkup, InputFile, Message, OrbitaObject, ReplyMarkup, Update,
                    URLInputFile, User, WebhookInfo)

log = logging.getLogger("orbitagram")


class Bot:
    def __init__(self, token: str, server: str | None = None, *, session: BaseSession | None = None,
                 timeout: float = 30, retries: int = 2):
        """token — из BotGod (/newbot или /token). server — адрес сервера Orbita (или переменная ORBITA_SERVER)."""
        token = (token or "").strip()
        if ":" not in token:
            raise ValueError("Неверный токен: возьмите его у @botgod (/newbot или /token)")
        server = (server or os.environ.get("ORBITA_SERVER") or "").strip().rstrip("/")
        if not server:
            raise ValueError("Укажите адрес сервера: Bot(token, server='https://…') или переменную ORBITA_SERVER")
        if not server.startswith(("http://", "https://")):
            server = "https://" + server
        self.token = token
        self.server = server
        self.session = session or UrllibSession()
        self.timeout = timeout
        self.retries = retries
        self._me: User | None = None

    def __repr__(self) -> str:
        return f"<Bot {self.token.split(':')[0]} @ {self.server}>"

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        await self.close()

    async def close(self) -> None:
        await self.session.close()

    @property
    def id(self) -> str:
        """Идентификатор бота (после первого get_me) — иначе начало токена"""
        return self._me.id if self._me else self.token.split(":")[0]

    # ---------------------------------------------------------------- запрос

    async def request(self, method: str, *, request_timeout: float | None = None, **params) -> Any:
        """Вызвать любой метод Bot API: await bot.request("sendMessage", chat_id=…, text=…)"""
        data, files = {}, {}
        for k, v in params.items():
            if v is None:
                continue
            if isinstance(v, URLInputFile):
                data[k] = v.url
            elif isinstance(v, InputFile):
                content = await asyncio.to_thread(v.read)
                files[k] = (v.filename, content, v.mime)
            elif isinstance(v, OrbitaObject):
                data[k] = v.to_dict()
            elif isinstance(v, (list, tuple)):
                data[k] = [x.to_dict() if isinstance(x, OrbitaObject) else x for x in v]
            else:
                data[k] = v
        url = f"{self.server}/bot{self.token}/{method}"
        attempt = 0
        while True:
            try:
                status, body = await self.session.post(url, data, files or None, request_timeout or self.timeout)
            except NetworkError:
                if attempt >= self.retries or method == "getUpdates":
                    raise
                attempt += 1
                await asyncio.sleep(0.5 * attempt)
                continue
            try:
                payload = json.loads(body or b"{}")
            except ValueError:
                payload = {"ok": False, "description": body[:200].decode("utf-8", "replace")}
            if status == 200 and payload.get("ok"):
                return payload.get("result")
            err = error_for(method, status, str(payload.get("description") or payload.get("error") or "error"), payload)
            if isinstance(err, RetryAfter) and attempt < self.retries:
                attempt += 1
                log.warning("%s: слишком часто, ждём %s с", method, err.retry_after)
                await asyncio.sleep(err.retry_after)
                continue
            raise err

    def _message(self, raw) -> Message:
        return Message.from_dict(raw, self)

    @staticmethod
    def _markup(markup: ReplyMarkup):
        return markup.to_dict() if isinstance(markup, OrbitaObject) else markup

    # ---------------------------------------------------------------- о боте

    async def get_me(self) -> User:
        self._me = User.from_dict(await self.request("getMe"), self)
        return self._me

    async def me(self) -> User:
        """get_me с кэшем"""
        return self._me or await self.get_me()

    async def set_my_commands(self, commands: Iterable[BotCommand | dict | tuple]) -> bool:
        """Команды в меню «/»: [BotCommand(command="start", description="Начать"), ("help", "Помощь")]"""
        items = []
        for c in commands:
            if isinstance(c, tuple):
                c = BotCommand(command=c[0], description=c[1])
            items.append(c.to_dict() if isinstance(c, BotCommand) else c)
        return await self.request("setMyCommands", commands=items)

    async def get_my_commands(self) -> list[BotCommand]:
        return [BotCommand.from_dict(c, self) for c in await self.request("getMyCommands") or []]

    async def delete_my_commands(self) -> bool:
        return await self.request("setMyCommands", commands=[])

    async def set_my_description(self, description: str) -> bool:
        """«Что умеет этот бот?» — текст на приветственном экране"""
        return await self.request("setMyDescription", description=description)

    async def get_my_description(self) -> str:
        return (await self.request("getMyDescription") or {}).get("description", "")

    # ---------------------------------------------------------------- обновления и вебхук

    async def get_updates(self, offset: int | None = None, limit: int = 100, timeout: int = 0) -> list[Update]:
        # long-poll: сервер держит запрос до timeout секунд, HTTP-таймаут — с запасом
        raw = await self.request("getUpdates", request_timeout=timeout + 15, offset=offset, limit=limit, timeout=timeout)
        return [Update.from_dict(u, self) for u in raw or []]

    async def set_webhook(self, url: str, secret_token: str | None = None, drop_pending_updates: bool = False) -> bool:
        """Включить вебхук (только https). Сервер будет присылать обновления POST-запросом с заголовком
        X-Orbita-Bot-Api-Secret-Token, если указан secret_token"""
        return await self.request("setWebhook", url=url, secret_token=secret_token,
                                  drop_pending_updates=drop_pending_updates or None)

    async def delete_webhook(self, drop_pending_updates: bool = False) -> bool:
        return await self.request("deleteWebhook", drop_pending_updates=drop_pending_updates or None)

    async def get_webhook_info(self) -> WebhookInfo:
        return WebhookInfo.from_dict(await self.request("getWebhookInfo"), self)

    # ---------------------------------------------------------------- сообщения

    async def send_message(self, chat_id: str, text: str, *, reply_markup: ReplyMarkup = None,
                           reply_to_message_id: str | None = None, disable_notification: bool | None = None) -> Message:
        return self._message(await self.request("sendMessage", chat_id=chat_id, text=text,
                                                reply_markup=self._markup(reply_markup),
                                                reply_to_message_id=reply_to_message_id,
                                                disable_notification=disable_notification))

    async def _send_file(self, method: str, field: str, chat_id: str, file, caption: str | None = None,
                         reply_markup: ReplyMarkup = None, reply_to_message_id: str | None = None,
                         disable_notification: bool | None = None, **extra) -> Message:
        return self._message(await self.request(method, chat_id=chat_id, **{field: file}, caption=caption,
                                                reply_markup=self._markup(reply_markup),
                                                reply_to_message_id=reply_to_message_id,
                                                disable_notification=disable_notification, **extra))

    async def send_photo(self, chat_id: str, photo, caption: str | None = None, **kw) -> Message:
        """photo: FSInputFile("cat.jpg"), BufferedInputFile(bytes, "a.png"), file_id или https-ссылка"""
        return await self._send_file("sendPhoto", "photo", chat_id, photo, caption, **kw)

    async def send_document(self, chat_id: str, document, caption: str | None = None, **kw) -> Message:
        return await self._send_file("sendDocument", "document", chat_id, document, caption, **kw)

    async def send_video(self, chat_id: str, video, caption: str | None = None, duration: int | None = None,
                         width: int | None = None, height: int | None = None, **kw) -> Message:
        return await self._send_file("sendVideo", "video", chat_id, video, caption, duration=duration,
                                     width=width, height=height, **kw)

    async def send_animation(self, chat_id: str, animation, caption: str | None = None, **kw) -> Message:
        """Видео без звука, которое крутится по кругу (как GIF)"""
        return await self._send_file("sendAnimation", "animation", chat_id, animation, caption, **kw)

    async def send_audio(self, chat_id: str, audio, caption: str | None = None, title: str | None = None,
                         performer: str | None = None, duration: int | None = None, **kw) -> Message:
        return await self._send_file("sendAudio", "audio", chat_id, audio, caption, title=title,
                                     performer=performer, duration=duration, **kw)

    async def send_voice(self, chat_id: str, voice, caption: str | None = None, duration: int | None = None,
                         **kw) -> Message:
        return await self._send_file("sendVoice", "voice", chat_id, voice, caption, duration=duration, **kw)

    async def send_video_note(self, chat_id: str, video_note, duration: int | None = None, **kw) -> Message:
        """Кружок"""
        return await self._send_file("sendVideoNote", "video_note", chat_id, video_note, None, duration=duration, **kw)

    async def send_sticker(self, chat_id: str, sticker, **kw) -> Message:
        """sticker: id стикера из набора (из входящего message.sticker.file_id) или PNG-файл"""
        return await self._send_file("sendSticker", "sticker", chat_id, sticker, None, **kw)

    async def send_chat_action(self, chat_id: str, action: str = "typing") -> bool:
        """«печатает…», «записывает голосовое…»: typing, upload_photo, record_voice, record_video, upload_document"""
        return await self.request("sendChatAction", chat_id=chat_id, action=action)

    async def edit_message_text(self, text: str, *, chat_id: str, message_id: str,
                                reply_markup: ReplyMarkup = None) -> Message:
        return self._message(await self.request("editMessageText", chat_id=chat_id, message_id=message_id, text=text,
                                                reply_markup=self._markup(reply_markup)))

    async def edit_message_caption(self, *, chat_id: str, message_id: str, caption: str,
                                   reply_markup: ReplyMarkup = None) -> Message:
        return self._message(await self.request("editMessageCaption", chat_id=chat_id, message_id=message_id,
                                                caption=caption, reply_markup=self._markup(reply_markup)))

    async def edit_message_reply_markup(self, *, chat_id: str, message_id: str,
                                        reply_markup: Optional[InlineKeyboardMarkup] = None) -> Message:
        """Поменять (или убрать, если None) кнопки под сообщением"""
        return self._message(await self.request("editMessageReplyMarkup", chat_id=chat_id, message_id=message_id,
                                                reply_markup=self._markup(reply_markup)))

    async def delete_message(self, chat_id: str, message_id: str) -> bool:
        return await self.request("deleteMessage", chat_id=chat_id, message_id=message_id)

    async def answer_callback_query(self, callback_query_id: str, text: str | None = None, show_alert: bool = False,
                                    url: str | None = None) -> bool:
        return await self.request("answerCallbackQuery", callback_query_id=callback_query_id, text=text,
                                  show_alert=show_alert or None, url=url)

    async def get_chat(self, chat_id: str):
        from .types import Chat
        return Chat.from_dict(await self.request("getChat", chat_id=chat_id), self)

    # ---------------------------------------------------------------- файлы

    async def get_file(self, file_id: str) -> File:
        return File.from_dict(await self.request("getFile", file_id=file_id), self)

    async def download(self, file: str | File, destination: str | os.PathLike | None = None, timeout: float = 120):
        """Скачать файл: без destination вернёт bytes, иначе сохранит на диск и вернёт путь"""
        f = file if isinstance(file, File) else await self.get_file(file)
        data = await self.session.get_bytes(f"{self.server}/{f.file_path}", timeout)
        if destination is None:
            return data
        path = os.fspath(destination)
        if os.path.isdir(path):
            path = os.path.join(path, f.file_id)
        await asyncio.to_thread(_write, path, data)
        return path

    def start_link(self, payload: str, username: str | None = None) -> str:
        """Ссылка, по которой бот откроется с параметром: «Старт» отправит /start <payload>"""
        name = username or (self._me.username if self._me else None)
        if not name:
            raise RuntimeError("Сначала await bot.get_me() (нужно имя бота) или передайте username")
        return f"{self.server}/u/{name}?start={payload}"


def _write(path: str, data: bytes) -> None:
    with open(path, "wb") as f:
        f.write(data)
