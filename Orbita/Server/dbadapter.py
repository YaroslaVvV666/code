"""Слой базы данных: один и тот же код сервера работает на SQLite (по умолчанию, для локального запуска)
и на PostgreSQL (для продакшена — выдерживает много одновременных запросов и не ограничен одним писателем).

Выбор: переменная окружения DATABASE_URL (postgres://user:pass@host/db) — тогда Postgres, иначе SQLite.
Код сервера пишет обычный SQLite-SQL; для Postgres запросы переводятся на лету (плейсхолдеры, INSERT OR REPLACE/IGNORE,
IS NOT, типы BLOB/REAL). Строки в обоих случаях ведут себя как словарь: row["col"], "col" in row.keys()."""

import os
import re
import sqlite3


# Таблицы с INSERT OR REPLACE: колонки первичного ключа (для перевода в ON CONFLICT ... DO UPDATE)
REPLACE_KEYS = {
    "call_log": ["id"],
    "group_restricted": ["group_id", "user_id"],
    "imported_contacts": ["owner", "phone_idx"],
    "media_review": ["media_id"],
    "message_notes": ["user_id", "message_id"],
    "notif_state": ["user_id"],
    "pins": ["chat_key", "message_id"],
    "post_reports": ["post_id", "reporter"],
    "reactions": ["message_id", "user_id"],
    "user_langs": ["user_id"],
    "wall_reactions": ["entry_id", "user_id"],
}


def make_db(data_dir):
    url = os.environ.get("DATABASE_URL", "").strip()
    if url.startswith("postgres"):
        return PostgresDB(url)
    return SQLiteDB(data_dir)


# ---------------- SQLite (как было) ----------------

class SQLiteDB:
    backend = "sqlite"

    def __init__(self, data_dir):
        self.conn = sqlite3.connect(os.path.join(data_dir, "orbita-v2.db"), check_same_thread=False, isolation_level=None)
        self.conn.row_factory = sqlite3.Row
        for pragma in ("foreign_keys = ON", "journal_mode = WAL", "secure_delete = ON", "synchronous = NORMAL",
                       "cache_size = -65536", "temp_store = MEMORY", "mmap_size = 268435456",
                       "busy_timeout = 5000", "wal_autocheckpoint = 2000"):
            self.conn.execute("PRAGMA " + pragma)

    def execute(self, sql, args=()):
        return self.conn.execute(sql, args)

    def executescript(self, sql):
        self.conn.executescript(sql)

    def columns(self, table):
        return [r["name"] for r in self.conn.execute("PRAGMA table_info(%s)" % table)]

    def add_column(self, table, ddl):
        self.conn.execute("ALTER TABLE %s ADD COLUMN %s" % (table, ddl))


# ---------------- PostgreSQL ----------------

class _Result:
    """Обёртка курсора: совместима с тем, как сервер читает результат (fetchall / fetchone / for row in ...)."""
    def __init__(self, rows):
        self._rows = rows

    def fetchall(self):
        return self._rows

    def fetchone(self):
        return self._rows[0] if self._rows else None

    def __iter__(self):
        return iter(self._rows)


class PostgresDB:
    backend = "postgres"

    def __init__(self, url):
        import psycopg2
        from psycopg2.extras import RealDictCursor
        self._psycopg2 = psycopg2
        self._RealDict = RealDictCursor
        self._url = url
        # Весь доступ к БД в сервере сериализован глобальным LOCK (как и у SQLite — одно соединение),
        # поэтому держим одно общее соединение в режиме autocommit (каждый запрос — своя транзакция, как isolation_level=None).
        self._conn_obj = None
        self._get_conn()

    def _get_conn(self):
        c = self._conn_obj
        if c is None or c.closed:
            c = self._psycopg2.connect(self._url)
            c.autocommit = True
            c.set_client_encoding("UTF8")  # иначе эмодзи/кириллица падают, если кластер в SQL_ASCII/C-локали
            self._conn_obj = c
        return c

    # --- перевод SQLite-SQL в Postgres ---

    @staticmethod
    def _is_write(sql):
        head = sql.lstrip()[:6].upper()
        return head not in ("SELECT",)

    def _translate(self, sql):
        s = sql
        # psycopg2 трактует % как свой плейсхолдер — удваиваем литеральные % (например LIKE 'demo-%')
        if "%" in s:
            s = s.replace("%", "%%")
        # плейсхолдеры: SQLite-нумерованные ?1,?2 (один аргумент можно переиспользовать) -> именованные %(aN)s;
        # обычные ? -> позиционные %s. Смешивать их в одном запросе нельзя (код и не смешивает).
        if re.search(r"\?\d", s):
            s = re.sub(r"\?(\d+)", lambda m: "%(a" + m.group(1) + ")s", s)
        else:
            s = s.replace("?", "%s")
        # DDL через DB.execute (CREATE/ALTER): типы и SQLite-only синтаксис, как в _translate_ddl
        head = s.lstrip()[:6].upper()
        if head in ("CREATE", "ALTER "):
            s = re.sub(r"\bBLOB\b", "BYTEA", s)
            s = re.sub(r"\bREAL\b", "DOUBLE PRECISION", s)
            s = re.sub(r"\bWITHOUT\s+ROWID\b", "", s, flags=re.I)
            s = re.sub(r"\bAUTOINCREMENT\b", "", s, flags=re.I)
            return s
        # IS NOT 'literal' -> IS DISTINCT FROM 'literal' (в Postgres IS NOT только с NULL/TRUE/FALSE)
        s = re.sub(r"IS\s+NOT\s+('(?:[^']|'')*')", r"IS DISTINCT FROM \1", s, flags=re.I)
        # INSERT OR IGNORE -> INSERT ... ON CONFLICT DO NOTHING
        m = re.match(r"\s*INSERT\s+OR\s+IGNORE\s+INTO\s+(\w+)", s, re.I)
        if m:
            s = re.sub(r"INSERT\s+OR\s+IGNORE", "INSERT", s, count=1, flags=re.I)
            if "ON CONFLICT" not in s.upper():
                s = s.rstrip().rstrip(";") + " ON CONFLICT DO NOTHING"
            return s
        # INSERT OR REPLACE -> INSERT ... ON CONFLICT (pk) DO UPDATE SET col=EXCLUDED.col ...
        m = re.match(r"\s*INSERT\s+OR\s+REPLACE\s+INTO\s+(\w+)\s*\(([^)]*)\)", s, re.I)
        if m:
            table, cols = m.group(1), [c.strip() for c in m.group(2).split(",")]
            keys = REPLACE_KEYS.get(table)
            s = re.sub(r"INSERT\s+OR\s+REPLACE", "INSERT", s, count=1, flags=re.I)
            if keys and "ON CONFLICT" not in s.upper():
                updates = [c for c in cols if c not in keys]
                setter = ", ".join("%s = EXCLUDED.%s" % (c, c) for c in updates) or keys[0] + " = EXCLUDED." + keys[0]
                s = s.rstrip().rstrip(";") + " ON CONFLICT (%s) DO UPDATE SET %s" % (", ".join(keys), setter)
            return s
        return s

    @staticmethod
    def _translate_ddl(sql):
        # типы: BLOB -> BYTEA, REAL -> DOUBLE PRECISION; PRAGMA/без-rowid убираем
        out = []
        for stmt in _split_statements(sql):
            st = stmt.strip()
            if not st or st.upper().startswith("PRAGMA"):
                continue
            st = re.sub(r"\bBLOB\b", "BYTEA", st)
            st = re.sub(r"\bREAL\b", "DOUBLE PRECISION", st)
            st = re.sub(r"\bWITHOUT\s+ROWID\b", "", st, flags=re.I)
            st = re.sub(r"\bAUTOINCREMENT\b", "", st, flags=re.I)
            out.append(st)
        return out

    def _run_cursor(self, work):
        """Выполнить work(conn); при разрыве соединения — переподключиться и повторить один раз."""
        try:
            return work(self._get_conn())
        except (self._psycopg2.OperationalError, self._psycopg2.InterfaceError):
            try:
                if self._conn_obj and not self._conn_obj.closed:
                    self._conn_obj.close()
            except Exception:
                pass
            self._conn_obj = None
            return work(self._get_conn())

    def execute(self, sql, args=()):
        tsql = self._translate(sql)
        # нумерованные плейсхолдеры переведены в %(aN)s — передаём аргументы словарём a1,a2,…
        if re.search(r"\?\d", sql):
            params = {"a%d" % (i + 1): v for i, v in enumerate(args)}
        else:
            params = tuple(args)

        def work(conn):
            with conn.cursor(cursor_factory=self._RealDict) as cur:
                cur.execute(tsql, params)
                return _Result(cur.fetchall() if cur.description else [])
        return self._run_cursor(work)

    def executescript(self, sql):
        stmts = self._translate_ddl(sql)

        def work(conn):
            with conn.cursor() as cur:
                for st in stmts:
                    cur.execute(st)
        return self._run_cursor(work)

    def columns(self, table):
        def work(conn):
            with conn.cursor(cursor_factory=self._RealDict) as cur:
                cur.execute("SELECT column_name AS name FROM information_schema.columns WHERE table_name = %s", (table,))
                return [r["name"] for r in cur.fetchall()]
        return self._run_cursor(work)

    def add_column(self, table, ddl):
        ddl = re.sub(r"\bBLOB\b", "BYTEA", ddl)
        ddl = re.sub(r"\bREAL\b", "DOUBLE PRECISION", ddl)

        def work(conn):
            with conn.cursor() as cur:
                cur.execute("ALTER TABLE %s ADD COLUMN IF NOT EXISTS %s" % (table, ddl))
        return self._run_cursor(work)


def _split_statements(script):
    """Разбить набор CREATE-ов на отдельные команды. В нашей схеме точка с запятой встречается только между
    командами (внутри значений по умолчанию их нет), поэтому простого разделения достаточно."""
    return [s for s in script.split(";")]
