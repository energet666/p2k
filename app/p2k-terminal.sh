#!/usr/bin/env bash
#
# Запускает px и открывает терминал, в котором программы ходят
# в интернет через обычный HTTP-прокси без логина и пароля.
#
#   app/p2k-terminal.sh              интерактивная оболочка
#   app/p2k-terminal.sh команда ...  выполнить одну команду через прокси
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

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    usage
    exit 0
fi

if [[ ! -t 0 || ! -t 1 ]] && [[ -z ${P2K_IN_TERMINAL:-} ]] && (($# == 0)); then
    p2k_open_in_terminal "$P2K_DIR/p2k-terminal.sh" "$@"
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
