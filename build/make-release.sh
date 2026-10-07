#!/usr/bin/env bash
#
# Собирает релизный архив p2k, в котором уже лежат px, Xray и Chromium.
# На машине пользователя после распаковки ничего загружать не нужно.
#
#   build/make-release.sh            собрать из того, что есть в opt
#   build/make-release.sh --update   сначала загрузить свежие Xray и Chromium
#
# Недостающие Xray и Chromium загружаются автоматически. Версии можно
# закрепить переменными XRAY_VERSION (например 26.3.27) и CHROMIUM_REVISION.
# Загрузка идёт через px (см. build/download.sh), P2K_DIRECT=1 отключает это.
#
# Результат: dist/p2k-linux-x86_64-ГГГГММДД.tar.gz и файл .sha256 рядом.
# Личный xray-config.json и каталог data в архив не попадают.

set -Eeuo pipefail

P2K_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$P2K_DIR/lib/common.sh"

DIST_DIR="${DIST_DIR:-$P2K_DIR/dist}"
XRAY_DIR="$(dirname -- "$XRAY_BIN")"
CHROMIUM_DIR="$(dirname -- "$CHROMIUM_BIN")"

# Что входит в релиз. Пути относительно корня проекта.
RELEASE_FILES=(
    README.md
    setup.sh
    p2k-terminal.sh
    p2k-chrome.sh
    p2k-check.sh
    p2k-xray-config.sh
    px.ini
    xray-config.example.json
    lib
    opt/px
    opt/xray
    opt/chromium
)

update=0
for arg in "$@"; do
    case "$arg" in
        --update) update=1 ;;
        -h | --help)
            sed -n '3,15s/^# \{0,1\}//p' "$0"
            exit 0
            ;;
        *) p2k_fail "неизвестный параметр: $arg" ;;
    esac
done

for tool in tar gzip sha256sum; do
    command -v "$tool" >/dev/null || p2k_fail "для сборки нужна утилита $tool"
done

staging=""
trap '[[ -n $staging ]] && rm -rf -- "$staging"' EXIT

# Загружает компонент во временный каталог и заменяет им текущий,
# чтобы неудачная загрузка не оставила проект без программы.
refresh_component() {
    local installer="$1" target_dir="$2" bin_var="$3" bin_name="$4" version="$5"
    local temp
    temp="$(mktemp -d "$P2K_DIR/opt/.update.XXXXXX")"
    if ! env "$bin_var=$temp/new/$bin_name" "$installer" ${version:+"$version"}; then
        rm -rf -- "$temp"
        p2k_fail "не удалось загрузить компонент установщиком $installer"
    fi
    rm -rf -- "$target_dir"
    mv -- "$temp/new" "$target_dir"
    rm -rf -- "$temp"
}

mkdir -p -- "$P2K_DIR/opt"
if ((update)) || [[ ! -x $XRAY_BIN ]]; then
    refresh_component "$P2K_DIR/build/install-xray.sh" "$XRAY_DIR" \
        XRAY_BIN xray "${XRAY_VERSION:-}"
fi
if ((update)) || [[ ! -x $CHROMIUM_BIN ]]; then
    refresh_component "$P2K_DIR/build/install-chromium.sh" "$CHROMIUM_DIR" \
        CHROMIUM_BIN chrome "${CHROMIUM_REVISION:-}"
fi

[[ -x $PX_BIN ]] || p2k_fail "нет px: $PX_BIN"
[[ -x $XRAY_BIN ]] || p2k_fail "нет Xray: $XRAY_BIN"
[[ -x $CHROMIUM_BIN ]] || p2k_fail "нет Chromium: $CHROMIUM_BIN"

xray_version="$("$XRAY_BIN" version | sed -n 1p)"
chromium_revision="$(cat "$CHROMIUM_DIR/.p2k-revision" 2>/dev/null || echo неизвестна)"
chromium_version="$("$CHROMIUM_BIN" --version 2>/dev/null || echo неизвестна)"

stamp="$(date +%Y%m%d)"
name="p2k-linux-x86_64-$stamp"
staging="$(mktemp -d)"
root="$staging/p2k"
mkdir -p -- "$root"

(cd -- "$P2K_DIR" && tar -cf - --exclude='.update.*' -- "${RELEASE_FILES[@]}") |
    (cd -- "$root" && tar -xpf -)

cat >"$root/VERSIONS.txt" <<EOF
p2k для Linux x86_64, сборка $stamp

px:       готовая сборка из opt/px
Xray:     $xray_version
Chromium: $chromium_version, snapshot $chromium_revision

Архив не содержит паролей, билетов Kerberos, профилей браузера,
журналов и личной конфигурации Xray.
EOF

# Единые права: всё читается всеми, скрипты и программы запускаются.
chmod -R u+rwX,go+rX,go-w -- "$root"
chmod +x -- "$root"/p2k-*.sh "$root/setup.sh" "$root/opt/px/px" \
    "$root/opt/xray/xray" "$root/opt/chromium/chrome"

mkdir -p -- "$DIST_DIR"
archive="$DIST_DIR/$name.tar.gz"
tar -C "$staging" --owner=0 --group=0 --numeric-owner -czf "$archive" p2k
(cd -- "$DIST_DIR" && sha256sum -- "$name.tar.gz" >"$name.tar.gz.sha256")

p2k_info "Релиз собран: $archive ($(du -h -- "$archive" | cut -f1))"
cat "$root/VERSIONS.txt"
