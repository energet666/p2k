#!/usr/bin/env bash
#
# Загружает Xray-core в app/opt/xray и проверяет контрольную сумму.
#   build/install-xray.sh [версия]     например: build/install-xray.sh 26.3.27
#
# Загрузка идёт через px, если не задана переменная https_proxy
# или P2K_DIRECT=1.

set -Eeuo pipefail

P2K_ROOT="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)"
P2K_DIR="$P2K_ROOT/app"
# shellcheck source=../app/lib/common.sh
. "$P2K_DIR/lib/common.sh"
# shellcheck source=download.sh
. "$P2K_ROOT/build/download.sh"

XRAY_DIR="$(dirname -- "$XRAY_BIN")"
RELEASE_BASE="https://github.com/XTLS/Xray-core/releases"

[[ $(uname -m) == x86_64 ]] || p2k_fail "сборка Xray-linux-64 требует x86_64"
for tool in curl unzip sha256sum; do
    command -v "$tool" >/dev/null || p2k_fail "не найдена утилита $tool"
done
[[ ! -e $XRAY_DIR ]] || p2k_fail "каталог уже существует: $XRAY_DIR. Удалите его для переустановки."

version="${1:-latest}"
if [[ $version == latest ]]; then
    download_base="$RELEASE_BASE/latest/download"
else
    [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || p2k_fail "версия должна иметь вид 26.3.27"
    download_base="$RELEASE_BASE/download/v$version"
fi

temp_dir="$(mktemp -d)"
trap 'rm -rf -- "$temp_dir"; p2k_release_all' EXIT

p2k_download_setup
p2k_info "Загружаю Xray-core ($version)..."
p2k_download "$download_base/Xray-linux-64.zip" "$temp_dir/xray.zip"
p2k_download "$download_base/Xray-linux-64.zip.dgst" "$temp_dir/xray.zip.dgst"

expected="$(awk -F '= ' '$1 == "SHA2-256" { print $2 }' "$temp_dir/xray.zip.dgst")"
actual="$(sha256sum "$temp_dir/xray.zip")"
actual="${actual%% *}"
[[ -n $expected && $actual == "$expected" ]] || p2k_fail "контрольная сумма Xray-core не совпала"

unzip -q "$temp_dir/xray.zip" -d "$temp_dir/xray"
[[ -x $temp_dir/xray/xray ]] || p2k_fail "в архиве нет исполняемого файла xray"
mkdir -p -- "$(dirname -- "$XRAY_DIR")"
mv -- "$temp_dir/xray" "$XRAY_DIR"

"$XRAY_DIR/xray" version | sed -n 1p >"$XRAY_DIR/.p2k-version"
p2k_info "Xray-core установлен: $(cat "$XRAY_DIR/.p2k-version")"
