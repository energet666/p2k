#!/usr/bin/env bash
#
# Подготовка p2k. Запускается один раз после распаковки архива и повторно,
# если каталог перенесли в другое место.
#
#   ./setup.sh               проверить всё, настроить Xray, создать ярлыки
#   ./setup.sh --uninstall   удалить ярлыки p2k из меню и с рабочего стола,
#                            созданные прежними версиями p2k
#
# Скрипт проверяет комплект программ, билет Kerberos и вход на
# корпоративный прокси, предлагает вставить ссылку на сервер Xray и
# создаёт ярлыки рядом с собой. Вне каталога p2k он ничего не создаёт
# и ничего не загружает.

set -Eeuo pipefail

P2K_ROOT="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
P2K_DIR="$P2K_ROOT/app"

if [[ ! -f $P2K_DIR/lib/common.sh ]]; then
    printf 'Ошибка: рядом с setup.sh нет каталога app. Распакуйте архив p2k заново.\n' >&2
    exit 1
fi

# shellcheck source=app/lib/common.sh
. "$P2K_DIR/lib/common.sh"
# shellcheck source=app/lib/check.sh
. "$P2K_DIR/lib/check.sh"
# shellcheck source=app/lib/ui.sh
. "$P2K_DIR/lib/ui.sh"

APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
LAUNCHERS=(p2k-terminal p2k-chrome)
STEPS=5

action=install
for arg in "$@"; do
    case "$arg" in
        --uninstall) action=uninstall ;;
        -h | --help)
            sed -n '3,14s/^# \{0,1\}//p' "$0"
            exit 0
            ;;
        *) p2k_fail "неизвестный параметр: $arg" ;;
    esac
done

# Запуск двойным щелчком из файлового менеджера: открываем окно терминала,
# чтобы были видны результаты проверок и можно было вставить ссылку.
if [[ ! -t 0 || ! -t 1 ]] && [[ -z ${P2K_IN_TERMINAL:-} ]] &&
    [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]]; then
    p2k_open_in_terminal "$P2K_ROOT/setup.sh" "$@"
fi
launched_by_shortcut="${P2K_IN_TERMINAL:-}"
unset P2K_IN_TERMINAL

p2k_ui_init

pause_before_exit() {
    if [[ -n $launched_by_shortcut ]] && ui_interactive; then
        printf '\n   Нажмите Enter, чтобы закрыть окно...'
        read -r _ || true
    fi
}
trap 'p2k_test_px_stop; pause_before_exit' EXIT

problems=()

# ---------------------------------------------------------------- ярлыки

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

# Ярлыки p2k вне каталога проекта: в меню и на рабочих столах.
# Ярлык считается ярлыком p2k, если запускает p2k-terminal.sh или p2k-chrome.sh.
system_launchers() {
    local dir name file
    local -a dirs=("$APPS_DIR")
    mapfile -t -O 1 dirs < <(desktop_dirs)
    for dir in "${dirs[@]}"; do
        for name in "${LAUNCHERS[@]}"; do
            file="$dir/$name.desktop"
            if [[ -f $file ]] && grep -q -E '^Exec=.*p2k-(terminal|chrome)\.sh' -- "$file"; then
                printf '%s\n' "$file"
            fi
        done
    done
}

if [[ $action == uninstall ]]; then
    found=0
    while IFS= read -r file; do
        rm -f -- "$file"
        ui_ok "Удалён ярлык: $file"
        found=1
    done < <(system_launchers)
    ((found)) || ui_info "Ярлыков p2k в меню и на рабочем столе нет"
    exit 0
fi

# ------------------------------------------------------------------- шаги

ui_banner

# 1. Комплект программ ------------------------------------------------------
ui_step 1 $STEPS "Комплект программ"

# Права на запуск теряются при копировании через некоторые носители.
chmod +x -- "$P2K_ROOT/setup.sh" "$P2K_DIR"/p2k-*.sh 2>/dev/null || true
for bin in "$PX_BIN" "$XRAY_BIN" "$CHROMIUM_BIN" "$(dirname -- "$CHROMIUM_BIN")/chrome_crashpad_handler"; do
    if [[ -f $bin ]]; then chmod +x -- "$bin" 2>/dev/null || true; fi
done

bundle_ok=1
if [[ -x $PX_BIN ]]; then
    ui_ok "px"
else
    ui_err "нет px: $PX_BIN"
    bundle_ok=0
fi
if [[ -x $XRAY_BIN ]]; then
    ui_ok "$("$XRAY_BIN" version 2>/dev/null | awk 'NR == 1 { print $1, $2 }')"
else
    ui_err "нет Xray: $XRAY_BIN"
    bundle_ok=0
fi
if [[ -x $CHROMIUM_BIN ]]; then
    revision="$(cat "$(dirname -- "$CHROMIUM_BIN")/.p2k-revision" 2>/dev/null || true)"
    ui_ok "Chromium${revision:+ (сборка $revision)}"
else
    ui_err "нет Chromium: $CHROMIUM_BIN"
    bundle_ok=0
fi
if ((!bundle_ok)); then
    printf '\n'
    ui_err "Комплект неполный. Распакуйте архив p2k заново и запустите setup.sh."
    exit 1
fi

# 2. Kerberos ---------------------------------------------------------------
ui_step 2 $STEPS "Билет Kerberos"

ticket_ok=1
if ! command -v klist >/dev/null; then
    ui_info "klist не установлен, наличие билета проверить нельзя"
elif klist -s 2>/dev/null; then
    principal="$(klist 2>/dev/null | awk -F': ' '/^Default principal|^Principal/ { print $2; exit }')"
    ui_ok "Билет найден${principal:+: $principal}"
else
    ticket_ok=0
    ui_err "Нет действующего билета Kerberos"
    ui_note "Войдите в систему под доменной учётной записью или выполните kinit."
    problems+=("получить билет Kerberos: kinit или вход в домен")
fi

# 3. Корпоративный прокси ---------------------------------------------------
ui_step 3 $STEPS "Корпоративный прокси"

server="$(p2k_ini_get "$PX_CONFIG" proxy server)"
proxy_host="${server%:*}"
proxy_port="${server##*:}"
ui_info "Прокси: $server (задан в app/px.ini)"

proxy_reachable=0
if command -v getent >/dev/null && ! getent hosts "$proxy_host" >/dev/null 2>&1; then
    ui_err "Адрес $proxy_host не найден в DNS"
    ui_note "Вы подключены к корпоративной сети?"
    problems+=("подключиться к корпоративной сети")
elif ! timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$proxy_host" "$proxy_port" 2>/dev/null; then
    ui_err "Нет связи с $server"
    ui_note "Вы подключены к корпоративной сети?"
    problems+=("подключиться к корпоративной сети")
else
    proxy_reachable=1
    ui_ok "Прокси доступен"
fi

if ((proxy_reachable && ticket_ok)); then
    test_port="$(p2k_free_port || true)"
    test_log="$(mktemp)"
    if [[ -n $test_port ]] && p2k_test_px_start auto "$test_port" 20 "$test_log"; then
        if [[ -t 1 ]]; then
            printf '   %s%s%s Проверяю вход через px (до 30 секунд)...' "$UI_DIM" "$UI_INFO" "$UI_RESET"
        fi
        site_ok=0
        site_result="$(p2k_check_site "$test_port" ya.ru 20 "$test_log")" && site_ok=1
        p2k_test_px_stop
        [[ -t 1 ]] && printf '\r\e[K'
        auth_result="$(p2k_auth_verdict "$test_log")"
        case "$auth_result" in
            OK*) ui_ok "Вход по билету Kerberos выполнен" ;;
            НЕТ*) ui_info "Прокси не запросил авторизацию" ;;
            *)
                ui_err "Вход по билету Kerberos не удался"
                ui_note "${auth_result#*: }"
                problems+=("выяснить, почему не удался вход: app/p2k-check.sh")
                ;;
        esac
        if ((site_ok)); then
            ui_ok "Сайт ya.ru открывается"
        elif [[ $auth_result == OK* ]]; then
            ui_warn "ya.ru: $site_result"
            ui_note "Подробная проверка: app/p2k-check.sh"
        fi
    else
        p2k_test_px_stop
        ui_err "px не запустился"
        tail -n 5 -- "$test_log" | sed 's/^/     /'
        problems+=("выяснить, почему не запускается px: app/p2k-check.sh")
    fi
    rm -f -- "$test_log"
fi

# 4. Xray -------------------------------------------------------------------
ui_step 4 $STEPS "Сервер Xray для браузера"

xray_server() {
    grep -m 1 -o -E '"address"[[:space:]]*:[[:space:]]*"[^"]*"' -- "$XRAY_CONFIG" 2>/dev/null |
        sed -E 's/.*"([^"]*)"$/\1/' || true
}

xray_config_valid() {
    [[ -f $XRAY_CONFIG ]] && "$XRAY_BIN" run -test -config "$XRAY_CONFIG" >/dev/null 2>&1
}

ask_link=0
if [[ -f $XRAY_CONFIG ]]; then
    if xray_config_valid; then
        address="$(xray_server)"
        ui_ok "Конфигурация есть${address:+, сервер $address}"
        if ui_ask "Заменить её конфигурацией из новой ссылки?" нет; then ask_link=1; fi
    else
        ui_err "Конфигурация app/xray-config.json содержит ошибки"
        if ui_ask "Создать новую из ссылки на сервер?" да; then
            ask_link=1
        else
            problems+=("исправить настройку Xray: app/p2k-xray-config.sh")
        fi
    fi
else
    ui_info "Конфигурации пока нет"
    ask_link=1
fi

if ((ask_link)); then
    if ! ui_interactive; then
        problems+=("настроить Xray: app/p2k-xray-config.sh")
    else
        ui_note "Ссылку на сервер выдаёт администратор VPN или клиент (v2rayN, Hiddify и др.)."
        ui_note "Поддерживаются vless://, trojan:// и ss://. Пустой ввод — пропустить."
        configured=0
        for _ in 1 2 3; do
            ui_input "Вставьте ссылку и нажмите Enter:" || break
            link="${UI_INPUT#"${UI_INPUT%%[![:space:]]*}"}"
            link="${link%"${link##*[![:space:]]}"}"
            [[ -n $link ]] || break
            if output="$("$P2K_DIR/p2k-xray-config.sh" "$link" 2>&1)"; then
                configured=1
                ui_ok "Конфигурация создана"
                grep -E '^  (сервер|протокол):' <<<"$output" | sed 's/^  /     /' || true
                if grep -q 'Прежняя конфигурация' <<<"$output"; then
                    ui_note "Прежняя конфигурация сохранена в app/ с суффиксом .bak-ДАТА."
                fi
                break
            fi
            ui_err "$(grep -m 1 'Ошибка:' <<<"$output" | sed 's/^Ошибка: //' || true)"
        done
        unset link UI_INPUT
        if ((!configured)); then
            if xray_config_valid; then
                ui_info "Оставлена прежняя конфигурация"
            else
                ui_warn "Xray не настроен: браузер p2k пока работать не будет"
                problems+=("настроить Xray: app/p2k-xray-config.sh")
            fi
        fi
    fi
fi

# 5. Ярлыки -----------------------------------------------------------------
ui_step 5 $STEPS "Ярлыки"

chrome_icon=web-browser
if [[ -f $P2K_DIR/opt/chromium/product_logo_48.png ]]; then
    chrome_icon="$P2K_DIR/opt/chromium/product_logo_48.png"
fi
write_launcher "$P2K_ROOT/p2k-terminal.desktop" \
    "p2k: терминал через прокси" \
    "Терминал, в котором программы работают через корпоративный прокси" \
    "$P2K_DIR/p2k-terminal.sh" utilities-terminal "System;TerminalEmulator;Network;"
write_launcher "$P2K_ROOT/p2k-chrome.desktop" \
    "p2k: Chromium через Xray" \
    "Отдельный Chromium, работающий через Xray и корпоративный прокси" \
    "$P2K_DIR/p2k-chrome.sh" "$chrome_icon" "Network;WebBrowser;"
ui_ok "p2k-terminal.desktop — терминал через прокси"
ui_ok "p2k-chrome.desktop — Chromium через Xray"
ui_note "Ярлыки лежат рядом с setup.sh. Если нужно, скопируйте их на рабочий стол."

mapfile -t old_launchers < <(system_launchers)
if ((${#old_launchers[@]})); then
    ui_warn "Вне каталога p2k есть ярлыки прежних версий:"
    for file in "${old_launchers[@]}"; do
        ui_note "$file"
    done
    ui_note "Удалить их: ./setup.sh --uninstall"
fi

# Итог ----------------------------------------------------------------------
printf '\n'
if ((${#problems[@]} == 0)); then
    ui_box "Готово" \
        "Запускайте ярлыками из каталога p2k:" \
        "  p2k-terminal.desktop   терминал через прокси" \
        "  p2k-chrome.desktop     Chromium через Xray" \
        "" \
        "Подробности: README.md" \
        "Если что-то не работает: app/p2k-check.sh"
else
    lines=("Осталось сделать:")
    for item in "${problems[@]}"; do
        lines+=("  $UI_INFO $item")
    done
    lines+=("" "Затем запустите setup.sh ещё раз." "Подробности: README.md")
    ui_box "Почти готово" "${lines[@]}"
fi
