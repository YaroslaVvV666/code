#!/usr/bin/env bash
# Установка Orbita на Ubuntu/Debian VPS. Запуск: sudo bash setup.sh orbita.example.com
# Домен должен указывать A-записью на IP сервера (или используйте  1-2-3-4.sslip.io  вместо домена).
set -euo pipefail
DOMAIN="${1:?Укажите домен: sudo bash setup.sh orbita.example.com}"
SRC="$(cd "$(dirname "$0")/.." && pwd)"

apt-get update
apt-get install -y python3 python3-venv python3-pip caddy ufw

id orbita >/dev/null 2>&1 || useradd --system --home /opt/orbita --shell /usr/sbin/nologin orbita
mkdir -p /opt/orbita/app /var/lib/orbita
cp -r "$SRC"/. /opt/orbita/app/
rm -rf /opt/orbita/app/deploy /opt/orbita/app/__pycache__
python3 -m venv /opt/orbita/venv
/opt/orbita/venv/bin/pip install -q -r /opt/orbita/app/requirements.txt

# мастер-ключ шифрования: создаётся один раз. ПОТЕРЯ КЛЮЧА = потеря всех данных, сделайте копию!
if [ ! -f /etc/orbita.key ]; then
  head -c 32 /dev/urandom | base64 > /etc/orbita.key
  echo ">>> Создан /etc/orbita.key — сохраните копию в надёжном месте"
fi
chown orbita:orbita /var/lib/orbita /etc/orbita.key
chmod 600 /etc/orbita.key
chown -R orbita:orbita /opt/orbita

cp "$SRC/deploy/orbita.service" /etc/systemd/system/orbita.service
sed "s/DOMAIN/$DOMAIN/g" "$SRC/deploy/Caddyfile" > /etc/caddy/Caddyfile

ufw allow OpenSSH; ufw allow 80/tcp; ufw allow 443/tcp; ufw --force enable

systemctl daemon-reload
systemctl enable --now orbita
systemctl restart caddy
echo "Готово: https://$DOMAIN  — этот адрес впишите в приложении как сервер"
