"""Проверка, что загружаемый файл действительно является заявленным медиа (картинкой/видео),
а не замаскированным кодом. Главная цель — стикеры и анимированные эмодзи: туда часто пытаются
подсунуть SVG/HTML со скриптом, полиглоты или исполняемые файлы под видом картинки.

Проверки без зависимостей (всегда):
  * сигнатура (магические байты) в начале файла совпадает с заявленным типом;
  * файл не начинается как разметка/скрипт/архив/исполняемый файл (SVG, HTML, XML, JS, ELF, PE, ZIP, PDF…);
  * в начале картинки нет тегов <script>/<svg>/javascript: (защита от полиглотов).

Дополнительно, если установлены Pillow / ffprobe:
  * картинка реально открывается декодером, формат = PNG/JPEG, размер в разумных пределах,
    нет «бомбы распаковки»;
  * видео реально разбирается ffprobe и содержит видеопоток в контейнере mp4/mov.
Если инструментов нет — эти шаги пропускаются (fail-open), но проверка сигнатур работает всегда.
"""
import os
import re
import subprocess

# Разрешённые типы совпадают с ALLOWED_MIME в server.py (растровые картинки и mp4/mov)
MAX_IMAGE_SIDE = 8192                 # сторона картинки-стикера: больше — подозрительно (и бомба распаковки)
_HEAD = 4096                          # сколько байт читаем для сигнатуры/разметки

# Явно опасные начала файла — понятная причина отказа (сигнатура всё равно не совпала бы)
_BAD_PREFIXES = (
    (b"<?xml", "xml"), (b"<svg", "svg"), (b"<!doctype", "html"), (b"<html", "html"),
    (b"<head", "html"), (b"<body", "html"), (b"<script", "script"), (b"<!--", "html"),
    (b"MZ", "executable"), (b"\x7fELF", "executable"), (b"PK\x03\x04", "archive"),
    (b"PK\x05\x06", "archive"), (b"%PDF", "pdf"), (b"#!", "script"), (b"{\\rtf", "rtf"),
    (b"\xca\xfe\xba\xbe", "executable"), (b"\xfe\xed\xfa", "executable"),
)
_SCRIPT_MARKERS = (b"<script", b"javascript:", b"<svg", b"<!doctype html", b"<html")


def _image_ok(head):
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if head.startswith(b"\xff\xd8\xff"):
        return "jpeg"
    return None


def _video_ok(head):
    # ISO Base Media (mp4) / QuickTime (mov): первый атом — ftyp, либо один из допустимых ведущих атомов
    if len(head) >= 12 and head[4:8] in (b"ftyp", b"moov", b"mdat", b"free", b"skip", b"wide"):
        return "mp4"
    return None


def sniff(path, top, mime=""):
    """Возвращает (ok, reason). top — 'image' или 'video'. Безопасно по умолчанию: при любой
    неоднозначности отклоняем. reason — короткий машинный код для лога/ответа."""
    try:
        with open(path, "rb") as f:
            head = f.read(_HEAD)
    except OSError:
        return False, "unreadable"
    if not head:
        return False, "empty"

    low = head.lstrip()[:64].lower()
    for prefix, label in _BAD_PREFIXES:
        if low.startswith(prefix):
            return False, "looks_like_" + label

    if top == "image":
        fmt = _image_ok(head)
        if not fmt:
            return False, "not_an_image"
        # полиглот: валидная картинка, но с внедрённой разметкой/скриптом в начале
        low_head = head.lower()
        if any(m in low_head for m in _SCRIPT_MARKERS):
            return False, "embedded_markup"
        return _verify_image(path)

    if top == "video":
        if not _video_ok(head):
            return False, "not_a_video"
        return _verify_video(path)

    return False, "unsupported_kind"


def _verify_image(path):
    """Глубокая проверка картинки декодером Pillow — если он есть."""
    try:
        from PIL import Image
    except Exception:
        return True, "ok_no_decoder"          # Pillow нет — ограничиваемся сигнатурой
    try:
        Image.MAX_IMAGE_PIXELS = MAX_IMAGE_SIDE * MAX_IMAGE_SIDE
        with Image.open(path) as im:
            fmt = (im.format or "").upper()
            w, h = im.size
            im.verify()                        # структурная проверка без полной распаковки
        if fmt not in ("PNG", "JPEG"):
            return False, "format_mismatch"
        if w < 1 or h < 1 or w > MAX_IMAGE_SIDE or h > MAX_IMAGE_SIDE:
            return False, "bad_dimensions"
        # второй проход: реально декодируем пиксели (verify() закрывает файл)
        with Image.open(path) as im2:
            im2.load()
        return True, "ok"
    except Exception:
        return False, "decode_failed"


def _verify_video(path):
    """Глубокая проверка видео через ffprobe — если он есть."""
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-print_format", "json", "-show_format", "-show_streams", path],
            capture_output=True, timeout=20, check=False)
    except (OSError, subprocess.SubprocessError):
        return True, "ok_no_probe"             # ffprobe нет — ограничиваемся сигнатурой
    if out.returncode != 0:
        return False, "probe_failed"
    try:
        import json
        info = json.loads(out.stdout or b"{}")
    except ValueError:
        return False, "probe_unparsable"
    fmt = (info.get("format", {}).get("format_name") or "").lower()
    allowed = ("mp4", "mov", "m4a", "3gp", "isom", "quicktime", "matroska", "webm")
    if not any(a in fmt for a in allowed):
        return False, "container_mismatch"
    streams = info.get("streams", [])
    if not any(s.get("codec_type") == "video" for s in streams):
        return False, "no_video_stream"
    return True, "ok"
