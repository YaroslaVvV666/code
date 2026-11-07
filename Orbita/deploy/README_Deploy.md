# Разворачивание Orbita (боевой стек)

Один `docker compose` поднимает всё: PostgreSQL + Redis + сервер (несколько воркеров) + nginx.

```bash
cd Orbita/deploy
cp .env.example .env
# отредактируйте .env: пароль БД, число воркеров, (желательно) ORBITA_MASTER_KEY и ORBITA_ADMIN_TOKEN
docker compose up -d --build
```

Сервер окажется за nginx на порту 80 (для 443/TLS — раскомментируйте порт в `docker-compose.yml`, сертификаты
и строки `ssl_*` в `nginx.conf`). Проверка: `curl http://localhost/v1/ping`.

Прогнать дымовой тест по живому стеку:

```bash
ORBITA_TEST_URL=http://localhost ORBITA_ADMIN_TOKEN=<из .env> python3 ../Server/tests/smoke.py
```

## Важное

- **Число воркеров.** `ORBITA_WORKERS` в `.env` и число строк `server app:808x` в `nginx.conf` должны совпадать
  (по умолчанию 4 → порты 8080..8083).
- **Мастер-ключ.** Без `ORBITA_MASTER_KEY` ключ создаётся в томе `app-data` (`/data/keys/master.key`). Сделайте
  его резервную копию отдельно от данных — без него переписка и медиа не расшифруются.
- **Масштаб по машинам.** Для нескольких серверов вынесите БД и Redis в управляемые сервисы, а в `upstream`
  nginx добавьте адреса воркеров на разных хостах. Детали и тюнинг — в `../docs/scaling.md`.
- **Комплаенс.** `ORBITA_ADMIN_TOKEN` включает ручки законной выгрузки; закройте их на уровне сети
  (в `nginx.conf` `/v1/admin/` можно ограничить allowlist'ом по IP). См. `../docs/compliance.md`.

## Что внутри

| Сервис | Образ | Роль |
|---|---|---|
| db | postgres:16 | основная база (том `db-data`) |
| cache | redis:7 | realtime-состояние, кэш, события, лимиты |
| app | собирается из `Dockerfile` | сервер Orbita, мастер + N воркеров |
| nginx | nginx:1.27-alpine | TLS, «липкая» балансировка, лимит по IP |
