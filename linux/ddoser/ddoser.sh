#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  DDoSer 2.0 — Анализатор access-логов для защиты от DDoS               ║
# ║  Панели: ISPManager · FastPanel · Hestia                                ║
# ║  Автор: Vladislav Pavlovich · TG @sysadminctl                          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -o pipefail

readonly VERSION="2.0.2"
readonly SCRIPT_NAME="DDoSer"

# Подавление ошибок — скрипт должен работать даже при отсутствии утилит
_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout "$@"
    else
        # Без timeout — запускаем напрямую (может зависнуть, но не упадёт)
        shift  # убираем аргумент секунд
        "$@"
    fi
}

# Безопасная арифметика (пустая строка → 0)
_num() { echo "${1:-0}"; }

# ═══════════════════════════════════════════════════════════════════════════
#  CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════
readonly REPORT_WIDTH=118
readonly CHART_WIDTH=72
readonly SITE_LINE_W=116

readonly DEFAULT_TOP_N=50
readonly DEFAULT_URI_N=10
readonly DEFAULT_PERIOD="24h"

readonly GEOIP_DIR="/usr/share/GeoIP"
readonly GEOIP_URL_V4="https://mailfud.org/geoip-legacy/GeoIP.dat.gz"
readonly GEOIP_URL_V6="https://mailfud.org/geoip-legacy/GeoIPv6.dat.gz"
readonly GEOIP_MAX_AGE=604800   # 7 дней

# Классификация ботов
readonly BOTS_GREEN="googlebot|google-inspectiontool|yandexbot|yandexaccessibilitybot|yandexmobilebot"
readonly BOTS_YELLOW="bingbot|msnbot|semrushbot|ahrefsbot|applebot|meta-externalagent|serpstatbot|duckduckbot"
# Всё остальное — красные (нежелательные)

# Безопасные страны (не подсвечиваются красным)
readonly SAFE_COUNTRIES="RU|DE|FR|GB|NL|US|CA|UA|BY|KZ|PL|CZ|FI|SE|NO|DK|AT|CH|IT|ES|PT|IE|BE|LT|LV|EE|BG|RO|HU|SK|SI|HR|JP|KR|AU|NZ|SG|IL"

# Фильтрация мусорных HTTP-кодов
readonly SKIP_CODES="444|400|403|408|429|499"

# ═══════════════════════════════════════════════════════════════════════════
#  COLORS & FORMATTING
# ═══════════════════════════════════════════════════════════════════════════
setup_colors() {
    if [[ "$SCRIPT_MODE" == "true" ]] || [[ ! -t 1 ]]; then
        R="" G="" Y="" C="" B="" M="" W="" NC="" BOLD="" DIM=""
    else
        R=$'\033[31m'   G=$'\033[32m'   Y=$'\033[33m'
        C=$'\033[36m'   B=$'\033[34m'   M=$'\033[35m'
        W=$'\033[97m'   NC=$'\033[0m'   BOLD=$'\033[1m'
        DIM=$'\033[2m'
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  UTILITY FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════
die()  { echo "${R}Ошибка: $1${NC}" >&2; exit 1; }
info() { echo "${C}$1${NC}" >&2; }
warn() { echo "${Y}$1${NC}" >&2; }

fmt_num() {
    # Portable thousand separator using awk
    echo "$1" | awk '{
        s = sprintf("%d", $1)
        out = ""
        n = length(s)
        for (i=1; i<=n; i++) {
            if (i > 1 && (n-i+1) % 3 == 0) out = out " "
            out = out substr(s,i,1)
        }
        print out
    }'
}

fmt_bytes() {
    local bytes="${1:-0}"
    if   (( bytes >= 1073741824 )); then awk "BEGIN{printf \"%.1fG\", $bytes/1073741824}"
    elif (( bytes >= 1048576 ));    then awk "BEGIN{printf \"%.1fM\", $bytes/1048576}"
    elif (( bytes >= 1024 ));       then awk "BEGIN{printf \"%.1fK\", $bytes/1024}"
    else echo "${bytes}B"
    fi
}

print_header() {
    local text="$1"
    local line
    line=$(printf '═%.0s' $(seq 1 $REPORT_WIDTH))
    echo ""
    echo "  ${BOLD}${W}${line}${NC}"
    echo "  ${BOLD}${W}  ${text}${NC}"
    echo "  ${BOLD}${W}${line}${NC}"
}

print_separator() {
    printf '  '
    printf '─%.0s' $(seq 1 $SITE_LINE_W)
    echo ""
}

# Спиннер
_spin_pid=0
spin_start() {
    local msg="$1"
    if [[ "$OPT_YES" == "true" ]] || [[ ! -t 1 ]]; then
        info "$msg"
        return
    fi
    (
        local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        local i=0
        while true; do
            printf "\r  ${C}${chars:$i:1} ${msg}${NC}  " >&2
            i=$(( (i+1) % ${#chars} ))
            sleep 0.1
        done
    ) &
    _spin_pid=$!
    disown $_spin_pid 2>/dev/null
}
spin_stop() {
    if [[ $_spin_pid -ne 0 ]]; then
        kill $_spin_pid 2>/dev/null
        wait $_spin_pid 2>/dev/null
        _spin_pid=0
        printf "\r\033[K" >&2
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  HELP & VERSION
# ═══════════════════════════════════════════════════════════════════════════
show_help() {
    cat <<EOF
${BOLD}${W}DDoSer ${VERSION}${NC} — Анализатор access-логов для защиты от DDoS
${DIM}Панели: ISPManager · FastPanel · Hestia${NC}

${BOLD}Использование:${NC}
  bash <(curl -s URL)
  bash ddoser.sh [опции]

${BOLD}Режимы:${NC}
  ${Y}(по умолчанию)${NC}  Интерактивный: цвета, system info, промпты
  ${Y}-s, --script${NC}    Без цветов и промптов (для записи в файл)

${BOLD}Опции:${NC}
  ${Y}-t, --time P${NC}    Период: 1h, 6h, 24h, 3 (дня)     [по умолчанию: 24h]
  ${Y}-n, --top N${NC}     Кол-во строк в топе IP/ботов      [по умолчанию: 50]
  ${Y}-u, --uris N${NC}    Кол-во URI на сайт                 [по умолчанию: 10]
  ${Y}-f, --fast${NC}      Пропустить per-site URIs, DNS-проверки
  ${Y}-q, --quiet${NC}     Пропустить рекомендации
  ${Y}-y, --yes${NC}       Автоматически подтверждать все промпты
  ${Y}-p, --priority${NC}  Низкий приоритет (nice/ionice)
  ${Y}-D, --debug${NC}     Включить set -x
  ${Y}-V, --version${NC}   Версия
  ${Y}-h, --help${NC}      Справка

${BOLD}Примеры:${NC}
  bash ddoser.sh                     # Интерактивный запуск
  bash ddoser.sh -fqy                # Быстрый запуск без промптов
  bash ddoser.sh -t 1h -n 20        # Последний час, топ-20
  bash ddoser.sh -s > report.txt     # Сохранить отчёт в файл

${BOLD}Автор:${NC} Vladislav Pavlovich · TG @sysadminctl
EOF
    exit 0
}

show_version() {
    echo "DDoSer ${VERSION}"
    exit 0
}

# ═══════════════════════════════════════════════════════════════════════════
#  ARGUMENT PARSING
# ═══════════════════════════════════════════════════════════════════════════
OPT_PERIOD="24h"
OPT_TOP_N=$DEFAULT_TOP_N
OPT_URI_N=$DEFAULT_URI_N
OPT_FAST=false
OPT_QUIET=false
OPT_YES=false
OPT_PRIORITY=false
OPT_DEBUG=false
SCRIPT_MODE=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--time)     OPT_PERIOD="$2"; shift 2 ;;
            -n|--top)      OPT_TOP_N="$2";  shift 2 ;;
            -u|--uris)     OPT_URI_N="$2";  shift 2 ;;
            -f|--fast)     OPT_FAST=true;    shift ;;
            -q|--quiet)    OPT_QUIET=true;   shift ;;
            -y|--yes)      OPT_YES=true;     shift ;;
            -p|--priority) OPT_PRIORITY=true; shift ;;
            -s|--script)   SCRIPT_MODE=true; OPT_YES=true; shift ;;
            -D|--debug)    OPT_DEBUG=true;   shift ;;
            -V|--version)  show_version ;;
            -h|--help)     show_help ;;
            -*)
                # Комбо-флаги: -fqy
                local flags="${1#-}"
                shift
                local i
                for (( i=0; i<${#flags}; i++ )); do
                    case "${flags:$i:1}" in
                        f) OPT_FAST=true ;;
                        q) OPT_QUIET=true ;;
                        y) OPT_YES=true ;;
                        p) OPT_PRIORITY=true ;;
                        s) SCRIPT_MODE=true; OPT_YES=true ;;
                        D) OPT_DEBUG=true ;;
                        V) show_version ;;
                        h) show_help ;;
                        *) die "Неизвестный флаг: -${flags:$i:1}. Используйте -h для справки." ;;
                    esac
                done
                ;;
            *)  die "Неизвестный аргумент: $1. Используйте -h для справки." ;;
        esac
    done
}

parse_args "$@"
[[ "$OPT_DEBUG" == "true" ]] && set -x
setup_colors

if [[ "$OPT_PRIORITY" == "true" ]]; then
    renice -n 19 $$ >/dev/null 2>&1
    ionice -c3 -p $$ >/dev/null 2>&1
fi

# Рассчёт cutoff timestamp
calc_cutoff() {
    local period="$OPT_PERIOD"
    local now
    now=$(date +%s)
    local seconds=86400  # default 24h

    if [[ "$period" =~ ^([0-9]+)h$ ]]; then
        seconds=$(( ${BASH_REMATCH[1]} * 3600 ))
    elif [[ "$period" =~ ^([0-9]+)d?$ ]]; then
        seconds=$(( ${BASH_REMATCH[1]} * 86400 ))
    fi

    CUTOFF_TS=$(( now - seconds ))
    PERIOD_HOURS=$(( seconds / 3600 ))
    PERIOD_LABEL="${PERIOD_HOURS}ч"
    [[ $PERIOD_HOURS -ge 24 ]] && PERIOD_LABEL="$(( PERIOD_HOURS / 24 ))д"
}
calc_cutoff

# ═══════════════════════════════════════════════════════════════════════════
#  CLEANUP
# ═══════════════════════════════════════════════════════════════════════════
TMPDIR_WORK=""
cleanup() {
    spin_stop
    [[ -n "$TMPDIR_WORK" ]] && rm -rf "$TMPDIR_WORK"
}
trap cleanup EXIT INT TERM

TMPDIR_WORK=$(mktemp -d /tmp/ddoser.XXXXXX)

# ═══════════════════════════════════════════════════════════════════════════
#  SYSTEM INFO
# ═══════════════════════════════════════════════════════════════════════════
collect_system_info() {
    OS_NAME=$(grep -E "^NAME=" /etc/*release* 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d '"')
    OS_VERSION=$(grep -E "^VERSION_ID=" /etc/*release* 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d '"')
    [[ -z "$OS_NAME" ]] && OS_NAME="Unknown"
    [[ -z "$OS_VERSION" ]] && OS_VERSION=""
    # Сокращаем: "Debian GNU/Linux" → "Debian", "CentOS Linux" → "CentOS"
    OS_NAME=$(echo "$OS_NAME" | sed 's/ GNU\/Linux//; s/ Linux//')

    PHP_VERSION=$(php -v 2>/dev/null | head -1 | awk '{print $2}' | cut -d. -f1,2)
    [[ -z "$PHP_VERSION" ]] && PHP_VERSION="-"

    LOAD_AVG=$(cat /proc/loadavg 2>/dev/null | awk '{print $1}')
    [[ -z "$LOAD_AVG" ]] && LOAD_AVG="-"
    RAM_USED=$(free -m 2>/dev/null | awk '/Mem:/{printf "%.1f/%.1fG", $3/1024, $2/1024}')
    [[ -z "$RAM_USED" ]] && RAM_USED="-"

    # Uptime: сокращаем до "12w 6d 12h"
    UPTIME_STR=$(uptime -p 2>/dev/null | sed 's/up //')
    if [[ -n "$UPTIME_STR" ]]; then
        UPTIME_STR=$(echo "$UPTIME_STR" | sed \
            -e 's/ years\?/y/g' \
            -e 's/ months\?/mo/g' \
            -e 's/ weeks\?/w/g' \
            -e 's/ days\?/d/g' \
            -e 's/ hours\?/h/g' \
            -e 's/ minutes\?/m/g' \
            -e 's/,//g' \
            -e 's/  */ /g')
    else
        UPTIME_STR=$(uptime 2>/dev/null | sed 's/.*up //' | sed 's/,.*//')
    fi
    [[ -z "$UPTIME_STR" ]] && UPTIME_STR="-"

    SERVER_TZ=$(date +%Z)
    SERVER_TIME=$(date '+%H:%M %Z')

    # Диски
    DISK_INFO=$(df -h / 2>/dev/null | awk 'NR==2{printf "%s/%s (%s)", $3, $2, $5}')
    [[ -z "$DISK_INFO" ]] && DISK_INFO="-"
    INODE_INFO=$(df -i / 2>/dev/null | awk 'NR==2{print $5}')
    [[ -z "$INODE_INFO" ]] && INODE_INFO="-"

    # Сервисы
    SVC_NGINX="—"; SVC_APACHE="—"; SVC_MYSQL="—"
    systemctl is-active --quiet nginx 2>/dev/null   && SVC_NGINX="${G}✓${NC}" || SVC_NGINX="${R}✗${NC}"
    systemctl is-active --quiet apache2 2>/dev/null  && SVC_APACHE="${G}✓${NC}" || {
        systemctl is-active --quiet httpd 2>/dev/null && SVC_APACHE="${G}✓${NC}" || SVC_APACHE="${DIM}—${NC}"
    }
    for svc in mysql mariadb mysqld; do
        systemctl is-active --quiet "$svc" 2>/dev/null && { SVC_MYSQL="${G}✓${NC}"; break; }
    done

    # Connections
    CONN_COUNT=$(ss -ntu 2>/dev/null | tail -n+2 | wc -l)

    # iptables policy
    IPT_POLICY=$(iptables -L INPUT 2>/dev/null | head -1 | awk '{print $NF}' | tr -d '()')
    [[ -z "$IPT_POLICY" ]] && IPT_POLICY="N/A"

    # GeoIP дата
    GEOIP_DATE="-"
    [[ -f "${GEOIP_DIR}/GeoIP.dat" ]] && GEOIP_DATE=$(date -r "${GEOIP_DIR}/GeoIP.dat" '+%Y-%m-%d' 2>/dev/null)

    # Панель: дата обновления
    PANEL_UPDATED=""
    case "$CONTROL_PANEL" in
        ispmanager)
            local bin="/usr/local/mgr5/sbin/ihttpd"
            if [[ -f "$bin" ]]; then
                local age=$(( ($(date +%s) - $(stat -c %Y "$bin" 2>/dev/null || echo 0)) / 86400 ))
                PANEL_UPDATED="${age}д назад"
                (( age > 90 )) && PANEL_UPDATED="${R}${age}д назад${NC}"
            fi
            # Версия
            local isp_ver=""
            if [[ -f "/usr/local/mgr5/sbin/licctl" ]]; then
                isp_ver=$(/usr/local/mgr5/sbin/licctl info ispmgr 2>/dev/null | grep -i "version" | head -1 | awk '{print $NF}' | cut -d. -f1)
            fi
            [[ -n "$isp_ver" ]] && PANEL_DISPLAY="ISPManager $isp_ver" || PANEL_DISPLAY="ISPManager"
            ;;
        fastpanel)
            local bin="/opt/fastpanel2/bin/fastpanel2"
            [[ ! -f "$bin" ]] && bin=$(find /opt/fastpanel* -name "fastpanel*" -type f 2>/dev/null | head -1)
            if [[ -n "$bin" ]] && [[ -f "$bin" ]]; then
                local age=$(( ($(date +%s) - $(stat -c %Y "$bin" 2>/dev/null || echo 0)) / 86400 ))
                PANEL_UPDATED="${age}д назад"
                (( age > 90 )) && PANEL_UPDATED="${R}${age}д назад${NC}"
            fi
            PANEL_DISPLAY="FastPanel"
            ;;
        hestia)
            local bin="/usr/local/hestia/bin/v-list-sys-info"
            if [[ -f "$bin" ]]; then
                local age=$(( ($(date +%s) - $(stat -c %Y "$bin" 2>/dev/null || echo 0)) / 86400 ))
                PANEL_UPDATED="${age}д назад"
                (( age > 90 )) && PANEL_UPDATED="${R}${age}д назад${NC}"
            fi
            PANEL_DISPLAY="Hestia"
            local hestia_ver=$(/usr/local/hestia/bin/v-list-sys-info 2>/dev/null | awk 'NR==3{print $1}')
            [[ -n "$hestia_ver" ]] && PANEL_DISPLAY="Hestia ${hestia_ver}"
            ;;
        *)
            PANEL_DISPLAY="не определена"
            ;;
    esac
    [[ -n "$PANEL_UPDATED" ]] && PANEL_DISPLAY="${PANEL_DISPLAY} · обновлена ${PANEL_UPDATED}"
}

render_system_info() {
    local w=$(( REPORT_WIDTH - 4 ))
    local line
    line=$(printf '─%.0s' $(seq 1 $w))
    echo ""
    echo "  ${BOLD}${W}┌─${line}─┐${NC}"
    echo "  ${BOLD}${W}│${NC} Система:  ${OS_NAME} ${OS_VERSION} · PHP ${PHP_VERSION} · LA ${LOAD_AVG} · RAM ${RAM_USED} · Up ${UPTIME_STR} · ${SERVER_TIME}"
    echo "  ${BOLD}${W}│${NC}"
    echo "  ${BOLD}${W}│${NC} Панель:   ${PANEL_DISPLAY}"
    echo "  ${BOLD}${W}│${NC}"
    echo "  ${BOLD}${W}│${NC} Диски:    ${DISK_INFO} · Inodes ${INODE_INFO}"
    echo "  ${BOLD}${W}│${NC}"
    echo "  ${BOLD}${W}│${NC} Сервисы:  nginx ${SVC_NGINX} · apache ${SVC_APACHE} · mysql ${SVC_MYSQL}"
    echo "  ${BOLD}${W}│${NC}"
    echo "  ${BOLD}${W}│${NC} Сеть:     INPUT ${IPT_POLICY} · Соединений: ${CONN_COUNT} · GeoIP ${GEOIP_DATE}"
    echo "  ${BOLD}${W}└─${line}─┘${NC}"
}

# ═══════════════════════════════════════════════════════════════════════════
#  PANEL DETECTION & LOG PATHS
# ═══════════════════════════════════════════════════════════════════════════
CONTROL_PANEL="none"
LOG_FILES=()
SITE_COUNT=0
SERVER_IP=""

detect_panel() {
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

    # ISPManager
    if [[ -d "/usr/local/mgr5" ]] || systemctl is-active --quiet ihttpd.service 2>/dev/null; then
        CONTROL_PANEL="ispmanager"
        return
    fi

    # FastPanel
    if systemctl is-active --quiet fastpanel2.service 2>/dev/null || [[ -d "/usr/local/fastpanel" ]]; then
        CONTROL_PANEL="fastpanel"
        return
    fi

    # Hestia
    if [[ -d "/usr/local/hestia" ]] || systemctl is-active --quiet hestia.service 2>/dev/null; then
        CONTROL_PANEL="hestia"
        return
    fi

    CONTROL_PANEL="none"
}

collect_log_files() {
    local -a patterns=()

    case "$CONTROL_PANEL" in
        ispmanager)
            patterns=( /var/www/httpd-logs/*.access.log )
            ;;
        fastpanel)
            # Предпочитаем backend-логи
            local -a backend=( /var/www/*/data/logs/*-backend.access.log )
            if [[ -e "${backend[0]}" ]]; then
                patterns=( "${backend[@]}" )
                # Добавляем frontend для сайтов без backend
                for dir in /var/www/*/data/logs/; do
                    [[ -d "$dir" ]] || continue
                    local site_name=$(basename "$(dirname "$(dirname "$dir")")")
                    local has_backend=false
                    for f in "${backend[@]}"; do
                        [[ "$f" == *"$site_name"* ]] && { has_backend=true; break; }
                    done
                    if [[ "$has_backend" == "false" ]]; then
                        for f in "$dir"*-frontend.access.log; do
                            [[ -f "$f" ]] && patterns+=( "$f" )
                        done
                    fi
                done
            else
                patterns=( /var/www/*/data/logs/*access.log )
            fi
            ;;
        hestia)
            patterns=( /var/log/apache2/domains/*.log )
            # Если нет apache-логов, используем nginx
            if ! ls ${patterns[0]} >/dev/null 2>&1; then
                patterns=( /var/log/nginx/domains/*.log )
            fi
            ;;
        none)
            if [[ -f "/var/log/nginx/access.log" ]]; then
                patterns=( /var/log/nginx/access.log )
            elif [[ -f "/var/log/apache2/access.log" ]]; then
                patterns=( /var/log/apache2/access.log )
            fi
            ;;
    esac

    # Собираем файлы
    local f
    for f in "${patterns[@]}"; do
        [[ -f "$f" ]] && [[ -s "$f" ]] && LOG_FILES+=( "$f" )
    done

    # Ротированные логи (.log.1) — подключаем всегда для полноты
    for f in "${patterns[@]}"; do
        local rotated="${f}.1"
        [[ -f "$rotated" ]] && [[ -s "$rotated" ]] && LOG_FILES+=( "$rotated" )
    done

    SITE_COUNT=${#LOG_FILES[@]}
}

# ═══════════════════════════════════════════════════════════════════════════
#  DEPENDENCIES
# ═══════════════════════════════════════════════════════════════════════════
install_pkg() {
    local pkg="$1"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y "$pkg" >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$pkg" >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$pkg" >/dev/null 2>&1
    fi
}

ensure_dependencies() {
    # geoiplookup
    if ! command -v geoiplookup >/dev/null 2>&1; then
        info "Устанавливаю geoiplookup..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq >/dev/null 2>&1
            install_pkg "geoip-bin"
        else
            install_pkg "GeoIP"
        fi
    fi

    # whois (fallback)
    if ! command -v whois >/dev/null 2>&1; then
        install_pkg "whois" 2>/dev/null
    fi

    # dig (для DNS-проверок)
    if [[ "$OPT_FAST" != "true" ]] && ! command -v dig >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            install_pkg "dnsutils"
        else
            install_pkg "bind-utils"
        fi
    fi

    # Обновление GeoIP баз
    update_geoip
}

update_geoip() {
    local marker="/tmp/.ddoser-geoip-update"
    # Не обновляем чаще раза в день
    if [[ -f "$marker" ]]; then
        local marker_age=$(( $(date +%s) - $(stat -c %Y "$marker" 2>/dev/null || echo 0) ))
        (( marker_age < 86400 )) && return
    fi

    local need_update=false
    if [[ ! -f "${GEOIP_DIR}/GeoIP.dat" ]]; then
        need_update=true
    else
        local file_age=$(( $(date +%s) - $(stat -c %Y "${GEOIP_DIR}/GeoIP.dat" 2>/dev/null || echo 0) ))
        (( file_age > GEOIP_MAX_AGE )) && need_update=true
    fi

    if [[ "$need_update" == "true" ]] && command -v curl >/dev/null 2>&1; then
        spin_start "Обновление GeoIP баз..."
        mkdir -p "$GEOIP_DIR" 2>/dev/null
        curl -sL "$GEOIP_URL_V4" 2>/dev/null | gunzip > "${GEOIP_DIR}/GeoIP.dat" 2>/dev/null
        curl -sL "$GEOIP_URL_V6" 2>/dev/null | gunzip > "${GEOIP_DIR}/GeoIPv6.dat" 2>/dev/null
        spin_stop
        # Если скачать не удалось, пробуем apt
        if [[ ! -s "${GEOIP_DIR}/GeoIP.dat" ]]; then
            install_pkg "geoip-database" 2>/dev/null
        fi
    fi
    touch "$marker" 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════════════════
#  GeoIP FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════
declare -A GEO_CACHE

geo_lookup() {
    local ip="$1"
    [[ -n "${GEO_CACHE[$ip]+x}" ]] && { echo "${GEO_CACHE[$ip]}"; return; }

    local result=""
    if command -v geoiplookup >/dev/null 2>&1; then
        if [[ "$ip" == *:* ]]; then
            result=$(geoiplookup6 "$ip" 2>/dev/null | head -1 | sed 's/.*: //')
        else
            result=$(geoiplookup "$ip" 2>/dev/null | head -1 | sed 's/.*: //')
        fi
        [[ "$result" == *"not found"* ]] && result=""
        [[ "$result" == *"IP Address"* ]] && result=""
    fi

    # whois fallback
    if [[ -z "$result" ]] && command -v whois >/dev/null 2>&1; then
        local country
        country=$(_timeout 3 whois "$ip" 2>/dev/null | grep -i "^country:" | head -1 | awk '{print $2}' | tr -d '\r')
        [[ -n "$country" ]] && result="${country}, Unknown"
    fi

    [[ -z "$result" ]] && result="??, Unknown"
    GEO_CACHE["$ip"]="$result"
    echo "$result"
}

geo_batch_resolve() {
    # Batch-резолв всех IP из файла
    local ip_file="$1"
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        geo_lookup "$ip" >/dev/null
    done < "$ip_file"
}

geo_country_code() {
    local geo_str="$1"
    echo "$geo_str" | cut -d',' -f1 | tr -d ' '
}

geo_country_name() {
    local geo_str="$1"
    echo "$geo_str" | cut -d',' -f2- | sed 's/^ //'
}

is_safe_country() {
    local code="$1"
    echo "$code" | grep -qE "^(${SAFE_COUNTRIES})$"
}

# ═══════════════════════════════════════════════════════════════════════════
#  BOT CLASSIFICATION
# ═══════════════════════════════════════════════════════════════════════════
bot_class() {
    local ua_lower
    ua_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')

    # Green — поисковики
    if echo "$ua_lower" | grep -qE "(${BOTS_GREEN})"; then
        echo "green"
        return
    fi

    # Yellow — коммерческие
    if echo "$ua_lower" | grep -qE "(${BOTS_YELLOW})"; then
        echo "yellow"
        return
    fi

    # Red — нежелательные
    echo "red"
}

extract_bot_name() {
    local ua="$1"
    local name

    # Стандартные боты: "compatible; BotName/1.0"
    name=$(echo "$ua" | grep -oP 'compatible;\s*\K[^/;]+' | head -1)
    [[ -n "$name" ]] && { echo "$name"; return; }

    # Формат "BotName/1.0"
    name=$(echo "$ua" | grep -oP '\b[A-Z][a-zA-Z]*[Bb]ot\b' | head -1)
    [[ -n "$name" ]] && { echo "$name"; return; }

    name=$(echo "$ua" | grep -oP '\b[a-zA-Z]+[Ss]pider\b' | head -1)
    [[ -n "$name" ]] && { echo "$name"; return; }

    name=$(echo "$ua" | grep -oP '\b[a-zA-Z]+[Cc]rawler\b' | head -1)
    [[ -n "$name" ]] && { echo "$name"; return; }

    # Известные имена
    local ua_lower
    ua_lower=$(echo "$ua" | tr '[:upper:]' '[:lower:]')
    for bot in curl wget python-requests go-http-client java axios scrapy l9explore; do
        if echo "$ua_lower" | grep -q "$bot"; then
            echo "$bot"
            return
        fi
    done

    echo ""
}

# Определение типа клиента (браузер/бот/proxy)
classify_client() {
    local main_ua="$1"
    local ua_count="$2"

    # Пустой UA
    [[ -z "$main_ua" || "$main_ua" == "-" ]] && { echo "empty"; return; }

    # Бот?
    local bot_name
    bot_name=$(extract_bot_name "$main_ua")
    if [[ -n "$bot_name" ]]; then
        if (( ua_count > 1 )); then
            echo "${bot_name} (${ua_count} UA)"
        else
            echo "${bot_name}"
        fi
        return
    fi

    # WordPress (не бот, но специфический клиент)
    if echo "$main_ua" | grep -qi "wordpress"; then
        if (( ua_count > 1 )); then
            echo "WordPress (${ua_count} UA)"
        else
            echo "WordPress"
        fi
        return
    fi

    # Proxy (100+ разных UA)
    if (( ua_count >= 100 )); then
        echo "proxy (${ua_count} UA)"
        return
    fi

    # Браузер
    local browser=""
    local ver=""
    if echo "$main_ua" | grep -q "Chrome/"; then
        ver=$(echo "$main_ua" | grep -oP 'Chrome/\K[0-9]+')
        browser="Chrome ${ver}"
    elif echo "$main_ua" | grep -q "Firefox/"; then
        ver=$(echo "$main_ua" | grep -oP 'Firefox/\K[0-9]+')
        browser="Firefox ${ver}"
    elif echo "$main_ua" | grep -q "Safari/" && echo "$main_ua" | grep -q "Version/"; then
        ver=$(echo "$main_ua" | grep -oP 'Version/\K[0-9]+')
        browser="Safari ${ver}"
    elif echo "$main_ua" | grep -q "Edg/"; then
        ver=$(echo "$main_ua" | grep -oP 'Edg/\K[0-9]+')
        browser="Edge ${ver}"
    elif echo "$main_ua" | grep -q "curl"; then
        browser="curl"
    else
        browser="Mozilla"
    fi

    # Мобильный?
    if echo "$main_ua" | grep -qi "mobile\|android\|iphone"; then
        browser="${browser} Mobile"
    fi

    if (( ua_count > 1 )); then
        echo "${browser} (${ua_count} UA)"
    else
        echo "${browser}"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  DNS CHECKS (per-site)
# ═══════════════════════════════════════════════════════════════════════════
declare -A DNS_CACHE

dns_check_site() {
    local domain="$1"
    # Пропускаем невалидные домены
    [[ -z "$domain" || "$domain" == "-" || "$domain" == "unknown" ]] && { echo ""; return; }
    [[ "$domain" != *.* ]] && { echo ""; return; }
    [[ -n "${DNS_CACHE[$domain]+x}" ]] && { echo "${DNS_CACHE[$domain]}"; return; }

    if ! command -v dig >/dev/null 2>&1; then
        DNS_CACHE["$domain"]="?"
        echo "?"
        return
    fi

    local a_record ns_provider tag=""

    # A-запись
    a_record=$(_timeout 2 dig +short "$domain" A 2>/dev/null | head -1)

    if [[ -z "$a_record" ]]; then
        tag="→???"
    elif [[ "$a_record" == "$SERVER_IP" ]]; then
        tag="→SRV"
    else
        # Проверяем CDN: сначала по IP (Cloudflare, etc.), потом по CNAME
        local is_cdn=false

        # Cloudflare IP ranges: 104.16-23.x.x, 172.64-71.x.x, 162.158-159.x.x,
        # 141.101.x.x, 108.162.x.x, 173.245.x.x, 188.114.x.x, 190.93.x.x, 131.0.72.x
        if echo "$a_record" | grep -qE '^(104\.(1[6-9]|2[0-3])|172\.(6[4-9]|7[01])|162\.15[89]|141\.101|108\.162|173\.245|188\.114|190\.93|131\.0\.7[2-5]|198\.41\.1[2-9][0-9]|103\.(21\.24|22\.20|31\.[4-7]))\.'; then
            is_cdn=true
            ns_provider="Cloudflare"
        fi

        # DDos-Guard, Akamai, Fastly — по CNAME
        if [[ "$is_cdn" == "false" ]]; then
            local cname
            cname=$(_timeout 2 dig +short "$domain" CNAME 2>/dev/null | head -1)
            if echo "$cname" | grep -qi "cloudflare\|akamai\|fastly\|cdn\|ddos-guard\|cloudfront\|sucuri\|edgekey\|edgesuite"; then
                is_cdn=true
            fi
        fi

        if [[ "$is_cdn" == "true" ]]; then
            tag="→CDN"
        else
            tag="→EXT"
        fi
    fi

    # NS-провайдер
    ns_provider=""
    local ns
    ns=$(_timeout 2 dig +short "$domain" NS 2>/dev/null | head -1)
    if [[ -z "$ns" ]]; then
        # Пробуем родительский домен
        local parent
        parent=$(echo "$domain" | awk -F. '{if(NF>2) {for(i=2;i<=NF;i++) printf "%s%s",$i,(i<NF?".":"")} else print $0}')
        ns=$(_timeout 2 dig +short "$parent" NS 2>/dev/null | head -1)
    fi

    if [[ -z "$ns_provider" && -n "$ns" ]]; then
        # Определяем провайдера по NS
        local ns_lower
        ns_lower=$(echo "$ns" | tr '[:upper:]' '[:lower:]')
        if   echo "$ns_lower" | grep -q "cloudflare"; then ns_provider="Cloudflare"
        elif echo "$ns_lower" | grep -q "namecheap\|registrar-servers"; then ns_provider="Namecheap"
        elif echo "$ns_lower" | grep -q "hetzner"; then ns_provider="Hetzner"
        elif echo "$ns_lower" | grep -q "digitalocean"; then ns_provider="DigitalOcean"
        elif echo "$ns_lower" | grep -q "godaddy\|domaincontrol"; then ns_provider="GoDaddy"
        elif echo "$ns_lower" | grep -q "reg.ru\|regru"; then ns_provider="Reg.ru"
        elif echo "$ns_lower" | grep -q "yandex"; then ns_provider="Yandex"
        elif echo "$ns_lower" | grep -q "google"; then ns_provider="Google"
        elif echo "$ns_lower" | grep -q "aws\|amazon"; then ns_provider="AWS"
        else ns_provider=$(echo "$ns" | sed 's/\.$//' | awk -F. '{print $(NF-1)"."$NF}')
        fi
    fi

    local result="${ns_provider} ${tag}"
    DNS_CACHE["$domain"]="$result"
    echo "$result"
}

# ═══════════════════════════════════════════════════════════════════════════
#  MAIN DATA COLLECTION (single awk pass)
# ═══════════════════════════════════════════════════════════════════════════
collect_data() {
    spin_start "Парсинг ${#LOG_FILES[@]} лог-файлов (${PERIOD_LABEL})..."

    # Определяем, нужно ли фильтровать по дате в awk
    # Передаём cutoff timestamp в awk
    local cutoff_ts="$CUTOFF_TS"

    # Генерируем cutoff date string для сравнения (portable, не нужен mktime)
    local cutoff_date
    cutoff_date=$(date -d "@${cutoff_ts}" '+%d/%b/%Y:%H:%M:%S' 2>/dev/null || date -r "$cutoff_ts" '+%d/%b/%Y:%H:%M:%S' 2>/dev/null || echo "")

    awk -v cutoff_str="$cutoff_date" \
        -v skip_codes="$SKIP_CODES" \
        -v fast="$OPT_FAST" \
    '
    BEGIN {
        # Для сравнения дат строкой — конвертируем месяц в число
        split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", months)
        for (i=1; i<=12; i++) mon_num[months[i]] = sprintf("%02d", i)
    }

    # Конвертирует "04/Apr/2026:11:20:33" в "20260404112033" для сравнения
    function ts_to_cmp(s,    p,d,m,y,rest) {
        p = index(s, "[")
        if (p) s = substr(s, p+1)
        p = index(s, "]")
        if (p) s = substr(s, 1, p-1)
        # s = "04/Apr/2026:11:20:33 +0000"
        split(s, _t, "/")
        d = _t[1]
        m = _t[2]
        rest = _t[3]
        split(rest, _t2, ":")
        y = _t2[1]
        if (!(m in mon_num)) return ""
        return y mon_num[m] sprintf("%02d", d+0) _t2[2] _t2[3] _t2[4]
    }

    {
        # Находим позицию timestamp
        ts_str = ""
        for (i=1; i<=NF; i++) {
            if ($i ~ /^\[/) {
                ts_str = $i
                if (i+1 <= NF && $(i+1) ~ /\+[0-9]/) ts_str = ts_str " " $(i+1)
                break
            }
        }

        # Фильтрация по дате (строковое сравнение)
        if (cutoff_str != "" && ts_str != "") {
            ts_cmp = ts_to_cmp(ts_str)
            cutoff_cmp = ts_to_cmp("[" cutoff_str "]")
            if (ts_cmp != "" && cutoff_cmp != "" && ts_cmp < cutoff_cmp) next
        }

        # IP - первое поле
        ip = $1
        if (ip !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && ip !~ /:/) next

        # Парсинг через split по кавычкам (наиболее надёжный для combined формата)
        # Формат: IP - - [ts] "METHOD URI HTTP/x.x" STATUS BYTES "referer" "UA"
        n = split($0, parts, "\"")
        # parts[2] = "GET /uri HTTP/1.1"
        # parts[4] = referer
        # parts[6] = User-Agent
        request = (n >= 2) ? parts[2] : ""
        ua = (n >= 6) ? parts[6] : "-"
        if (ua == "" || ua == " ") ua = "-"

        # Извлекаем URI
        split(request, req_parts, " ")
        uri = req_parts[2]
        if (uri == "") uri = "-"

        # Обрезаем query string для агрегации (? и всё после)
        sub(/\?.*/, "", uri)

        # Статус и байты из parts[3]: " STATUS BYTES " (между request и referer)
        status = ""; bytes = 0
        if (n >= 3) {
            # parts[3] = " 200 1234 " — trim и split
            gsub(/^ +| +$/, "", parts[3])
            split(parts[3], sb, " ")
            status = sb[1]
            bytes = sb[2]
            if (bytes !~ /^[0-9]+$/) bytes = 0
        }

        # Пропуск мусорных кодов
        n_skip = split(skip_codes, sc, "|")
        for (k=1; k<=n_skip; k++) {
            if (status == sc[k]) next
        }

        # Определяем сайт из имени файла (FILENAME)
        site = FILENAME
        gsub(/.*\//, "", site)
        gsub(/-?(backend|frontend)?\.?access\.log.*/, "", site)
        gsub(/\.log.*/, "", site)
        if (site == "") site = "unknown"

        # === Агрегация ===

        # IP
        ip_hits[ip]++

        # UA per IP
        ua_key = ip SUBSEP ua
        if (!(ua_key in ip_ua_seen)) {
            ip_ua_seen[ua_key] = 1
            ip_ua_count[ip]++
        }
        ip_ua_hits[ua_key]++
        if (ip_ua_hits[ua_key] > ip_ua_max_hits[ip]) {
            ip_ua_max_hits[ip] = ip_ua_hits[ua_key]
            ip_main_ua[ip] = ua
        }

        # Status codes
        if (status ~ /^2/) s2xx++
        else if (status ~ /^3/) s3xx++
        else if (status ~ /^4/) s4xx++
        else if (status ~ /^5/) { s5xx++; site_5xx[site]++ }

        # Bytes
        total_bytes += bytes
        site_bytes[site] += bytes

        # Hourly stats
        if (match(ts_str, /:[0-9][0-9]:/)) {
            h_str = substr(ts_str, RSTART+1, 2)
            hourly[h_str + 0]++
        }

        # Per-site URI
        if (fast != "true") {
            site_uri[site SUBSEP uri]++
        }
        site_hits[site]++

        # Bot detection (portable — no capture groups)
        ua_lower = tolower(ua)
        is_bot = 0
        if (ua_lower ~ /bot|crawl|spider|scraper|scanner|slurp|wget|curl|python|go-http|java|axios|l9explore/) {
            is_bot = 1
            bot_name = ""
            # Try to extract bot name from common patterns
            if (ua_lower ~ /googlebot/)        bot_name = "Googlebot"
            else if (ua_lower ~ /yandexbot/)   bot_name = "YandexBot"
            else if (ua_lower ~ /bingbot/)     bot_name = "bingbot"
            else if (ua_lower ~ /gptbot/)      bot_name = "GPTBot"
            else if (ua_lower ~ /claudebot/)   bot_name = "ClaudeBot"
            else if (ua_lower ~ /ahrefsbot/)   bot_name = "AhrefsBot"
            else if (ua_lower ~ /semrushbot/)  bot_name = "SemrushBot"
            else if (ua_lower ~ /dotbot/)      bot_name = "DotBot"
            else if (ua_lower ~ /applebot/)    bot_name = "Applebot"
            else if (ua_lower ~ /serpstatbot/) bot_name = "serpstatbot"
            else if (ua_lower ~ /baiduspider/) bot_name = "Baiduspider"
            else if (ua_lower ~ /bytespider/)  bot_name = "Bytespider"
            else if (ua_lower ~ /amazonbot/)   bot_name = "Amazonbot"
            else if (ua_lower ~ /msnbot/)      bot_name = "msnbot"
            else if (ua_lower ~ /duckduckbot/) bot_name = "DuckDuckBot"
            else if (ua_lower ~ /mauibot/)     bot_name = "MauiBot"
            else if (ua_lower ~ /meta-externalagent/) bot_name = "meta-externalagent"
            else if (ua_lower ~ /l9explore/)   bot_name = "l9explore"
            else if (ua_lower ~ /curl/)        bot_name = "curl"
            else if (ua_lower ~ /wget/)        bot_name = "wget"
            else if (ua_lower ~ /python/)      bot_name = "python"
            else if (ua_lower ~ /go-http/)     bot_name = "Go-http-client"
            else if (ua_lower ~ /java/)        bot_name = "Java"
            else if (ua_lower ~ /axios/)       bot_name = "axios"
            else if (ua_lower ~ /scrapy/)      bot_name = "Scrapy"
            else {
                # Попытка извлечь имя бота: ищем слово с "bot/spider/crawler"
                n2 = split(ua, ua_words, /[ \/;()]/)
                for (w=1; w<=n2; w++) {
                    wl = tolower(ua_words[w])
                    if (wl ~ /bot$|spider$|crawler$|scraper$/) {
                        bot_name = ua_words[w]
                        break
                    }
                }
                if (bot_name == "") bot_name = "unknown-bot"
            }
            gsub(/^ +| +$/, "", bot_name)
            bot_hits[bot_name]++
        }

        # Traffic type
        if (is_bot) traffic_bot++
        else if (ua_lower ~ /mobile|android|iphone|ipad/) traffic_mobile++
        else traffic_desktop++

        total_requests++
    }

    END {
        # === OUTPUT ===

        # Summary
        print "SUMMARY"
        print "total_requests=" total_requests
        print "s2xx=" s2xx+0
        print "s3xx=" s3xx+0
        print "s4xx=" s4xx+0
        print "s5xx=" s5xx+0
        print "total_bytes=" total_bytes+0
        print "traffic_bot=" traffic_bot+0
        print "traffic_desktop=" traffic_desktop+0
        print "traffic_mobile=" traffic_mobile+0

        # Unique IPs
        unique_ips = 0
        for (ip in ip_hits) unique_ips++
        print "unique_ips=" unique_ips

        # Unique bots
        unique_bots = 0
        for (b in bot_hits) unique_bots++
        print "unique_bots=" unique_bots

        # Sites
        site_count = 0
        for (s in site_hits) site_count++
        print "site_count=" site_count

        print "END_SUMMARY"

        # Hourly
        print "HOURLY"
        for (h=0; h<=23; h++) {
            printf "%d=%d\n", h, hourly[h]+0
        }
        print "END_HOURLY"

        # Top IPs (unsorted — sort later)
        print "TOP_IPS"
        for (ip in ip_hits) {
            # main_ua и ua_count
            m_ua = ip_main_ua[ip]
            u_cnt = ip_ua_count[ip]
            gsub(/\t/, " ", m_ua)
            printf "%d\t%s\t%s\t%d\n", ip_hits[ip], ip, m_ua, u_cnt
        }
        print "END_TOP_IPS"

        # Bots
        print "BOTS"
        for (b in bot_hits) {
            printf "%d\t%s\n", bot_hits[b], b
        }
        print "END_BOTS"

        # Per-site
        print "SITES"
        for (s in site_hits) {
            printf "SITE\t%s\t%d\t%d\t%d\n", s, site_hits[s], site_bytes[s]+0, site_5xx[s]+0
        }
        print "END_SITES"

        # Per-site URIs
        if (fast != "true") {
            print "SITE_URIS"
            for (key in site_uri) {
                split(key, su, SUBSEP)
                printf "%s\t%s\t%d\n", su[1], su[2], site_uri[key]
            }
            print "END_SITE_URIS"
        }
    }
    ' "${LOG_FILES[@]}" > "${TMPDIR_WORK}/raw_data.txt" 2>/dev/null

    spin_stop
}

# ═══════════════════════════════════════════════════════════════════════════
#  PARSE AWK OUTPUT
# ═══════════════════════════════════════════════════════════════════════════
declare -A SUMMARY
declare -a HOURLY_DATA
declare -A SITE_DATA

parse_collected_data() {
    local section=""
    local line

    while IFS= read -r line; do
        case "$line" in
            SUMMARY)       section="summary" ;;
            END_SUMMARY)   section="" ;;
            HOURLY)        section="hourly" ;;
            END_HOURLY)    section="" ;;
            TOP_IPS)       section="ips" ;;
            END_TOP_IPS)   section="" ;;
            BOTS)          section="bots" ;;
            END_BOTS)      section="" ;;
            SITES)         section="sites" ;;
            END_SITES)     section="" ;;
            SITE_URIS)     section="uris" ;;
            END_SITE_URIS) section="" ;;
            *)
                case "$section" in
                    summary)
                        local key val
                        key="${line%%=*}"
                        val="${line#*=}"
                        SUMMARY["$key"]="$val"
                        ;;
                    hourly)
                        local h v
                        h="${line%%=*}"
                        v="${line#*=}"
                        HOURLY_DATA[$h]="$v"
                        ;;
                    ips)
                        echo "$line" >> "${TMPDIR_WORK}/top_ips.tsv"
                        ;;
                    bots)
                        echo "$line" >> "${TMPDIR_WORK}/bots.tsv"
                        ;;
                    sites)
                        echo "$line" >> "${TMPDIR_WORK}/sites.tsv"
                        ;;
                    uris)
                        echo "$line" >> "${TMPDIR_WORK}/site_uris.tsv"
                        ;;
                esac
                ;;
        esac
    done < "${TMPDIR_WORK}/raw_data.txt"

    # Сортируем
    [[ -f "${TMPDIR_WORK}/top_ips.tsv" ]] && sort -t$'\t' -k1 -nr "${TMPDIR_WORK}/top_ips.tsv" > "${TMPDIR_WORK}/top_ips_sorted.tsv"
    [[ -f "${TMPDIR_WORK}/bots.tsv" ]]    && sort -t$'\t' -k1 -nr "${TMPDIR_WORK}/bots.tsv" > "${TMPDIR_WORK}/bots_sorted.tsv"
    [[ -f "${TMPDIR_WORK}/sites.tsv" ]]   && sort -t$'\t' -k3 -nr "${TMPDIR_WORK}/sites.tsv" > "${TMPDIR_WORK}/sites_sorted.tsv"
}

# ═══════════════════════════════════════════════════════════════════════════
#  GeoIP BATCH RESOLVE
# ═══════════════════════════════════════════════════════════════════════════
resolve_all_ips() {
    [[ ! -f "${TMPDIR_WORK}/top_ips_sorted.tsv" ]] && return

    spin_start "GeoIP: определение стран..."

    # Извлекаем уникальные IP
    awk -F'\t' '{print $2}' "${TMPDIR_WORK}/top_ips_sorted.tsv" | head -n "$OPT_TOP_N" > "${TMPDIR_WORK}/ips_to_resolve.txt"

    # Батч-резолв
    geo_batch_resolve "${TMPDIR_WORK}/ips_to_resolve.txt"

    spin_stop
}

# ═══════════════════════════════════════════════════════════════════════════
#  SUBNET AGGREGATION
# ═══════════════════════════════════════════════════════════════════════════
aggregate_subnets() {
    [[ ! -f "${TMPDIR_WORK}/top_ips_sorted.tsv" ]] && return

    awk -F'\t' '
    {
        hits = $1; ip = $2
        # /24 for IPv4
        if (ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
            n = split(ip, oct, ".")
            subnet = oct[1]"."oct[2]"."oct[3]".0/24"
            subnet_hits[subnet] += hits
            subnet_ips[subnet]++
        }
    }
    END {
        for (s in subnet_hits) {
            printf "%d\t%d\t%s\n", subnet_hits[s], subnet_ips[s], s
        }
    }' "${TMPDIR_WORK}/top_ips_sorted.tsv" | sort -t$'\t' -k1 -nr > "${TMPDIR_WORK}/subnets.tsv"
}

# ═══════════════════════════════════════════════════════════════════════════
#  RENDER: SUMMARY
# ═══════════════════════════════════════════════════════════════════════════
render_summary() {
    print_header "Сводка"

    local period_start period_end
    period_start=$(date -d "@${CUTOFF_TS}" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$CUTOFF_TS" '+%Y-%m-%d %H:%M' 2>/dev/null)
    period_end=$(date '+%Y-%m-%d %H:%M')

    echo "  Период (сервер):     ${period_start} — ${period_end} (${SERVER_TZ}, ${PERIOD_LABEL})"
    echo "  Всего запросов:      $(fmt_num "${SUMMARY[total_requests]:-0}")"
    echo "  Трафик:              $(fmt_num "${SUMMARY[traffic_bot]:-0}") bot  /  $(fmt_num "${SUMMARY[traffic_desktop]:-0}") desktop  /  $(fmt_num "${SUMMARY[traffic_mobile]:-0}") mobile"
    echo "  Статус-коды:         ${G}$(fmt_num "${SUMMARY[s2xx]:-0}") 2xx${NC}  /  ${C}$(fmt_num "${SUMMARY[s3xx]:-0}") 3xx${NC}  /  ${Y}$(fmt_num "${SUMMARY[s4xx]:-0}") 4xx${NC}  /  ${R}$(fmt_num "${SUMMARY[s5xx]:-0}") 5xx${NC}"
    echo "  Объём:               $(fmt_bytes "${SUMMARY[total_bytes]:-0}")"
    echo "  Уникальных IP:       $(fmt_num "${SUMMARY[unique_ips]:-0}")"
    echo "  Уникальных ботов:    ${SUMMARY[unique_bots]:-0}"
    echo "  Сайтов:              ${SUMMARY[site_count]:-0}"
}

# ═══════════════════════════════════════════════════════════════════════════
#  RENDER: CHART
# ═══════════════════════════════════════════════════════════════════════════
render_chart() {
    print_header "Запросы / час"

    # Находим максимум
    local max_val=0 h
    for h in $(seq 0 23); do
        local v=${HOURLY_DATA[$h]:-0}
        (( v > max_val )) && max_val=$v
    done

    [[ $max_val -eq 0 ]] && { echo "  Нет данных."; return; }

    # Ширина Y-axis метки (для числа с пробелами-разделителями)
    local y_label_w=8

    # ASCII chart (12 строк высотой)
    local rows=12
    local r

    for (( r=rows; r>=1; r-- )); do
        local threshold=$(( max_val * r / rows ))
        if (( r == rows )); then
            printf "  %${y_label_w}s ┤" "$(fmt_num $max_val)"
        elif (( r == rows/2 )); then
            printf "  %${y_label_w}s ┤" "$(fmt_num $(( max_val / 2 )))"
        elif (( r == 1 )); then
            printf "  %${y_label_w}s ┤" "0"
        else
            printf "  %${y_label_w}s ┤" ""
        fi

        for h in $(seq 0 23); do
            local v=${HOURLY_DATA[$h]:-0}
            local bar_height=$(( v * rows / max_val ))
            if (( bar_height >= r )); then
                printf "${G}█${NC}"
            else
                printf " "
            fi
            printf "  "
        done
        echo ""
    done

    # X-axis
    printf "  %${y_label_w}s └" ""
    for h in $(seq 0 23); do
        printf "───"
    done
    echo ""
    printf "  %${y_label_w}s  " ""
    for h in $(seq 0 23); do
        printf "%-3d" "$h"
    done
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
#  RENDER: TOP IPs
# ═══════════════════════════════════════════════════════════════════════════
render_top_ips() {
    [[ ! -f "${TMPDIR_WORK}/top_ips_sorted.tsv" ]] && return

    print_header "Топ ${OPT_TOP_N} IP"

    printf "  ${BOLD}%-9s | %-39s | %-30s | %s${NC}\n" "HITS" "IP" "COUNTRY" "CLIENT"
    print_separator

    local count=0
    while IFS=$'\t' read -r hits ip main_ua ua_count; do
        (( count >= OPT_TOP_N )) && break

        # GeoIP
        local geo_str
        geo_str=$(geo_lookup "$ip")
        local cc
        cc=$(geo_country_code "$geo_str")
        local cn
        cn=$(geo_country_name "$geo_str")

        # Цвет страны
        local country_raw="${cc}, ${cn}"
        local country_display
        if [[ "$ip" == "$SERVER_IP" ]]; then
            country_display="${Y}THIS SERVER${NC}"
            country_raw="THIS SERVER"
        elif is_safe_country "$cc"; then
            country_display="${G}${country_raw}${NC}"
        else
            country_display="${R}${country_raw}${NC}"
        fi

        # Клиент
        local client
        client=$(classify_client "$main_ua" "$ua_count")

        # Padding вручную (без ANSI кодов в %-Ns)
        local pad_country=$(( 30 - ${#country_raw} ))
        (( pad_country < 0 )) && pad_country=0
        local country_padded="${country_display}$(printf '%*s' $pad_country '')"

        printf "  %-9s | %-39s | %s | %s\n" "$hits" "$ip" "$country_padded" "$client"
        count=$((count + 1))
    done < "${TMPDIR_WORK}/top_ips_sorted.tsv"

    print_separator
    echo "  Всего: ${SUMMARY[unique_ips]:-0} уникальных IP, ${SUMMARY[total_requests]:-0} запросов"
}

# ═══════════════════════════════════════════════════════════════════════════
#  RENDER: TOP SUBNETS
# ═══════════════════════════════════════════════════════════════════════════
render_top_subnets() {
    [[ ! -f "${TMPDIR_WORK}/subnets.tsv" ]] && return

    print_header "Топ 10 подсетей"

    printf "  ${BOLD}%-11s | %-6s | %-28s | %s${NC}\n" "HITS" "IPs" "SUBNET" "COUNTRY"
    print_separator

    local count=0
    while IFS=$'\t' read -r hits ips subnet; do
        (( count >= 10 )) && break

        local base_ip
        base_ip=$(echo "$subnet" | sed 's|/24||' | sed 's|\.0$|.1|')
        local geo_str
        geo_str=$(geo_lookup "$base_ip")
        local cc cn
        cc=$(geo_country_code "$geo_str")
        cn=$(geo_country_name "$geo_str")

        local country_raw="${cc}, ${cn}"
        local country_display
        if is_safe_country "$cc"; then
            country_display="${G}${country_raw}${NC}"
        else
            country_display="${R}${country_raw}${NC}"
        fi

        printf "  %-11s | %-6s | %-28s | %s\n" "$hits" "$ips" "$subnet" "$country_display"
        count=$((count + 1))
    done < "${TMPDIR_WORK}/subnets.tsv"
}

# ═══════════════════════════════════════════════════════════════════════════
#  RENDER: TOP BOTS
# ═══════════════════════════════════════════════════════════════════════════
render_top_bots() {
    [[ ! -f "${TMPDIR_WORK}/bots_sorted.tsv" ]] && return

    local bot_top=30

    print_header "Топ ${bot_top} ботов"

    printf "  ${BOLD}%-11s %s${NC}\n" "HITS" "BOT"
    print_separator

    local count=0
    while IFS=$'\t' read -r hits bot_name; do
        (( count >= bot_top )) && break

        # Цвет бота
        local color=""
        local cls
        cls=$(bot_class "$bot_name")
        if (( hits >= 1000 )); then
            case "$cls" in
                green)  color="$G" ;;
                yellow) color="$Y" ;;
                red)    color="$R" ;;
            esac
        fi

        printf "  %-11s${color}%-40s${NC}\n" "$hits" "$bot_name"
        count=$((count + 1))
    done < "${TMPDIR_WORK}/bots_sorted.tsv"
}

# ═══════════════════════════════════════════════════════════════════════════
#  RENDER: PER-SITE URIs
# ═══════════════════════════════════════════════════════════════════════════
render_site_uris() {
    [[ "$OPT_FAST" == "true" ]] && return
    [[ ! -f "${TMPDIR_WORK}/sites_sorted.tsv" ]] && return

    local sites_top=10

    print_header "Топ ${sites_top} сайтов по запросам (URI топ-${OPT_URI_N})"

    # sites_sorted.tsv format: SITE\tname\thits\tbytes\t5xx
    local site_count=0
    while IFS=$'\t' read -r _prefix site_name site_hits site_bytes site_5xx; do
        [[ -z "$site_name" || "$site_name" == "-" || "$site_name" == "unknown" ]] && continue
        (( site_count >= sites_top )) && break

        local bytes_fmt
        bytes_fmt=$(fmt_bytes "${site_bytes:-0}")
        local extra=""
        (( ${site_5xx:-0} > 0 )) && extra="${R}${site_5xx} 5xx${NC} · "
        extra="${extra}${bytes_fmt} · ${site_hits} req"

        echo ""
        printf "  ${BOLD}${W}%-60s${NC} %s\n" "$site_name" "$extra"

        # DNS info
        local dns_info
        dns_info=$(dns_check_site "$site_name" 2>/dev/null)
        [[ -n "$dns_info" && "$dns_info" != "?" ]] && echo "      ${DIM}${dns_info}${NC}"

        print_separator

        # URIs для этого сайта
        if [[ -f "${TMPDIR_WORK}/site_uris.tsv" ]]; then
            awk -F'\t' -v site="$site_name" '$1 == site' "${TMPDIR_WORK}/site_uris.tsv" 2>/dev/null | \
                sort -t$'\t' -k3 -nr | head -n "$OPT_URI_N" | \
                while IFS=$'\t' read -r _s uri uri_hits; do
                    printf "  %-9s%s\n" "$uri_hits" "$uri"
                done
        fi

        site_count=$((site_count + 1))
    done < "${TMPDIR_WORK}/sites_sorted.tsv"
}

# ═══════════════════════════════════════════════════════════════════════════
#  RENDER: RECOMMENDATIONS
# ═══════════════════════════════════════════════════════════════════════════
render_recommendations() {
    [[ "$OPT_QUIET" == "true" ]] && return

    print_header "Рекомендации"
    echo "  ${DIM}Проверьте перед применением. Используйте на свое усмотрение.${NC}"

    local rec_num=1

    # 1. Блокировка нежелательных ботов через nginx
    local bad_bots=""
    if [[ -f "${TMPDIR_WORK}/bots_sorted.tsv" ]]; then
        while IFS=$'\t' read -r hits bot_name; do
            local cls
            cls=$(bot_class "$bot_name")
            if [[ "$cls" == "red" ]] && (( hits >= 50 )); then
                [[ -n "$bad_bots" ]] && bad_bots="${bad_bots}|"
                bad_bots="${bad_bots}${bot_name}"
            fi
        done < "${TMPDIR_WORK}/bots_sorted.tsv"
    fi

    if [[ -n "$bad_bots" ]]; then
        # Определяем путь для конфига
        local conf_path=""
        case "$CONTROL_PANEL" in
            ispmanager) conf_path="/etc/nginx/vhosts-includes/block-bots.conf" ;;
            fastpanel)  conf_path="/etc/nginx/fastpanel2-includes/block-bots.conf" ;;
            hestia)     conf_path="/etc/nginx/conf.d/block-bots.conf" ;;
            *)          conf_path="/etc/nginx/conf.d/block-bots.conf" ;;
        esac

        echo ""
        echo "  ${BOLD}[${rec_num}] Блокировка нежелательных ботов (nginx):${NC}"
        echo "   Файл: ${C}${conf_path}${NC}"
        echo ""
        echo "   ${Y}if (\$http_user_agent ~* (${bad_bots})) {${NC}"
        echo "   ${Y}    return 444;${NC}"
        echo "   ${Y}}${NC}"
        echo ""
        echo "   ${DIM}Применить: nginx -t && systemctl reload nginx${NC}"
        rec_num=$((rec_num + 1))
    fi

    # 2. Блокировка подозрительных подсетей через iptables
    if [[ -f "${TMPDIR_WORK}/subnets.tsv" ]]; then
        local suspicious_subnets=""
        local count=0
        while IFS=$'\t' read -r hits ips subnet; do
            (( count >= 5 )) && break
            (( hits < 500 )) && continue

            local base_ip
            base_ip=$(echo "$subnet" | sed 's|/24||' | sed 's|\.0$|.1|')
            local geo_str
            geo_str=$(geo_lookup "$base_ip")
            local cc
            cc=$(geo_country_code "$geo_str")

            if ! is_safe_country "$cc"; then
                [[ -n "$suspicious_subnets" ]] && suspicious_subnets="${suspicious_subnets}\n"
                suspicious_subnets="${suspicious_subnets}   iptables -I INPUT -s ${subnet} -j DROP  # ${cc} (${hits} запросов)"
                count=$((count + 1))
            fi
        done < "${TMPDIR_WORK}/subnets.tsv"

        if [[ -n "$suspicious_subnets" ]]; then
            echo ""
            echo "  ${BOLD}[${rec_num}] Блокировка подозрительных подсетей (iptables):${NC}"
            echo -e "$suspicious_subnets"
            echo ""
            echo "   ${DIM}Сохранить правила: iptables-save > /etc/iptables/rules.v4${NC}"
            rec_num=$((rec_num + 1))
        fi
    fi

    # 3. Защита wp-login / xmlrpc
    local has_wp=false
    if [[ -f "${TMPDIR_WORK}/site_uris.tsv" ]]; then
        grep -q "wp-login\|xmlrpc" "${TMPDIR_WORK}/site_uris.tsv" 2>/dev/null && has_wp=true
    fi

    if [[ "$has_wp" == "true" ]]; then
        echo ""
        echo "  ${BOLD}[${rec_num}] Защита WordPress (wp-login.php, xmlrpc.php):${NC}"
        echo "   ${Y}location = /xmlrpc.php { return 444; }${NC}"
        echo "   ${Y}location = /wp-login.php {${NC}"
        echo "   ${Y}    limit_req zone=login burst=3 nodelay;${NC}"
        echo "   ${Y}    # или ограничить по IP:${NC}"
        echo "   ${Y}    # allow YOUR.IP.HERE;${NC}"
        echo "   ${Y}    # deny all;${NC}"
        echo "   ${Y}}${NC}"
        rec_num=$((rec_num + 1))
    fi

    # 4. Блокировка пустых User-Agent
    local empty_ua_hits=0
    if [[ -f "${TMPDIR_WORK}/top_ips_sorted.tsv" ]]; then
        while IFS=$'\t' read -r hits ip main_ua ua_count; do
            [[ "$main_ua" == "-" || -z "$main_ua" ]] && empty_ua_hits=$((empty_ua_hits + hits))
        done < <(head -n "$OPT_TOP_N" "${TMPDIR_WORK}/top_ips_sorted.tsv")
    fi

    if (( empty_ua_hits > 100 )); then
        echo ""
        echo "  ${BOLD}[${rec_num}] Блокировка пустых User-Agent (${empty_ua_hits} запросов):${NC}"
        echo "   ${Y}if (\$http_user_agent = \"\") { return 444; }${NC}"
        rec_num=$((rec_num + 1))
    fi

    # 5. Топ IP для ручной блокировки
    if [[ -f "${TMPDIR_WORK}/top_ips_sorted.tsv" ]]; then
        local top3_block=""
        local count=0
        while IFS=$'\t' read -r hits ip main_ua ua_count; do
            (( count >= 3 )) && break
            (( hits < 1000 )) && continue
            [[ "$ip" == "$SERVER_IP" ]] && continue

            local geo_str
            geo_str=$(geo_lookup "$ip")
            local cc
            cc=$(geo_country_code "$geo_str")

            top3_block="${top3_block}   iptables -I INPUT -s ${ip} -j DROP  # ${cc} (${hits} запросов)\n"
            count=$((count + 1))
        done < "${TMPDIR_WORK}/top_ips_sorted.tsv"

        if [[ -n "$top3_block" ]]; then
            echo ""
            echo "  ${BOLD}[${rec_num}] Блокировка самых активных IP (iptables):${NC}"
            echo -e "$top3_block"
            rec_num=$((rec_num + 1))
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════════════════
main() {
    # 1. Detect panel
    detect_panel

    # 2. Banner
    if [[ "$SCRIPT_MODE" != "true" ]]; then
        clear 2>/dev/null
        echo ""
        echo "  ${BOLD}${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo "  ${BOLD}${W}  DDoSer ${VERSION}${NC} — Анализ access-логов на предмет DDoS-атак"
        echo "  ${C}  Создано Vladislav Pavlovich · TG @sysadminctl${NC}"
        echo "  ${BOLD}${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
    fi

    # 3. Collect log files
    collect_log_files
    if [[ ${#LOG_FILES[@]} -eq 0 ]]; then
        die "Не найдено лог-файлов. Панель: ${CONTROL_PANEL}. Проверьте пути к логам."
    fi

    # Prompt на больших серверах
    if [[ "$OPT_YES" != "true" ]] && [[ ${#LOG_FILES[@]} -gt 30 ]]; then
        echo "  ${Y}${#LOG_FILES[@]} лог-файлов обнаружено. Анализ может занять время.${NC}"
        echo ""
        echo "  Для быстрого запуска используйте: ${C}bash ddoser.sh -fqy${NC}"
        echo ""
        read -p "  Продолжить? [Y/n] " answer
        [[ "$answer" =~ ^[Nn] ]] && exit 0

        if [[ "$OPT_FAST" != "true" ]] && [[ ${#LOG_FILES[@]} -gt 50 ]]; then
            read -p "  URI по сайтам только для топ-10? (полный список может быть длинным) [Y/n] " answer2
            [[ ! "$answer2" =~ ^[Nn] ]] && OPT_URI_N=10
        fi
    fi

    # 4. Dependencies
    ensure_dependencies

    # 5. System info
    collect_system_info

    # 6. Validate log format (first non-empty line)
    local first_line
    first_line=$(head -1 "${LOG_FILES[0]}" 2>/dev/null)
    if [[ -n "$first_line" ]] && ! echo "$first_line" | grep -qP '^\S+ \S+ \S+ \['; then
        warn "Формат логов может быть нестандартным. Результаты могут быть неточными."
    fi

    # 7. Collect data (single awk pass)
    collect_data

    # 8. Parse
    parse_collected_data

    # 9. GeoIP batch resolve
    resolve_all_ips

    # 10. Subnet aggregation
    aggregate_subnets

    # 11. DNS pre-collect (if not fast)
    if [[ "$OPT_FAST" != "true" ]] && [[ -f "${TMPDIR_WORK}/sites_sorted.tsv" ]]; then
        spin_start "DNS-проверки сайтов..."
        while IFS=$'\t' read -r _ site_name _ _ _; do
            dns_check_site "$site_name" >/dev/null 2>&1
        done < <(head -n 20 "${TMPDIR_WORK}/sites_sorted.tsv")
        spin_stop
    fi

    # ═══════════════════════════════════════════════════════════════════
    #  RENDER (всё в буфер)
    # ═══════════════════════════════════════════════════════════════════
    local output_file="${TMPDIR_WORK}/report.txt"
    {
        render_system_info
        render_summary
        render_chart
        render_top_ips
        render_top_subnets
        render_top_bots

        # Per-site URIs
        if [[ "$OPT_FAST" != "true" ]]; then
            render_site_uris
        fi

        render_recommendations

        # Footer
        echo ""
        local total_req="${SUMMARY[total_requests]:-0}"
        local unique_ips="${SUMMARY[unique_ips]:-0}"
        local site_count="${SUMMARY[site_count]:-0}"
        local bw
        bw=$(fmt_bytes "${SUMMARY[total_bytes]:-0}")
        echo "  ${DIM}${total_req} req, ${unique_ips} IPs, ${site_count} сайтов, ${bw} трафик${NC}"
        echo ""
    } > "$output_file"

    # Output
    cat "$output_file"
}

# ═══════════════════════════════════════════════════════════════════════════
#  RUN
# ═══════════════════════════════════════════════════════════════════════════
main