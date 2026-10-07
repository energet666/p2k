# shellcheck shell=bash
# Проверка входа на корпоративный прокси через временный экземпляр px.
# Используется в setup.sh и p2k-check.sh. Требует lib/common.sh.

P2K_TEST_PX_PID=""

# Свободный локальный порт для временного px.
p2k_free_port() {
    local port
    for port in $(seq 18090 18190); do
        if ! p2k_port_is_open 127.0.0.1 "$port"; then
            printf '%s\n' "$port"
            return 0
        fi
    done
    return 1
}

# Запускает временный px с подробным журналом.
#   p2k_test_px_start режим_gssapi порт тайм-аут файл_журнала [файл_трассировки]
p2k_test_px_start() {
    local mode="$1" port="$2" timeout="$3" log="$4" trace="${5:-/dev/null}"
    local -a cmd=()
    P2K_GSSAPI="$mode" p2k_px_command cmd --config="$PX_CONFIG" \
        --listen=127.0.0.1 --port="$port" --log=4 --socktimeout="$timeout"
    KRB5_TRACE="$trace" "${cmd[@]}" </dev/null >"$log" 2>&1 &
    P2K_TEST_PX_PID=$!
    local i
    for ((i = 0; i < 100; i++)); do
        p2k_port_is_open 127.0.0.1 "$port" && return 0
        kill -0 "$P2K_TEST_PX_PID" 2>/dev/null || return 1
        sleep 0.1
    done
    return 1
}

p2k_test_px_stop() {
    if [[ -n $P2K_TEST_PX_PID ]]; then
        kill "$P2K_TEST_PX_PID" 2>/dev/null || true
        wait "$P2K_TEST_PX_PID" 2>/dev/null || true
        P2K_TEST_PX_PID=""
    fi
}

# Отправляет px запрос CONNECT и печатает строку статуса ответа.
#   p2k_probe порт сайт тайм-аут
p2k_probe() {
    local port="$1" host="$2" timeout="$3" line=""
    (
        exec 3<>"/dev/tcp/127.0.0.1/$port" || exit 1
        printf 'CONNECT %s:443 HTTP/1.1\r\nHost: %s:443\r\n\r\n' "$host" "$host" >&3
        IFS= read -r -t "$((timeout + 15))" line <&3 || true
        printf '%s\n' "${line%$'\r'}"
    )
}

# Что случилось с авторизацией, по журналу px. Первое слово ответа:
# OK, ОШИБКА или НЕТ (прокси не запрашивал авторизацию).
p2k_auth_verdict() {
    local log="$1" error
    error="$(grep -o -E 'gss_init_sec_context\(\) failed: .*' -- "$log" 2>/dev/null | head -n 1 || true)"
    if grep -q 'Proxy-Authorization: Negotiate' -- "$log" 2>/dev/null; then
        printf 'OK: токен Kerberos сформирован и отправлен прокси\n'
    elif ! grep -q 'Proxy-Authenticate' -- "$log" 2>/dev/null; then
        # curl пробует получить токен заранее, поэтому ошибка GSSAPI
        # без запроса авторизации от прокси ничего не значит.
        printf 'НЕТ: прокси не запрашивал авторизацию\n'
    elif [[ -n $error ]]; then
        printf 'ОШИБКА: токен Kerberos не сформирован (%s)\n' "${error%% SPNEGO*}"
    else
        printf 'ОШИБКА: прокси запросил авторизацию, но px её не выполнил\n'
    fi
}

# Расшифровка ответа px на CONNECT по строке статуса и по журналу px,
# записанному во время этой проверки.
#   p2k_site_verdict статус секунды текст_журнала
p2k_site_verdict() {
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

# Проверяет один сайт через запущенный временный px.
# Печатает вердикт; код возврата 0, если сайт доступен.
#   p2k_check_site порт сайт тайм-аут файл_журнала_px
p2k_check_site() {
    local port="$1" host="$2" timeout="$3" log="$4"
    local started=$SECONDS lines_before status
    lines_before="$(wc -l <"$log")"
    status="$(p2k_probe "$port" "$host" "$timeout" || true)"
    sleep 0.5
    p2k_site_verdict "$status" "$((SECONDS - started))" \
        "$(tail -n "+$((lines_before + 1))" -- "$log")"
    [[ $status == *" 200"* ]]
}
