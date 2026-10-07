#!/usr/bin/env bash
#
# Запускает px и открывает терминал, в котором программы ходят
# в интернет через обычный HTTP-прокси без логина и пароля.
#
#   ./p2k-terminal.sh              интерактивная оболочка
#   ./p2k-terminal.sh команда ...  выполнить одну команду через прокси
#
# Если скрипт запущен без терминала (ярлыком с рабочего стола),
# он сам откроет окно терминала.

set -Eeuo pipefail

P2K_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib/common.sh
. "$P2K_DIR/lib/common.sh"

usage() {
    cat <<EOF
Использование: $(basename -- "$0") [команда [аргументы...]]

Без аргументов открывает оболочку, в которой заданы переменные
http_proxy, https_proxy и другие. Они указывают на локальный px,
который авторизуется на корпоративном прокси билетом Kerberos сеанса.

С аргументами выполняет одну команду с этими переменными.
EOF
}

# Ищет эмулятор терминала и запускает в нём этот же скрипт.
open_in_terminal() {
    local self="$P2K_DIR/p2k-terminal.sh"
    local -a cmd=()

    if [[ -n ${P2K_TERMINAL:-} ]]; then
        # Пользовательская команда, например: P2K_TERMINAL="konsole -e"
        read -r -a cmd <<<"$P2K_TERMINAL"
    elif command -v x-terminal-emulator >/dev/null; then
        cmd=(x-terminal-emulator -e)
    elif command -v fly-term >/dev/null; then
        cmd=(fly-term -e)
    elif command -v konsole >/dev/null; then
        cmd=(konsole -e)
    elif command -v xfce4-terminal >/dev/null; then
        cmd=(xfce4-terminal -x)
    elif command -v mate-terminal >/dev/null; then
        cmd=(mate-terminal -x)
    elif command -v gnome-terminal >/dev/null; then
        cmd=(gnome-terminal --)
    elif command -v qterminal >/dev/null; then
        cmd=(qterminal -e)
    elif command -v lxterminal >/dev/null; then
        cmd=(lxterminal -e)
    elif command -v xterm >/dev/null; then
        cmd=(xterm -e)
    else
        p2k_fail "не найден эмулятор терминала. Запустите $self из открытого терминала."
    fi

    export P2K_IN_TERMINAL=1
    exec "${cmd[@]}" "$self" "$@"
}

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    usage
    exit 0
fi

if [[ ! -t 0 || ! -t 1 ]] && [[ -z ${P2K_IN_TERMINAL:-} ]] && (($# == 0)); then
    open_in_terminal "$@"
fi

launched_by_shortcut="${P2K_IN_TERMINAL:-}"
unset P2K_IN_TERMINAL
session_started=""

on_exit() {
    local status=$?
    p2k_release_all
    # Окно, открытое ярлыком, не должно закрыться раньше, чем
    # пользователь прочтёт сообщение об ошибке.
    if ((status != 0)) && [[ -n $launched_by_shortcut && -z $session_started ]]; then
        printf '\nНажмите Enter, чтобы закрыть окно...'
        read -r _ || true
    fi
}

p2k_require_tools
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 129' HUP
trap 'exit 143' TERM

p2k_px_acquire
p2k_export_proxy_env "$P2K_PROXY_URL"
export P2K_ACTIVE=1

if (($# > 0)); then
    status=0
    "$@" || status=$?
    exit "$status"
fi

cat <<EOF

p2k: программы в этом терминале работают через прокси $P2K_PROXY_URL
     http_proxy, https_proxy и no_proxy уже заданы.
     Для sudo используйте sudo -E, чтобы переменные сохранились.
     Закройте окно или выполните exit, чтобы завершить сеанс.

EOF

session_started=1
user_shell="${SHELL:-/bin/bash}"
[[ -x $user_shell ]] || user_shell=/bin/bash
status=0
if [[ ${user_shell##*/} == bash ]]; then
    "$user_shell" --rcfile "$P2K_DIR/lib/bashrc" -i || status=$?
else
    "$user_shell" -i || status=$?
fi
exit "$status"
