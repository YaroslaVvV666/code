# Сервер Orbita

Один файл на Python, без фреймворков. Зависимость одна — `cryptography`.

```bash
pip3 install -r requirements.txt
python3 server.py            # порт 8080, слушает всю локальную сеть
```

Переменные окружения: `ORBITA_PORT`, `ORBITA_HOST`, `ORBITA_DATA` (папка данных),
`ORBITA_DEMO=0` (не создавать демо-посты), `ORBITA_MASTER_KEY` / `ORBITA_MASTER_KEY_FILE`.

## Проверка с iPhone, сервер на Mac

1. Mac и iPhone — в одной Wi-Fi сети.
2. На Mac: `cd Server && pip3 install -r requirements.txt && python3 server.py`.
3. Адрес Mac: `ipconfig getifaddr en0` (например `192.168.1.20`).
4. В приложении: Профиль → Сервер → `http://192.168.1.20:8080` → «Проверить подключение».
5. iPhone спросит доступ к локальной сети — разрешите. Если соединения нет, проверьте брандмауэр macOS.
6. В симуляторе достаточно `http://localhost:8080`.

## Шифрование

- AES-256-GCM для всех пользовательских полей (имя, @username, био, тексты постов и комментариев) и для медиа (чанки по 64 КиБ, поддержка Range).
- Поиск по @username — через слепой индекс (HMAC), открытого текста в базе нет.
- Иерархия ключей (HKDF-SHA256): мастер-ключ → ключ пользователя → ключ области (`profile`, `posts`, `comments`, `media`) → ключ файла.
- Мастер-ключ: `keys/master.key` (создаётся при первом запуске, права 0600) или переменные окружения. **Сделайте его резервную копию отдельно от данных — без него данные не прочитать.**

## Выдача ключей без мастер-ключа

```bash
python3 keytool.py users
python3 keytool.py export --user @name --reason "основание" --scope posts,comments --out bundle.json
python3 keytool.py decrypt --bundle bundle.json
python3 keytool.py log
```

Пакет содержит только производные ключи одного пользователя: по нему нельзя получить мастер-ключ или данные других людей.
Каждая выдача записывается в `data/disclosure.log`.

## API (версия 5)

`/v1/ping`, `/v1/session`, `/v1/me`, `/v1/username/check`, `/v1/users/{id}`, `/v1/lookup?u=`, `/v1/media`, `/media/{id}`,
`/v1/posts` (+ `/like`, `/comments`), `/v1/comments/{id}/like`, `/v1/comments/{id}/pin`.

Фотографии профиля: `GET /v1/users/{id}/avatars`, `POST /v1/me/avatars`, `PUT /v1/me/avatars/order`, `DELETE /v1/me/avatars/{id}`.

Сеансы: `GET /v1/sessions`, `DELETE /v1/sessions/{id}`, `DELETE /v1/sessions` (все, кроме текущего).

Вход по QR: `POST /v1/qr` (новое устройство), `GET /v1/qr/{id}?secret=` (опрос),
`GET /v1/qr/{id}/info` и `POST /v1/qr/{id}/approve` (вошедшее устройство). Незавершённые QR хранятся только в памяти.

Имя, фамилия, день рождения, названия устройств и IP шифруются так же, как остальные поля; у каждого устройства свой токен (в базе — SHA-256).
Старая база обновляется сама: единственный токен превращается в сеанс, аватар — в галерею.

Ответы на комментарии — всегда в ветке корневого комментария. Закреплять может только автор поста и только корневые комментарии.

## Настоящие SMS и письма с кодом

Приложение само ничего не отправляет: оно просит сервер (`POST /v1/otp/send`), а сервер шлёт код через вашего провайдера.
Ключи провайдера лежат только в окружении сервера. Если сервер недоступен или провайдер не настроен, приложение
по-прежнему работает в учебном режиме: код показывается баннером на экране.

**Почта** — любой SMTP (Gmail «пароль приложения», Яндекс, Mail.ru, Mailgun, Postbox, свой Postfix):

```
export ORBITA_SMTP_HOST=smtp.yandex.ru
export ORBITA_SMTP_PORT=465            # 465 = SSL, 587 = STARTTLS
export ORBITA_SMTP_USER=no-reply@your-domain.ru
export ORBITA_SMTP_PASS=********
export ORBITA_SMTP_FROM="Orbita <no-reply@your-domain.ru>"
```

**SMS** — выберите провайдера (`ORBITA_SMS_PROVIDER`):

| Провайдер | Переменные |
|---|---|
| `smsru` (sms.ru) | `ORBITA_SMS_API_ID`, `ORBITA_SMS_FROM` (имя отправителя, необязательно) |
| `smsc` (smsc.ru) | `ORBITA_SMS_LOGIN`, `ORBITA_SMS_PASSWORD`, `ORBITA_SMS_FROM` |
| `twilio` | `ORBITA_TWILIO_SID`, `ORBITA_TWILIO_TOKEN`, `ORBITA_TWILIO_FROM` |
| `webhook` | `ORBITA_SMS_WEBHOOK` — ваш шлюз получает POST `{"phone": "+7…", "text": "…"}` |

Нужны: договор или аккаунт у провайдера, пополненный баланс; для российских номеров — согласованное имя отправителя
(иначе SMS уходят с общего номера или блокируются). Проверьте: `curl localhost:8080/v1/ping` → `"otp": {"sms": true, "email": true}`.

Защита: код 6 цифр, живёт 5 минут, хранится только в виде HMAC, 5 попыток, повтор не чаще раза в 45 секунд,
не больше 5 кодов в час на адрес и 20 в час на IP. Для разработки без провайдера: `ORBITA_OTP_DEV=1` — сервер вернёт код
в ответе (`debug_code`), приложение покажет его баннером. В продакшене эту переменную не включать.

## Публикации, стена, приватность, плейлист (версия 5)

- `PUT /v1/posts/{id}` — правка (текст, форматирование, набор медиа), в ответе `edited_at`; удалённые из поста файлы стираются.
- `GET /v1/users/{id}/posts` — стена пользователя; `{"posts": [], "private": true}`, если стена закрыта от вас.
- `PUT /v1/me` с `"privacy": {"phone","last_seen","photos","bio","birthday","music","wall","calls","forwards","invites","comments"}`,
  значения `"all"` или `"nobody"`. «Закрытый профиль» — это `"wall": "nobody"`: прячется только стена.
  `calls`, `forwards`, `invites` пока только сохраняются — мессенджера ещё нет.
- Чёрный список: `GET /v1/me/blocks`, `PUT|DELETE /v1/me/blocks/{user_id}`. Заблокированные не видят друг друга в ленте
  и комментариях; заблокировавший для них — «пустая» страница (имя, @username).
- Плейлист: загрузка `POST /v1/media?kind=audio` (mp3 / m4a, до 40 МБ), затем `POST /v1/me/playlist`,
  `PUT /v1/me/playlist/order`, `PUT|DELETE /v1/me/playlist/{id}`, `GET /v1/users/{id}/playlist`.
  Названия и исполнители шифруются как остальные поля профиля.

## Безопасность сервера (жёсткий прод)

**Мастер-ключ — не на диске.** По умолчанию ключ лежит файлом (`/etc/orbita.key`), что защищает от кражи
диска/бэкапа, но не от взлома живого сервера. В проде берите ключ из внешнего хранилища секретов — тогда он
не лежит рядом с данными. Приоритет источников в `KeyRing.load`:
1. `ORBITA_MASTER_KEY_CMD` — команда, печатающая ключ (base64 или hex) в stdout. Примеры:
   - AWS KMS: `aws kms decrypt --ciphertext-blob fileb:///etc/orbita.key.enc --query Plaintext --output text`
   - Vault: `vault kv get -field=master_key secret/orbita`
2. `ORBITA_MASTER_KEY` — ключ (base64/hex) в переменной окружения (подставляет оркестратор).
3. `ORBITA_MASTER_KEY_FILE` / `keys/master.key` — файл (создаётся при первом запуске; для разработки).

`ORBITA_MASTER_KEY_FINGERPRINT` (необязательно) — отпечаток ожидаемого ключа; при несовпадении служба не
стартует (защита от тихой подмены ключа, после которой данные стали бы «нечитаемыми»).

**Код только для чтения + контроль целостности.** `deploy/orbita.service` запускает службу в песочнице systemd:
`ProtectSystem=strict`, код в `/opt/orbita/app` смонтирован только для чтения, писать можно лишь в
`/var/lib/orbita`; сброшены все capabilities, включён фильтр системных вызовов, запрещено повышение прав.
Перед каждым запуском `ExecStartPre` вызывает `deploy/integrity.sh verify` — если любой `.py` подменили,
служба не стартует. Эталон создаётся при деплое (`setup.sh` → `integrity.sh generate`); после легального
обновления кода пересоздайте его повторным запуском `setup.sh` (или `integrity.sh generate /opt/orbita/app`).

## Защита от вредоносных файлов и ссылок

- **Тип файла проверяется по содержимому, а не по заявленному MIME.** Картинки (PNG/JPEG), видео (mp4/mov) и голосовые/аудио
  (mp3/m4a/AAC) проходят `media_safety.sniff`: сигнатура, отказ для HTML/SVG/скриптов/исполняемых/архивов, поиск внедрённой
  разметки; при наличии Pillow/ffprobe — реальное декодирование и ограничение размеров (защита от «бомб распаковки»).
- **Раздача медиа:** `X-Content-Type-Options: nosniff` и `Content-Security-Policy: sandbox`; произвольные файлы — всегда
  `application/octet-stream` + `Content-Disposition: attachment` (никогда не открываются как страница).
- **Имена файлов** (`clean_filename`): без `/`, `\`, `..`, ведущих точек, управляющих и невидимых символов направления текста
  (`U+202E` и др. — ими подделывают расширение). Приложение очищает имя ещё раз перед сохранением (`SafeFileName`).
- **SSRF:** превью ссылок и вебхуки ботов ходят наружу только через `safe_request` — http(s), стандартные порты, только
  публичные IP (проверенный адрес закрепляется за соединением — DNS rebinding не сработает), редиректы проверяются на каждом шаге.
  Вебхук: только `https`, без логина/пароля в адресе, без редиректов.
- **Приложение:** ссылки из чужого текста открываются только со схемами http/https/mailto/tel/sms; картинки декодируются
  только с уменьшением (`ImageCache.downsample`).

Проверка: `python3 tests/test_security.py`.

## Звонки: TURN-сервер (обязателен для разных сетей)

Звонки идут напрямую между телефонами (P2P WebRTC). Между разными сетями (два мобильных оператора в разных
городах) прямое соединение почти никогда не проходит — нужен **TURN** (ретранслятор). Без него звонок соединится
только в «удобных» сетях (общий Wi-Fi).

Поднять coturn (на том же VPS или отдельном):

    sudo bash deploy/setup-turn.sh turn.example.com

Скрипт поставит coturn, сгенерирует секрет для временных логинов, получит TLS-сертификат (certbot), настроит
файрвол и в конце напечатает две строки `Environment=ORBITA_TURN_URL=…` / `ORBITA_TURN_SECRET=…` — их нужно
добавить в `orbita.service` на сервере приложения и перезапустить его. Логины одноразовые (REST API coturn,
HMAC по секрету), постоянных паролей на диске нет.

**Чтобы звонок звонил, когда приложение закрыто** (как в Telegram), нужен VoIP-пуш (PushKit) — отдельно от
обычных уведомлений, требует платный Apple Developer Program. Сейчас входящий звонок доходит, только пока
приложение открыто (сигнал по long-poll); CallKit (системный экран звонка) уже подключён.

## «Кратко» — пересказ непрочитанного

В чате, где накопилось 10+ непрочитанных, появляется плашка «✨ Кратко». Сервер (`GET /v1/chats/<id>/summary?from=<первое непрочитанное>`)
собирает пропущенные сообщения (до 300) и отдаёт пересказ пунктами. Ответ кэшируется на 30 минут, лимит — 20 пересказов в час на человека.

- **Без настройки** — простая выжимка без ИИ (кто писал, самые содержательные сообщения, сколько вопросов).
- **С Claude** — `pip install anthropic` и переменная `ANTHROPIC_API_KEY` в `orbita.service`. Модель по умолчанию — `claude-opus-5-5`,
  сменить можно через `ORBITA_SUMMARY_MODEL` (например, `claude-haiku-5-5` — заметно дешевле для такой простой задачи).
  Если Claude недоступен (нет сети, лимит, отказ), сервер молча отдаёт простую выжимку.

Важно: при включённом Claude текст пропущенных сообщений этого чата уходит в API Anthropic — только когда человек сам нажал «Кратко».
С российского VPS API Anthropic недоступен напрямую — понадобится сервер за рубежом или исходящий прокси (`HTTPS_PROXY`).

## Геопозиция и трансляция

Вложение `{"type": "location", "lat", "lon", "acc", "title", "live": 900|3600|28800}` в обычном сообщении. С `live` — трансляция:
телефон присылает точки `PUT /v1/live-location/<id сообщения>` (раз в ~10 с при движении, раз в 30 с на месте), остановка —
`POST /v1/live-location/<id>/stop`. Точки хранятся зашифрованными (`live_locations`), получатели будятся long-poll'ом и видят
движущуюся точку. Пересланная трансляция становится обычной точкой. Проверка: `python3 tests/test_location.py`.

В Xcode (Info.plist таргета) нужно добавить:
- `NSLocationWhenInUseUsageDescription` — «Чтобы отправлять геопозицию в чат»;
- для трансляции со свёрнутым приложением: Signing & Capabilities → Background Modes → **Location updates**
  (без этого трансляция идёт, только пока приложение открыто).

## Боты (BotGod и Bot API)

Встроенные боты (@botgod, @stickers) отвечают не мгновенно: сначала «печатает…», через ~1–2 с — ответ (как в Telegram). Пауза задаётся `ORBITA_BOT_DELAY` (секунды, по умолчанию 0.9; `0` — мгновенно, для тестов).

Свои боты создаются в чате с **@botgod** (как BotFather в Telegram): `/newbot` → имя → @username, оканчивающийся на `bot` →
токен. Настройка: `/setdescription` («Что умеет этот бот?» — видно в начале чата), `/setdescriptionpic` (баннер — картинка
или видео до 30 с), `/setuserpic` (аватарка), `/setabouttext` («о себе»), `/setcommands` (меню «/»), `/setname`, `/token`,
`/revoke`, `/deletebot`. Пока человек не нажал «Старт», в чате с ботом вместо поля ввода — кнопка «Старт» (отправляет `/start`);
бот не может написать первым.

Код бота работает через Bot API (форма вызовов как в Telegram, GET или POST с JSON):

    https://ваш-сервер/bot<токен>/getMe
    https://ваш-сервер/bot<токен>/getUpdates?offset=<последний update_id + 1>&timeout=30   # long-poll
    POST https://ваш-сервер/bot<токен>/sendMessage        {"chat_id": "<id человека>", "text": "Привет"}
    POST https://ваш-сервер/bot<токен>/setMyCommands      {"commands": [{"command": "start", "description": "Начать"}]}
    POST https://ваш-сервер/bot<токен>/setWebhook         {"url": "https://..."}   # вместо getUpdates; deleteWebhook — выключить

Простейший бот-эхо на Python:

```python
import json, time, urllib.request
API = "https://ваш-сервер/bot<токен>/"
def call(m, **p):
    r = urllib.request.Request(API + m, data=json.dumps(p).encode(), headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(r, timeout=60))["result"]
offset = 0
while True:
    for u in call("getUpdates", offset=offset, timeout=30):
        offset = u["update_id"] + 1
        msg = u.get("message", {})
        if "text" in msg:
            call("sendMessage", chat_id=msg["chat"]["id"], text="Вы написали: " + msg["text"])
```

Проверка: `python3 tests/test_bots.py`.


## Новое: кнопки ботов, докачка, темы, групповые звонки

- **Bot API**: `reply_markup` (`inline_keyboard` с `callback_data`/`url`, `keyboard`, `remove_keyboard`), `answerCallbackQuery`,
  `editMessageText/Caption/ReplyMarkup`, `deleteMessage`, `sendPhoto/Document/Video/Animation/Audio/Voice/VideoNote/Sticker`
  (multipart, `file_id` или https-ссылка). Ссылка на бота `…/u/<bot>?start=abc` — «Старт» отправит `/start abc`.
- **Вход с нового устройства**: сообщение от служебного аккаунта «Orbita» с кнопкой «Это не я» (завершает тот сеанс).
- **Викторины**: `poll.quiz = true`, `correct`, `explanation`; правильный ответ виден только после ответа.
- **Загрузка частями**: `POST /v1/uploads` → `PUT /v1/uploads/<id>?offset=` (куски до 8 МБ) → `POST …/finish`.
  Куски на диске зашифрованы, незаконченные загрузки удаляются через сутки.
- **Темы в группах**: `PUT /v1/groups/<id>/forum`, `GET/POST /v1/groups/<id>/topics`, `PUT/DELETE …/topics/<tid>`;
  сообщения темы — `GET /v1/chats/<id>/messages?topic=<tid|general>`, отправка — `topic_id` в теле.
- **Групповые звонки** (mesh, до 8 участников): `/v1/groups/<id>/call` (статус), `/join`, `/leave`, `/state`,
  `/signal` (offer/answer/ice), `/poll` (long-poll). Нужен тот же TURN, что и для личных звонков.

Тесты: `test_login_alert.py`, `test_quiz.py`, `test_uploads.py`, `test_topics.py`, `test_group_calls.py`.


## Библиотека для разработчиков ботов (Python)

`SDK/python` — пакет **orbitagram** в духе aiogram: `Bot`, `Dispatcher`/`Router`, фильтры и `F`, FSM,
клавиатуры, `CallbackData`, middleware, polling и вебхуки. Установка: `pip install ./SDK/python`.
Документация и примеры — `SDK/python/README_Orbitagram.md`.

Для подсказки в BotGod укажите публичный адрес сервера: `ORBITA_PUBLIC_URL=https://orbita.example.com`.
Методы Bot API, добавленные для библиотеки: `getFile` (скачивание по `/media/<id>`), `sendChatAction`, `getChat`,
`setMyDescription`/`getMyDescription`, `getWebhookInfo`, `setWebhook(secret_token, drop_pending_updates)`.
Входящие сообщения приходят в формате Telegram: `photo`, `document`, `video`, `animation`, `video_note`, `voice`,
`audio`, `sticker`, `location`, `caption`, `reply_to_message`.

Записи от имени бота: `sendPost` (`text`, `media` — до 10 file_id своих фото/видео, `wall_only`) и `deletePost` (`post_id`).
Владелец бота публикует из приложения: `POST /v1/bots/<bot_id>/posts` (тело как у `/v1/posts`); записи своего бота
он может править и удалять (`mine: true`), а в профиле бота приходит `bot_owned: true`.
Проверка: `python3 tests/test_bot_posts.py`.


## Статьи в сообщениях

`POST /v1/chats/<id>/messages` принимает `blocks` — сообщение из блоков, как статьи в Telegram:
`heading` (`level` 1–6), `text`, `quote`, `pullquote` (`author`), `code` (`lang`), `formula` (LaTeX),
`button` (`text`, `url`, `color`: default/red/blue/green/orange/yellow/white), `list` (`style`: bullet/number/check,
`items`), `collapse` (`text` — заголовок, `body`), `table` (`rows`, `header`), `media` (вложение, как в `attachments`,
и `caption`), `divider`. И `buttons` — кнопки-ссылки под сообщением с цветом. Блоки шифруются, медиа — только свои
файлы, ссылки — только http(s). Поле `text` заполняется выжимкой для списка чатов. Работает в личке, группах и каналах.
Проверка: `python3 tests/test_articles.py`.


## Свои эмодзи (как custom emoji в Telegram)

Делаются в боте @stickers: `/newemojipack`, `/addemoji`, `/delemoji` (`/mypacks`, `/delpack`, `/done` — общие со стикерами).
- Статичный эмодзи — картинка (PNG с прозрачностью; JPEG/WEBP тоже). Не 100×100 — сервер обрезает её по центру
  до квадрата и приводит к PNG 100×100.
- Анимированный — только Lottie `.json`; другие форматы анимаций не принимаются. Проверки: холст квадратный
  100–512, до 60 кадров/с, до 3 секунд, без вставленных картинок, шрифтов и выражений (скриптов), не больше 1 МБ.
  Хранится сжатым (gzip, mime `application/x-orbita-lottie`) — до 64 КБ.
- В тексте сообщения: обычный эмодзи-заменитель + сущность `{"type": "custom_emoji", "url": "u:<id>"}`.
  `GET /v1/custom-emoji?ids=u:…,u:…` — сведения для отрисовки (даже если набора у человека нет).
- Наборы эмодзи приходят в `GET /v1/stickers` с `"kind": "emoji"`, у анимированных — `"lottie": true`.
Проверка: `python3 tests/test_custom_emoji.py`.

Создать набор эмодзи и добавить в него эмодзи можно только в переписке с ботом @stickers; из приложения
`POST /v1/stickers/packs` создаёт только наборы стикеров.
Реакции: `PUT /v1/messages/<id>/reaction` принимает и `"emoji": "u:<id>"` — своё эмодзи.


## Капсула времени, секрет на месте, статус

- **Капсула времени**: `POST /v1/chats/<peer>/messages` с `"lock": {"open_at": <unix-время>}` (от 30 секунд до 10 лет).
  Получатель до срока видит только `lock` и `sealed: true` — без текста; в списке чатов и push — «⏳ Капсула времени».
  Когда время пришло, сервер будит получателя и шлёт push «Капсула времени открылась».
- **Секрет на месте**: `"lock": {"lat", "lon", "radius" (30–2000 м), "title"}`. Получатель открывает его на месте:
  `POST /v1/messages/<id>/unlock` с `{"lat", "lon", "acc"}` — сервер проверяет расстояние (`403 too_far` + `distance`).
  Можно совместить с `open_at`: сначала время, потом место. Нераскрытую капсулу/секрет нельзя переслать.
- **Статус «чем я занят»**: `PUT /v1/me/activity` `{"emoji", "text", "hours" (0.25–24)}`, `DELETE /v1/me/activity`.
  В профиле и у друзей в орбите приходит `activity: {emoji, text, until}`, пока не истёк.
Проверка: `python3 tests/test_capsule_secret.py`.


## Перенос переписки, дуэты, фото-цепочка

- **Экспорт**: `GET /v1/chats/<peer>/export?before=<ts>&limit=500` — история постранично (телефон собирает .zip:
  result.json как у Telegram, messages.txt как у WhatsApp, фото).
- **Импорт** из Telegram / WhatsApp: `POST /v1/chats/<peer>/import` `{"source", "messages": [{mine, text, date, name, attachments}]}`
  (до 500 за раз). Сообщения встают с исходными датами и полем `imported: {source, name}` — у обоих собеседников.
  Проверка: `python3 tests/test_chat_import.py`.
- **Дуэты**: шортс с `"duet_of": <id шортса>`; в ответе `duet: {id, author}`. Если автор запретил репосты — дуэт нельзя.
  Проверка: `python3 tests/test_duets.py`.
- **Фото-цепочка**: сообщение с `"chain": {"theme", "moderated"}` (личка и группы); `POST /v1/chains/<id>/items` (фото),
  `/items/<item>/approve`, `DELETE /items/<item>`, `/settings` (`moderated`, `closed`), `/reel` — коллаж в шортсы.
  С проверкой новые фото видит только владелец, пока не одобрит. Проверка: `python3 tests/test_photo_chain.py`.


## Скрепка: список, звук, контакт

- **Список** (чек-лист): сообщение с `"checklist": {"title", "items": [...], "others_add": true}` (личка и группы, до 50 пунктов).
  `POST /v1/checklists/<id>/items/<item>/toggle` — отметить/снять (видно кто и когда), `POST /v1/checklists/<id>/items {"text"}` —
  добавить пункт (если владелец разрешил другим). В сообщении — `checklist: {owner, others_add, items: [{id, text, done, done_by, done_at}]}`.
- **Контакт**: вложение `{"type": "contact", "user_id", "phone"?}` — сервер подставляет имя, @username, аватарку и номер
  (если человек его показывает). Изменить нельзя — только удалить. `GET /v1/contacts` теперь отдаёт и `phone`.
- **Звук**: `GET /v1/me/recent-audio` — музыка из своих переписок и групп (до 60, свежие сверху);
  `POST /v1/messages/<id>/audio-copy {"media_id"}` и `POST /v1/me/playlist/<track>/copy` — своя копия трека для отправки
  (удалят сообщение — оригинал останется). Проверка: `python3 tests/test_attach_extras.py`.

## Дни рождения

`GET /v1/me/birthdays?today=MM-DD` — у кого из контактов сегодня день рождения (день — по часам телефона).
Учитывается, только если человек показывает дату этому собеседнику (настройка «День рождения»). В ответе `age`, если указан год.
Проверка: `python3 tests/test_birthdays.py`.

## Сгорающее голосовое (прослушать один раз)

Вложение `{"type": "voice", "media_id", "once": true}`. Получатель не получает `media_id` в сообщении: файл выдаёт
`POST /v1/messages/<id>/once-open` — ровно один раз (повторно — 410). После прослушивания приложение зовёт
`POST /v1/messages/<id>/once-done` — в личке файл удаляется совсем, у отправителя голосовое помечается `consumed`
(в группе — счётчик `listened`). Переслать такое сообщение нельзя. Проверка: `python3 tests/test_once_voice.py`.

## Поиск по шортсам: вкладки, подфильтры, статистика

- `GET /v1/reels/search?q=&tab=best|video|photo&filter=all|unseen|seen|recent` — «Лучшее» ранжирует по совпадению и популярности,
  первый ролик помечен `top: true` («Топовое в поиске»). «Просмотрено» — только ролики, открытые на весь экран.
- `GET /v1/reels/search/extra?kind=people|music|tags&q=` — вкладки «Люди», «Музыка», «Хэштеги» («Места» ищет телефон через Карты Apple).
- `POST /v1/reels/search/track {"q", "events": [{"post_id", "kind": "shown"|"autoplay"|"open"}]}` — для статистики автора:
  в `GET /v1/posts/<id>/stats` поле `search` (увидели, проигрывалось само, открыли, доля открытий, запросы).
  Проверка: `python3 tests/test_reel_search_tabs.py`.

## Пометки шортса

`POST /v1/posts` с `"reel": true` принимает `"labels": [{"kind": "ai"|"place"|"ad"|"custom", "text"?}]` — до трёх
(«Создано ИИ», место, «Реклама», своя). В ответе поста — поле `labels`. Показываются над ником автора.

## Фильтр чатов («фокус»)

`PUT /v1/me/chat-focus {"folder": "personal"|"groups"|"channels"|"mentions"|null}` — пока выбран фильтр, push-уведомления
приходят только из подходящих чатов (в «Упоминаниях» — только когда вас отметили). `null` или «Новые» — все. Проверка: `python3 tests/test_chat_focus.py`.

## Поиск в мессенджере

- `GET /v1/me/search-hub` — `top`: 20 человек, с кем больше всего переписывался за 30 дней (`count`); `bots`: боты, с которыми общался (`monthly`).
- `GET /v1/me/shared?kind=media|files|links|music|voice&before=<ts>` — всё присланное во всех чатах (личные и группы), свежие сверху,
  по 60, с чатом-источником. Сгорающие голосовые, капсулы и секреты сюда не попадают. Проверка: `python3 tests/test_search_hub.py`.

## Продвижение шортсов

- `GET /v1/promo/options` — пакеты просмотров, цена за 1000 показов (`cpm`), «в топ» за сутки, страны, интересы. `free: true` — тестовый период.
- `POST /v1/posts/<id>/promote` `{"kind": "views"|"budget"|"top", "goal": "views"|"followers"|"profile", "views"|"daily"+"days"|"days",
  "targeting": {"age_min", "age_max", "gender": "m"|"f", "countries": [...], "cities": [...], "interests": [...]}}`.
  18+, ролики с жалобами и запрещёнными словами — `rejected`.
- Показ: в «Рекомендациях» — один продвигаемый ролик на страницу (у «в топ» — первым), в поиске — выше в выдаче. Одному зрителю — один раз,
  дневной лимит у «бюджета». Пометки для зрителей нет.
- `GET /v1/posts/<id>/promotions` — показы, просмотры, лайки, новые подписчики, график по дням; `POST /v1/promotions/<id>/pause|resume|stop`.
- Аудитория: пол и город — новые поля профиля (`PUT /v1/me {"gender", "city"}`, видны только владельцу), возраст — из даты рождения,
  страна — по номеру телефона, интересы — из «вкуса». Неизвестное зрителю не мешает показу.
- Проверка: `python3 tests/test_promo.py`.

### Модерация продвижений

Новое продвижение — `review`. Админ решает на странице **`/admin/promotions`** (вводит токен администратора) или через API:
`GET /v1/admin/promotions?status=review`, `POST /v1/admin/promotions/<id>/decide {"decision": "personal"|"ad"|"reject", "note", "erid"}`.
- `personal` — обычное видео (природа, жизнь): идёт без пометок.
- `ad` — товары/услуги/бренд: у зрителей «Реклама» и «О рекламодателе» (название, ИНН, erid). Если автор не указал рекламодателя —
  статус `needs_info`, автор заполняет `POST /v1/promotions/<id>/advertiser {"type": "ooo"|"ip"|"self", "name", "inn"}`.
- `reject` — с причиной. Каждое решение пишется в журнал `admin_access_log`, автору приходит уведомление.

## Теневое ограничение шортсов

Подпись или пометки со словами вроде «бесплатно», «купить», «заработок», «промокод», «розыгрыш», «казино», ссылками на t.me/wa.me
(или двумя «мягкими»: «скидка», «цена», «пиши в лс», «доставка»…) — шортс ограничивается: в «Рекомендациях» и поиске его видят только
первые `ORBITA_SHADOW_CAP` (по умолчанию 5) человек. Автор, его профиль и прямые ссылки — как обычно. Обходы вида «б е с п л а т н о»
и латиница («бeсплатно») тоже ловятся. Продвигать такие ролики нельзя, пока админ не одобрил продвижение (решение админа снимает ограничение).
Админ: раздел «Теневое ограничение» на `/admin/promotions`, `GET /v1/admin/shadow`, `POST /v1/admin/posts/<id>/shadow {"on": false|true}`.
Проверка: `python3 tests/test_shadow.py`.
