#!/usr/bin/env bash
#
# Однократная подготовка p2k на новой машине.
#
#   ./setup.sh               подготовить всё
#   ./setup.sh --uninstall   удалить ярлыки p2k из меню и с рабочего стола
#
# Скрипт восстанавливает права на запуск, создаёт ярлыки и проверяет,
# что всё готово к работе. Ничего не загружает и не устанавливает:
# px, Xray и Chromium уже лежат в каталоге opt.

set -Eeuo pipefail

P2K_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib/common.sh
. "$P2K_DIR/lib/common.sh"

APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
LAUNCHERS=(p2k-terminal p2k-chrome)

action=install
for arg in "$@"; do
    case "$arg" in
        --uninstall) action=uninstall ;;
        -h | --help)
            sed -n '3,10s/^# \{0,1\}//p' "$0"
            exit 0
            ;;
        *) p2k_fail "неизвестный параметр: $arg" ;;
    esac
done

# Каталоги рабочего стола. В Astra Linux (Fly) это обычно ~/Desktops/Desktop1.
desktop_dirs() {
    local dir
    if command -v xdg-user-dir >/dev/null; then
        dir="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
        [[ -n $dir && $dir != "$HOME" && -d $dir ]] && printf '%s\n' "$dir"
    fi
    for dir in "$HOME/Desktops/Desktop1" "$HOME/Desktop" "$HOME/Рабочий стол"; do
        [[ -d $dir ]] && printf '%s\n' "$dir"
    done | sort -u
}

# Экранирование пути для строки Exec в .desktop-файле.
desktop_exec_quote() {
    local s="$1"
    s="${s//\\/\\\\\\\\}"
    s="${s//\"/\\\\\"}"
    s="${s//\`/\\\\\`}"
    s="${s//\$/\\\\\$}"
    printf '"%s"' "$s"
}

write_launcher() {
    local file="$1" name="$2" comment="$3" script="$4" icon="$5" categories="$6"
    cat >"$file" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=$name
Comment=$comment
Exec=$(desktop_exec_quote "$script")
Path=$P2K_DIR
Icon=$icon
Terminal=false
Categories=$categories
EOF
    chmod +x -- "$file"
}

remove_launchers() {
    local dir name
    for name in "${LAUNCHERS[@]}"; do
        rm -f -- "$APPS_DIR/$name.desktop"
        while IFS= read -r dir; do
            rm -f -- "$dir/$name.desktop"
        done < <(desktop_dirs)
    done
}

install_launchers() {
    local dir name chrome_icon=web-browser
    [[ -f $P2K_DIR/opt/chromium/product_logo_48.png ]] &&
        chrome_icon="$P2K_DIR/opt/chromium/product_logo_48.png"

    mkdir -p -- "$APPS_DIR"
    write_launcher "$APPS_DIR/p2k-terminal.desktop" \
        "p2k: терминал через прокси" \
        "Терминал, в котором программы работают через корпоративный прокси" \
        "$P2K_DIR/p2k-terminal.sh" utilities-terminal "System;TerminalEmulator;Network;"
    write_launcher "$APPS_DIR/p2k-chrome.desktop" \
        "p2k: Chromium через Xray" \
        "Отдельный Chromium, работающий через Xray и корпоративный прокси" \
        "$P2K_DIR/p2k-chrome.sh" "$chrome_icon" "Network;WebBrowser;"

    while IFS= read -r dir; do
        for name in "${LAUNCHERS[@]}"; do
            cp -f -- "$APPS_DIR/$name.desktop" "$dir/$name.desktop"
            chmod +x -- "$dir/$name.desktop"
        done
        p2k_info "Ярлыки добавлены на рабочий стол: $dir"
    done < <(desktop_dirs)
    p2k_info "Ярлыки добавлены в меню приложений"
}

if [[ $action == uninstall ]]; then
    remove_launchers
    p2k_info "Ярлыки p2k удалены. Каталог проекта можно просто удалить."
    exit 0
fi

problems=()

# 1. Права на запуск теряются при копировании через некоторые носители.
chmod +x -- "$P2K_DIR"/p2k-*.sh "$P2K_DIR/setup.sh"
[[ -f $PX_BIN ]] && chmod +x -- "$PX_BIN"
[[ -f $XRAY_BIN ]] && chmod +x -- "$XRAY_BIN"
if [[ -f $CHROMIUM_BIN ]]; then
    chmod +x -- "$CHROMIUM_BIN"
    chmod +x -- "$(dirname -- "$CHROMIUM_BIN")"/chrome_crashpad_handler 2>/dev/null || true
fi

missing=()
[[ -x $PX_BIN ]] || missing+=("px ($PX_BIN)")
[[ -x $XRAY_BIN ]] || missing+=("Xray ($XRAY_BIN)")
[[ -x $CHROMIUM_BIN ]] || missing+=("Chromium ($CHROMIUM_BIN)")
if ((${#missing[@]})); then
    p2k_fail "комплект неполный, нет: ${missing[*]}. Распакуйте релизный архив p2k заново."
fi

# 2. Kerberos.
if ! command -v klist >/dev/null; then
    p2k_info "Наличие билета Kerberos не проверялось: в системе нет klist"
elif p2k_kerberos_ok; then
    p2k_info "Билет Kerberos сеанса найден"
else
    p2k_kerberos_hint >&2
    problems+=("нет билета Kerberos")
fi

# 3. Ярлыки.
install_launchers

# 4. Конфигурация Xray.
if [[ ! -f $XRAY_CONFIG ]]; then
    problems+=("нет xray-config.json: положите свой конфиг Xray в $XRAY_CONFIG (см. README.md)")
elif [[ -x $XRAY_BIN ]] && ! "$XRAY_BIN" run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
    problems+=("xray-config.json содержит ошибки: проверьте его командой opt/xray/xray run -test -config xray-config.json")
fi

printf '\n'
if ((${#problems[@]} == 0)); then
    p2k_info "Готово. Используйте ярлыки «p2k: терминал через прокси» и «p2k: Chromium через Xray»."
else
    p2k_info "Подготовка завершена, но осталось сделать:"
    for item in "${problems[@]}"; do
        printf '  * %s\n' "$item"
    done
fi
