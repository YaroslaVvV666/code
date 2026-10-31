# Тесты сервера

## Дымовой тест (smoke)

Прогоняет по HTTP основные сценарии против запущенного сервера: здоровье, сессии, переписку, группы,
реакции/заметки, медиа (загрузка/скачивание/диапазон), звонки, long-poll события, метрики, лимиты и
(если задан токен) законную выгрузку.

Поднять сервер локально и прогнать:

```bash
# терминал 1 — сервер (SQLite, без Redis)
ORBITA_OTP_DEV=1 ORBITA_ADMIN_TOKEN=adm-test python3 Server/server.py

# терминал 2 — тест
ORBITA_ADMIN_TOKEN=adm-test python3 Server/tests/smoke.py
```

Против боевой связки (PostgreSQL + Redis + воркеры) — то же самое, только `ORBITA_TEST_URL`
указывает на адрес сервера/nginx:

```bash
ORBITA_TEST_URL=https://ваш-домен ORBITA_ADMIN_TOKEN=... python3 Server/tests/smoke.py
```

Код выхода `0` — всё прошло, `1` — есть провалы (имена провалов печатаются в конце).

Проверено на обоих режимах: один процесс (SQLite, память) и 3 воркера (PostgreSQL + Redis) — 22/22.
