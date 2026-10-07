# shellcheck shell=bash
# Оформление вывода в терминале: рамки, значки состояния, вопросы.
# Цвет включается только в терминале и отключается переменной NO_COLOR.

p2k_ui_init() {
    local locale="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
    if [[ $locale == *[Uu][Tt][Ff]-8* || $locale == *[Uu][Tt][Ff]8* ]]; then
        UI_H="─" UI_V="│" UI_TL="╭" UI_TR="╮" UI_BL="╰" UI_BR="╯"
        UI_OK="✔" UI_WARN="▲" UI_ERR="✘" UI_INFO="•" UI_ASK="?"
    else
        UI_H="-" UI_V="|" UI_TL="+" UI_TR="+" UI_BL="+" UI_BR="+"
        UI_OK="+" UI_WARN="!" UI_ERR="x" UI_INFO="*" UI_ASK="?"
    fi

    UI_RESET="" UI_BOLD="" UI_DIM="" UI_GREEN="" UI_YELLOW="" UI_RED="" UI_CYAN=""
    if [[ -t 1 && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
        UI_RESET=$'\e[0m' UI_BOLD=$'\e[1m' UI_DIM=$'\e[2m'
        UI_GREEN=$'\e[32m' UI_YELLOW=$'\e[33m' UI_RED=$'\e[31m' UI_CYAN=$'\e[36m'
    fi
}

# Длина строки в символах независимо от локали: в UTF-8 каждый символ
# состоит из одного ведущего байта и байтов продолжения 0x80-0xBF.
ui_len() {
    local LC_ALL=C s="$1"
    s="${s//[$'\x80'-$'\xbf']/}"
    printf '%s' "${#s}"
}

ui_repeat() {
    local text="$1" count="$2" out=""
    while ((count-- > 0)); do out+="$text"; done
    printf '%s' "$out"
}

# Рамка вокруг строк. Первый аргумент — заголовок рамки (может быть пустым).
ui_box() {
    local title="$1"
    shift
    local line len width=0 title_len
    title_len="$(ui_len "$title")"
    for line in "$@"; do
        len="$(ui_len "$line")"
        ((len > width)) && width=$len
    done
    ((title_len + 4 > width)) && width=$((title_len + 4))

    local top
    if [[ -n $title ]]; then
        top="$UI_H $UI_BOLD$title$UI_RESET$UI_CYAN $(ui_repeat "$UI_H" $((width - title_len - 1)))"
    else
        top="$(ui_repeat "$UI_H" $((width + 2)))"
    fi
    printf '  %s%s%s%s%s\n' "$UI_CYAN" "$UI_TL" "$top" "$UI_TR" "$UI_RESET"
    for line in "$@"; do
        printf '  %s%s%s %s%s %s%s%s\n' "$UI_CYAN" "$UI_V" "$UI_RESET" \
            "$line" "$(ui_repeat " " $((width - $(ui_len "$line"))))" "$UI_CYAN" "$UI_V" "$UI_RESET"
    done
    printf '  %s%s%s%s%s\n' "$UI_CYAN" "$UI_BL" "$(ui_repeat "$UI_H" $((width + 2)))" "$UI_BR" "$UI_RESET"
}

ui_banner() {
    printf '\n'
    if [[ $UI_H == "─" ]]; then
        ui_box "" \
            "" \
            "  ┏━┓ ┏━┓ ╻┏     Интернет через корпоративный прокси" \
            "  ┣━┛ ┏━┛ ┣┻┓    по билету Kerberos, без пароля," \
            "  ╹   ┗━╸ ╹ ╹    и браузер через Xray" \
            ""
    else
        ui_box "" "" "  p2k   Интернет через корпоративный прокси" \
            "        по билету Kerberos, без пароля," \
            "        и браузер через Xray" ""
    fi
}

# Заголовок шага: ui_step номер всего название
ui_step() {
    local head="$1/$2  $3"
    printf '\n %s%s%s %s%s%s %s%s\n' "$UI_CYAN" "$(ui_repeat "$UI_H" 2)" "$UI_RESET" \
        "$UI_BOLD" "$head" "$UI_RESET" "$UI_CYAN$(ui_repeat "$UI_H" $((50 - $(ui_len "$head"))))" "$UI_RESET"
}

ui_ok() { printf '   %s%s%s %s\n' "$UI_GREEN" "$UI_OK" "$UI_RESET" "$*"; }
ui_warn() { printf '   %s%s%s %s\n' "$UI_YELLOW" "$UI_WARN" "$UI_RESET" "$*"; }
ui_err() { printf '   %s%s%s %s\n' "$UI_RED" "$UI_ERR" "$UI_RESET" "$*"; }
ui_info() { printf '   %s%s%s %s\n' "$UI_DIM" "$UI_INFO" "$UI_RESET" "$*"; }
ui_note() { printf '     %s%s%s\n' "$UI_DIM" "$*" "$UI_RESET"; }

# Можно ли задавать вопросы пользователю.
ui_interactive() {
    [[ -t 0 && -t 1 ]]
}

# Вопрос «да/нет». ui_ask текст да|нет — второй аргумент задаёт ответ
# по умолчанию. Без терминала возвращается ответ по умолчанию.
ui_ask() {
    local text="$1" default="${2:-нет}" hint answer
    [[ $default == да ]] && hint="[Д/н]" || hint="[д/Н]"
    if ! ui_interactive; then
        [[ $default == да ]]
        return
    fi
    printf '   %s%s%s %s %s ' "$UI_CYAN" "$UI_ASK" "$UI_RESET" "$text" "$hint"
    IFS= read -r answer || answer=""
    case "${answer,,}" in
        "") [[ $default == да ]] ;;
        д | да | y | yes) return 0 ;;
        *) return 1 ;;
    esac
}

# Запрос строки. ui_input текст → значение в переменной UI_INPUT.
ui_input() {
    UI_INPUT=""
    ui_interactive || return 1
    printf '   %s%s%s %s\n   %s>%s ' "$UI_CYAN" "$UI_ASK" "$UI_RESET" "$1" "$UI_CYAN" "$UI_RESET"
    IFS= read -r UI_INPUT || UI_INPUT=""
}
