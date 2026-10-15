#!/bin/bash
# Запуск сервера Orbita одной командой:   bash start.sh
# Сам ставит зависимости, находит адрес Мака в Wi-Fi и показывает QR-код для телефона.
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
PORT="${ORBITA_PORT:-8080}"
VENV="$HOME/.orbita-venv"

if ! command -v python3 >/dev/null 2>&1; then
  echo "Не найден python3. Установите: xcode-select --install"; exit 1
fi

# отдельное окружение: не мешает системному Python и работает на новых macOS
if [ ! -x "$VENV/bin/python" ]; then
  echo "Первый запуск: ставлю зависимости…"
  python3 -m venv "$VENV"
fi
"$VENV/bin/python" -m pip install -q --disable-pip-version-check cryptography qrcode "httpx[http2]" >/dev/null 2>&1 || \
  "$VENV/bin/python" -m pip install --disable-pip-version-check cryptography qrcode "httpx[http2]"

# адрес Мака в локальной сети
IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
if [ -z "$IP" ]; then
  IP="$("$VENV/bin/python" -c 'import socket;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.connect(("8.8.8.8",80));print(s.getsockname()[0])' 2>/dev/null || echo localhost)"
fi
URL="http://$IP:$PORT"

# без SMS/почтового провайдера коды показываются баннером в приложении (режим разработки)
if [ -z "$ORBITA_SMS_PROVIDER" ] && [ -z "$ORBITA_SMTP_HOST" ]; then
  export ORBITA_OTP_DEV=1
fi
export ORBITA_PORT="$PORT"
export ORBITA_HOST="0.0.0.0"

echo
echo "════════════════════════════════════════════"
echo "  Orbita Server"
echo "  Адрес для телефона:  $URL"
echo "════════════════════════════════════════════"
echo "  Отсканируйте QR камерой iPhone — Orbita подключится к серверу сама."
echo "  (или впишите адрес вручную: Профиль → Сервер)"
echo
"$VENV/bin/python" - "$URL" <<'PY' || true
import sys, qrcode
q = qrcode.QRCode(border=1)
q.add_data("orbita://server?url=" + sys.argv[1])
q.make()
q.print_ascii(invert=True)
PY
echo
echo "  Остановить сервер: Ctrl+C"
echo

cd "$ROOT/Server"
exec "$VENV/bin/python" server.py
