#!/usr/bin/env bash
# ============================================================================
# diaglinux.sh — Linux Server Diagnostic Script
# ============================================================================
# Version:  2.0.0
# Original: Vladislav Pavlovich (v1.0.0)
# Rewrite:  Полный рефакторинг — единый status-фреймворк, оптимизация, флаги,
#           итоговый summary, корректные exit-коды для cron/мониторинга.
#
# Требования: bash >= 4.0, coreutils. Рекомендуется root для полной проверки.
# ============================================================================

# --- strict mode --------------------------------------------------------------
# -e намеренно НЕ ставим: большинство grep | awk пайпов могут легитимно
# возвращать non-zero (паттерн не найден), это не ошибка скрипта.
set -uo pipefail

# UTF-8 locale для корректного подсчёта ширины строк с кириллицей (${#var})
# На разных дистрибутивах locale может называться C.UTF-8, C.utf8, en_US.UTF-8 и т.д.
_setup_utf8_locale() {
    local available
    available=$(locale -a 2>/dev/null) || return 0
    local candidate
    for candidate in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8 ru_RU.UTF-8 ru_RU.utf8; do
        if grep -qixF "$candidate" <<< "$available"; then
            export LC_ALL="$candidate"
            return 0
        fi
    done
    # Последний шанс — любая UTF-8 locale
    local any
    any=$(grep -iE '\.(utf-?8)$' <<< "$available" | head -1)
    [[ -n "$any" ]] && export LC_ALL="$any"
}
_setup_utf8_locale
unset -f _setup_utf8_locale

# --- bash version guard -------------------------------------------------------
if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: требуется bash >= 4.0 (текущий: $BASH_VERSION)" >&2
    exit 127
fi

# --- metadata -----------------------------------------------------------------
readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_NAME="diaglinux"
readonly SCRIPT_START_TS=$(date +%s)

# ============================================================================
# КОНФИГУРАЦИЯ ПО УМОЛЧАНИЮ (можно переопределить через env или флаги)
# ============================================================================
: "${LOG_DEPTH:=10000}"        # сколько строк лога анализировать
: "${LOG_TAIL:=30}"            # сколько уникальных паттернов показывать
: "${LARGE_LOG_SIZE:=500M}"    # порог "большого" лога
: "${LARGE_LAST_SIZE:=128}"    # порог /var/log/*tmp в MB
: "${LA_WARN:=4.0}"            # порог LA для WARN
: "${LA_FAIL:=8.0}"            # порог LA для FAIL
: "${DISK_WARN_PCT:=85}"       # порог заполнения диска для WARN
: "${DISK_FAIL_PCT:=90}"       # порог для FAIL
: "${MEM_FREE_MIN_MB:=50}"     # минимум свободной RAM
: "${MEM_AVAIL_MIN_MB:=200}"   # минимум available RAM
: "${SWAP_WARN_MB:=100}"       # порог swap usage для WARN
: "${DEBUG:=0}"                # общий debug
: "${SMART_DEBUG:=0}"          # debug для smartctl парсинга

# ============================================================================
# ФЛАГИ (переопределяются через аргументы)
# ============================================================================
OPT_NO_COLOR=0
OPT_VERBOSE=0
OPT_QUIET=0
OPT_SKIP_LOGS=0
OPT_SKIP_SMART=0
OPT_SKIP_TOP=0
OPT_SKIP_PANEL=0
OPT_JSON=0
OPT_NO_PANEL_LOGIN=0

# ============================================================================
# ТРЕКИНГ СТАТУСОВ (для итогового summary и exit-кода)
# ============================================================================
declare -A CHECK_STATUS   # name -> OK|WARN|FAIL|NA|INFO
declare -A CHECK_DETAILS  # name -> human-readable
declare -a CHECK_ORDER    # порядок для JSON-вывода
COUNT_OK=0
COUNT_WARN=0
COUNT_FAIL=0
COUNT_NA=0

# ============================================================================
# USAGE / HELP
# ============================================================================
show_help() {
    cat <<EOF
$SCRIPT_NAME $SCRIPT_VERSION — быстрая диагностика Linux-сервера

ИСПОЛЬЗОВАНИЕ:
    $0 [ОПЦИИ]

ОПЦИИ:
    -h, --help              Показать эту справку
    -V, --version           Показать версию
    -v, --verbose           Подробный вывод (debug)
    -q, --quiet             Только WARN/FAIL в выводе
        --no-color          Без ANSI-цветов (для logfile/CI)
        --json              Добавить JSON-отчёт в конец
        --skip-logs         Пропустить анализ логов (быстрый режим)
        --skip-smart        Пропустить SMART-проверку дисков
        --skip-top          Пропустить TOP-рейтинги процессов/пользователей
        --skip-panel        Не детектить панель управления
        --no-panel-login    Детектить панель, но не генерить логин-ссылки
                            (не создавать пользователей в .htpasswd и т.п.)

НАСТРОЙКИ ЧЕРЕЗ ENV:
    LOG_DEPTH=N             Глубина анализа логов (строк) [по умолч. 10000]
    LOG_TAIL=N              Число уникальных паттернов в отчёте [30]
    LARGE_LOG_SIZE=SIZE     Порог "большого" лога [500M]
    LA_WARN=N               Порог LA для WARN [4.0]
    LA_FAIL=N               Порог LA для FAIL [8.0]
    DISK_WARN_PCT=N         Порог заполнения для WARN [85]
    DISK_FAIL_PCT=N         Порог заполнения для FAIL [90]
    DEBUG=1                 Включить отладочные сообщения
    SMART_DEBUG=N           Debug smartctl парсинга (0–7)

EXIT-КОДЫ:
    0   Все проверки [OK]
    1   Есть [WARN] (внимание, но не критично)
    2   Есть [FAIL] (критические проблемы)
    127 Неподдерживаемая среда

ПРИМЕРЫ:
    $0                              # обычный запуск
    $0 --skip-logs --skip-smart     # быстрый запуск
    $0 --no-color | tee report.log  # запись в файл
    LOG_TAIL=50 $0 --json           # больше ошибок, c JSON
    $0 -q                           # только проблемы

Оригинал: Vladislav Pavlovich
EOF
}

show_version() {
    echo "$SCRIPT_NAME $SCRIPT_VERSION"
}

# ============================================================================
# ПАРСИНГ АРГУМЕНТОВ
# ============================================================================
parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -h|--help)          show_help; exit 0 ;;
            -V|--version)       show_version; exit 0 ;;
            -v|--verbose)       OPT_VERBOSE=1; DEBUG=1 ;;
            -q|--quiet)         OPT_QUIET=1 ;;
            --no-color)         OPT_NO_COLOR=1 ;;
            --json)             OPT_JSON=1 ;;
            --skip-logs)        OPT_SKIP_LOGS=1 ;;
            --skip-smart)       OPT_SKIP_SMART=1 ;;
            --skip-top)         OPT_SKIP_TOP=1 ;;
            --skip-panel)       OPT_SKIP_PANEL=1 ;;
            --no-panel-login)   OPT_NO_PANEL_LOGIN=1 ;;
            --)                 shift; break ;;
            -*)                 echo "Неизвестная опция: $1" >&2
                                echo "Используйте --help" >&2
                                exit 2 ;;
            *)                  echo "Неожиданный аргумент: $1" >&2; exit 2 ;;
        esac
        shift
    done
}

# ============================================================================
# ЦВЕТА (лениво, с учётом --no-color и isatty)
# ============================================================================
setup_colors() {
    if (( OPT_NO_COLOR )) || [[ ! -t 1 ]] || [[ "${TERM:-dumb}" == "dumb" ]]; then
        C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN='' C_MAGENTA=''
        C_WHITE='' C_GRAY='' C_BOLD='' C_DIM='' C_RESET=''
        C_BG_RED='' C_BG_GREEN='' C_BG_DARK=''
    else
        C_RED=$'\033[0;31m'
        C_GREEN=$'\033[0;32m'
        C_YELLOW=$'\033[0;33m'
        C_BLUE=$'\033[0;34m'
        C_MAGENTA=$'\033[0;35m'
        C_CYAN=$'\033[0;36m'
        C_WHITE=$'\033[1;37m'
        C_GRAY=$'\033[0;90m'
        C_BOLD=$'\033[1m'
        C_DIM=$'\033[2m'
        C_RESET=$'\033[0m'
        C_BG_RED=$'\033[41m'
        C_BG_GREEN=$'\033[42m'
        C_BG_DARK=$'\033[48;5;237m'
    fi
}

# ============================================================================
# УТИЛИТЫ
# ============================================================================
has_cmd() { command -v "$1" >/dev/null 2>&1; }

is_root() { [[ $EUID -eq 0 ]]; }

stderr_is_tty() { [[ -t 2 ]]; }

debug() {
    (( DEBUG )) || return 0
    printf '%s[DEBUG]%s %s\n' "$C_GRAY" "$C_RESET" "$*" >&2
}

warn_msg() {
    printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2
}

err_msg() {
    printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
}

# Печать прогресса (перезаписываемая строка) — только если stderr tty
progress() {
    stderr_is_tty || return 0
    (( OPT_QUIET )) && return 0
    printf '\r\033[2K%s' "$1" >&2
}
progress_end() {
    stderr_is_tty || return 0
    (( OPT_QUIET )) && return 0
    printf '\r\033[2K' >&2
}

# Сравнение float через awk (bc не требуется)
float_gt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>b)}'; }
float_ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>=b)}'; }
float_lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a<b)}'; }

# ============================================================================
# ГЛАВНАЯ ФУНКЦИЯ СТАТУС-ВЫВОДА
# report "Название проверки" STATUS "Детали"
# STATUS ∈ OK | WARN | FAIL | NA | INFO
# ============================================================================
report() {
    local name="$1"
    local status="$2"
    local details="${3:-}"

    CHECK_STATUS[$name]="$status"
    CHECK_DETAILS[$name]="$details"
    CHECK_ORDER+=("$name")

    local tag color
    case "$status" in
        OK)   tag="[ОК]";       color="$C_GREEN";  ((COUNT_OK++))   ;;
        WARN) tag="[ВНИМАНИЕ]"; color="$C_YELLOW"; ((COUNT_WARN++)) ;;
        FAIL) tag="[ОШИБКА]";   color="$C_RED";    ((COUNT_FAIL++)) ;;
        NA)   tag="[Н/Д]";      color="$C_GRAY";   ((COUNT_NA++))   ;;
        INFO) tag="[ИНФО]";     color="$C_CYAN"                     ;;
        *)    tag="[?]";        color="$C_WHITE"                    ;;
    esac

    # В quiet-режиме печатаем только WARN/FAIL
    if (( OPT_QUIET )) && [[ "$status" != "WARN" && "$status" != "FAIL" ]]; then
        return 0
    fi

    # Выравнивание имени (40 симв.) и тега (12 симв.) — работает в UTF-8 locale
    local name_width=40 tag_width=12
    local name_pad=$(( name_width - ${#name} )); (( name_pad < 0 )) && name_pad=0
    local tag_pad=$(( tag_width  - ${#tag}  )); (( tag_pad  < 0 )) && tag_pad=0
    local name_padding="" tag_padding=""
    (( name_pad > 0 )) && printf -v name_padding '%*s' "$name_pad" ''
    (( tag_pad  > 0 )) && printf -v tag_padding  '%*s' "$tag_pad"  ''

    if [[ -n "$details" ]]; then
        printf '  %s%s %s%s%s%s %s%s%s\n' \
            "$name" "$name_padding" \
            "$color" "$tag" "$C_RESET" "$tag_padding" \
            "$C_DIM" "$details" "$C_RESET"
    else
        printf '  %s%s %s%s%s\n' \
            "$name" "$name_padding" "$color" "$tag" "$C_RESET"
    fi
}

# Печать секционного заголовка
section() {
    (( OPT_QUIET )) && return 0
    printf '\n%s━━━ %s ━━━%s\n' "$C_BOLD" "$1" "$C_RESET"
}

# Печать подробностей (многострочно, с отступом)
detail_block() {
    (( OPT_QUIET )) && [[ "${1:-}" != "force" ]] && return 0
    [[ "${1:-}" == "force" ]] && shift
    while IFS= read -r line; do
        printf '      %s%s%s\n' "$C_DIM" "$line" "$C_RESET"
    done <<< "$1"
}

# ============================================================================
# ДЕТЕКТ ОС
# ============================================================================
detect_os() {
    local os_name="unknown" os_version="0" os_pretty=""

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os_name="${NAME:-unknown}"
        os_version="${VERSION_ID:-0}"
        os_pretty="${PRETTY_NAME:-$os_name $os_version}"
    elif [[ -r /etc/redhat-release ]]; then
        os_pretty=$(< /etc/redhat-release)
        os_name="RedHat-like"
    else
        os_pretty="$(uname -srm)"
    fi

    # Uptime из /proc/uptime — без парсинга `uptime`
    local uptime_pretty=""
    if [[ -r /proc/uptime ]]; then
        local up_sec
        read -r up_sec _ < /proc/uptime
        up_sec=${up_sec%.*}
        local d=$((up_sec / 86400))
        local h=$(((up_sec % 86400) / 3600))
        local m=$(((up_sec % 3600) / 60))
        if (( d > 0 )); then
            uptime_pretty="uptime ${d}d ${h}h ${m}m"
        elif (( h > 0 )); then
            uptime_pretty="uptime ${h}h ${m}m"
        else
            uptime_pretty="uptime ${m}m"
        fi
    fi

    report "ОС" "INFO" "$os_pretty, $uptime_pretty"

    # Предупреждение для совсем старых версий
    case "$os_name" in
        *Debian*)
            float_lt "$os_version" "10" && \
                report "Версия ОС" "WARN" "устаревший Debian (<10)"
            ;;
        *Ubuntu*)
            float_lt "$os_version" "20.04" && \
                report "Версия ОС" "WARN" "устаревший Ubuntu (<20.04)"
            ;;
        *CentOS*)
            float_lt "$os_version" "8" && \
                report "Версия ОС" "WARN" "устаревший CentOS (<8) — EOL"
            ;;
    esac
}

# ============================================================================
# ДЕТЕКТ ВНЕШНЕГО IP
# ============================================================================
detect_ip() {
    local rip=""
    local sources=(
        "https://ifconfig.me"
        "https://ipinfo.io/ip"
        "https://api.ipify.org"
    )

    for url in "${sources[@]}"; do
        if has_cmd curl; then
            rip=$(timeout 5 curl -fsS --insecure -4 -L --max-time 5 \
                --connect-timeout 5 "$url" 2>/dev/null || true)
        elif has_cmd wget; then
            rip=$(timeout 5 wget --no-check-certificate --inet4-only \
                --prefer-family=IPv4 --timeout=5 --tries=1 -qO- "$url" \
                2>/dev/null || true)
        fi
        if [[ "$rip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            break
        fi
        rip=""
    done

    if [[ -z "$rip" ]]; then
        report "Внешний IP" "WARN" "не удалось получить (нет сети или curl/wget)"
        CPIP=""
        # Попробуем локальный fallback для ссылок на панели
        if has_cmd ip; then
            CPIP=$(ip -4 addr show scope global 2>/dev/null | \
                awk '/inet /{print $2}' | awk -F/ '{print $1}' | head -1)
        fi
        return
    fi

    # Проверяем, что IP реально на локальных интерфейсах
    local is_local="неизвестно"
    if has_cmd ip; then
        if ip -4 addr | awk '/inet /{print $2}' | awk -F/ '{print $1}' \
                | grep -qxF "$rip"; then
            is_local="локальный"
        else
            is_local="НЕ найден локально (NAT/floating?)"
        fi
    fi

    report "Внешний IP" "INFO" "$rip ($is_local)"
    CPIP="$rip"
}

# ============================================================================
# ПАНЕЛИ УПРАВЛЕНИЯ — генерация логин-ссылок
# (функции из оригинала, с небольшими правками безопасности)
# ============================================================================

# ISPmanager 5 / ISPmgr legacy
isp_login() {
    local ip="$1"
    local key
    key=$(date +%s%N | md5sum | head -c 16)
    local mgrctl=""
    [[ -x /usr/local/mgr5/sbin/mgrctl ]] && mgrctl=/usr/local/mgr5/sbin/mgrctl
    [[ -x /usr/local/ispmgr/sbin/mgrctl ]] && mgrctl=/usr/local/ispmgr/sbin/mgrctl
    [[ -z "$mgrctl" ]] && return 1

    "$mgrctl" -m ispmgr session.newkey username=root key="$key" sok=o >/dev/null 2>&1 || return 1
    echo "https://${ip}:1500/manager/ispmgr?func=auth&username=root&key=${key}&checkcookie=no"
}

# FastPanel 2
fp2_login() {
    local ip="$1"
    has_cmd mogwai || return 1
    local url
    url=$(timeout 5 mogwai usrlogin 2>/dev/null) || return 1
    echo "https://${ip}:${url##*:}"
}

# FastPanel 1 (legacy) — создаёт временного пользователя в .htpasswd.
# ВНИМАНИЕ: это деструктивно, cleanup не автоматический. Используйте
# --no-panel-login, чтобы не создавать пользователя.
fp1_login() {
    local ip="$1"
    has_cmd htpasswd || return 1
    [[ -f /var/www/.htpasswd ]] || return 1
    local pass user="t2fpsupport"
    pass=$(date +%s%N | md5sum | head -c 32)
    htpasswd -b /var/www/.htpasswd "$user" "$pass" >/dev/null 2>&1 || return 1
    [[ -x /etc/init.d/lighttpd ]] && /etc/init.d/lighttpd restart >/dev/null 2>&1
    # Печатаем отдельно user/pass, чтобы не утекли через процесс-листинг
    echo "https://${ip}:8888/"
    echo "  логин: ${user}"
    echo "  пароль: ${pass}"
    echo "  ⚠  временный пользователь создан в /var/www/.htpasswd — удалите вручную!"
}

# VestaCP
vesta_login() {
    local ip="$1"
    [[ -r /usr/local/vesta/conf/mysql.conf ]] || return 1
    local pass
    pass=$(awk -F\' '/PASSWORD=/{print $2; exit}' /usr/local/vesta/conf/mysql.conf)
    [[ -z "$pass" ]] && return 1
    timeout 5 curl -fsSk -X POST "https://${ip}:8083/api/" \
        --data-urlencode "user=admin" \
        --data-urlencode "password=${pass}" 2>/dev/null || return 1
}

# DirectAdmin
da_login() {
    local ip="$1"
    [[ -r /usr/local/directadmin/scripts/setup.txt ]] || return 1
    local pass
    pass=$(awk -F= '/^adminpass=/{print $2; exit}' \
        /usr/local/directadmin/scripts/setup.txt)
    [[ -z "$pass" ]] && return 1
    timeout 5 curl -fsSk --request POST \
        "https://${ip}:2222/CMD_LOGIN?username=admin" \
        --data-urlencode "passwd=${pass}" 2>/dev/null \
        | grep -oP '(?<=Location: ).*' || return 1
}

# cPanel / WHM
whm_login() {
    local ip="$1"
    has_cmd whmapi1 || return 1
    whmapi1 create_user_session user=root service=cpaneld 2>/dev/null \
        | grep -oP '(?<=url: ).*' || return 1
}

detect_panel() {
    (( OPT_SKIP_PANEL )) && return 0
    local -A panels=(
        [fastpanel2]="FastPanel 2"
        [fastpanel]="FastPanel (legacy)"
        [mgr5]="ISPmanager 5"
        [ispmgr]="ISPmgr (legacy)"
        [cpanel]="cPanel/WHM"
        [vesta]="VestaCP"
        [directadmin]="DirectAdmin"
    )
    local found=()
    for p in "${!panels[@]}"; do
        [[ -d "/usr/local/$p" ]] && found+=("$p")
    done

    if (( ${#found[@]} == 0 )); then
        report "Панель управления" "INFO" "не найдена"
        return
    fi

    for p in "${found[@]}"; do
        report "Панель: ${panels[$p]}" "INFO" "/usr/local/$p"
    done

    if (( OPT_NO_PANEL_LOGIN )) || [[ -z "${CPIP:-}" ]]; then
        [[ -z "${CPIP:-}" ]] && debug "CPIP пуст — пропускаю генерацию ссылок"
        return
    fi

    # Для каждой найденной — генерим ссылку
    for p in "${found[@]}"; do
        local url=""
        case "$p" in
            fastpanel2)  url=$(fp2_login "$CPIP" 2>/dev/null) ;;
            fastpanel)   url=$(fp1_login "$CPIP" 2>/dev/null) ;;
            mgr5|ispmgr) url=$(isp_login "$CPIP" 2>/dev/null) ;;
            cpanel)      url=$(whm_login "$CPIP" 2>/dev/null) ;;
            vesta)       url=$(vesta_login "$CPIP" 2>/dev/null) ;;
            directadmin) url=$(da_login "$CPIP" 2>/dev/null) ;;
        esac
        if [[ -n "$url" ]]; then
            printf '      %s→ Ссылка входа в %s:%s\n' \
                "$C_CYAN" "${panels[$p]}" "$C_RESET"
            while IFS= read -r line; do
                printf '        %s%s%s\n' "$C_BOLD" "$line" "$C_RESET"
            done <<< "$url"
        fi
    done

    if (( ${#found[@]} > 1 )); then
        warn_msg "Найдено несколько панелей: ${found[*]}"
    fi
}

# ============================================================================
# LOAD AVERAGE
# ============================================================================
check_load() {
    local la
    la=$(awk '{print $1}' /proc/loadavg 2>/dev/null) || {
        report "Load Average" "NA" "/proc/loadavg недоступен"
        return
    }
    local cores
    cores=$(nproc 2>/dev/null || echo 1)
    local detail="LA=${la} (cores=${cores})"

    if float_gt "$la" "$LA_FAIL"; then
        report "Load Average" "FAIL" "$detail — критично"
    elif float_gt "$la" "$LA_WARN"; then
        report "Load Average" "WARN" "$detail"
    else
        report "Load Average" "OK" "$detail"
    fi
}

# ============================================================================
# ДИСКОВОЕ ПРОСТРАНСТВО + INODES
# ============================================================================
check_disk_space() {
    local df_out
    df_out=$(df -h --exclude-type=squashfs --exclude-type=tmpfs \
        --exclude-type=devtmpfs --exclude-type=overlay 2>/dev/null \
        | grep -v "/var/lib/docker" | tail -n +2) || true

    [[ -z "$df_out" ]] && { report "Дисковое пространство" "NA"; return; }

    local worst_pct=0 worst_mount="" worst_avail=""
    local problems=()

    while read -r fs size used avail pct mount; do
        [[ "$pct" == "-" ]] && continue
        local pct_num=${pct%\%}
        [[ ! "$pct_num" =~ ^[0-9]+$ ]] && continue

        if (( pct_num > worst_pct )); then
            worst_pct=$pct_num
            worst_mount=$mount
            worst_avail=$avail
        fi

        if (( pct_num >= DISK_FAIL_PCT )); then
            problems+=("FAIL: ${mount} = ${pct} (доступно ${avail})")
        elif (( pct_num >= DISK_WARN_PCT )); then
            problems+=("WARN: ${mount} = ${pct} (доступно ${avail})")
        fi
    done <<< "$df_out"

    local detail="макс ${worst_pct}% на ${worst_mount} (свободно ${worst_avail})"

    if (( worst_pct >= DISK_FAIL_PCT )); then
        report "Место на диске" "FAIL" "$detail"
    elif (( worst_pct >= DISK_WARN_PCT )); then
        report "Место на диске" "WARN" "$detail"
    else
        report "Место на диске" "OK" "$detail"
    fi

    if (( ${#problems[@]} > 0 )); then
        for p in "${problems[@]}"; do
            detail_block "$p"
        done
    fi
}

check_inodes() {
    local df_out
    df_out=$(df -i --exclude-type=squashfs --exclude-type=tmpfs \
        --exclude-type=devtmpfs --exclude-type=overlay 2>/dev/null \
        | grep -v "/var/lib/docker" | tail -n +2) || true

    [[ -z "$df_out" ]] && { report "Inodes" "NA"; return; }

    local worst_pct=0 worst_mount=""
    local problems=()

    while read -r fs inodes iused ifree pct mount; do
        [[ "$pct" == "-" ]] && continue
        local pct_num=${pct%\%}
        [[ ! "$pct_num" =~ ^[0-9]+$ ]] && continue

        if (( pct_num > worst_pct )); then
            worst_pct=$pct_num
            worst_mount=$mount
        fi

        if (( pct_num >= DISK_FAIL_PCT )); then
            problems+=("FAIL: ${mount} = ${pct}")
        elif (( pct_num >= DISK_WARN_PCT )); then
            problems+=("WARN: ${mount} = ${pct}")
        fi
    done <<< "$df_out"

    local detail="макс ${worst_pct}% на ${worst_mount}"

    if (( worst_pct >= DISK_FAIL_PCT )); then
        report "Inodes" "FAIL" "$detail"
    elif (( worst_pct >= DISK_WARN_PCT )); then
        report "Inodes" "WARN" "$detail"
    else
        report "Inodes" "OK" "$detail"
    fi

    if (( ${#problems[@]} > 0 )); then
        for p in "${problems[@]}"; do
            detail_block "$p"
        done
    fi
}

check_readonly_mounts() {
    # Фильтруем:
    #  - виртуальные FS (sysfs, proc, cgroup, 9p, tmpfs, squashfs, overlay и т.д.)
    #  - контейнерные/снапшотные монтирования
    # Оставляем только "настоящие" блочные устройства, реально смонтированные ro.
    local ro
    ro=$(mount 2>/dev/null | awk '
        # Пропускаем виртуальные FS по типу (поле 5: "type XXX")
        $5 ~ /^(sysfs|proc|cgroup|cgroup2|devtmpfs|tmpfs|devpts|mqueue|hugetlbfs|9p|fuse\..*|overlay|squashfs|ramfs|pstore|bpf|tracefs|debugfs|securityfs|configfs|autofs|rpc_pipefs|binfmt_misc|fusectl|nfsd|efivarfs)$/ { next }
        # Пропускаем "none on ..." (обычно виртуальное)
        $1 == "none" { next }
        # Только блочные устройства / реальные FS с флагом ro
        $0 ~ /[(,]ro[,)]/ { print }
    ') || true

    if [[ -z "$ro" ]]; then
        report "Read-only разделы" "OK"
    else
        local count
        count=$(echo "$ro" | wc -l)
        report "Read-only разделы" "WARN" "найдено $count"
        detail_block "$ro"
    fi
}

# ============================================================================
# MDADM / RAID
# ============================================================================
check_mdstat() {
    [[ -e /proc/mdstat ]] || return 0

    if ! has_cmd mdadm; then
        report "/proc/mdstat" "WARN" "mdstat есть, но mdadm не установлен"
        return
    fi

    local mdstat
    mdstat=$(< /proc/mdstat)
    local raid_devs=(/dev/md[0-9]*)

    if [[ ! -e "${raid_devs[0]}" ]]; then
        report "/proc/mdstat" "INFO" "mdstat есть, но RAID-массивов нет"
        return
    fi

    # Degraded detection
    if echo "$mdstat" | grep -qiE '\[.{0,5}(_U|U_).{0,5}\]'; then
        report "/proc/mdstat" "FAIL" "DEGRADED"
        detail_block "force" "$mdstat"
        return
    fi

    # Recovery / rebuild
    if echo "$mdstat" | grep -qiE 'repair|rebuilding|recovery'; then
        report "/proc/mdstat" "WARN" "идёт rebuild/recovery"
        return
    fi

    # RAID0 warning
    local raid_info=""
    for dev in "${raid_devs[@]}"; do
        [[ -e "$dev" ]] || continue
        local lvl
        lvl=$(mdadm --detail "$dev" 2>/dev/null | awk -F: '/Raid Level/{gsub(/ /,"",$2); print $2; exit}')
        raid_info+="$dev=$lvl "
        if [[ "$lvl" == "raid0" ]]; then
            report "/proc/mdstat" "WARN" "$dev — RAID0 (нет избыточности)"
            return
        fi
    done

    report "/proc/mdstat" "OK" "$raid_info"
}

check_raid_controllers() {
    if has_cmd megacli; then
        local out
        out=$(megacli -LDInfo -Lall -aALL 2>/dev/null || true)
        if [[ -n "$out" ]] && echo "$out" | grep -qE 'Fail|Degraded|Offline'; then
            report "MegaCLI RAID" "FAIL" "обнаружены ошибки"
            detail_block "$(echo "$out" | grep -E 'Fail|Degraded|Offline')"
        elif [[ -n "$out" ]]; then
            report "MegaCLI RAID" "OK"
        fi
    fi

    if has_cmd arcconf; then
        local out
        out=$(arcconf getconfig 1 ld 2>/dev/null || true)
        if [[ -n "$out" ]] && echo "$out" | grep -qE 'Group.*Segment.*: Missing'; then
            report "Adaptec arcconf" "FAIL" "обнаружены ошибки"
        elif [[ -n "$out" ]]; then
            report "Adaptec arcconf" "OK"
        fi
    fi
}

# ============================================================================
# SMART
# ============================================================================
_smart_check_counter() {
    # $1=имя поля, $2=значение, $3=порог, $4=описание
    local name="$1" val="$2" max="$3" desc="${4:-}"
    [[ "$val" =~ ^[0-9]+$ ]] || return 0
    if (( val >= max )); then
        if [[ -n "$desc" ]]; then
            echo "  ${name} = ${val} — ${desc}"
        else
            echo "  ${name} = ${val}"
        fi
    fi
}

_smart_analyze_disk() {
    local disk="$1"
    local smart_out errors="" disk_type="" serial=""

    if [[ "$disk" == /dev/nvme* ]]; then
        disk_type="NVMe"
        smart_out=$({ smartctl -a "$disk" 2>/dev/null; smartctl -a "${disk%n*}" 2>/dev/null; } || true)
    else
        smart_out=$(smartctl -a "$disk" 2>/dev/null || true)
        if echo "$smart_out" | grep -qiE 'rotation rate.*(Solid State|^0)'; then
            disk_type="SSD"
        else
            disk_type="HDD"
        fi
    fi

    if [[ -z "$smart_out" ]]; then
        report "SMART $disk" "NA" "нет ответа от smartctl"
        return
    fi

    (( SMART_DEBUG > 5 )) && debug "$disk smartctl output:"$'\n'"$smart_out"

    serial=$(echo "$smart_out" | awk -F: '/[Ss]erial [Nn]umber/{gsub(/^ +| +$/,"",$2); print $2; exit}')

    # Критические маркеры
    local crit
    crit=$(echo "$smart_out" | grep -iE \
        'SMART overall-health self-assessment test result:\s+FAILED|Completed:\s+read failure|FAILING_NOW' \
        | grep -viE 'No Errors Logged|Error Information' || true)
    [[ -n "$crit" ]] && errors+="$crit"$'\n'

    # Счётчики
    local rs pct lifetime ou cps ru
    rs=$(echo "$smart_out"       | awk '/Reallocated_Sector_Ct/{print $NF; exit}'  | tr -cd '0-9')
    ou=$(echo "$smart_out"       | awk '/Offline_Uncorrectable/{print $NF; exit}'  | tr -cd '0-9')
    cps=$(echo "$smart_out"      | awk '/Current_Pending_Sector/{print $NF; exit}' | tr -cd '0-9')
    ru=$(echo "$smart_out"       | awk '/Reported_Uncorrect/{print $NF; exit}'     | tr -cd '0-9')
    pct=$(echo "$smart_out"      | awk -F: '/Percentage Used/{gsub(/[^0-9]/,"",$2); print $2; exit}')
    lifetime=$(echo "$smart_out" | awk '/Percent_Lifetime_Used/{print $NF; exit}'  | tr -cd '0-9')

    local cnt_errs=""
    cnt_errs+=$(_smart_check_counter "Reallocated_Sector_Ct" "$rs" 500 "")
    cnt_errs+=$(_smart_check_counter "Offline_Uncorrectable" "$ou" 200 "")
    cnt_errs+=$(_smart_check_counter "Current_Pending_Sector" "$cps" 200 "")
    cnt_errs+=$(_smart_check_counter "Reported_Uncorrect" "$ru" 200 "")
    cnt_errs+=$(_smart_check_counter "Percentage_Used" "$pct" 100 "диск на исходе ресурса")
    cnt_errs+=$(_smart_check_counter "Percent_Lifetime_Used" "$lifetime" 100 "диск на исходе ресурса")
    [[ -n "$cnt_errs" ]] && errors+="$cnt_errs"$'\n'

    local detail="${disk_type}"
    [[ -n "$serial" ]] && detail+=", S/N: $serial"

    if [[ -n "$errors" ]]; then
        report "SMART $disk" "FAIL" "$detail"
        detail_block "force" "$errors"
    else
        report "SMART $disk" "OK" "$detail"
    fi
}

check_smart() {
    (( OPT_SKIP_SMART )) && return 0
    if ! has_cmd smartctl; then
        # Проверим, есть ли вообще диски для анализа
        if compgen -G "/dev/sd[a-z]" > /dev/null \
           || compgen -G "/dev/nvme[0-9]n[0-9]" > /dev/null; then
            report "SMART" "NA" "smartctl не установлен"
        fi
        return
    fi

    if ! is_root; then
        report "SMART" "NA" "требуется root"
        return
    fi

    # Собираем список дисков
    local disks=()
    local d
    for d in /dev/sd[a-z] /dev/hd[a-z] /dev/nvme[0-9]n[0-9]; do
        [[ -b "$d" ]] && disks+=("$d")
    done

    if (( ${#disks[@]} == 0 )); then
        report "SMART" "INFO" "диски не найдены"
        return
    fi

    for d in "${disks[@]}"; do
        _smart_analyze_disk "$d"
    done
}

# ============================================================================
# RAM / SWAP
# ============================================================================
check_ram_swap() {
    local free_out
    free_out=$(free -m 2>/dev/null) || { report "RAM/SWAP" "NA"; return; }

    local total_mem used_mem free_mem avail_mem total_swap used_swap
    total_mem=$(echo "$free_out" | awk '/^Mem:/{print $2}')
    used_mem=$(echo "$free_out"  | awk '/^Mem:/{print $3}')
    free_mem=$(echo "$free_out"  | awk '/^Mem:/{print $4}')
    avail_mem=$(echo "$free_out" | awk '/^Mem:/{print $7}')
    total_swap=$(echo "$free_out" | awk '/^Swap:/{print $2}')
    used_swap=$(echo "$free_out"  | awk '/^Swap:/{print $3}')

    local ram_detail="${used_mem}/${total_mem}MB (свободно ${avail_mem}MB)"
    local swap_detail="${used_swap}/${total_swap}MB"

    local ram_status="OK"
    if (( free_mem < MEM_FREE_MIN_MB )) || (( avail_mem < MEM_AVAIL_MIN_MB )); then
        ram_status="WARN"
    fi
    report "RAM" "$ram_status" "$ram_detail"

    if (( total_swap == 0 )); then
        report "SWAP" "INFO" "swap не настроен"
    elif (( used_swap > SWAP_WARN_MB )); then
        report "SWAP" "WARN" "$swap_detail"
        _check_swap_top
    else
        report "SWAP" "OK" "$swap_detail"
    fi
}

_check_swap_top() {
    [[ -r /proc ]] || return 0
    progress "Сбор TOP-потребителей swap..."
    local top_out
    top_out=$(
        for pid_dir in /proc/[0-9]*; do
            local pid=${pid_dir##*/}
            [[ -r "$pid_dir/status" ]] || continue
            awk -v pid="$pid" '
                /^Name:/{name=$2}
                /^VmSwap:/{if ($2>0) print $2, name}
            ' "$pid_dir/status" 2>/dev/null
        done | awk '{s[$2]+=$1} END{for (n in s) printf "%10.2f MB  %s\n", s[n]/1024, n}' \
             | sort -nr | head -5
    )
    progress_end
    [[ -n "$top_out" ]] && detail_block "force" "TOP-5 swap users:"$'\n'"$top_out"
}

# ============================================================================
# БОЛЬШИЕ ЛОГИ
# ============================================================================
check_large_logs() {
    local found=()
    local path
    local search_paths=(/var/log)

    # Glob раскрывается правильно здесь — не в массиве строк
    for path in /var/www/*/data/logs /var/www/httpd-logs /home/*/logs; do
        [[ -d "$path" ]] && search_paths+=("$path")
    done

    for path in "${search_paths[@]}"; do
        local maxdepth=3
        [[ "$path" != "/var/log" ]] && maxdepth=2
        while IFS= read -r -d '' f; do
            local sz
            sz=$(du -h "$f" 2>/dev/null | awk '{print $1}')
            found+=("  ${sz}	${f}")
        done < <(find "$path" -maxdepth "$maxdepth" -type f \
            -size +"$LARGE_LOG_SIZE" ! -name "*.gz" ! -name "*.xz" \
            ! -name "*.bz2" -print0 2>/dev/null)
    done

    if (( ${#found[@]} == 0 )); then
        report "Большие логи (>${LARGE_LOG_SIZE})" "OK"
    else
        report "Большие логи (>${LARGE_LOG_SIZE})" "WARN" "найдено ${#found[@]}"
        printf '%s\n' "${found[@]}" | detail_block "$(cat)"
    fi
}

check_lastlogs() {
    local found=()
    local threshold_bytes=$((LARGE_LAST_SIZE * 1024 * 1024))
    local f
    for f in /var/log/[a-z]tmp; do
        [[ -f "$f" ]] || continue
        local size
        size=$(stat -c%s "$f" 2>/dev/null) || continue
        if (( size > threshold_bytes )); then
            local mb=$((size / 1024 / 1024))
            found+=("  ${mb}M	${f}")
        fi
    done

    if (( ${#found[@]} == 0 )); then
        report "Большие last-логи" "OK"
    else
        report "Большие last-логи (>${LARGE_LAST_SIZE}M)" "WARN" "найдено ${#found[@]}"
        printf '%s\n' "${found[@]}" | while IFS= read -r l; do detail_block "$l"; done
        detail_block "Это может приводить к задержкам входа по SSH и падению cron-задач"
    fi
}

# ============================================================================
# SYSTEMD / WEB-СЕРВЕРЫ / OpenVZ
# ============================================================================
check_systemd_failed() {
    if ! has_cmd systemctl; then
        report "systemd (failed units)" "NA"
        return
    fi
    local failed
    failed=$(systemctl list-units --state=failed --no-legend --no-pager 2>/dev/null \
        | awk '{print $1, $2, $3, $4}') || true

    if [[ -z "$failed" ]]; then
        report "systemd (failed units)" "OK"
    else
        local count
        count=$(echo "$failed" | wc -l)
        report "systemd (failed units)" "FAIL" "$count упавших"
        detail_block "$failed"
    fi
}

check_nginx() {
    has_cmd nginx || { report "Nginx config" "NA"; return; }
    local out
    out=$(nginx -t 2>&1) || true
    if echo "$out" | grep -qi 'test failed'; then
        report "Nginx config" "FAIL"
        detail_block "$out"
    elif echo "$out" | grep -qi 'syntax is ok'; then
        report "Nginx config" "OK"
    else
        report "Nginx config" "WARN" "неожиданный ответ"
        detail_block "$out"
    fi
}

check_apache() {
    local cmd=""
    has_cmd apache2ctl && cmd=apache2ctl
    has_cmd apachectl  && cmd=apachectl
    has_cmd httpd      && [[ -z "$cmd" ]] && cmd=httpd
    if [[ -z "$cmd" ]]; then
        report "Apache config" "NA"
        return
    fi
    local out
    out=$("$cmd" -t 2>&1) || true
    if echo "$out" | grep -qi 'Syntax OK'; then
        report "Apache config" "OK"
    else
        report "Apache config" "FAIL"
        detail_block "$out"
    fi
}

check_beancounters() {
    [[ -e /proc/user_beancounters ]] || return 0
    local bad
    bad=$(grep -v failcnt /proc/user_beancounters \
          | grep -v Version \
          | awk '$NF !~ /^[ ]*0$/' 2>/dev/null) || true
    if [[ -z "$bad" ]]; then
        report "/proc/user_beancounters" "OK"
    else
        report "/proc/user_beancounters" "WARN" "найдены ненулевые failcnt"
        detail_block "$bad"
    fi
}

# ============================================================================
# TOP ПРОЦЕССОВ / ПОЛЬЗОВАТЕЛЕЙ
# ============================================================================
show_top_processes() {
    (( OPT_SKIP_TOP )) && return 0
    (( OPT_QUIET )) && return 0

    section "TOP процессов"

    # Один снимок ps — используем многократно
    local ps_snapshot
    ps_snapshot=$(ps -eo pid,user,%cpu,%mem,rss,args --no-headers 2>/dev/null) || return

    printf '\n%sПо CPU:%s\n' "$C_CYAN" "$C_RESET"
    echo "$ps_snapshot" | sort -k3 -nr | head -5 | awk -v d="$C_DIM" -v r="$C_RESET" '
        {
            printf "  %6.2f%%  PID %-7s  %-12s  ", $3, $1, $2
            cmd=""; for (i=6; i<=NF; i++) cmd = cmd $i " "
            if (length(cmd) > 130) cmd = substr(cmd,1,127) "..."
            print cmd
        }'

    printf '\n%sПо RAM:%s\n' "$C_CYAN" "$C_RESET"
    echo "$ps_snapshot" | sort -k4 -nr | head -5 | awk '
        {
            rss_mb=$5/1024
            printf "  %6.2f%%  %6.1fMB  PID %-7s  %-12s  ", $4, rss_mb, $1, $2
            cmd=""; for (i=6; i<=NF; i++) cmd = cmd $i " "
            if (length(cmd) > 120) cmd = substr(cmd,1,117) "..."
            print cmd
        }'
}

show_top_users() {
    (( OPT_SKIP_TOP )) && return 0
    (( OPT_QUIET )) && return 0

    section "TOP пользователей"
    local ps_snapshot
    ps_snapshot=$(ps -eo user,%cpu,%mem,rss --no-headers 2>/dev/null) || return

    printf '\n%sПо количеству процессов / CPU / RAM:%s\n' "$C_CYAN" "$C_RESET"
    echo "$ps_snapshot" | awk '
        {
            count[$1]++
            cpu[$1]+=$2
            mem_mb[$1]+=$4/1024
        }
        END {
            printf "  %-20s  %-8s  %-10s  %-10s\n", "USER", "PROCS", "%CPU", "RAM(MB)"
            for (u in count) {
                printf "  %-20s  %-8d  %7.2f%%   %8.1f\n", u, count[u], cpu[u], mem_mb[u]
            }
        }' | (read -r header; echo "$header"; sort -k4 -nr) | head -8
}

show_disk_load() {
    (( OPT_SKIP_TOP )) && return 0
    (( OPT_QUIET )) && return 0
    has_cmd atop || return 0
    is_root || return 0

    section "TOP нагрузки на диск (atop)"
    progress "Запуск atop (7s)..."
    local out
    out=$(timeout 8 atop -d 1 1 2>/dev/null | \
          grep -E '^[[:space:]]*[0-9]+[[:space:]]+' | \
          awk '$(NF-1) ~ /[1-9]/' | head -10) || true
    progress_end

    if [[ -z "$out" ]]; then
        printf '  %s(нет активности или atop не работает)%s\n' "$C_DIM" "$C_RESET"
    else
        echo "$out" | awk '{
            pid=$1; load=$(NF-1); cmd=$NF
            printf "  %-8s  %-12s  PID %s\n", load, cmd, pid
        }'
    fi
}

# ============================================================================
# АНАЛИЗ ЛОГОВ — оптимизированная версия
# Ключевое улучшение: лог кэшируется в tmp-файл один раз,
# затем все grep-ы идут по файлу. Это в разы быстрее оригинала.
# ============================================================================

# shellcheck disable=SC2016
readonly LOG_PATTERNS='Cannot allocate memory|Too many open files|marked as crashed|Table corruption|Database page corruption|errno: 145|SYN flooding|emerg|error|temperature|[^e]fault|fail[^2]|i/o.{0,5}(error|fail|fault)|ata.*FREEZE|ata.*LOCK|ata3.*hard resetting link|EXT4-fs error|Input/output error|memory corruption|Remounting filesystem read-only|Corrupted data|Buffer I/O error|XFS.{1,20}Corruption|Superblock last mount time is in the future|degraded array|array is degraded|disk failure|Failed to write to block|failed to read/write block|slab corruption|Segmentation fault|segfault|Failed to allocate memory|Low memory|Out of memory|oom_reaper|link down|SMART error|kernel BUG|EDAC MC0:'

readonly LOG_EXCLUDE='Scanning for low memory corruption every|Scanning [0-9]+ areas for low memory|No matching DirectoryIndex|error log file re-opened|xrdp_(sec|rdp|process|iso)_|plasmashell|chrom.*Fontconfig error|Image: Error decoding|Playing audio notification failed|org_kde_powerdevil|Failed to set global shortcut|wayland_wrapper|RAS: Correctable Errors collector initialized|spectacle.*display'

readonly LOG_SUPER_DANGER='i/o.{0,5}(error|fail|fault)|EXT4-fs error|Input/output error|FAILED SMART self-check|BACK UP DATA NOW'
readonly LOG_DANGER='Too many open files|Remounting filesystem read-only|XFS.{1,20}Corruption|degraded array|array is degraded|disk failure|slab corruption'
readonly LOG_WARN='Cannot allocate memory|memory corruption|marked as crashed|Out of memory|oom_reaper|link down|kernel BUG|service: Failed|segfault'

# Нормализация строки лога (отрубаем таймстампы, PID-ы, кастомную мишуру)
strip_log_line() {
    sed -E '
        # Syslog формат: "Oct 01 12:34:56 hostname prog[PID]: "
        s/^[A-Z][a-z]{2}[[:space:]]+[0-9]{1,2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}[[:space:]]+\S+[[:space:]]+[^:]+: //
        # ISO формат: "2024-10-01T12:34:56.123+03:00 host prog[PID]: "
        s/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?([+-][0-9:]+|Z)[[:space:]]+\S+[[:space:]]+[^:]+: //
        # Kernel: "[12345.678] "
        s/^\[[[:space:]]*[0-9]+\.[0-9]+\][[:space:]]*//
        # Apache: "[Mon Sep 01 12:34:56 2024] "
        s/^\[[A-Z][a-z]{2}[[:space:]]+[A-Z][a-z]{2}[[:space:]]+[0-9]+[[:space:]]+[0-9:]+[[:space:]]+[0-9]{4}\][[:space:]]*//
        # PID в скобках
        s/\[[0-9]{3,}\]/[PID]/g
        # IP-адреса
        s/[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/IP/g
        # Длинные hex-строки
        s/0x[0-9a-fA-F]{8,}/0xHEX/g
        # Пути с /var/www/SOMETHING/
        s#/var/www/[^/ ]+/#/var/www/SITE/#g
    '
}

# Раскраска строки по опасности (single sed для скорости; # вместо | — в паттернах есть | )
colorize_log_line() {
    # Если цвета отключены — возвращаем как есть
    [[ -z "$C_RED" ]] && { printf '%s\n' "$1"; return; }
    printf '%s\n' "$1" | sed -E \
        -e "s#($LOG_SUPER_DANGER)#${C_BG_RED}${C_WHITE}\1${C_RESET}#Ig" \
        -e "s#($LOG_DANGER)#${C_RED}\1${C_RESET}#Ig" \
        -e "s#($LOG_WARN)#${C_YELLOW}\1${C_RESET}#Ig"
}

# Цвет для счётчика в зависимости от величины
count_color() {
    local n="$1"
    if   (( n >= 50 )); then echo "$C_RED"
    elif (( n >= 20 )); then echo "$C_RED"
    elif (( n >= 10 )); then echo "$C_YELLOW"
    elif (( n >= 3  )); then echo "$C_YELLOW"
    else                     echo "$C_GRAY"
    fi
}

# Главная функция анализа лога — ОДИН проход по данным
# $1 = имя; $2 = команда-источник; $3 = (опц.) фильтр (по умолч. cat)
analyze_log() {
    (( OPT_SKIP_LOGS )) && return 0
    local name="$1" source_cmd="$2" filter_cmd="${3:-cat}"

    # Проверяем доступность источника
    local first_token
    first_token=$(awk '{print $1}' <<< "$source_cmd")

    if [[ "$first_token" == "tail" ]]; then
        # Извлекаем имя файла (предпоследний аргумент tail)
        local file
        file=$(awk '{print $NF}' <<< "$source_cmd")
        [[ -r "$file" ]] || return 0
    elif ! has_cmd "$first_token"; then
        return 0
    fi

    progress "Анализ $name..."

    # ОДИН раз выполняем источник и кэшируем
    local tmp
    tmp=$(mktemp -t "diaglinux.${name//\//_}.XXXXXX") || return 1
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN

    eval "$source_cmd" 2>/dev/null \
        | eval "$filter_cmd" 2>/dev/null \
        | tail -n "$LOG_DEPTH" > "$tmp" || true

    if [[ ! -s "$tmp" ]]; then
        progress_end
        return 0
    fi

    # Фильтруем, нормализуем, группируем — всё за один pipeline
    local grouped
    grouped=$(grep -iE "$LOG_PATTERNS" "$tmp" 2>/dev/null \
        | grep -vE "$LOG_EXCLUDE" 2>/dev/null \
        | strip_log_line \
        | sort | uniq -c | sort -nr | head -n "$LOG_TAIL") || true

    progress_end

    if [[ -z "$grouped" ]]; then
        report "Лог: $name" "OK"
        return 0
    fi

    # Считаем общее число совпадений для статуса
    local total_matches
    total_matches=$(echo "$grouped" | awk '{s+=$1} END{print s+0}')

    # Определяем статус по самым опасным сигнатурам
    local status="WARN"
    if echo "$grouped" | grep -qiE "$LOG_SUPER_DANGER"; then
        status="FAIL"
    elif echo "$grouped" | grep -qiE "$LOG_DANGER"; then
        status="FAIL"
    fi

    local unique_count
    unique_count=$(echo "$grouped" | wc -l)
    report "Лог: $name" "$status" "уникальных паттернов: ${unique_count}, всего: ${total_matches}"

    # Выводим отсортированный список
    echo "$grouped" | while IFS= read -r line; do
        local cnt rest
        cnt=$(awk '{print $1}' <<< "$line")
        rest=$(sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//' <<< "$line")
        local col
        col=$(count_color "$cnt")
        # Обрезаем длинные строки
        if (( ${#rest} > 180 )); then
            rest="${rest:0:177}..."
        fi
        local colored
        colored=$(colorize_log_line "$rest")
        printf '      [%s%4d%s] %s\n' "$col" "$cnt" "$C_RESET" "$colored"
    done
}

# Батч-вызов всех логов
analyze_all_logs() {
    (( OPT_SKIP_LOGS )) && return 0
    section "Анализ логов"

    local log_configs=(
        "syslog|tail -n $LOG_DEPTH /var/log/syslog|grep -vE 'auth failed|no auth attempts'"
        "journalctl|journalctl -n $LOG_DEPTH --no-pager|cat"
        "dmesg|dmesg -T|grep -vE 'Possible SYN flooding'"
        "kern.log|tail -n $LOG_DEPTH /var/log/kern.log|cat"
        "messages|tail -n $LOG_DEPTH /var/log/messages|cat"
        "apache2-error|tail -n $LOG_DEPTH /var/log/apache2/error.log|cat"
        "httpd-error|tail -n $LOG_DEPTH /var/log/httpd/error_log|cat"
        "nginx-error|tail -n $LOG_DEPTH /var/log/nginx/error.log|grep -v '13: Permission denied'"
        "daemon.log|tail -n $((LOG_DEPTH/4)) /var/log/daemon.log|cat"
        "fastpanel|tail -n $((LOG_DEPTH/4)) /var/log/fastpanel2/fast.log|cat"
    )

    local cfg name src flt
    for cfg in "${log_configs[@]}"; do
        IFS='|' read -r name src flt <<< "$cfg"
        analyze_log "$name" "$src" "$flt"
    done

    # PHP-FPM логи — glob-expansion
    local f
    for f in /var/log/php*fpm.log; do
        [[ -r "$f" ]] || continue
        analyze_log "$(basename "$f")" "tail -n $((LOG_DEPTH/4)) $f" "cat"
    done
}

# ============================================================================
# ИТОГОВЫЙ SUMMARY + EXIT CODE
# ============================================================================
print_summary() {
    local elapsed=$(( $(date +%s) - SCRIPT_START_TS ))

    section "ИТОГО"

    local total=$((COUNT_OK + COUNT_WARN + COUNT_FAIL + COUNT_NA))
    printf '\n'
    printf '  %sВсего проверок:%s %d\n' "$C_BOLD" "$C_RESET" "$total"
    printf '  %s✓ OK:%s        %d\n' "$C_GREEN" "$C_RESET" "$COUNT_OK"
    printf '  %s⚠ WARN:%s      %d\n' "$C_YELLOW" "$C_RESET" "$COUNT_WARN"
    printf '  %s✗ FAIL:%s      %d\n' "$C_RED" "$C_RESET" "$COUNT_FAIL"
    printf '  %s— N/A:%s       %d\n' "$C_GRAY" "$C_RESET" "$COUNT_NA"
    printf '  %sВремя:%s       %ds\n' "$C_CYAN" "$C_RESET" "$elapsed"
    printf '\n'

    # Критические проблемы — список
    if (( COUNT_FAIL > 0 )); then
        printf '%sКритические проблемы:%s\n' "$C_RED$C_BOLD" "$C_RESET"
        local name
        for name in "${CHECK_ORDER[@]}"; do
            if [[ "${CHECK_STATUS[$name]}" == "FAIL" ]]; then
                printf '  %s✗%s %s — %s\n' "$C_RED" "$C_RESET" \
                    "$name" "${CHECK_DETAILS[$name]}"
            fi
        done
        printf '\n'
    fi

    if (( COUNT_WARN > 0 )); then
        printf '%sПредупреждения:%s\n' "$C_YELLOW$C_BOLD" "$C_RESET"
        local name
        for name in "${CHECK_ORDER[@]}"; do
            if [[ "${CHECK_STATUS[$name]}" == "WARN" ]]; then
                printf '  %s⚠%s %s — %s\n' "$C_YELLOW" "$C_RESET" \
                    "$name" "${CHECK_DETAILS[$name]}"
            fi
        done
        printf '\n'
    fi
}

print_json() {
    (( OPT_JSON )) || return 0
    printf '\n--- JSON ---\n{\n'
    printf '  "version": "%s",\n' "$SCRIPT_VERSION"
    printf '  "timestamp": %d,\n' "$SCRIPT_START_TS"
    printf '  "summary": { "ok": %d, "warn": %d, "fail": %d, "na": %d },\n' \
        "$COUNT_OK" "$COUNT_WARN" "$COUNT_FAIL" "$COUNT_NA"
    printf '  "checks": [\n'
    local i=0 total=${#CHECK_ORDER[@]}
    for name in "${CHECK_ORDER[@]}"; do
        ((i++))
        local comma=","
        (( i == total )) && comma=""
        # Экранирование кавычек и бэкслешей
        local esc_name esc_details
        esc_name=${name//\\/\\\\}
        esc_name=${esc_name//\"/\\\"}
        esc_details=${CHECK_DETAILS[$name]//\\/\\\\}
        esc_details=${esc_details//\"/\\\"}
        printf '    {"name": "%s", "status": "%s", "details": "%s"}%s\n' \
            "$esc_name" "${CHECK_STATUS[$name]}" "$esc_details" "$comma"
    done
    printf '  ]\n}\n'
}

compute_exit_code() {
    if (( COUNT_FAIL > 0 )); then return 2
    elif (( COUNT_WARN > 0 )); then return 1
    else return 0; fi
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    parse_args "$@"
    setup_colors

    # Шапка
    if ! (( OPT_QUIET )); then
        printf '%s%s%s %s%s%s — диагностика сервера %s\n' \
            "$C_BOLD" "$SCRIPT_NAME" "$C_RESET" \
            "$C_CYAN" "v$SCRIPT_VERSION" "$C_RESET" \
            "$(hostname -s 2>/dev/null || echo '?')"
        is_root || warn_msg "Запуск без root — часть проверок будет пропущена (SMART, atop, systemd details)"
    fi

    # === Секция 1: окружение ===
    section "Окружение"
    detect_os
    detect_ip
    detect_panel

    # === Секция 2: системные ресурсы ===
    section "Ресурсы"
    check_load
    check_ram_swap
    check_disk_space
    check_inodes
    check_readonly_mounts

    # === Секция 3: диски и RAID ===
    section "Диски и RAID"
    check_mdstat
    check_raid_controllers
    check_smart

    # === Секция 4: сервисы ===
    section "Сервисы"
    check_systemd_failed
    check_nginx
    check_apache
    check_beancounters

    # === Секция 5: логи ===
    check_large_logs
    check_lastlogs
    analyze_all_logs

    # === Секция 6: TOP ===
    show_top_processes
    show_top_users
    show_disk_load

    # === Итого ===
    print_summary
    print_json

    compute_exit_code
}

main "$@"