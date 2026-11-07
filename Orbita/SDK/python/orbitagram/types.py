"""Типы Bot API: сообщения, пользователи, кнопки, файлы. Знакомы по Telegram/aiogram.

Входящие объекты «знают» своего бота, поэтому можно писать `await message.answer("Привет")`
или `await call.answer("Готово")` без явного `bot`."""
from __future__ import annotations

import dataclasses
import os
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Any, ClassVar, Optional, Union

from .session import guess_mime

if TYPE_CHECKING:
    from .bot import Bot


def _alias(name: str) -> dict:
    return {"alias": name}


@dataclass
class OrbitaObject:
    """База для всех типов: разбор из JSON (с вложенными типами) и обратно"""
    _nested: ClassVar[dict[str, Any]] = {}
    extra: dict = field(default_factory=dict, repr=False, compare=False)
    _bot: Any = field(default=None, repr=False, compare=False)

    @classmethod
    def from_dict(cls, data: dict | None, bot: "Bot | None" = None):
        if data is None:
            return None
        if isinstance(data, cls):
            return data
        kwargs, used = {}, set()
        for f in dataclasses.fields(cls):
            if f.name in ("extra", "_bot"):
                continue
            key = f.metadata.get("alias", f.name)
            if key not in data:
                continue
            used.add(key)
            value = data[key]
            nested = cls._nested.get(f.name)
            if nested is not None and value is not None:
                if isinstance(nested, list):
                    value = [nested[0].from_dict(v, bot) for v in value]
                elif isinstance(nested, tuple):                  # список рядов: [[кнопка]]
                    value = [[nested[0].from_dict(b, bot) for b in row] for row in value]
                else:
                    value = nested.from_dict(value, bot)
            kwargs[f.name] = value
        obj = cls(**kwargs)
        obj.extra = {k: v for k, v in data.items() if k not in used}
        obj._bot = bot
        return obj

    def to_dict(self) -> dict:
        out = {}
        for f in dataclasses.fields(self):
            if f.name in ("extra", "_bot"):
                continue
            v = getattr(self, f.name)
            if v is None:
                continue
            out[f.metadata.get("alias", f.name)] = _dump(v)
        return out

    @property
    def bot(self) -> "Bot":
        if self._bot is None:
            raise RuntimeError("Объект не привязан к боту: создайте его через бота или передайте bot=… явно")
        return self._bot

    def as_(self, bot: "Bot"):
        """Привязать объект к боту (для объектов, созданных вручную)"""
        self._bot = bot
        return self


def _dump(v):
    if isinstance(v, OrbitaObject):
        return v.to_dict()
    if isinstance(v, list):
        return [_dump(x) for x in v]
    return v


# ---------- люди и чаты ----------

@dataclass
class User(OrbitaObject):
    id: str = ""
    is_bot: bool = False
    first_name: str = ""
    last_name: Optional[str] = None
    username: Optional[str] = None
    language_code: Optional[str] = None

    @property
    def full_name(self) -> str:
        return " ".join(x for x in (self.first_name, self.last_name) if x)

    @property
    def mention(self) -> str:
        return "@" + self.username if self.username else self.full_name


@dataclass
class Chat(OrbitaObject):
    id: str = ""
    type: str = "private"
    first_name: Optional[str] = None
    last_name: Optional[str] = None
    username: Optional[str] = None
    title: Optional[str] = None

    @property
    def full_name(self) -> str:
        return self.title or " ".join(x for x in (self.first_name, self.last_name) if x)


# ---------- файлы ----------

@dataclass
class PhotoSize(OrbitaObject):
    file_id: str = ""
    file_unique_id: Optional[str] = None
    width: int = 0
    height: int = 0
    file_size: Optional[int] = None


@dataclass
class Document(OrbitaObject):
    file_id: str = ""
    file_unique_id: Optional[str] = None
    file_name: Optional[str] = None
    mime_type: Optional[str] = None
    file_size: Optional[int] = None


@dataclass
class Video(OrbitaObject):
    file_id: str = ""
    file_unique_id: Optional[str] = None
    width: int = 0
    height: int = 0
    duration: int = 0
    mime_type: Optional[str] = None
    file_size: Optional[int] = None


@dataclass
class Animation(Video):
    pass


@dataclass
class VideoNote(OrbitaObject):
    file_id: str = ""
    file_unique_id: Optional[str] = None
    length: int = 0
    duration: int = 0
    file_size: Optional[int] = None


@dataclass
class Voice(OrbitaObject):
    file_id: str = ""
    file_unique_id: Optional[str] = None
    duration: int = 0
    mime_type: Optional[str] = None
    file_size: Optional[int] = None


@dataclass
class Audio(OrbitaObject):
    file_id: str = ""
    file_unique_id: Optional[str] = None
    duration: int = 0
    title: Optional[str] = None
    performer: Optional[str] = None
    file_name: Optional[str] = None
    mime_type: Optional[str] = None
    file_size: Optional[int] = None


@dataclass
class Sticker(OrbitaObject):
    file_id: str = ""
    file_unique_id: Optional[str] = None
    emoji: Optional[str] = None
    set_name: Optional[str] = None


@dataclass
class Location(OrbitaObject):
    latitude: float = 0.0
    longitude: float = 0.0
    live_period: Optional[int] = None


@dataclass
class File(OrbitaObject):
    file_id: str = ""
    file_unique_id: Optional[str] = None
    file_size: Optional[int] = None
    file_path: Optional[str] = None
    mime_type: Optional[str] = None


@dataclass
class MessageEntity(OrbitaObject):
    type: str = ""
    offset: int = 0
    length: int = 0
    url: Optional[str] = None

    def extract_from(self, text: str) -> str:
        return text[self.offset:self.offset + self.length]


# ---------- кнопки ----------

@dataclass
class InlineKeyboardButton(OrbitaObject):
    text: str = ""
    callback_data: Optional[str] = None
    url: Optional[str] = None


@dataclass
class InlineKeyboardMarkup(OrbitaObject):
    _nested: ClassVar[dict] = {"inline_keyboard": (InlineKeyboardButton,)}
    inline_keyboard: list = field(default_factory=list)


@dataclass
class KeyboardButton(OrbitaObject):
    text: str = ""


@dataclass
class ReplyKeyboardMarkup(OrbitaObject):
    _nested: ClassVar[dict] = {"keyboard": (KeyboardButton,)}
    keyboard: list = field(default_factory=list)
    resize_keyboard: Optional[bool] = None
    one_time_keyboard: Optional[bool] = None
    input_field_placeholder: Optional[str] = None


@dataclass
class ReplyKeyboardRemove(OrbitaObject):
    remove_keyboard: bool = True


ReplyMarkup = Union[InlineKeyboardMarkup, ReplyKeyboardMarkup, ReplyKeyboardRemove, dict, None]


@dataclass
class BotCommand(OrbitaObject):
    command: str = ""
    description: str = ""


@dataclass
class WebhookInfo(OrbitaObject):
    url: str = ""
    has_custom_certificate: bool = False
    pending_update_count: int = 0


# ---------- сообщение ----------

@dataclass
class Message(OrbitaObject):
    _nested: ClassVar[dict] = {}
    message_id: str = ""
    date: int = 0
    chat: Optional[Chat] = None
    from_user: Optional[User] = field(default=None, metadata=_alias("from"))
    text: Optional[str] = None
    caption: Optional[str] = None
    entities: Optional[list] = None
    photo: Optional[list] = None
    document: Optional[Document] = None
    video: Optional[Video] = None
    animation: Optional[Animation] = None
    video_note: Optional[VideoNote] = None
    voice: Optional[Voice] = None
    audio: Optional[Audio] = None
    sticker: Optional[Sticker] = None
    location: Optional[Location] = None
    reply_to_message: Optional["Message"] = None
    reply_markup: Optional[InlineKeyboardMarkup] = None
    edit_date: Optional[int] = None

    CONTENT_TYPES: ClassVar[tuple] = ("text", "photo", "document", "video", "animation", "video_note", "voice",
                                      "audio", "sticker", "location")

    @property
    def content_type(self) -> str:
        """Что пришло: "text", "photo", "document", "voice"… (animation проверяется раньше video)"""
        for t in ("animation", "photo", "document", "video", "video_note", "voice", "audio", "sticker", "location", "text"):
            if getattr(self, t):
                return t
        return "unknown"

    @property
    def html_text(self) -> str:
        return self.text or self.caption or ""

    # --- ответы ---

    async def answer(self, text: str, **kwargs) -> "Message":
        """Ответить в этот же чат"""
        return await self.bot.send_message(self.chat.id, text, **kwargs)

    async def reply(self, text: str, **kwargs) -> "Message":
        """Ответить цитатой на это сообщение"""
        return await self.bot.send_message(self.chat.id, text, reply_to_message_id=self.message_id, **kwargs)

    async def answer_photo(self, photo, caption: str | None = None, **kwargs) -> "Message":
        return await self.bot.send_photo(self.chat.id, photo, caption=caption, **kwargs)

    async def answer_document(self, document, caption: str | None = None, **kwargs) -> "Message":
        return await self.bot.send_document(self.chat.id, document, caption=caption, **kwargs)

    async def answer_video(self, video, caption: str | None = None, **kwargs) -> "Message":
        return await self.bot.send_video(self.chat.id, video, caption=caption, **kwargs)

    async def answer_animation(self, animation, caption: str | None = None, **kwargs) -> "Message":
        return await self.bot.send_animation(self.chat.id, animation, caption=caption, **kwargs)

    async def answer_audio(self, audio, caption: str | None = None, **kwargs) -> "Message":
        return await self.bot.send_audio(self.chat.id, audio, caption=caption, **kwargs)

    async def answer_voice(self, voice, caption: str | None = None, **kwargs) -> "Message":
        return await self.bot.send_voice(self.chat.id, voice, caption=caption, **kwargs)

    async def answer_video_note(self, video_note, **kwargs) -> "Message":
        return await self.bot.send_video_note(self.chat.id, video_note, **kwargs)

    async def answer_sticker(self, sticker, **kwargs) -> "Message":
        return await self.bot.send_sticker(self.chat.id, sticker, **kwargs)

    async def answer_chat_action(self, action: str = "typing") -> bool:
        return await self.bot.send_chat_action(self.chat.id, action)

    # --- изменение своего сообщения ---

    async def edit_text(self, text: str, reply_markup: ReplyMarkup = None) -> "Message":
        return await self.bot.edit_message_text(text, chat_id=self.chat.id, message_id=self.message_id,
                                                reply_markup=reply_markup)

    async def edit_caption(self, caption: str, reply_markup: ReplyMarkup = None) -> "Message":
        return await self.bot.edit_message_caption(chat_id=self.chat.id, message_id=self.message_id,
                                                   caption=caption, reply_markup=reply_markup)

    async def edit_reply_markup(self, reply_markup: ReplyMarkup = None) -> "Message":
        return await self.bot.edit_message_reply_markup(chat_id=self.chat.id, message_id=self.message_id,
                                                        reply_markup=reply_markup)

    async def delete(self) -> bool:
        return await self.bot.delete_message(self.chat.id, self.message_id)

    async def download(self, destination=None):
        """Скачать файл из сообщения (фото — самое крупное). Возвращает байты или путь"""
        target = (self.photo[-1] if self.photo else None) or self.document or self.video or self.animation \
            or self.voice or self.audio or self.video_note
        if target is None:
            raise ValueError("В сообщении нет файла")
        return await self.bot.download(target.file_id, destination)


Message._nested = {"chat": Chat, "from_user": User, "photo": [PhotoSize], "document": Document, "video": Video,
                   "animation": Animation, "video_note": VideoNote, "voice": Voice, "audio": Audio, "sticker": Sticker,
                   "location": Location, "reply_to_message": Message, "reply_markup": InlineKeyboardMarkup,
                   "entities": [MessageEntity]}


@dataclass
class CallbackQuery(OrbitaObject):
    _nested: ClassVar[dict] = {"from_user": User, "message": Message}
    id: str = ""
    from_user: Optional[User] = field(default=None, metadata=_alias("from"))
    message: Optional[Message] = None
    data: Optional[str] = None
    chat_instance: Optional[str] = None

    async def answer(self, text: str | None = None, show_alert: bool = False, url: str | None = None) -> bool:
        """Ответ на нажатие: подсказка (или окно при show_alert=True). Ответить нужно в течение ~6 секунд.
        Если не ответить, библиотека сама ответит пустым ответом после обработчика — у человека не будет «ожидания»"""
        self.extra["__answered__"] = True
        return await self.bot.answer_callback_query(self.id, text=text, show_alert=show_alert, url=url)

    @property
    def answered(self) -> bool:
        return bool(self.extra.get("__answered__"))


@dataclass
class Update(OrbitaObject):
    _nested: ClassVar[dict] = {"message": Message, "edited_message": Message, "callback_query": CallbackQuery}
    update_id: int = 0
    message: Optional[Message] = None
    edited_message: Optional[Message] = None
    callback_query: Optional[CallbackQuery] = None

    @property
    def event_type(self) -> str:
        for t in ("message", "edited_message", "callback_query"):
            if getattr(self, t) is not None:
                return t
        return "unknown"

    @property
    def event(self):
        return getattr(self, self.event_type, None)


@dataclass
class ErrorEvent:
    """Что передаётся в обработчики ошибок: исходное событие и исключение"""
    update: Update
    exception: BaseException


# ---------- файлы для отправки ----------

class InputFile:
    """Файл для загрузки. Обычная строка вместо него — это file_id или https-ссылка"""
    filename: str = "file"

    def read(self) -> bytes:
        raise NotImplementedError

    @property
    def mime(self) -> str:
        return guess_mime(self.filename)


class FSInputFile(InputFile):
    """Файл с диска: FSInputFile("cat.jpg")"""

    def __init__(self, path: str | os.PathLike, filename: str | None = None):
        self.path = os.fspath(path)
        self.filename = filename or os.path.basename(self.path)

    def read(self) -> bytes:
        with open(self.path, "rb") as f:
            return f.read()


class BufferedInputFile(InputFile):
    """Файл из памяти: BufferedInputFile(png_bytes, "chart.png")"""

    def __init__(self, data: bytes, filename: str):
        self.data = data
        self.filename = filename

    def read(self) -> bytes:
        return self.data


class URLInputFile(InputFile):
    """Файл по ссылке — его скачает сам сервер (только публичные https/http-адреса)"""

    def __init__(self, url: str, filename: str | None = None):
        self.url = url
        self.filename = filename or url.rsplit("/", 1)[-1] or "file"

    def read(self) -> bytes:
        raise RuntimeError("URLInputFile передаётся ссылкой")
