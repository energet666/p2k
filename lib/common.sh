# shellcheck shell=bash
# Общие функции p2k. Подключается из скриптов в корне проекта.
#
# px и Xray запускаются по требованию и разделяются между всеми скриптами
# p2k. Каждый скрипт, которому нужен сервис, держит на нём разделяемую
# блокировку. Когда последний такой скрипт завершается, сервис
# останавливается. Сервис, запущенный кем-то другим, p2k не трогает.

P2K_DIR="${P2K_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
P2K_DATA_DIR="${P2K_DATA_DIR:-$P2K_DIR/data}"
P2K_RUN_DIR="$P2K_DATA_DIR/run"
P2K_LOG_DIR="$P2K_DATA_DIR/logs"

PX_BIN="${PX_BIN:-$P2K_DIR/opt/px/px}"
PX_CONFIG="${PX_CONFIG:-$P2K_DIR/px.ini}"
PX_HOST=127.0.0.1

XRAY_BIN="${XRAY_BIN:-$P2K_DIR/opt/xray/xray}"
XRAY_CONFIG="${XRAY_CONFIG:-$P2K_DIR/xray-config.json}"

CHROMIUM_BIN="${CHROMIUM_BIN:-$P2K_DIR/opt/chromium/chrome}"

declare -A P2K_HELD_FDS=()
P2K_HELD_ORDER=()

# ---------------------------------------------------------------- сообщения

p2k_log() {
    mkdir -p -- "$P2K_LOG_DIR" 2>/dev/null || return 0
    printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$P2K_LOG_DIR/p2k.log" 2>/dev/null || true
}

p2k_info() {
    printf '%s\n' "$*"
    p2k_log "$*"
}

p2k_warn() {
    printf 'Внимание: %s\n' "$*" >&2
    p2k_log "Внимание: $*"
}

# Показывает сообщение в окне, если скрипт запущен без терминала
# (например, ярлыком с рабочего стола). Тип: error, warning или info.
p2k_dialog() {
    local kind="$1" text="$2"
    [[ -t 2 ]] && return 0
    [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] || return 0

    if command -v zenity >/dev/null; then
        zenity "--$kind" --title=p2k --no-wrap --text="$text" >/dev/null 2>&1 &
    elif command -v kdialog >/dev/null; then
        local flag="--msgbox"
        [[ $kind == error ]] && flag="--error"
        [[ $kind == warning ]] && flag="--sorry"
        kdialog --title p2k "$flag" "$text" >/dev/null 2>&1 &
    elif command -v notify-send >/dev/null; then
        local urgency=normal
        [[ $kind == error ]] && urgency=critical
        notify-send -u "$urgency" p2k "$text" >/dev/null 2>&1 &
    elif command -v xmessage >/dev/null; then
        xmessage -center "p2k: $text" >/dev/null 2>&1 &
    fi
}

p2k_fail() {
    printf 'Ошибка: %s\n' "$*" >&2
    p2k_log "Ошибка: $*"
    p2k_dialog error "$*"
    exit 1
}

# ------------------------------------------------------------------ утилиты

p2k_port_is_open() {
    (exec 3<>"/dev/tcp/$1/$2") 2>/dev/null
}

# Значение параметра из ini-файла: p2k_ini_get файл секция ключ
p2k_ini_get() {
    awk -v want_section="$2" -v want_key="$3" '
        /^[[:space:]]*[;#]/ { next }
        /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
            section = $0
            gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", section)
            next
        }
        section == want_section {
            line = $0
            if (sub(/^[[:space:]]*/, "", line) && index(line, "=")) {
                key = substr(line, 1, index(line, "=") - 1)
                value = substr(line, index(line, "=") + 1)
                gsub(/[[:space:]]+$/, "", key)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                if (key == want_key) { print value; exit }
            }
        }
    ' "$1"
}

p2k_px_port() {
    local port
    port="$(p2k_ini_get "$PX_CONFIG" proxy port 2>/dev/null || true)"
    [[ $port =~ ^[0-9]+$ ]] || port=3128
    printf '%s\n' "$port"
}

p2k_require_tools() {
    local tool
    for tool in flock setsid awk; do
        command -v "$tool" >/dev/null || p2k_fail "не найдена системная утилита $tool"
    done
}

# ----------------------------------------------------------------- Kerberos

# Возвращает 0, если у сеанса есть действующий билет Kerberos или проверить
# это нечем (нет klist). Возвращает 1, если билета точно нет.
p2k_kerberos_ok() {
    command -v klist >/dev/null || return 0
    klist -s 2>/dev/null
}

p2k_kerberos_hint() {
    cat <<'EOF'
Не найден действующий билет Kerberos текущего сеанса.
px не сможет авторизоваться на корпоративном прокси.

Что сделать:
  * войти в систему под доменной учётной записью;
  * или получить билет вручную командой kinit;
  * проверить билет можно командой klist.
EOF
}

# ------------------------------------------------- разделяемые сервисы

# Закрывает в текущем процессе все дескрипторы, кроме 0, 1 и 2.
# Так фоновые сервисы не наследуют блокировки p2k.
p2k_close_extra_fds() {
    local path fd
    for path in /proc/"$BASHPID"/fd/*; do
        fd="${path##*/}"
        [[ $fd =~ ^[0-9]+$ ]] && ((fd > 2)) || continue
        eval "exec $fd>&-" 2>/dev/null || true
    done
}

# Запускает команду в фоне, отвязав её от терминала и блокировок p2k.
# PID запущенного процесса записывает в переменную P2K_SPAWNED_PID.
p2k_spawn() {
    local log="$1"
    shift
    (
        p2k_close_extra_fds
        exec setsid "$@" </dev/null >>"$log" 2>&1
    ) &
    P2K_SPAWNED_PID="$!"
}

p2k_wait_port() {
    local name="$1" host="$2" port="$3" pid="$4" log="$5" attempts="${6:-150}"
    local i
    for ((i = 0; i < attempts; i++)); do
        p2k_port_is_open "$host" "$port" && return 0
        if ! kill -0 "$pid" 2>/dev/null; then
            printf '%s завершился при запуске. Последние строки журнала %s:\n' \
                "$name" "$log" >&2
            tail -n 20 -- "$log" >&2 || true
            return 1
        fi
        sleep 0.1
    done
    printf '%s не открыл порт %s:%s за отведённое время. Журнал: %s\n' \
        "$name" "$host" "$port" "$log" >&2
    return 1
}

# Подключается к сервису, при необходимости запуская его.
#   p2k_service_acquire имя хост порт команда [аргументы...]
p2k_service_acquire() {
    local name="$1" host="$2" port="$3"
    shift 3
    local users="$P2K_RUN_DIR/$name.users"
    local start="$P2K_RUN_DIR/$name.start"
    local pidfile="$P2K_RUN_DIR/$name.pid"
    local log="$P2K_LOG_DIR/$name.log"
    local users_fd start_fd pid

    mkdir -p -- "$P2K_RUN_DIR" "$P2K_LOG_DIR"

    exec {start_fd}>>"$start"
    flock -x "$start_fd"

    exec {users_fd}>>"$users"
    flock -s "$users_fd"
    P2K_HELD_FDS[$name]="$users_fd"
    P2K_HELD_ORDER+=("$name")

    if p2k_port_is_open "$host" "$port"; then
        p2k_info "$name уже работает на $host:$port"
    else
        p2k_info "Запускаю $name (журнал: $log)"
        printf '\n=== %s запуск\n' "$(date '+%F %T')" >>"$log"
        p2k_spawn "$log" "$@"
        pid="$P2K_SPAWNED_PID"
        printf '%s\n' "$pid" >"$pidfile"
        if ! p2k_wait_port "$name" "$host" "$port" "$pid" "$log"; then
            kill "$pid" 2>/dev/null || true
            rm -f -- "$pidfile"
            eval "exec $start_fd>&-"
            return 1
        fi
        p2k_info "$name готов: $host:$port"
    fi

    eval "exec $start_fd>&-"
}

p2k_service_stop_if_unused() {
    local name="$1"
    local users="$P2K_RUN_DIR/$name.users"
    local start="$P2K_RUN_DIR/$name.start"
    local pidfile="$P2K_RUN_DIR/$name.pid"
    local start_fd users_fd pid i

    exec {start_fd}>>"$start"
    flock -x "$start_fd"
    exec {users_fd}>>"$users"

    if flock -n -x "$users_fd" && [[ -f $pidfile ]]; then
        pid="$(<"$pidfile")"
        if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            for ((i = 0; i < 30; i++)); do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.1
            done
            kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
            p2k_log "$name остановлен"
        fi
        rm -f -- "$pidfile"
    fi

    eval "exec $users_fd>&- $start_fd>&-"
}

# Отпускает все сервисы в обратном порядке. Безопасно вызывать повторно.
p2k_release_all() {
    local idx name fd
    for ((idx = ${#P2K_HELD_ORDER[@]} - 1; idx >= 0; idx--)); do
        name="${P2K_HELD_ORDER[idx]}"
        fd="${P2K_HELD_FDS[$name]:-}"
        [[ -n $fd ]] || continue
        eval "exec $fd>&-"
        unset 'P2K_HELD_FDS[$name]'
        p2k_service_stop_if_unused "$name"
    done
    P2K_HELD_ORDER=()
}

# -------------------------------------------------------------------- px

# Путь к системной библиотеке GSSAPI (MIT Kerberos) или пустая строка.
p2k_system_gssapi() {
    local dir
    for dir in /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu /usr/lib64 /lib64 /usr/lib /lib; do
        if [[ -e $dir/libgssapi_krb5.so.2 ]]; then
            printf '%s\n' "$dir/libgssapi_krb5.so.2"
            return 0
        fi
    done
    if [[ -x /sbin/ldconfig ]]; then
        /sbin/ldconfig -p 2>/dev/null |
            awk '/libgssapi_krb5\.so\.2 .*x86-64/ { print $NF; exit }'
    fi
}

# Собирает команду запуска px в массив с именем $1, остальные аргументы
# передаются px.
#
# Встроенная в px библиотека Kerberos не знает о доработках Astra Linux
# и модулях SSSD или ALD. Поэтому по умолчанию px подгружает системную
# библиотеку GSSAPI, ту же, которой пользуются klist и kinit. Её функции
# перекрывают встроенные. Режим задаётся переменной P2K_GSSAPI:
#   auto     системная библиотека, если она есть, иначе встроенная;
#   system   только системная;
#   bundled  только встроенная.
p2k_px_command() {
    local -n out="$1"
    shift
    local mode="${P2K_GSSAPI:-auto}" lib=""

    case "$mode" in
        auto | system) lib="$(p2k_system_gssapi)" ;;
        bundled) ;;
        *) p2k_fail "неизвестное значение P2K_GSSAPI: $mode (auto, system или bundled)" ;;
    esac
    if [[ $mode == system && -z $lib ]]; then
        p2k_fail "P2K_GSSAPI=system, но системная библиотека libgssapi_krb5.so.2 не найдена"
    fi

    if [[ -n $lib ]]; then
        P2K_GSSAPI_USED="system:$lib"
        out=(env "LD_PRELOAD=$lib${LD_PRELOAD:+:$LD_PRELOAD}" "$PX_BIN" "$@")
    else
        P2K_GSSAPI_USED=bundled
        out=("$PX_BIN" "$@")
    fi
}

p2k_px_acquire() {
    local port
    port="$(p2k_px_port)"
    [[ -x $PX_BIN ]] || p2k_fail "px не найден или не исполняемый: $PX_BIN. Распакуйте релизный архив p2k заново и запустите setup.sh."
    [[ -f $PX_CONFIG ]] || p2k_fail "конфиг px не найден: $PX_CONFIG"

    if ! p2k_kerberos_ok; then
        p2k_kerberos_hint >&2
        p2k_log "нет билета Kerberos"
        p2k_dialog warning "$(p2k_kerberos_hint)"
    fi

    local -a px_cmd
    p2k_px_command px_cmd --config="$PX_CONFIG"
    p2k_log "px: библиотека GSSAPI $P2K_GSSAPI_USED"
    p2k_service_acquire px "$PX_HOST" "$port" "${px_cmd[@]}" ||
        p2k_fail "не удалось запустить px. Подробности в $P2K_LOG_DIR/px.log"

    P2K_PROXY_URL="http://$PX_HOST:$port"
}

# Переменные окружения, по которым программы находят прокси.
p2k_export_proxy_env() {
    local url="$1"
    local no_proxy_list="localhost,127.0.0.1,::1${P2K_NO_PROXY:+,$P2K_NO_PROXY}"
    export http_proxy="$url" https_proxy="$url" ftp_proxy="$url"
    export HTTP_PROXY="$url" HTTPS_PROXY="$url" FTP_PROXY="$url"
    export no_proxy="$no_proxy_list" NO_PROXY="$no_proxy_list"
}

# ------------------------------------------------------------------ Xray

# Определяет вход Xray, к которому подключать браузер. Печатает
# «протокол адрес порт». Нужен python3; без него используется
# http 127.0.0.1 21000.
p2k_xray_inbound() {
    local result=""
    if command -v python3 >/dev/null; then
        result="$(python3 -I - "$XRAY_CONFIG" <<'EOF' 2>/dev/null
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    config = json.load(fh)
for inbound in config.get("inbounds") or []:
    proto = inbound.get("protocol")
    if proto in ("http", "socks", "mixed") and isinstance(inbound.get("port"), int):
        listen = inbound.get("listen") or "0.0.0.0"
        print("socks" if proto == "socks" else "http", listen, inbound["port"])
        break
EOF
)" || result=""
    fi
    printf '%s\n' "${result:-http 127.0.0.1 21000}"
}

# Проверяет наличие Xray и его конфигурации и определяет адрес входа.
# Вызывается до запуска px, чтобы не поднимать его зря.
p2k_xray_check() {
    [[ -x $XRAY_BIN ]] || p2k_fail "Xray не найден: $XRAY_BIN. Распакуйте релизный архив p2k заново и запустите setup.sh."
    [[ -f $XRAY_CONFIG ]] || p2k_fail "нет конфигурации Xray: $XRAY_CONFIG.
Скопируйте свой конфиг в этот файл. Как его составить, описано в README.md."

    local listen check_log
    read -r P2K_XRAY_PROTO listen P2K_XRAY_PORT <<<"$(p2k_xray_inbound)"
    P2K_XRAY_HOST="$listen"
    case "$listen" in
        0.0.0.0 | "::" | "")
            P2K_XRAY_HOST=127.0.0.1
            p2k_warn "вход Xray слушает все сетевые интерфейсы ($listen:$P2K_XRAY_PORT). Его могут использовать другие компьютеры сети. Укажите \"listen\": \"127.0.0.1\"."
            ;;
    esac

    mkdir -p -- "$P2K_LOG_DIR"
    check_log="$P2K_LOG_DIR/xray-check.log"
    if ! p2k_port_is_open "$P2K_XRAY_HOST" "$P2K_XRAY_PORT" &&
        ! "$XRAY_BIN" run -test -config "$XRAY_CONFIG" >"$check_log" 2>&1; then
        tail -n 15 -- "$check_log" >&2 || true
        p2k_fail "конфигурация Xray содержит ошибки: $XRAY_CONFIG. Подробности в $check_log"
    fi
}

p2k_xray_acquire() {
    [[ -n ${P2K_XRAY_PORT:-} ]] || p2k_xray_check
    local proto="$P2K_XRAY_PROTO" host="$P2K_XRAY_HOST" port="$P2K_XRAY_PORT"

    p2k_service_acquire xray "$host" "$port" \
        "$XRAY_BIN" run -config "$XRAY_CONFIG" ||
        p2k_fail "не удалось запустить Xray. Подробности в $P2K_LOG_DIR/xray.log"

    if [[ $proto == socks ]]; then
        P2K_XRAY_URL="socks5://$host:$port"
    else
        P2K_XRAY_URL="http://$host:$port"
    fi
}
