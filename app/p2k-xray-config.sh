#!/usr/bin/env bash
#
# Создаёт xray-config.json из ссылки на сервер.
#
#   app/p2k-xray-config.sh                 спросит ссылку, её можно вставить
#   app/p2k-xray-config.sh 'vless://...'   ссылка аргументом (в кавычках)
#
# Поддерживаются ссылки vless://, trojan:// и ss:// (Shadowsocks).
# Транспорты: tcp (raw), ws, grpc, httpupgrade, xhttp, kcp.
# Защита: none, tls, reality.
#
# В конфигурации будут:
#   * вход для браузера: HTTP-прокси 127.0.0.1:21000;
#   * выход к вашему серверу из ссылки;
#   * подключение к серверу через px (корпоративный прокси).
#
# Прежний xray-config.json сохраняется рядом с суффиксом .bak-ДАТА.
# Ссылка содержит ключи доступа, поэтому скрипт не пишет её в журналы.

set -Eeuo pipefail

P2K_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib/common.sh
. "$P2K_DIR/lib/common.sh"

INBOUND_PORT="${P2K_XRAY_PORT:-21000}"

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    sed -n '3,19s/^# \{0,1\}//p' "$0"
    exit 0
fi

# ------------------------------------------------------------------ разбор

urldecode() {
    local s="${1//\\/\\\\}"
    printf '%b' "${s//%/\\x}"
}

# Строка в JSON-кавычках.
js() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    printf '"%s"' "$s"
}

# Список через запятую в JSON-массив строк.
js_list() {
    local -
    set -f
    local IFS=, item out=""
    for item in $1; do
        [[ -n $item ]] && out+="${out:+, }$(js "$item")"
    done
    printf '[%s]' "$out"
}

# base64 с вариантами URL-safe и без выравнивания.
b64decode() {
    local s="${1//-/+}"
    s="${s//_//}"
    while ((${#s} % 4)); do s+="="; done
    printf '%s' "$s" | base64 -d 2>/dev/null
}

declare -A q=()

# Разбирает строку параметров a=1&b=2 в массив q, раскодируя значения.
parse_query() {
    local -
    set -f
    local pair key value
    local IFS='&'
    for pair in $1; do
        [[ -n $pair ]] || continue
        key="${pair%%=*}"
        value=""
        [[ $pair == *=* ]] && value="${pair#*=}"
        q[$(urldecode "$key")]="$(urldecode "$value")"
    done
}

# Разбирает «пользователь@хост:порт». Заполняет user, host, port.
parse_authority() {
    local authority="$1" hostport
    [[ $authority == *@* ]] || p2k_fail "в ссылке нет части «ключ@адрес:порт»"
    user="$(urldecode "${authority%@*}")"
    hostport="${authority##*@}"
    if [[ $hostport =~ ^\[([0-9A-Fa-f:.]+)\]:([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    elif [[ $hostport =~ ^([^:/]+):([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    else
        p2k_fail "не удалось разобрать адрес и порт сервера в ссылке"
    fi
    ((port > 0 && port < 65536)) || p2k_fail "неверный порт сервера: $port"
}

# ------------------------------------------------------------ части JSON

stream_settings() {
    local network="${q[type]:-tcp}" security="${q[security]:-$1}"
    local path="${q[path]:-}" hosthdr="${q[host]:-}"
    local out="" transport=""

    case "$network" in
        tcp | raw)
            network=tcp
            if [[ ${q[headerType]:-none} == http ]]; then
                transport="\"tcpSettings\": {
          \"header\": {
            \"type\": \"http\",
            \"request\": {
              \"path\": $(js_list "${path:-/}"),
              \"headers\": { \"Host\": $(js_list "$hosthdr") }
            }
          }
        }"
            fi
            ;;
        ws)
            transport="\"wsSettings\": { \"path\": $(js "${path:-/}"), \"host\": $(js "$hosthdr") }"
            ;;
        grpc)
            local multi=false
            [[ ${q[mode]:-} == multi ]] && multi=true
            transport="\"grpcSettings\": {
          \"serviceName\": $(js "${q[serviceName]:-}"),
          \"authority\": $(js "${q[authority]:-}"),
          \"multiMode\": $multi
        }"
            ;;
        httpupgrade)
            transport="\"httpupgradeSettings\": { \"path\": $(js "${path:-/}"), \"host\": $(js "$hosthdr") }"
            ;;
        xhttp | splithttp)
            network=xhttp
            transport="\"xhttpSettings\": {
          \"path\": $(js "${path:-/}"),
          \"host\": $(js "$hosthdr"),
          \"mode\": $(js "${q[mode]:-auto}")${q[extra]:+,
          \"extra\": ${q[extra]}}
        }"
            ;;
        kcp | mkcp)
            network=kcp
            if [[ ${q[headerType]:-none} != none || -n ${q[seed]:-} ]]; then
                p2k_fail "mKCP с маскировкой (headerType или seed) в этой версии Xray настраивается иначе. Составьте конфигурацию вручную."
            fi
            ;;
        *) p2k_fail "транспорт «$network» не поддерживается (tcp, ws, grpc, httpupgrade, xhttp, kcp)" ;;
    esac

    out+="\"network\": $(js "$network"),
        \"security\": $(js "$security")"

    case "$security" in
        none | "") ;;
        tls)
            local insecure=false
            [[ ${q[allowInsecure]:-${q[insecure]:-0}} =~ ^(1|true)$ ]] && insecure=true
            out+=",
        \"tlsSettings\": {
          \"serverName\": $(js "${q[sni]:-${q[peer]:-$hosthdr}}"),
          \"fingerprint\": $(js "${q[fp]:-chrome}"),
          \"alpn\": $(js_list "${q[alpn]:-}"),
          \"allowInsecure\": $insecure
        }"
            ;;
        reality)
            [[ -n ${q[pbk]:-} ]] || p2k_fail "в ссылке с security=reality нет параметра pbk (публичный ключ)"
            out+=",
        \"realitySettings\": {
          \"serverName\": $(js "${q[sni]:-}"),
          \"fingerprint\": $(js "${q[fp]:-chrome}"),
          \"publicKey\": $(js "${q[pbk]}"),
          \"shortId\": $(js "${q[sid]:-}"),
          \"spiderX\": $(js "${q[spx]:-/}")${q[pqv]:+,
          \"mldsa65Verify\": $(js "${q[pqv]}")}
        }"
            ;;
        *) p2k_fail "защита «$security» не поддерживается (none, tls, reality)" ;;
    esac

    [[ -n $transport ]] && out+=",
        $transport"
    out+=",
        \"sockopt\": { \"dialerProxy\": \"corporate-proxy\" }"
    printf '%s' "$out"
}

# ------------------------------------------------------------------ main

link="${1:-}"
if [[ -z $link ]]; then
    if [[ -t 0 ]]; then
        printf 'Вставьте ссылку на сервер (vless://, trojan:// или ss://) и нажмите Enter:\n'
        IFS= read -r link || true
    else
        IFS= read -r link || true
    fi
fi
# Пробелы по краям появляются при копировании, внутри ссылки они допустимы
# только в названии сервера после «#».
link="${link#"${link%%[![:space:]]*}"}"
link="${link%"${link##*[![:space:]]}"}"
[[ -n $link ]] || p2k_fail "ссылка не указана"

scheme="${link%%://*}"
[[ $link == *://* ]] || p2k_fail "это не ссылка на сервер: нет части «схема://»"
rest="${link#*://}"
name=""
if [[ $rest == *"#"* ]]; then
    name="$(urldecode "${rest#*#}")"
    rest="${rest%%#*}"
fi
query=""
if [[ $rest == *"?"* ]]; then
    query="${rest#*\?}"
    rest="${rest%%\?*}"
fi
rest="${rest%/}"
parse_query "$query"

user="" host="" port=""
case "$scheme" in
    vless)
        parse_authority "$rest"
        [[ $user =~ ^[0-9A-Fa-f-]{36}$ ]] || p2k_warn "идентификатор пользователя не похож на UUID"
        settings="\"vnext\": [
          {
            \"address\": $(js "$host"),
            \"port\": $port,
            \"users\": [
              {
                \"id\": $(js "$user"),
                \"encryption\": $(js "${q[encryption]:-none}")${q[flow]:+,
                \"flow\": $(js "${q[flow]}")}
              }
            ]
          }
        ]"
        stream="$(stream_settings none)"
        protocol=vless
        ;;
    trojan)
        parse_authority "$rest"
        settings="\"servers\": [
          { \"address\": $(js "$host"), \"port\": $port, \"password\": $(js "$user") }
        ]"
        stream="$(stream_settings tls)"
        protocol=trojan
        ;;
    ss)
        # ss://base64(метод:пароль)@хост:порт или ss://base64(метод:пароль@хост:порт)
        if [[ $rest != *@* ]]; then
            rest="$(b64decode "$rest")" || p2k_fail "не удалось раскодировать ссылку ss://"
        fi
        parse_authority "$rest"
        if [[ $user != *:* ]]; then
            user="$(b64decode "$user")" || p2k_fail "не удалось раскодировать метод и пароль Shadowsocks"
        fi
        [[ $user == *:* ]] || p2k_fail "в ссылке ss:// нет метода шифрования и пароля"
        [[ -z ${q[plugin]:-} ]] || p2k_fail "плагины Shadowsocks (plugin=...) не поддерживаются"
        settings="\"servers\": [
          {
            \"address\": $(js "$host"),
            \"port\": $port,
            \"method\": $(js "${user%%:*}"),
            \"password\": $(js "${user#*:}")
          }
        ]"
        stream="$(stream_settings none)"
        protocol=shadowsocks
        ;;
    vmess)
        p2k_fail "ссылки vmess:// пока не поддерживаются. Составьте конфигурацию вручную по README.md."
        ;;
    *)
        p2k_fail "неизвестный тип ссылки «$scheme://». Поддерживаются vless://, trojan:// и ss://"
        ;;
esac

px_port="$(p2k_px_port)"
[[ -x $XRAY_BIN ]] || p2k_fail "Xray не найден: $XRAY_BIN. Распакуйте релизный архив p2k заново."

new_config="$(mktemp --suffix=.json "$XRAY_CONFIG.new.XXXXXX")"
trap 'rm -f -- "$new_config"' EXIT
chmod 600 -- "$new_config"

cat >"$new_config" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "browser",
      "listen": "127.0.0.1",
      "port": $INBOUND_PORT,
      "protocol": "http",
      "settings": {}
    }
  ],
  "outbounds": [
    {
      "tag": "vpn",
      "protocol": "$protocol",
      "settings": {
        $settings
      },
      "streamSettings": {
        $stream
      }
    },
    {
      "tag": "corporate-proxy",
      "protocol": "http",
      "settings": {
        "servers": [
          {
            "address": "127.0.0.1",
            "port": $px_port
          }
        ]
      }
    }
  ]
}
EOF

check_log="$(mktemp)"
if ! "$XRAY_BIN" run -test -config "$new_config" >"$check_log" 2>&1; then
    grep -v -i 'Reading config' -- "$check_log" | tail -n 5 >&2 || true
    rm -f -- "$check_log"
    p2k_fail "Xray не принял созданную конфигурацию. Проверьте ссылку."
fi
rm -f -- "$check_log"

if [[ -f $XRAY_CONFIG ]]; then
    backup="$XRAY_CONFIG.bak-$(date +%Y%m%d-%H%M%S)"
    cp -p -- "$XRAY_CONFIG" "$backup"
    p2k_info "Прежняя конфигурация сохранена: $backup"
fi
mv -- "$new_config" "$XRAY_CONFIG"
trap - EXIT

network="${q[type]:-tcp}"
security="${q[security]:-}"
[[ -n $security ]] || { [[ $protocol == trojan ]] && security=tls || security=none; }
p2k_info "Создан $XRAY_CONFIG"
printf '  сервер:    %s%s\n' "$host:$port" "${name:+ ($name)}"
printf '  протокол:  %s, транспорт %s, защита %s\n' "$protocol" "$network" "$security"
printf '  браузер:   http://127.0.0.1:%s\n' "$INBOUND_PORT"
printf '  через px:  127.0.0.1:%s\n' "$px_port"
