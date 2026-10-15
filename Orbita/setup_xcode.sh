#!/bin/bash
# Создаёт готовый проект Xcode со всеми настройками (Info.plist, разрешения, URL-схема) и открывает его.
#   bash setup_xcode.sh
set -e
cd "$(dirname "$0")"
if ! command -v xcodegen >/dev/null 2>&1; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "Нужен Homebrew: https://brew.sh  (вставьте команду с сайта в Терминал, потом запустите этот скрипт снова)"; exit 1
  fi
  brew install xcodegen
fi
xcodegen generate
echo "Готово. Открываю проект. В Xcode: Orbita → Signing & Capabilities → выберите свой Team, затем ⌘R."
open Orbita.xcodeproj
