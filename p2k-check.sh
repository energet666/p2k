#!/usr/bin/env bash
#
# Диагностика авторизации на корпоративном прокси.
#
#   ./p2k-check.sh [сайт ...]   по умолчанию ya.ru и example.com
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
px_pid=""

stop_px() {
    if [[ -n $px_pid ]]; then
        kill "$px_pid" 2>/dev/null || true
        wait "$px_pid" 2>/dev/null || true
        px_pid=""
    fi
}
trap 'stop_px; rm -rf -- "$work"' EXIT

section() {
    printf '\n===== %s =====\n' "$*"
}

# Свободный локальный порт для временного px.
free_port() {
    local port
    for port in $(seq 18090 18190); do
        p2k_port_is_open 127.0.0.1 "$port" || {
            printf '%s\n' "$port"
            return 0
        }
    done
    return 1
}

# Отправляет px запрос CONNECT и печатает строку статуса ответа.
probe() {
    local port="$1" host="$2" line=""
    (
        exec 3<>"/dev/tcp/127.0.0.1/$port" || exit 1
        printf 'CONNECT %s:443 HTTP/1.1\r\nHost: %s:443\r\n\r\n' "$host" "$host" >&3
        IFS= read -r -t "$((timeout + 15))" line <&3 || true
        printf '%s\n' "${line%$'\r'}"
    )
}

# Строки трассировки Kerberos, по которым видна причина отказа.
trace_problems() {
    grep -i -E 'error|not found|no credentials|unable|denied|skew|expired|failed|no such|unknown|cannot' \
        -- "$1" 2>/dev/null | grep -v 'X-CACHECONF' | sed 's/^\[[0-9]*\] [0-9.]*: //' | sort -u | head -n 15 || true
}

main() {
trap stop_px EXIT

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

# Что случилось с авторизацией, по журналу px.
auth_verdict() {
    local log="$1" error
    error="$(grep -o -E 'gss_init_sec_context\(\) failed: .*' -- "$log" 2>/dev/null | head -n 1 || true)"
    if grep -q 'Proxy-Authorization: Negotiate' -- "$log" 2>/dev/null; then
        printf 'OK: токен Kerberos сформирован и отправлен прокси\n'
    elif [[ -n $error ]]; then
        printf 'ОШИБКА: токен Kerberos не сформирован (%s)\n' "$error"
    elif grep -q 'Proxy-Authenticate' -- "$log" 2>/dev/null; then
        printf 'ОШИБКА: прокси запросил авторизацию, но px её не выполнил\n'
    else
        printf 'прокси не запрашивал авторизацию\n'
    fi
}

# Расшифровка ответа px на CONNECT по строке статуса и по журналу px,
# записанному во время этой проверки.
site_verdict() {
    local status="$1" seconds="$2" log="$3"
    if [[ $status == *" 200"* ]]; then
        printf 'доступен (%s с)\n' "$seconds"
    elif grep -q 'response 403' <<<"$log"; then
        printf 'корпоративный прокси запретил доступ к сайту (403)\n'
    elif grep -q 'response 407' <<<"$log"; then
        printf 'корпоративный прокси не принял авторизацию (407)\n'
    elif grep -q -i 'timed out' <<<"$log" || [[ -z $status || $status == *" 504"* ]]; then
        printf 'корпоративный прокси не ответил за %s с: сайт закрыт для корпоративной сети или прокси слишком долго к нему подключается\n' "$seconds"
    elif grep -q -i 'resolve' <<<"$log"; then
        printf 'не найден адрес корпоративного прокси (DNS)\n'
    elif grep -q -i -E 'Failed to connect|refused' <<<"$log"; then
        printf 'нет связи с корпоративным прокси\n'
    elif [[ $status =~ \ ([0-9]{3}) ]]; then
        local upstream
        upstream="$(grep -o -E 'response [0-9]{3}' <<<"$log" | tail -n 1 || true)"
        printf 'ошибка %s%s\n' "${BASH_REMATCH[1]}" "${upstream:+, ответ прокси: ${upstream#response }}"
    else
        printf '%s (%s с)\n' "$status" "$seconds"
    fi
}

declare -A auth=() sites=() any_ok=()
for mode in "${modes[@]}"; do
    section "Проверка входа: библиотека $mode"
    port="$(free_port)" || {
        printf 'Нет свободного порта для px\n'
        continue
    }
    trace="$work/trace-$mode.log"
    pxlog="$work/px-$mode.log"
    : >"$trace"

    declare -a cmd=()
    P2K_GSSAPI="$mode" p2k_px_command cmd --config="$PX_CONFIG" \
        --listen=127.0.0.1 --port="$port" --log=4 --socktimeout="$timeout"
    KRB5_TRACE="$trace" "${cmd[@]}" </dev/null >"$pxlog" 2>&1 &
    px_pid=$!

    for _ in $(seq 1 100); do
        p2k_port_is_open 127.0.0.1 "$port" && break
        kill -0 "$px_pid" 2>/dev/null || break
        sleep 0.1
    done

    # Встроенную библиотеку достаточно проверить на одном сайте.
    mode_targets=("${targets[@]}")
    [[ $mode == bundled && -n $system_lib ]] && mode_targets=("${targets[0]}")

    sites[$mode]=""
    for host in "${mode_targets[@]}"; do
        printf 'Проверяю %s (ожидание до %s с)...\n' "$host" "$timeout"
        started=$SECONDS
        lines_before="$(wc -l <"$pxlog")"
        status="$(probe "$port" "$host" || true)"
        sleep 0.5
        verdict="$(site_verdict "$status" "$((SECONDS - started))" \
            "$(tail -n "+$((lines_before + 1))" -- "$pxlog")")"
        printf '  %s: %s\n' "$host" "$verdict"
        sites[$mode]+="  $host: $verdict"$'\n'
        [[ $status == *" 200"* ]] && any_ok[$mode]=1
    done
    stop_px

    auth[$mode]="$(auth_verdict "$pxlog")"
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
        printf '  ./p2k-check.sh имя.сайта\n'
    fi
else
    printf 'Вход на корпоративный прокси не удался. Частые причины:\n'
    printf '  * нет билета Kerberos: проверьте klist, получите билет командой kinit;\n'
    printf '  * «Server not found in Kerberos database»: у прокси нет учётной записи\n'
    printf '    службы HTTP/<имя прокси>; укажите в px.ini имя, под которым прокси\n'
    printf '    зарегистрирован в домене;\n'
    printf '  * «Clock skew too great»: время на компьютере расходится с доменом.\n'
fi

printf '\nПолный отчёт: %s\n' "$report"
}

main 2>&1 | tee -- "$report"
cat -- "$work/details.txt" >>"$report" 2>/dev/null || true
