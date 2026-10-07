#!/usr/bin/env bash
#
# Диагностика авторизации на корпоративном прокси.
#
#   app/p2k-check.sh [сайт ...]   по умолчанию ya.ru и example.com
#
# Скрипт показывает сведения о билете Kerberos, затем запускает отдельный
# экземпляр px и проверяет вход через прокси двумя способами: с системной
# библиотекой GSSAPI и со встроенной в px. Отдельно видно, прошла ли
# авторизация и пустил ли прокси на каждый сайт. Время ожидания ответа
# задаёт P2K_CHECK_TIMEOUT (по умолчанию 90 секунд). Полный отчёт
# с трассировкой Kerberos сохраняется в data/logs.
#
# Отчёт содержит имя пользователя, имена серверов и типы ключей,
# но не содержит паролей и самих билетов.

set -Eeuo pipefail

P2K_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib/common.sh
. "$P2K_DIR/lib/common.sh"
# shellcheck source=lib/check.sh
. "$P2K_DIR/lib/check.sh"

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    sed -n '3,15s/^# \{0,1\}//p' "$0"
    exit 0
fi

targets=("$@")
((${#targets[@]})) || targets=(ya.ru example.com)
timeout="${P2K_CHECK_TIMEOUT:-90}"
[[ $timeout =~ ^[0-9]+$ ]] || timeout=90
mkdir -p -- "$P2K_LOG_DIR"
stamp="$(date +%Y%m%d-%H%M%S)"
report="$P2K_LOG_DIR/check-$stamp.txt"
work="$(mktemp -d)"
trap 'p2k_test_px_stop; rm -rf -- "$work"' EXIT

section() {
    printf '\n===== %s =====\n' "$*"
}

# Строки трассировки Kerberos, по которым видна причина отказа.
trace_problems() {
    grep -i -E 'error|not found|no credentials|unable|denied|skew|expired|failed|no such|unknown|cannot' \
        -- "$1" 2>/dev/null | grep -v 'X-CACHECONF' | sed 's/^\[[0-9]*\] [0-9.]*: //' | sort -u | head -n 15 || true
}

main() {
trap p2k_test_px_stop EXIT

section "Система"
if [[ -r /etc/os-release ]]; then
    (. /etc/os-release && printf 'ОС: %s\n' "${PRETTY_NAME:-неизвестна}")
fi
printf 'Ядро: %s\n' "$(uname -r)"
printf 'Пользователь: %s\n' "$(id -un)"
printf 'Дата: %s\n' "$(date '+%F %T %z')"

section "Kerberos"
printf 'KRB5CCNAME=%s\n' "${KRB5CCNAME:-<не задана>}"
printf 'KRB5_CONFIG=%s\n' "${KRB5_CONFIG:-<не задана>}"
krb5_files=("${KRB5_CONFIG:-/etc/krb5.conf}")
for f in /etc/krb5.conf.d/* /var/lib/sss/pubconf/krb5.include.d/*; do
    [[ -f $f ]] && krb5_files+=("$f")
done
for f in "${krb5_files[@]}"; do
    [[ -r $f ]] || continue
    grep -H -n -i -E 'default_realm|default_ccache_name|dns_canonicalize_hostname|rdns|includedir|module|udp_preference_limit' \
        -- "$f" 2>/dev/null || true
done
if command -v klist >/dev/null; then
    printf -- '--- klist\n'
    klist 2>&1 || true
else
    printf 'klist не установлен\n'
fi

section "Корпоративный прокси"
server="$(p2k_ini_get "$PX_CONFIG" proxy server)"
printf 'server = %s\n' "$server"
proxy_host="${server%:*}"
if command -v getent >/dev/null; then
    printf 'Адреса %s: %s\n' "$proxy_host" "$(getent ahosts "$proxy_host" | awk '{print $1}' | sort -u | tr '\n' ' ')"
fi

section "Библиотека GSSAPI"
system_lib="$(p2k_system_gssapi)"
printf 'Системная: %s\n' "${system_lib:-не найдена}"

modes=()
[[ -n $system_lib ]] && modes+=(system)
modes+=(bundled)

declare -A auth=() sites=() any_ok=()
for mode in "${modes[@]}"; do
    section "Проверка входа: библиотека $mode"
    port="$(p2k_free_port)" || {
        printf 'Нет свободного порта для px\n'
        continue
    }
    trace="$work/trace-$mode.log"
    pxlog="$work/px-$mode.log"
    : >"$trace"

    p2k_test_px_start "$mode" "$port" "$timeout" "$pxlog" "$trace" || true

    # Встроенную библиотеку достаточно проверить на одном сайте.
    mode_targets=("${targets[@]}")
    [[ $mode == bundled && -n $system_lib ]] && mode_targets=("${targets[0]}")

    sites[$mode]=""
    for host in "${mode_targets[@]}"; do
        printf 'Проверяю %s (ожидание до %s с)...\n' "$host" "$timeout"
        if verdict="$(p2k_check_site "$port" "$host" "$timeout" "$pxlog")"; then
            any_ok[$mode]=1
        fi
        printf '  %s: %s\n' "$host" "$verdict"
        sites[$mode]+="  $host: $verdict"$'\n'
    done
    p2k_test_px_stop

    auth[$mode]="$(p2k_auth_verdict "$pxlog")"
    printf 'Авторизация: %s\n' "${auth[$mode]}"
    printf -- '--- Ошибки из журнала px:\n'
    px_errors="$(grep -i -E 'gss_|tunnel failed|authentication failed|Proxy-Authenticate|timed out' -- "$pxlog" 2>/dev/null |
        sed -E 's/^[0-9.]+: [^ ]+: [0-9]+: //' | sort -u | head -n 8 || true)"
    printf '%s\n' "${px_errors:-<ошибок не найдено>}"
    printf -- '--- Возможные причины из трассировки Kerberos:\n'
    problems="$(trace_problems "$trace")"
    printf '%s\n' "${problems:-<ошибок не найдено>}"

    {
        printf '\n----- Полная трассировка Kerberos (%s) -----\n' "$mode"
        cat -- "$trace"
        printf '\n----- Журнал px (%s), последние 150 строк -----\n' "$mode"
        tail -n 150 -- "$pxlog"
    } >>"$work/details.txt"
done

section "Итог"
best=""
for mode in "${modes[@]}"; do
    printf 'Библиотека %s\n  авторизация: %s\n%s' "$mode" "${auth[$mode]:-не проверялась}" "${sites[$mode]:-}"
    if [[ -z $best && ${auth[$mode]:-} == OK* ]]; then
        best="$mode"
    fi
done
printf '\n'

if [[ -n $best ]]; then
    if [[ $best == bundled && -n $system_lib ]]; then
        printf 'Kerberos работает только со встроенной библиотекой.\n'
        printf 'Задайте P2K_GSSAPI=bundled перед запуском скриптов p2k.\n'
    else
        printf 'Kerberos работает: px входит на корпоративный прокси по билету сеанса.\n'
    fi
    if [[ -n ${any_ok[$best]:-} ]]; then
        printf 'Сайты с ошибкой не пропускает сам корпоративный прокси. Это правило сети, а не ошибка p2k.\n'
        printf 'Такие сайты открывайте в браузере p2k через Xray.\n'
    else
        printf 'Но прокси не открыл ни один из проверенных сайтов.\n'
        printf 'Проверьте сайт, который точно разрешён в вашей сети:\n'
        printf '  app/p2k-check.sh имя.сайта\n'
    fi
elif [[ ${auth[${modes[0]}]:-} == НЕТ* ]]; then
    if [[ -n ${any_ok[${modes[0]}]:-} ]]; then
        printf 'Корпоративный прокси пускает без авторизации, px работает.\n'
    else
        printf 'До проверки входа дело не дошло: px не получил ответа от корпоративного прокси.\n'
        printf 'Причина указана выше в строках по сайтам. Проверьте подключение к корпоративной\n'
        printf 'сети и адрес прокси в app/px.ini.\n'
    fi
else
    printf 'Вход на корпоративный прокси не удался. Частые причины:\n'
    printf '  * нет билета Kerberos: проверьте klist, получите билет командой kinit;\n'
    printf '  * «Server not found in Kerberos database»: у прокси нет учётной записи\n'
    printf '    службы HTTP/<имя прокси>; укажите в app/px.ini имя, под которым прокси\n'
    printf '    зарегистрирован в домене;\n'
    printf '  * «Clock skew too great»: время на компьютере расходится с доменом.\n'
fi

printf '\nПолный отчёт: %s\n' "$report"
}

main 2>&1 | tee -- "$report"
cat -- "$work/details.txt" >>"$report" 2>/dev/null || true
