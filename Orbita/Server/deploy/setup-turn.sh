#!/usr/bin/env bash
# TURN-сервер (coturn) для звонков Orbita — ретранслятор, без которого звонки между разными
# сетями (двумя мобильными операторами через всю страну) почти никогда не соединяются.
#
# Запуск на Ubuntu/Debian VPS (можно на том же, где server.py, можно на отдельном):
#     sudo bash setup-turn.sh turn.example.com
#
# turn.example.com — домен, A-записью указывающий на IP ЭТОГО сервера. TLS-сертификат получим
# автоматически (certbot). Можно без домена — тогда TURN поднимется только без шифрования (turn:),
# для теста сойдёт, для прода нужен домен ради turns: (TLS, проходит через строгие файрволы).
set -euo pipefail
DOMAIN="${1:-}"

apt-get update
apt-get install -y coturn
[ -n "$DOMAIN" ] && apt-get install -y certbot || true

# секрет для временных логинов (use-auth-secret): сервер Orbita выдаёт короткоживущие пароли,
# подписанные этим секретом — его же знает coturn. Постоянных паролей на диске нет.
SECRET_FILE=/etc/orbita-turn.secret
if [ ! -f "$SECRET_FILE" ]; then
  head -c 32 /dev/urandom | base64 | tr -d '/+=' > "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"
fi
SECRET="$(cat "$SECRET_FILE")"

# внешний (публичный) IP сервера — нужен coturn, если он за NAT (у многих VPS это сам IP)
PUBIP="$(curl -s -4 https://api.ipify.org || hostname -I | awk '{print $1}')"

TLS_LINES=""
if [ -n "$DOMAIN" ]; then
  certbot certonly --standalone -n --agree-tos --register-unsafely-without-email -d "$DOMAIN" || \
    echo ">>> certbot не смог выпустить сертификат (проверьте, что домен указывает на этот сервер и порт 80 свободен). TURN поднимется без TLS."
  CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
  if [ -f "$CERT" ]; then
    TLS_LINES=$'tls-listening-port=5349\ncert='"$CERT"$'\npkey='"$KEY"
    # coturn читает сертификаты от своего пользователя — дадим доступ к каталогу Let's Encrypt
    [ -d /etc/letsencrypt ] && chmod -R a+rX /etc/letsencrypt || true
  fi
fi

cat > /etc/turnserver.conf <<EOF
# --- coturn для Orbita (сгенерировано setup-turn.sh) ---
listening-port=3478
${TLS_LINES}
fingerprint
use-auth-secret
static-auth-secret=${SECRET}
realm=${DOMAIN:-orbita}
external-ip=${PUBIP}
# только ретрансляция звонков, никаких лишних возможностей (безопасность)
no-cli
no-multicast-peers
no-tcp-relay
stale-nonce=600
# не давать ломиться во внутреннюю сеть через TURN
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
# предел на одного пользователя, чтобы один звонок не съел весь сервер
user-quota=12
total-quota=1200
EOF

# включить демона
sed -i 's/^#*TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn 2>/dev/null || echo "TURNSERVER_ENABLED=1" >> /etc/default/coturn

# файрвол: TURN слушает 3478 (UDP/TCP), 5349 (TLS) и диапазон ретрансляции
if command -v ufw >/dev/null 2>&1; then
  ufw allow 3478/udp; ufw allow 3478/tcp; ufw allow 5349/tcp; ufw allow 49152:65535/udp || true
fi

systemctl enable coturn
systemctl restart coturn

SCHEME_TLS=""
[ -n "$TLS_LINES" ] && SCHEME_TLS="turns:$DOMAIN:5349?transport=tcp,"
echo
echo "================= ГОТОВО: TURN запущен ================="
echo "Добавьте эти строки в /etc/systemd/system/orbita.service (секция [Service]) на сервере приложения:"
echo
echo "Environment=ORBITA_TURN_URL=${SCHEME_TLS}turn:${DOMAIN:-$PUBIP}:3478?transport=udp,turn:${DOMAIN:-$PUBIP}:3478?transport=tcp"
echo "Environment=ORBITA_TURN_SECRET=${SECRET}"
echo
echo "Затем:  systemctl daemon-reload && systemctl restart orbita"
echo "Проверка TURN:  в приложении позвоните между двумя телефонами на РАЗНЫХ сетях (Wi-Fi ↔ моб. интернет)."
echo "======================================================="
