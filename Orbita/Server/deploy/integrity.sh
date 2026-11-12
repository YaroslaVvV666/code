#!/usr/bin/env bash
# Контроль целостности кода сервера: фиксируем SHA-256 всех .py и при запуске проверяем,
# что их никто не подменил. Если злоумышленник (или случайная правка) изменил код —
# служба не стартует (см. ExecStartPre в orbita.service).
#
#   integrity.sh generate [APPDIR] [MANIFEST]   — записать эталон (делается при деплое)
#   integrity.sh verify   [APPDIR] [MANIFEST]   — сверить; код выхода 1 при расхождении
#
# Зависит только от coreutils (find, sort, sha256sum) — ничего ставить не нужно.
set -euo pipefail

CMD="${1:?Использование: integrity.sh generate|verify [APPDIR] [MANIFEST]}"
APPDIR="${2:-$(cd "$(dirname "$0")/.." && pwd)}"
MANIFEST="${3:-$APPDIR/.integrity.sha256}"

# Детерминированный список: все .py, кроме кэша; пути — относительно APPDIR, отсортированы.
list_hashes() {
  cd "$APPDIR"
  find . -type f -name '*.py' ! -path './__pycache__/*' ! -path '*/__pycache__/*' \
    | LC_ALL=C sort \
    | xargs -d '\n' sha256sum
}

case "$CMD" in
  generate)
    list_hashes > "$MANIFEST.tmp"
    mv "$MANIFEST.tmp" "$MANIFEST"
    echo "Эталон целостности записан: $MANIFEST ($(wc -l < "$MANIFEST") файлов)"
    ;;
  verify)
    if [ ! -f "$MANIFEST" ]; then
      echo "НЕТ эталона целостности ($MANIFEST) — сначала выполните: integrity.sh generate" >&2
      exit 1
    fi
    current="$(list_hashes)"
    if ! diff <(printf '%s\n' "$current") "$MANIFEST" >/dev/null 2>&1; then
      echo "ЦЕЛОСТНОСТЬ НАРУШЕНА: код сервера отличается от эталона. Запуск остановлен." >&2
      echo "Отличия (слева — сейчас, справа — эталон):" >&2
      diff <(printf '%s\n' "$current") "$MANIFEST" >&2 || true
      exit 1
    fi
    echo "Целостность кода подтверждена ($(wc -l < "$MANIFEST") файлов)"
    ;;
  *)
    echo "Неизвестная команда: $CMD (нужно generate или verify)" >&2
    exit 2
    ;;
esac
