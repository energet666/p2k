# shellcheck shell=bash
# Загрузка файлов для установщиков. Требует lib/common.sh.
#
# По умолчанию загрузка идёт через px, то есть через корпоративный прокси
# с билетом Kerberos сеанса. Если https_proxy уже задан (например, скрипт
# запущен из p2k-terminal.sh), используется он. P2K_DIRECT=1 отключает прокси.

p2k_download_setup() {
    if [[ ${P2K_DIRECT:-0} == 1 ]]; then
        P2K_DOWNLOAD_PROXY=""
    elif [[ -n ${https_proxy:-${HTTPS_PROXY:-}} ]]; then
        P2K_DOWNLOAD_PROXY="${https_proxy:-$HTTPS_PROXY}"
    else
        p2k_require_tools
        p2k_px_acquire
        P2K_DOWNLOAD_PROXY="$P2K_PROXY_URL"
    fi
}

p2k_download() {
    local -a proxy_args=(--noproxy '*')
    [[ -n ${P2K_DOWNLOAD_PROXY:-} ]] && proxy_args=(--proxy "$P2K_DOWNLOAD_PROXY")
    curl --fail --location --retry 3 --progress-bar \
        "${proxy_args[@]}" --output "$2" "$1" ||
        p2k_fail "не удалось загрузить $1"
}
