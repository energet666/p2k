#!/usr/bin/env bash
#
# Загружает официальную сборку Chromium (snapshot) в opt/chromium.
#   build/install-chromium.sh [ревизия]
#
# Загрузка идёт через px, если не задана переменная https_proxy
# или P2K_DIRECT=1.

set -Eeuo pipefail

P2K_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=common.sh
. "$P2K_DIR/lib/common.sh"
# shellcheck source=download.sh
. "$P2K_DIR/build/download.sh"

CHROMIUM_DIR="$(dirname -- "$CHROMIUM_BIN")"
SNAPSHOT_BASE="https://commondatastorage.googleapis.com/chromium-browser-snapshots/Linux_x64"

[[ $(uname -m) == x86_64 ]] || p2k_fail "сборка Chromium Linux_x64 требует x86_64"
for tool in curl unzip; do
    command -v "$tool" >/dev/null || p2k_fail "не найдена утилита $tool"
done
[[ ! -e $CHROMIUM_DIR ]] || p2k_fail "каталог уже существует: $CHROMIUM_DIR. Удалите его для переустановки."

temp_dir="$(mktemp -d)"
trap 'rm -rf -- "$temp_dir"; p2k_release_all' EXIT

p2k_download_setup

revision="${1:-}"
if [[ -z $revision ]]; then
    p2k_info "Узнаю номер последней сборки Chromium..."
    p2k_download "$SNAPSHOT_BASE/LAST_CHANGE" "$temp_dir/LAST_CHANGE"
    revision="$(<"$temp_dir/LAST_CHANGE")"
fi
[[ $revision =~ ^[0-9]+$ ]] || p2k_fail "некорректная ревизия Chromium: $revision"

p2k_info "Загружаю Chromium, ревизия $revision (около 200 МБ)..."
p2k_download "$SNAPSHOT_BASE/$revision/chrome-linux.zip" "$temp_dir/chrome.zip"

unzip -q "$temp_dir/chrome.zip" -d "$temp_dir/unpacked"
[[ -x $temp_dir/unpacked/chrome-linux/chrome ]] ||
    p2k_fail "в архиве нет исполняемого файла chrome-linux/chrome"
mkdir -p -- "$(dirname -- "$CHROMIUM_DIR")"
mv -- "$temp_dir/unpacked/chrome-linux" "$CHROMIUM_DIR"
printf '%s\n' "$revision" >"$CHROMIUM_DIR/.p2k-revision"

p2k_info "Chromium установлен: $CHROMIUM_DIR (ревизия $revision)"
