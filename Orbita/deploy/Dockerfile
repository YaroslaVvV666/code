# Образ сервера Orbita. Контекст сборки — папка Orbita/ (см. docker-compose.yml).
FROM python:3.12-slim

WORKDIR /app

COPY deploy/requirements-prod.txt /app/requirements-prod.txt
RUN pip install --no-cache-dir -r requirements-prod.txt

COPY Server/ /app/

# Ключ шифрования и (в режиме диска) медиа лежат в /data — монтируется томом, чтобы переживать пересоздание.
ENV ORBITA_HOME=/data \
    ORBITA_PORT=8080
VOLUME ["/data"]

# Воркеры слушают 8080..8080+N-1; наружу их отдаёт nginx.
EXPOSE 8080-8095

CMD ["python3", "server.py"]
