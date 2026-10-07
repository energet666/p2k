#!/usr/bin/env bash
#
# Запускает px, Xray и отдельный Chromium, который ходит в интернет
# через Xray. Xray, в свою очередь, подключается к своему серверу через px
# и корпоративный прокси.
#
#   app/p2k-chrome.sh [аргументы Chromium...]
#
# Все данные браузера (профиль, кэш, служебные файлы) хранятся в каталоге
# data/chromium внутри проекта. Домашний каталог пользователя не меняется.
# Загруженные файлы сохраняются в обычный каталог загрузок.

set -Eeuo pipefail

P2K_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib/common.sh
. "$P2K_DIR/lib/common.sh"

CHROMIUM_HOME="${CHROMIUM_HOME:-$P2K_DATA_DIR/chromium}"
CHROMIUM_PROFILE="$CHROMIUM_HOME/profile"
CHROMIUM_LOG="$P2K_LOG_DIR/chromium.log"

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    cat <<EOF
Использование: $(basename -- "$0") [аргументы Chromium...]

Запускает px, Xray (конфиг: $XRAY_CONFIG) и Chromium через Xray.
Профиль браузера: $CHROMIUM_PROFILE
EOF
    exit 0
fi

# Каталог загрузок пользователя, определённый до подмены HOME.
real_download_dir() {
    local dir=""
    if command -v xdg-user-dir >/dev/null; then
        dir="$(xdg-user-dir DOWNLOAD 2>/dev/null || true)"
    fi
    if [[ -z $dir || $dir == "$HOME" || ! -d $dir ]]; then
        local candidate
        for candidate in "$HOME/Загрузки" "$HOME/Downloads"; do
            [[ -d $candidate ]] && dir="$candidate" && break
        done
    fi
    printf '%s\n' "${dir:-$HOME}"
}

json_string() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "$s"
}

# При первом запуске задаёт каталог загрузок, иначе Chromium сохранял бы
# файлы внутрь data/chromium.
prepare_profile() {
    local prefs="$CHROMIUM_PROFILE/Default/Preferences"
    mkdir -p -- "$CHROMIUM_PROFILE/Default" "$CHROMIUM_HOME/.config" \
        "$CHROMIUM_HOME/.cache" "$CHROMIUM_HOME/.local/share"
    [[ -e $prefs ]] && return 0
    printf '{"download":{"default_directory":%s,"directory_upgrade":true},"savefile":{"default_directory":%s}}\n' \
        "$(json_string "$1")" "$(json_string "$1")" >"$prefs"
}

p2k_require_tools
[[ -x $CHROMIUM_BIN ]] ||
    p2k_fail "Chromium не найден: $CHROMIUM_BIN. Распакуйте релизный архив p2k заново и запустите setup.sh."

trap p2k_release_all EXIT
trap 'exit 130' INT
trap 'exit 129' HUP
trap 'exit 143' TERM

p2k_xray_check
p2k_px_acquire
p2k_xray_acquire

download_dir="$(real_download_dir)"
prepare_profile "$download_dir"

chromium_args=(
    --user-data-dir="$CHROMIUM_PROFILE"
    --proxy-server="$P2K_XRAY_URL"
    --no-first-run
    --no-default-browser-check
    --password-store=basic
    --force-webrtc-ip-handling-policy=disable_non_proxied_udp
)
if [[ ${P2K_CHROME_NO_SANDBOX:-0} == 1 ]]; then
    p2k_warn "песочница Chromium отключена (P2K_CHROME_NO_SANDBOX=1)"
    chromium_args+=(--no-sandbox)
fi

p2k_info "Запускаю Chromium через $P2K_XRAY_URL (журнал: $CHROMIUM_LOG)"
printf '\n=== %s запуск\n' "$(date '+%F %T')" >>"$CHROMIUM_LOG"
started_at=$SECONDS
status=0
(
    p2k_close_extra_fds
    cd -- "$(dirname -- "$CHROMIUM_BIN")"
    # Chromium и его библиотеки пишут служебные файлы в домашний каталог.
    # Подменяем его, чтобы всё оставалось внутри проекта.
    export HOME="$CHROMIUM_HOME"
    export XDG_CONFIG_HOME="$CHROMIUM_HOME/.config"
    export XDG_CACHE_HOME="$CHROMIUM_HOME/.cache"
    export XDG_DATA_HOME="$CHROMIUM_HOME/.local/share"
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
    exec "$CHROMIUM_BIN" "${chromium_args[@]}" "$@"
) </dev/null >>"$CHROMIUM_LOG" 2>&1 || status=$?

if ((status != 0 && SECONDS - started_at < 10)); then
    if awk '/^=== /{last=""} {last=last $0 "\n"} END{printf "%s", last}' \
        "$CHROMIUM_LOG" 2>/dev/null | grep -q -i 'sandbox'; then
        p2k_fail "Chromium не запустился из-за песочницы (sandbox). Обычно это значит, что в системе запрещены пользовательские пространства имён или скрипт запущен от root.
Попробуйте: P2K_CHROME_NO_SANDBOX=1 $P2K_DIR/p2k-chrome.sh
Подробности в $CHROMIUM_LOG"
    fi
    p2k_fail "Chromium завершился с ошибкой $status. Подробности в $CHROMIUM_LOG"
fi
exit 0
