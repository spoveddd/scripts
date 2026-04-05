#!/bin/bash
# ╔══════════════════════════════════════════════════════════════╗
# ║  Site Copy Script v4.0                                       ║
# ║  Поддержка: FastPanel · ISPManager · Hestia                  ║
# ║  Автор: Vladislav Pavlovich  |  Telegram: @sysadminctl       ║
# ╚══════════════════════════════════════════════════════════════╝
#
# Использование:
#   ./copy_site.sh [OPTIONS] [SOURCE TARGET]
#
# Опции:
#   --dry-run           Симуляция без реальных изменений
#   --force             Без переспросов (перезаписать если существует)
#   --no-ssl            Не выпускать SSL сертификат
#   --panel=PANEL       Принудительно задать панель (fastpanel|hestia|ispmanager)
#   --php=VERSION       PHP версия для wp-cli (например: 7.4 или 8.2)
#   -h, --help          Справка
#
# Примеры:
#   ./copy_site.sh site.ru copy.ru
#   ./copy_site.sh --dry-run --panel=hestia site.ru test.ru
#   ./copy_site.sh                          # интерактивный режим

set -eo pipefail

# Корректное имя скрипта (при запуске через bash <(curl ...) $0 = /dev/fd/63)
_SELF="${BASH_SOURCE[0]##*/}"
[[ "$_SELF" =~ ^[0-9]+$ ]] && _SELF="copy_site.sh"

# ─── Цвета ───────────────────────────────────────────────────
RED='\033[0;31m';   GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m';  CYAN='\033[0;36m';   BOLD='\033[1m'
WHITE='\033[1;37m'; DIM='\033[2m';        NC='\033[0m'

# ─── Глобальные переменные ───────────────────────────────────
LOG_FILE="/var/log/site_copy_$(date +%Y%m%d_%H%M%S).log"
CONTROL_PANEL=""
TEMP_DUMP_FILE=""
MGRCTL="/usr/local/mgr5/sbin/mgrctl"

DRY_RUN=false
FORCE=false
NO_SSL=false
FORCED_PANEL=""
FORCED_PHP=""
SOURCE_ARG=""
TARGET_ARG=""

STEP=0
TOTAL_STEPS=6

ROLLBACK_SITE_CREATED=false
ROLLBACK_DB_CREATED=false

DNS_OK=false
DNS_RESOLVED_IP=""
DNS_SKIP=false

# ═══════════════════════════════════════════════════════════════
# АРГУМЕНТЫ И СПРАВКА
# ═══════════════════════════════════════════════════════════════

usage() {
    cat >&2 <<EOF

Использование: $_SELF [OPTIONS] [SOURCE TARGET]

  SOURCE          Домен исходного сайта (например: site.ru)
  TARGET          Домен нового сайта    (например: copy.ru)

  --dry-run       Симуляция без реальных изменений
  --force         Перезаписать существующее без переспросов
  --no-ssl        Не выпускать SSL сертификат
  --panel=PANEL   Панель: fastpanel | hestia | ispmanager
  --php=VERSION   Версия PHP для wp-cli (7.4, 8.2, ...)
  -h, --help      Эта справка

Кириллические домены:
  Установите idn2: apt install libidn2-utils
  Или передайте punycode вручную: xn--...

EOF
    exit 0
}

parse_args() {
    local positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)    DRY_RUN=true ;;
            --force)      FORCE=true ;;
            --no-ssl)     NO_SSL=true ;;
            --panel=*)    FORCED_PANEL="${1#--panel=}" ;;
            --php=*)      FORCED_PHP="${1#--php=}" ;;
            -h|--help)    usage ;;
            -*)           log_error "Неизвестный флаг: $1"; exit 1 ;;
            *)            positional+=("$1") ;;
        esac
        shift
    done

    if [[ ${#positional[@]} -eq 2 ]]; then
        SOURCE_ARG="${positional[0]}"
        TARGET_ARG="${positional[1]}"
    elif [[ ${#positional[@]} -eq 1 ]]; then
        log_error "Укажите и SOURCE и TARGET, или запустите без аргументов (интерактивный режим)"
        exit 1
    fi
}

# ═══════════════════════════════════════════════════════════════
# ЛОГИРОВАНИЕ И ВИЗУАЛ
# ═══════════════════════════════════════════════════════════════

_log() {
    local level="$1" color="$2" icon="$3" msg="$4"
    printf "${color}${icon}${NC} %s\n" "$msg" >&2
    printf "[%s] [%-7s] %s\n" "$(date '+%H:%M:%S')" "$level" "$msg" >> "$LOG_FILE"
}

log_info()    { _log "INFO"  "$BLUE"   " ·" "$1"; }
log_success() { _log "OK"    "$GREEN"  " ✓" "$1"; }
log_warning() { _log "WARN"  "$YELLOW" " ⚠" "$1"; }
log_error()   { _log "ERROR" "$RED"    " ✗" "$1"; }

log_step() {
    STEP=$(( STEP + 1 ))
    printf "\n${BOLD}${CYAN}━━ [%d/%d] %s${NC}\n" "$STEP" "$TOTAL_STEPS" "$1" >&2
    printf "\n[STEP %d/%d] %s\n" "$STEP" "$TOTAL_STEPS" "$1" >> "$LOG_FILE"
}

show_header() {
    [[ "${SCRIPT_MODE:-}" != "true" ]] && clear 2>/dev/null

    local line="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "\n"
    printf "  ${BOLD}${GREEN}%s${NC}\n" "$line"
    printf "  ${BOLD}${WHITE}  copy_site.sh v4.0${NC} — инструмент удобного копирования сайтов\n"
    printf "  ${CYAN}  FastPanel · ISPManager · Hestia  |  Vladislav Pavlovich · @sysadminctl${NC}\n"
    printf "  ${BOLD}${GREEN}%s${NC}\n" "$line"
    printf "\n"

    if $DRY_RUN; then
        printf "  ${YELLOW}${BOLD}  ⚠  DRY-RUN MODE — симуляция, реальных изменений не будет${NC}\n\n"
    fi

    log_info "Лог файл: $LOG_FILE"
}

# Печатает строку "  Метка:   Значение" с правильным выравниванием для кириллицы.
# printf %-Ns считает байты, а не символы — поэтому считаем continuation-байты (0x80-0xBF)
# и компенсируем разницу между байтовой и визуальной шириной.
_row() {
    local label="$1" value="$2" target="${3:-18}"
    local byte_len=${#label}
    local extra_bytes
    # Считаем continuation-байты UTF-8 (0x80-0xBF) — они не дают визуальной ширины.
    # Стрипаем пробелы из вывода wc -l, иначе bash-арифметика падает.
    extra_bytes=$(printf '%s' "$label" | LC_ALL=C grep -oP '[\x80-\xBF]' 2>/dev/null | wc -l || echo 0)
    extra_bytes="${extra_bytes//[[:space:]]/}"
    [[ -z "$extra_bytes" || ! "$extra_bytes" =~ ^[0-9]+$ ]] && extra_bytes=0
    local vis_len=$(( byte_len - extra_bytes ))
    local pad=$(( target - vis_len ))
    [[ $pad -lt 1 ]] && pad=1
    # %*s с шириной pad и пустой строкой печатает ровно pad пробелов
    printf "  ${BOLD}%s${NC}%*s%s\n" "$label" "$pad" "" "$value"
}

show_summary() {
    local panel="$1"  source="$2"   target="$3"
    local path="$4"   owner="$5"    db_name="$6"
    local db_user="$7" db_pass="$8" cms="$9"

    local line="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    printf "\n"
    printf "  ${BOLD}${GREEN}%s${NC}\n" "$line"
    printf "  ${GREEN}✓${NC}  ${BOLD}Копирование завершено успешно!${NC}\n"
    printf "  ${BOLD}${GREEN}%s${NC}\n\n" "$line"

    _row "Панель:"     "$panel"
    _row "Источник:"   "$source"
    _row "Новый сайт:" "$target"
    _row "Директория:" "$path"
    _row "Владелец:"   "$owner"

    if [[ -n "$cms" && "$cms" != "other" ]]; then
        _row "CMS:" "$cms"
        if [[ -n "$db_name" ]]; then
            printf "\n"
            _row "База данных:"     "$db_name"
            _row "Пользователь БД:" "$db_user"
            _row "Пароль БД:"       "${YELLOW}${BOLD}${db_pass}${NC}"
        fi
    fi

    printf "\n"
    printf "  ${DIM}"
    _row "Лог:" "$LOG_FILE"
    printf "${NC}\n"
}

show_next_steps() {
    local domain="$1" server_ip="$2" cms="$3" ssl_was_skipped="$4"

    local line="  ─────────────────────────────────────────────────────────────────"
    printf "%s\n" "$line"
    printf "  ${BOLD}Что дальше:${NC}\n"

    # ── Локальный / тестовый домен ──────────────────────────
    if $DNS_SKIP; then
        printf "  ${DIM}Домен локальный/тестовый — DNS не проверялся${NC}\n"
        printf "  · Откройте в браузере: ${CYAN}http://%s${NC} (добавьте в /etc/hosts)\n" "$domain"
        printf "    ${DIM}Запись: %s  %s${NC}\n" "$server_ip" "$domain"
        printf "\n"
        return 0
    fi

    # ── DNS направлен правильно ──────────────────────────────
    if $DNS_OK; then
        printf "  ${GREEN}✓${NC} DNS настроен: ${BOLD}%s${NC} → ${CYAN}%s${NC}\n" "$domain" "$server_ip"

        if ! $ssl_was_skipped; then
            printf "  ${GREEN}✓${NC} SSL сертификат выпущен или запланирован\n"
            printf "  · Откройте в браузере: ${CYAN}https://%s${NC}\n" "$domain"
        else
            printf "  ${YELLOW}⚠${NC}  SSL не был запрошен (--no-ssl)\n"
            printf "  · Выпустите SSL вручную и откройте: ${CYAN}https://%s${NC}\n" "$domain"
            _ssl_hint "$domain" "$cms"
        fi

    # ── DNS НЕ настроен / указывает не туда ─────────────────
    else
        local extra=""
        [[ -n "$DNS_RESOLVED_IP" ]] && extra=" (сейчас → ${DNS_RESOLVED_IP})"

        printf "  ${YELLOW}⚠${NC}  ${BOLD}Домен %s не направлен на этот сервер${NC}%s\n" "$domain" "$extra"
        printf "\n"
        printf "  ${BOLD}Шаги для запуска:${NC}\n"
        printf "  ${BOLD}1.${NC} У регистратора домена добавьте / измените A-запись:\n"
        printf "       ${CYAN}%s${NC}  →  ${BOLD}%s${NC}\n" "$domain" "$server_ip"
        printf "  ${BOLD}2.${NC} Дождитесь обновления DNS (обычно 5–30 минут).\n"
        printf "       Проверить: ${DIM}dig +short %s @8.8.8.8${NC}\n" "$domain"
        printf "  ${BOLD}3.${NC} После обновления DNS выпустите SSL сертификат:\n"
        _ssl_hint "$domain" "$cms"
        printf "\n"
        printf "  ${BOLD}Проверить сайт до смены DNS${NC} (через /etc/hosts):\n"
        printf "  Добавьте на своём компьютере в файл hosts:\n"
        printf "    ${CYAN}Linux/Mac:${NC} /etc/hosts\n"
        printf "    ${CYAN}Windows:${NC}   C:\\Windows\\System32\\drivers\\etc\\hosts\n"
        printf "  Содержимое строки:\n"
        printf "    ${BOLD}%s  %s${NC}\n" "$server_ip" "$domain"
        printf "  Затем откройте: ${CYAN}http://%s${NC}  ${DIM}(без HTTPS — SSL ещё не выпущен)${NC}\n" "$domain"
    fi

    printf "%s\n\n" "$line"
}

_ssl_hint() {
    local domain="$1"
    case $CONTROL_PANEL in
        hestia)
            printf "       Панель: ${BOLD}Hestia${NC} → Веб-домены → %s → SSL → Let's Encrypt\n" "$domain"
            printf "       CLI:    ${DIM}v-add-letsencrypt-domain USER %s${NC}\n" "$domain"
            ;;
        fastpanel)
            printf "       Панель: ${BOLD}FastPanel${NC} → Сертификаты → Let's Encrypt → Добавить\n"
            printf "       CLI:    ${DIM}mogwai certificates create-le --server-name=%s --email=admin@%s${NC}\n" \
                "$domain" "$domain"
            ;;
        ispmanager)
            printf "       Панель: ${BOLD}ISPManager${NC} → SSL-сертификаты → Let's Encrypt\n"
            printf "       CLI:    ${DIM}%s -m ispmgr letsencrypt.generate sok=ok domain_name=%s email=admin@%s${NC}\n" \
                "$MGRCTL" "$domain" "$domain"
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════
# УТИЛИТЫ
# ═══════════════════════════════════════════════════════════════

# Dry-run обёртка: dr cmd arg1 arg2
dr() {
    if $DRY_RUN; then
        log_info "[DRY-RUN] $*"
        return 0
    fi
    "$@"
}

generate_password() {
    # Читаем фиксированный блок через head -c, затем фильтруем — без SIGPIPE
    local len="${1:-20}"
    local raw
    raw=$(head -c $(( len * 12 )) /dev/urandom | base64 2>/dev/null | tr -dc 'A-Za-z0-9')
    printf '%s' "${raw:0:$len}"
}

# Конвертация кириллических доменов в punycode
to_punycode() {
    local domain="$1"
    local result=""

    # Проверяем наличие не-ASCII символов
    if echo "$domain" | LC_ALL=C grep -qP '[^\x00-\x7F]' 2>/dev/null || \
       [[ "$domain" =~ [^[:ascii:]] ]]; then
        if command -v idn2 &>/dev/null; then
            result=$(idn2 --quiet "$domain" 2>/dev/null) || true
        elif command -v idn &>/dev/null; then
            result=$(idn --quiet --idna-to-ascii "$domain" 2>/dev/null) || true
        elif command -v python3 &>/dev/null; then
            result=$(python3 -c "
import sys
try:
    parts = sys.argv[1].split('.')
    print('.'.join(p.encode('idna').decode('ascii') for p in parts))
except Exception:
    print(sys.argv[1])
" "$domain" 2>/dev/null) || true
        fi

        if [[ -n "$result" && "$result" != "$domain" ]]; then
            log_info "Punycode: $domain → $result"
            echo "$result"
            return 0
        fi

        log_warning "Не удалось конвертировать в punycode: $domain"
        log_warning "Установите: apt install libidn2-utils"
        log_warning "Или введите punycode вручную (xn--...)"
    fi

    echo "$domain"
}

choose_admin_email() {
    local domain="$1"
    local tld="${domain##*.}"
    local bad_tlds=("local" "copy" "test" "localhost" "lan" "isp" "hestia" "internal" "example" "corp")
    for bad in "${bad_tlds[@]}"; do
        [[ "$tld" == "$bad" ]] && echo "admin@example.com" && return 0
    done
    [[ "$domain" != *.* ]] && echo "admin@example.com" && return 0
    echo "admin@$domain"
}

validate_site_name() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        log_error "Недопустимые символы в имени сайта: $name"
        log_error "Допускаются: латинские буквы, цифры, дефис, точка, подчёркивание"
        log_error "Кириллические домены конвертируйте через idn2 или используйте punycode"
        return 1
    fi
}

validate_db_name() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-zA-Z0-9_]+$ ]]; then
        log_error "Недопустимые символы в имени БД: $name"
        return 1
    fi
    if [[ "$CONTROL_PANEL" == "fastpanel" && ${#name} -gt 16 ]]; then
        log_error "Имя БД слишком длинное для FastPanel (макс. 16 символов): $name (${#name})"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════
# СИСТЕМНЫЕ ПРОВЕРКИ
# ═══════════════════════════════════════════════════════════════

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Скрипт должен быть запущен от имени root"
        exit 1
    fi
}

check_required_utilities() {
    log_info "Проверяю наличие утилит..."
    local missing=()
    for u in rsync mysqldump mysql sed grep find systemctl du df awk curl; do
        command -v "$u" &>/dev/null || missing+=("$u")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Отсутствуют утилиты: ${missing[*]}"
        log_error "Установите: apt install ${missing[*]}"
        exit 1
    fi
    log_success "Все необходимые утилиты найдены"
}

check_mysql_connection() {
    log_info "Проверяю подключение к MySQL..."
    if mysql -e "SELECT 1;" &>/dev/null; then
        log_success "Подключение к MySQL установлено"
    else
        log_error "Нет подключения к MySQL. Проверьте что mysqld запущен."
        exit 1
    fi
}

check_disk_space() {
    local src_path="$1" target_base="$2"
    local src_kb free_kb required_kb
    src_kb=$(du -sk "$src_path" 2>/dev/null | cut -f1)
    free_kb=$(df "$target_base" 2>/dev/null | tail -1 | awk '{print $4}')
    required_kb=$(( src_kb * 12 / 10 ))  # +20%
    if [[ $free_kb -lt $required_kb ]]; then
        log_error "Недостаточно места: нужно $((required_kb/1024))MB, доступно $((free_kb/1024))MB"
        exit 1
    fi
    log_success "Место: доступно $((free_kb/1024))MB, нужно ~$((required_kb/1024))MB"
}

check_os_compatibility() {
    local os_info="неизвестно"
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os_info="${PRETTY_NAME:-${NAME:-} ${VERSION_ID:-}}"
    fi
    log_info "ОС: $os_info  |  Bash: ${BASH_VERSION}"

    if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
        log_warning "Bash ${BASH_VERSION} — рекомендуется Bash 4.x+, возможны проблемы"
    fi
}

# Проверяет наличие нужных CLI-команд для обнаруженной панели
check_panel_compatibility() {
    echo "[$(date '+%H:%M:%S')] [INFO   ] Проверяю совместимость CLI: $CONTROL_PANEL" >> "$LOG_FILE"
    local warnings=0

    case $CONTROL_PANEL in
        fastpanel)
            command -v mogwai &>/dev/null || {
                log_error "Команда mogwai не найдена — FastPanel корректно установлен?"
                return 1
            }
            # Версию в лог (не на экран)
            local ver
            ver=$(mogwai --version 2>/dev/null | grep -oP '\d+\.\d+[\.\d]*' | head -1 || true)
            echo "[$(date '+%H:%M:%S')] [INFO   ] FastPanel mogwai: ${ver:-версия неизвестна}" >> "$LOG_FILE"

            mogwai sites list &>/dev/null || {
                log_error "'mogwai sites list' недоступен — проверьте права"
                return 1
            }
            # Проверяем наличие модуля SSL
            if ! mogwai certificates --help &>/dev/null 2>&1; then
                log_warning "SSL через mogwai недоступен — SSL будет пропущен (--no-ssl)"
                NO_SSL=true
                warnings=$(( warnings + 1 ))
            fi
            ;;

        hestia)
            local missing=()
            for cmd in v-add-web-domain v-delete-web-domain v-add-database v-delete-database; do
                command -v "$cmd" &>/dev/null || missing+=("$cmd")
            done
            if [[ ${#missing[@]} -gt 0 ]]; then
                log_error "Hestia CLI команды не найдены: ${missing[*]}"
                return 1
            fi
            local ver=""
            ver=$(cat /usr/local/hestia/conf/hestia.conf 2>/dev/null \
                | grep -i '^VERSION' | cut -d'=' -f2 | tr -d "' \"" || true)
            log_info "Hestia: ${ver:-версия неизвестна}"

            command -v v-add-letsencrypt-domain &>/dev/null || {
                log_warning "v-add-letsencrypt-domain недоступен — SSL будет пропущен"
                NO_SSL=true
                warnings=$(( warnings + 1 ))
            }
            ;;

        ispmanager)
            [[ -x "$MGRCTL" ]] || {
                log_error "mgrctl не найден: $MGRCTL"
                return 1
            }
            local ver=""
            ver=$($MGRCTL -m ispmgr -i 2>/dev/null \
                | grep -i 'version' | grep -oP '\d+\.\d+' | head -1 || true)
            log_info "ISPManager: ${ver:-версия неизвестна}"

            $MGRCTL -m ispmgr -i 2>/dev/null | grep -qi 'letsencrypt' || {
                log_warning "Let's Encrypt в ISPManager недоступен — SSL будет пропущен"
                NO_SSL=true
                warnings=$(( warnings + 1 ))
            }
            ;;
    esac

    if [[ $warnings -gt 0 ]]; then
        log_warning "Предупреждений совместимости: $warnings"
    else
        log_success "CLI панели совместим, все команды доступны"
    fi
    return 0
}

# Проверяет DNS записи домена
check_domain_dns() {
    local domain="$1" server_ip="$2"
    DNS_OK=false
    DNS_RESOLVED_IP=""
    DNS_SKIP=false

    # Пропускаем локальные/тестовые домены
    local tld="${domain##*.}"
    local skip_tlds=("local" "copy" "test" "localhost" "lan" "internal" "example" "corp" "dev" "isp")
    for bad in "${skip_tlds[@]}"; do
        if [[ "$tld" == "$bad" ]]; then
            log_info "Домен $domain — локальный, DNS не проверяем"
            DNS_OK=true
            DNS_SKIP=true
            return 0
        fi
    done

    log_info "Проверяю DNS: $domain → ожидается $server_ip"

    # Пытаемся установить dnsutils если нет ни одного DNS-инструмента
    if ! command -v dig &>/dev/null && ! command -v host &>/dev/null && ! command -v nslookup &>/dev/null; then
        log_warning "DNS-утилиты не найдены (dig/host/nslookup), пробую установить dnsutils..."
        local install_ok=false
        if command -v apt-get &>/dev/null; then
            apt-get install -y dnsutils >>"$LOG_FILE" 2>&1 && install_ok=true || true
        elif command -v yum &>/dev/null; then
            yum install -y bind-utils >>"$LOG_FILE" 2>&1 && install_ok=true || true
        elif command -v dnf &>/dev/null; then
            dnf install -y bind-utils >>"$LOG_FILE" 2>&1 && install_ok=true || true
        fi

        if $install_ok && command -v dig &>/dev/null; then
            log_success "dnsutils установлен"
        else
            log_warning "Не удалось установить dnsutils — DNS-проверка пропускается, продолжаю"
            DNS_OK=true   # не блокируем SSL из-за отсутствия инструмента
            return 0
        fi
    fi

    local resolved=""
    if command -v dig &>/dev/null; then
        resolved=$(dig +short +timeout=5 +tries=1 A "$domain" @8.8.8.8 2>/dev/null \
            | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1) || true
    elif command -v host &>/dev/null; then
        resolved=$(host -W 5 "$domain" 8.8.8.8 2>/dev/null \
            | grep 'has address' | awk '{print $NF}' | head -1) || true
    elif command -v nslookup &>/dev/null; then
        resolved=$(nslookup "$domain" 8.8.8.8 2>/dev/null \
            | awk '/^Address:/ && !/8\.8\.8\.8/ {print $2}' | head -1) || true
    fi

    DNS_RESOLVED_IP="$resolved"

    if [[ -z "$resolved" ]]; then
        log_warning "DNS: записей для $domain не найдено"
        DNS_OK=false
    elif [[ "$resolved" == "$server_ip" ]]; then
        log_success "DNS OK: $domain → $resolved"
        DNS_OK=true
    else
        log_warning "DNS: $domain → $resolved (ожидался $server_ip)"
        DNS_OK=false
    fi
}

# ═══════════════════════════════════════════════════════════════
# ОПРЕДЕЛЕНИЕ ПАНЕЛИ УПРАВЛЕНИЯ
# ═══════════════════════════════════════════════════════════════

detect_control_panel() {
    if [[ -n "$FORCED_PANEL" ]]; then
        CONTROL_PANEL="$FORCED_PANEL"
        log_success "Панель задана принудительно: $CONTROL_PANEL"
        return 0
    fi

    log_info "Определяю панель управления..."

    if systemctl is-active --quiet hestia 2>/dev/null || [[ -x /usr/local/hestia/bin/v-add-web-domain ]]; then
        CONTROL_PANEL="hestia"
        log_success "Обнаружена панель: Hestia"
        return 0
    fi

    if systemctl is-active --quiet fastpanel2 2>/dev/null || command -v mogwai &>/dev/null; then
        CONTROL_PANEL="fastpanel"
        log_success "Обнаружена панель: FastPanel"
        return 0
    fi

    if [[ -x "$MGRCTL" ]]; then
        CONTROL_PANEL="ispmanager"
        log_success "Обнаружена панель: ISPManager"
        return 0
    fi

    # Fallback по структуре директорий
    if find /home -maxdepth 3 -type d -name public_html 2>/dev/null | grep -q .; then
        CONTROL_PANEL="hestia"
        log_warning "Панель определена по структуре директорий: Hestia"
    elif [[ -d /var/www/www-root ]]; then
        CONTROL_PANEL="ispmanager"
        log_warning "Панель определена по структуре директорий: ISPManager"
    else
        CONTROL_PANEL="fastpanel"
        log_warning "Панель не определена, используется FastPanel по умолчанию"
    fi
}

# ═══════════════════════════════════════════════════════════════
# ДИРЕКТОРИИ И ВЛАДЕЛЬЦЫ
# ═══════════════════════════════════════════════════════════════

find_site_directory() {
    local site="$1"
    case $CONTROL_PANEL in
        hestia)
            for d in /home/*/; do
                [[ -d "${d}web/${site}/public_html" ]] && echo "${d}web/${site}/public_html" && return 0
            done ;;
        fastpanel|ispmanager)
            for d in /var/www/*/; do
                [[ -d "${d}data/www/${site}" ]] && echo "${d}data/www/${site}" && return 0
            done ;;
    esac
    return 1
}

get_site_owner() {
    local path="$1"
    case $CONTROL_PANEL in
        hestia)              echo "$path" | sed -n 's|/home/\([^/]*\)/.*|\1|p' ;;
        fastpanel|ispmanager) echo "$path" | sed -n 's|/var/www/\([^/]*\)/.*|\1|p' ;;
    esac
}

get_site_path_by_panel() {
    local owner="$1" domain="$2"
    case $CONTROL_PANEL in
        hestia)              echo "/home/${owner}/web/${domain}/public_html" ;;
        fastpanel|ispmanager) echo "/var/www/${owner}/data/www/${domain}" ;;
    esac
}

suggest_site_owner() {
    local src_path="$1" new_name="$2"
    case $CONTROL_PANEL in
        hestia|ispmanager)
            get_site_owner "$src_path" ;;
        fastpanel)
            local base
            base=$(echo "$new_name" | sed 's/[.-]/_/g')
            [[ ${#base} -gt 12 ]] && base="${base:0:12}"
            echo "${base}_usr" ;;
    esac
}

# ═══════════════════════════════════════════════════════════════
# ОПРЕДЕЛЕНИЕ PHP ВЕРСИИ
# ═══════════════════════════════════════════════════════════════

find_php_binary() {
    local version="$1"
    local nodot dot

    # Нормализуем: "82" → "8.2", "8.2" → "8.2"
    if [[ "$version" =~ ^[0-9]{2}$ ]]; then
        dot="${version:0:1}.${version:1:1}"
        nodot="$version"
    else
        dot="$version"
        nodot="${version//./}"
    fi

    for p in \
        "/opt/php${nodot}/bin/php" \
        "/opt/php${dot}/bin/php"   \
        "/usr/bin/php${dot}"       \
        "/usr/local/bin/php${dot}" \
        "/usr/bin/php${nodot}"; do
        [[ -x "$p" ]] && echo "$p" && return 0
    done

    echo "php"
}

detect_site_php() {
    local site="$1"

    # Принудительная версия через аргумент --php=
    if [[ -n "$FORCED_PHP" ]]; then
        local bin
        bin=$(find_php_binary "$FORCED_PHP")
        log_info "PHP версия задана принудительно: $bin"
        echo "$bin"
        return 0
    fi

    local ver=""
    case $CONTROL_PANEL in
        fastpanel)
            # mogwai sites list: ID  SERVER_NAME  ALIASES  OWNER  MODE  PHP_VERSION  IPS  DOCUMENT_ROOT
            ver=$(mogwai sites list 2>/dev/null | awk -v d="$site" 'NR>1 && $2==d {print $6}' | head -1) || true
            ;;
        hestia)
            local owner
            owner=$(get_site_owner "$(find_site_directory "$site" 2>/dev/null || true)") || true
            if [[ -n "$owner" ]]; then
                ver=$(v-list-web-domain "$owner" "$site" plain 2>/dev/null \
                    | grep -iE 'php|backend' | grep -oP '\d+\.\d+' | head -1) || true
            fi
            ;;
        ispmanager)
            ver=$($MGRCTL -m ispmgr webdomain.edit elid="$site" 2>/dev/null \
                | grep -i php | grep -oP '\d+\.\d+' | head -1) || true
            ;;
    esac

    if [[ -n "$ver" ]]; then
        local bin
        bin=$(find_php_binary "$ver")
        [[ "$bin" != "php" ]] && log_info "PHP версия сайта $site: $bin ($ver)"
        echo "$bin"
    else
        echo "php"
    fi
}

# ═══════════════════════════════════════════════════════════════
# ОПРЕДЕЛЕНИЕ CMS
# ═══════════════════════════════════════════════════════════════

detect_cms() {
    local path="$1"

    # WordPress
    if [[ -f "$path/wp-config.php" ]]; then
        echo "wordpress" && return 0
    fi
    if [[ $(find "$path" -maxdepth 1 -name "wp-*" -type f 2>/dev/null | wc -l) -gt 3 ]]; then
        echo "wordpress" && return 0
    fi

    # DLE
    if [[ -d "$path/engine" && -f "$path/engine/data/dbconfig.php" ]]; then
        echo "dle" && return 0
    fi
    if [[ -f "$path/admin.php" && -f "$path/cron.php" && -d "$path/engine" ]]; then
        echo "dle" && return 0
    fi

    # Joomla
    if [[ -f "$path/configuration.php" && -d "$path/administrator" ]]; then
        echo "joomla" && return 0
    fi

    # OpenCart
    if [[ -f "$path/admin/index.php" && -f "$path/system/startup.php" ]]; then
        echo "opencart" && return 0
    fi

    echo "other"
}

# ═══════════════════════════════════════════════════════════════
# ЧТЕНИЕ БД ИЗ КОНФИГОВ CMS
# ═══════════════════════════════════════════════════════════════

get_wp_table_prefix() {
    local cfg="$1"
    local prefix
    prefix=$(grep '^\$table_prefix' "$cfg" 2>/dev/null \
        | sed "s/.*['\"]\\([^'\"]*\\)['\"].*/\\1/" | head -1)
    echo "${prefix:-wp_}"
}

get_db_info_from_wp_config() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    local n u p
    n=$(grep "DB_NAME"     "$f" | grep -o "'[^']*'" | tail -1 | tr -d "'")
    u=$(grep "DB_USER"     "$f" | grep -o "'[^']*'" | tail -1 | tr -d "'")
    p=$(grep "DB_PASSWORD" "$f" | grep -o "'[^']*'" | tail -1 | tr -d "'")
    # Попытка с двойными кавычками
    [[ -z "$n" ]] && n=$(grep "DB_NAME"     "$f" | grep -o '"[^"]*"' | tail -1 | tr -d '"')
    [[ -z "$u" ]] && u=$(grep "DB_USER"     "$f" | grep -o '"[^"]*"' | tail -1 | tr -d '"')
    [[ -z "$p" ]] && p=$(grep "DB_PASSWORD" "$f" | grep -o '"[^"]*"' | tail -1 | tr -d '"')
    echo "$n|$u|$p"
}

get_db_info_from_dle_config() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    local n u p
    n=$(grep 'DBNAME' "$f" | sed 's/.*["\x27]\([^"\x27]*\)["\x27].*/\1/' | head -1)
    u=$(grep 'DBUSER' "$f" | sed 's/.*["\x27]\([^"\x27]*\)["\x27].*/\1/' | head -1)
    p=$(grep 'DBPASS' "$f" | sed 's/.*["\x27]\([^"\x27]*\)["\x27].*/\1/' | head -1)
    echo "$n|$u|$p"
}

get_db_info_from_joomla_config() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    local n u p
    n=$(grep "public \$db\b"       "$f" | sed "s/.*'\\([^']*\\)'.*/\\1/")
    u=$(grep "public \$user\b"     "$f" | sed "s/.*'\\([^']*\\)'.*/\\1/")
    p=$(grep "public \$password\b" "$f" | sed "s/.*'\\([^']*\\)'.*/\\1/")
    echo "$n|$u|$p"
}

get_db_info_from_opencart_config() {
    local f="$1/config.php"
    [[ -f "$f" ]] || f="$1/system/config.php"
    [[ -f "$f" ]] || return 1
    local n u p
    n=$(grep "DB_DATABASE\|'db_name'" "$f" | grep -o "'[^']*'" | tail -1 | tr -d "'")
    u=$(grep "DB_USERNAME\|'db_user'" "$f" | grep -o "'[^']*'" | tail -1 | tr -d "'")
    p=$(grep "DB_PASSWORD\|'db_pass'" "$f" | grep -o "'[^']*'" | tail -1 | tr -d "'")
    echo "$n|$u|$p"
}

# ═══════════════════════════════════════════════════════════════
# БАЗА ДАННЫХ
# ═══════════════════════════════════════════════════════════════

create_db_dump() {
    local db="$1"
    local dump="/tmp/${db}_$(date +%Y%m%d_%H%M%S).sql"

    mysql -e "USE \`${db}\`;" &>/dev/null \
        || { log_error "БД $db не существует или недоступна!"; return 1; }

    log_info "Создаю дамп БД $db..."
    if mysqldump --routines --triggers --events --single-transaction "$db" > "$dump" 2>>"$LOG_FILE"; then
        if [[ -s "$dump" ]]; then
            log_success "Дамп создан: $dump ($(du -h "$dump" | cut -f1))"
            echo "$dump"
        else
            log_error "Дамп создан, но файл пустой!"
            rm -f "$dump"
            return 1
        fi
    else
        log_error "Ошибка создания дампа БД $db"
        rm -f "$dump"
        return 1
    fi
}

import_db_dump() {
    local db="$1" dump="$2"
    [[ -f "$dump" && -s "$dump" ]] \
        || { log_error "Файл дампа не найден или пустой: $dump"; return 1; }
    mysql -e "USE \`${db}\`;" &>/dev/null \
        || { log_error "Целевая БД $db не существует!"; return 1; }

    log_info "Импортирую дамп ($(du -h "$dump" | cut -f1)) → $db ..."
    if mysql "$db" < "$dump" 2>>"$LOG_FILE"; then
        log_success "Дамп импортирован в $db"
    else
        log_error "Ошибка импорта дампа!"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════
# ОБНОВЛЕНИЕ КОНФИГУРАЦИОННЫХ ФАЙЛОВ CMS
# ═══════════════════════════════════════════════════════════════

update_wp_config() {
    local cfg="$1" db="$2" user="$3" pass="$4"
    [[ -f "$cfg" ]] || { log_error "wp-config.php не найден: $cfg"; return 1; }

    cp "$cfg" "${cfg}.bak"
    local tmp="${cfg}.tmp"
    cp "$cfg" "$tmp"

    # Универсальный regex: обрабатывает одинарные и двойные кавычки, пробелы
    sed -i "s|define[[:space:]]*([[:space:]]*['\"]DB_NAME['\"][[:space:]]*,[[:space:]]*['\"][^'\"]*['\"])|define( 'DB_NAME', '$db' )|" "$tmp"
    sed -i "s|define[[:space:]]*([[:space:]]*['\"]DB_USER['\"][[:space:]]*,[[:space:]]*['\"][^'\"]*['\"])|define( 'DB_USER', '$user' )|" "$tmp"
    sed -i "s|define[[:space:]]*([[:space:]]*['\"]DB_PASSWORD['\"][[:space:]]*,[[:space:]]*['\"][^'\"]*['\"])|define( 'DB_PASSWORD', '$pass' )|" "$tmp"

    mv "$tmp" "$cfg"
    log_success "wp-config.php обновлён"
}

install_wp_cli() {
    local php_bin="${1:-php}"
    log_info "Устанавливаю wp-cli..."
    if curl -fsSL -o /tmp/wp-cli.phar \
        https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar 2>>"$LOG_FILE"; then
        if "$php_bin" /tmp/wp-cli.phar --info &>/dev/null; then
            chmod +x /tmp/wp-cli.phar
            mv /tmp/wp-cli.phar /usr/local/bin/wp
            log_success "wp-cli установлен (/usr/local/bin/wp)"
            return 0
        fi
    fi
    rm -f /tmp/wp-cli.phar
    log_warning "Не удалось установить wp-cli"
    return 1
}

update_wp_urls_in_db() {
    local db="$1" old_url="$2" new_url="$3" prefix="${4:-wp_}"

    log_info "Обновляю URL в БД WordPress (prefix: $prefix)..."
    dr mysql "$db" <<SQL 2>>"$LOG_FILE"
UPDATE \`${prefix}options\`  SET option_value = REPLACE(option_value, 'http://$old_url',  'https://$new_url') WHERE option_name IN ('siteurl','home');
UPDATE \`${prefix}options\`  SET option_value = REPLACE(option_value, 'https://$old_url', 'https://$new_url') WHERE option_name IN ('siteurl','home');
UPDATE \`${prefix}posts\`    SET post_content  = REPLACE(post_content,  'http://$old_url',  'https://$new_url');
UPDATE \`${prefix}posts\`    SET post_content  = REPLACE(post_content,  'https://$old_url', 'https://$new_url');
UPDATE \`${prefix}postmeta\` SET meta_value    = REPLACE(meta_value,    'http://$old_url',  'https://$new_url');
UPDATE \`${prefix}postmeta\` SET meta_value    = REPLACE(meta_value,    'https://$old_url', 'https://$new_url');
SQL
    log_success "URL в БД WordPress обновлены"
}

update_wordpress_domains() {
    local path="$1" old="$2" new="$3" php_bin="${4:-php}"

    if ! command -v wp &>/dev/null; then
        log_warning "wp-cli не найден, пробую установить..."
        install_wp_cli "$php_bin" || {
            log_warning "wp-cli недоступен — search-replace пропускается"
            return 0
        }
    fi

    log_info "wp-cli search-replace: $old → $new"
    if $DRY_RUN; then
        log_info "[DRY-RUN] wp --allow-root --path='$path' search-replace '$old' '$new'"
        return 0
    fi

    if wp --allow-root --path="$path" search-replace "$old" "$new" --skip-columns=guid \
        >>"$LOG_FILE" 2>&1; then
        log_success "Домены заменены через wp-cli"
    else
        log_warning "wp-cli search-replace завершился с ошибкой (проверьте лог)"
    fi
}

update_dle_config() {
    local path="$1" db="$2" user="$3" pass="$4" url="$5"
    local dbcfg="$path/engine/data/dbconfig.php"
    local cfg="$path/engine/data/config.php"
    local escaped_pass
    escaped_pass=$(printf '%s\n' "$pass" | sed 's/[\/&]/\\&/g')

    if [[ -f "$dbcfg" ]]; then
        cp "$dbcfg" "${dbcfg}.bak"
        sed -i "s/define (\"DBNAME\", \"[^\"]*\")/define (\"DBNAME\", \"$db\")/" "$dbcfg"
        sed -i "s/define (\"DBUSER\", \"[^\"]*\")/define (\"DBUSER\", \"$user\")/" "$dbcfg"
        sed -i "s/define (\"DBPASS\", \"[^\"]*\")/define (\"DBPASS\", \"$escaped_pass\")/" "$dbcfg"
        sed -i "s/define ('DBNAME', '[^']*')/define ('DBNAME', '$db')/" "$dbcfg"
        sed -i "s/define ('DBUSER', '[^']*')/define ('DBUSER', '$user')/" "$dbcfg"
        sed -i "s/define ('DBPASS', '[^']*')/define ('DBPASS', '$escaped_pass')/" "$dbcfg"
        log_success "DLE dbconfig.php обновлён"
    else
        log_error "Файл DLE dbconfig.php не найден: $dbcfg"
        return 1
    fi

    if [[ -f "$cfg" ]]; then
        cp "$cfg" "${cfg}.bak"
        sed -i "s|'http_home_url' => '[^']*'|'http_home_url' => 'https://$url'|" "$cfg"
        log_success "DLE config.php обновлён (URL → https://$url)"
    fi
}

update_joomla_config() {
    local path="$1" db="$2" user="$3" pass="$4" url="$5"
    local cfg="$path/configuration.php"
    [[ -f "$cfg" ]] || { log_error "Joomla configuration.php не найден: $cfg"; return 1; }

    cp "$cfg" "${cfg}.bak"
    local escaped_pass
    escaped_pass=$(printf '%s\n' "$pass" | sed 's/[\/&]/\\&/g')

    sed -i "s|public \\\$db = '[^']*'|public \$db = '$db'|" "$cfg"
    sed -i "s|public \\\$user = '[^']*'|public \$user = '$user'|" "$cfg"
    sed -i "s|public \\\$password = '[^']*'|public \$password = '$escaped_pass'|" "$cfg"
    sed -i "s|public \\\$live_site = '[^']*'|public \$live_site = 'https://$url'|" "$cfg"
    log_success "Joomla configuration.php обновлён"
}

update_opencart_config() {
    local path="$1" db="$2" user="$3" pass="$4" url="$5"
    local escaped_pass
    escaped_pass=$(printf '%s\n' "$pass" | sed 's/[\/&]/\\&/g')

    for cfg in "$path/config.php" "$path/admin/config.php"; do
        [[ -f "$cfg" ]] || continue
        cp "$cfg" "${cfg}.bak"
        sed -i "s|define('DB_DATABASE', '[^']*')|define('DB_DATABASE', '$db')|" "$cfg"
        sed -i "s|define('DB_USERNAME', '[^']*')|define('DB_USERNAME', '$user')|" "$cfg"
        sed -i "s|define('DB_PASSWORD', '[^']*')|define('DB_PASSWORD', '$escaped_pass')|" "$cfg"
        sed -i "s|define('HTTP_SERVER', '[^']*')|define('HTTP_SERVER', 'https://$url/')|" "$cfg"
        sed -i "s|define('HTTPS_SERVER', '[^']*')|define('HTTPS_SERVER', 'https://$url/')|" "$cfg"
        log_success "OpenCart $(basename "$cfg") обновлён"
    done
}

# ═══════════════════════════════════════════════════════════════
# IP АДРЕСА
# ═══════════════════════════════════════════════════════════════

get_server_ips() {
    ip -4 addr show scope global 2>/dev/null \
        | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | sort -u
}

get_source_site_ip() {
    local site="$1"
    local cfg ip=""

    case $CONTROL_PANEL in
        hestia)
            cfg="/etc/nginx/conf.d/domains/${site}.conf"
            ;;
        ispmanager)
            cfg="/etc/nginx/vhosts/www-root/${site}.conf"
            ;;
        fastpanel)
            cfg=$(find /etc/nginx/fastpanel2-sites -name "${site}.conf" 2>/dev/null | head -1)
            ;;
    esac

    if [[ -n "$cfg" && -f "$cfg" ]]; then
        ip=$(grep -m1 -E "^\s+listen\s+[0-9]" "$cfg" | grep -oP '\d+\.\d+\.\d+\.\d+') || true
    fi

    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$ip" && return 0
    return 1
}

get_target_ip() {
    local site="$1"
    local ip=""

    # 1. IP из nginx-конфига исходного сайта
    if ip=$(get_source_site_ip "$site" 2>/dev/null); then
        log_success "IP из конфига nginx: $ip"
        echo "$ip" && return 0
    fi

    # 2. Системные IP сервера
    local server_ips
    server_ips=$(get_server_ips)
    local count
    count=$(echo "$server_ips" | grep -c . 2>/dev/null || true)

    if [[ "$count" -eq 1 ]]; then
        ip=$(echo "$server_ips" | head -1)
        log_success "Единственный IP сервера: $ip"
        echo "$ip" && return 0
    elif [[ "$count" -gt 1 ]]; then
        log_info "Доступные IP адреса сервера:"
        local i=1 arr=()
        while IFS= read -r a; do
            printf "    %d) %s\n" "$i" "$a" >&2
            arr+=("$a"); i=$(( i + 1 ))
        done <<< "$server_ips"

        local choice
        read -rp "  Выберите номер IP (1-${#arr[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#arr[@]}" ]]; then
            ip="${arr[$(( choice - 1 ))]}"
            log_success "Выбран IP: $ip"
            echo "$ip" && return 0
        fi
    fi

    # 3. Ручной ввод
    log_warning "Не удалось определить IP автоматически"
    read -rp "  Введите IP адрес для нового сайта: " ip
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ip" && return 0
    fi

    log_error "Некорректный IP адрес: $ip"
    return 1
}

# ═══════════════════════════════════════════════════════════════
# FASTPANEL CLI
# ═══════════════════════════════════════════════════════════════

fp_user_exists() {
    [[ -d "/var/www/$1" ]]
}

fp_site_exists() {
    mogwai sites list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$1"
}

fp_get_site_id() {
    mogwai sites list 2>/dev/null | awk -v d="$1" 'NR>1 && $2==d {print $1}'
}

fp_get_handler() {
    # Возвращает: MODE|PHP_VERSION (например: fcgi|82 или mpm_itk|)
    local site="$1"
    local mode ver
    mode=$(mogwai sites list 2>/dev/null | awk -v d="$site" 'NR>1 && $2==d {print $5}' | head -1) || true
    ver=$(mogwai sites list  2>/dev/null | awk -v d="$site" 'NR>1 && $2==d {print $6}' | head -1) || true
    echo "${mode:-mpm_itk}|${ver:-}"
}

create_fastpanel_site() {
    local domain="$1" ip="$2" owner="$3" handler_info="${4:-}"
    local mode="" ver=""

    IFS='|' read -r mode ver <<< "$handler_info"
    [[ -z "$mode" || "$mode" == "PHP_VERSION" ]] && mode="mpm_itk"

    # Проверка/создание пользователя
    if fp_user_exists "$owner"; then
        log_info "Пользователь FastPanel '$owner' уже существует"
    else
        local upass
        upass=$(generate_password)
        log_info "Создаю пользователя FastPanel '$owner'..."
        if dr mogwai users create --username="$owner" --password="$upass" >>"$LOG_FILE" 2>&1; then
            echo "$owner|$upass" > /tmp/fp_new_user.info
            log_success "Пользователь $owner создан"
        else
            log_error "Ошибка создания пользователя FastPanel '$owner'"
            return 1
        fi
    fi

    # Формируем аргументы
    local create_args="--server-name=$domain --owner=$owner --ip=$ip --handler=$mode"
    if [[ -n "$ver" && "$ver" != "PHP_VERSION" ]]; then
        create_args="$create_args --handler_version=$ver"
    fi

    log_info "Создаю сайт $domain в FastPanel (handler: $mode${ver:+, version: $ver})..."
    # shellcheck disable=SC2086
    if dr mogwai sites create $create_args >>"$LOG_FILE" 2>&1; then
        log_success "Сайт $domain создан в FastPanel"

        if ! $NO_SSL; then
            local email
            email=$(choose_admin_email "$domain")
            log_info "Выпускаю Let's Encrypt SSL для $domain..."
            local ssl_out
            ssl_out=$(dr mogwai certificates create-le \
                --server-name="$domain" --email="$email" 2>&1) || true
            if echo "$ssl_out" | grep -qiE "Cannot create|error|err:"; then
                log_warning "SSL не выпущен: можно сделать позже в FastPanel"
            else
                log_success "SSL выпущен для $domain"
            fi
        fi
        return 0
    else
        log_error "Ошибка создания сайта $domain в FastPanel"
        return 1
    fi
}

create_fastpanel_database() {
    local owner="$1" db="$2" db_user="$3" db_pass="$4"
    log_info "Создаю БД $db в FastPanel..."
    if dr mogwai databases create --server=1 \
        -n "$db" -o "$owner" -u "$db_user" -p "$db_pass" >>"$LOG_FILE" 2>&1; then
        log_success "БД $db создана в FastPanel"
    else
        log_error "Ошибка создания БД $db в FastPanel"
        return 1
    fi
}

delete_fastpanel_site() {
    local domain="$1"
    local id
    id=$(fp_get_site_id "$domain")
    if [[ -n "$id" ]]; then
        dr mogwai sites delete --id="$id" >>"$LOG_FILE" 2>&1 \
            && log_info "[откат] Сайт $domain удалён" \
            || log_warning "[откат] Не удалось удалить сайт $domain"
    fi
}

delete_fastpanel_database() {
    local db="$1"
    # Сначала пробуем через mogwai (если команда поддерживается)
    local id
    id=$(mogwai databases list 2>/dev/null | awk -v d="$db" 'NR>1 && $2==d {print $1}') || true
    if [[ -n "$id" ]]; then
        if dr mogwai databases delete --id="$id" >>"$LOG_FILE" 2>&1; then
            log_info "[откат] БД $db удалена через mogwai"
            return 0
        fi
    fi
    # Fallback: напрямую через MySQL
    if mysql -e "USE \`${db}\`;" &>/dev/null; then
        dr mysql -e "DROP DATABASE \`${db}\`;" >>"$LOG_FILE" 2>&1 \
            && log_info "[откат] БД $db удалена через MySQL" \
            || log_warning "[откат] Не удалось удалить БД $db"
    else
        log_info "[откат] БД $db не найдена, пропускаем"
    fi
}

# ═══════════════════════════════════════════════════════════════
# HESTIA CLI
# ═══════════════════════════════════════════════════════════════

hestia_site_exists() {
    local domain="$1"
    [[ -f "/etc/nginx/conf.d/domains/${domain}.conf" ]] || \
    find /home -maxdepth 4 -type d -name "$domain" 2>/dev/null | grep -q .
}

create_hestia_site() {
    local owner="$1" domain="$2" ip="$3"
    log_info "Создаю сайт $domain в Hestia..."
    if dr v-add-web-domain "$owner" "$domain" "$ip" "yes" >>"$LOG_FILE" 2>&1; then
        log_success "Сайт $domain создан в Hestia"

        if ! $NO_SSL; then
            log_info "Выпускаю Let's Encrypt SSL для $domain..."
            dr v-add-letsencrypt-user "$owner" >>"$LOG_FILE" 2>&1 || true
            if dr v-add-letsencrypt-domain "$owner" "$domain" "" "no" >>"$LOG_FILE" 2>&1; then
                log_success "SSL выпущен для $domain"
            elif dr v-schedule-letsencrypt-domain "$owner" "$domain" "" >>"$LOG_FILE" 2>&1; then
                log_info "SSL запланирован к выпуску (автоматически)"
            else
                log_warning "SSL не выпущен: сделайте вручную в панели Hestia"
            fi
        fi
        return 0
    else
        log_error "Ошибка создания сайта $domain в Hestia"
        return 1
    fi
}

create_hestia_database() {
    local owner="$1" db="$2" db_user="$3" db_pass="$4"
    log_info "Создаю БД $db в Hestia..."
    if dr v-add-database "$owner" "$db" "$db_user" "$db_pass" >>"$LOG_FILE" 2>&1; then
        # Hestia добавляет префикс пользователя
        local actual_db="${owner}_${db}"
        local actual_user="${owner}_${db_user}"
        log_success "БД создана: $actual_db (пользователь: $actual_user)"
        echo "$actual_db|$actual_user" > /tmp/hestia_db.info
        return 0
    else
        log_error "Ошибка создания БД в Hestia"
        return 1
    fi
}

delete_hestia_site() {
    local owner="$1" domain="$2"
    dr v-delete-web-domain "$owner" "$domain" >>"$LOG_FILE" 2>&1 \
        && log_info "[откат] Сайт $domain удалён" \
        || log_warning "[откат] Не удалось удалить сайт $domain"
}

delete_hestia_database() {
    local owner="$1" db="$2"
    dr v-delete-database "$owner" "$db" >>"$LOG_FILE" 2>&1 \
        && log_info "[откат] БД $db удалена" \
        || log_warning "[откат] Не удалось удалить БД $db"
}

# ═══════════════════════════════════════════════════════════════
# ISPMANAGER CLI
# ═══════════════════════════════════════════════════════════════

isp_site_exists() {
    local domain="$1"
    [[ -f "/etc/nginx/vhosts/www-root/${domain}.conf" ]] || \
    $MGRCTL -m ispmgr webdomain 2>/dev/null | grep -q "name=$domain"
}

create_ispmanager_site() {
    local owner="$1" domain="$2" ip="$3"
    local email
    email=$(choose_admin_email "$domain")
    log_info "Создаю сайт $domain в ISPManager..."
    if dr $MGRCTL -m ispmgr webdomain.edit sok=ok \
        name="$domain" owner="$owner" ip="$ip" email="$email" >>"$LOG_FILE" 2>&1; then
        log_success "Сайт $domain создан в ISPManager"

        if ! $NO_SSL; then
            log_info "Выпускаю Let's Encrypt SSL для $domain..."
            if dr $MGRCTL -m ispmgr letsencrypt.generate sok=ok \
                domain_name="$domain" email="$email" >>"$LOG_FILE" 2>&1; then
                log_success "SSL выпущен для $domain"
            else
                log_warning "SSL не выпущен: сделайте вручную в ISPManager"
            fi
        fi
        return 0
    else
        log_error "Ошибка создания сайта $domain в ISPManager"
        return 1
    fi
}

create_ispmanager_database() {
    local owner="$1" db="$2" db_user="$3" db_pass="$4"
    log_info "Создаю БД $db в ISPManager..."
    if dr $MGRCTL -m ispmgr db.edit sok=ok \
        name="$db" owner="$owner" username="$db_user" password="$db_pass" >>"$LOG_FILE" 2>&1; then
        log_success "БД $db создана в ISPManager"
    else
        log_error "Ошибка создания БД $db в ISPManager"
        return 1
    fi
}

delete_ispmanager_site() {
    local domain="$1"
    dr $MGRCTL -m ispmgr webdomain.delete elid="$domain" sok=ok >>"$LOG_FILE" 2>&1 \
        && log_info "[откат] Сайт $domain удалён" \
        || log_warning "[откат] Не удалось удалить сайт $domain"
}

delete_ispmanager_database() {
    local db="$1"
    dr $MGRCTL -m ispmgr db.delete elid="$db" sok=ok >>"$LOG_FILE" 2>&1 \
        && log_info "[откат] БД $db удалена" \
        || log_warning "[откат] Не удалось удалить БД $db"
}

# ═══════════════════════════════════════════════════════════════
# ОБЩИЕ ОБЁРТКИ ДЛЯ ВСЕХ ПАНЕЛЕЙ
# ═══════════════════════════════════════════════════════════════

check_site_exists() {
    case $CONTROL_PANEL in
        hestia)     hestia_site_exists  "$1" ;;
        fastpanel)  fp_site_exists      "$1" ;;
        ispmanager) isp_site_exists     "$1" ;;
    esac
}

create_site_via_cli() {
    local owner="$1" domain="$2" ip="$3" extra="${4:-}"
    case $CONTROL_PANEL in
        hestia)     create_hestia_site     "$owner" "$domain" "$ip" ;;
        fastpanel)  create_fastpanel_site  "$domain" "$ip" "$owner" "$extra" ;;
        ispmanager) create_ispmanager_site "$owner" "$domain" "$ip" ;;
    esac
}

create_db_via_cli() {
    local owner="$1" db="$2" db_user="$3" db_pass="$4"
    case $CONTROL_PANEL in
        hestia)     create_hestia_database     "$owner" "$db" "$db_user" "$db_pass" ;;
        fastpanel)  create_fastpanel_database  "$owner" "$db" "$db_user" "$db_pass" ;;
        ispmanager) create_ispmanager_database "$owner" "$db" "$db_user" "$db_pass" ;;
    esac
}

delete_site_via_cli() {
    local owner="$1" domain="$2"
    case $CONTROL_PANEL in
        hestia)     delete_hestia_site     "$owner" "$domain" ;;
        fastpanel)  delete_fastpanel_site  "$domain" ;;
        ispmanager) delete_ispmanager_site "$domain" ;;
    esac
}

delete_db_via_cli() {
    local owner="$1" db="$2"
    case $CONTROL_PANEL in
        hestia)     delete_hestia_database     "$owner" "$db" ;;
        fastpanel)  delete_fastpanel_database  "$db" ;;
        ispmanager) delete_ispmanager_database "$db" ;;
    esac
}

# ═══════════════════════════════════════════════════════════════
# ОТКАТ
# ═══════════════════════════════════════════════════════════════

do_rollback() {
    local stage="$1" owner="$2" domain="$3" db="${4:-}"

    log_error "Ошибка на этапе: $stage — запускаю откат..."

    # Удаляем БД если она была создана
    if $ROLLBACK_DB_CREATED && [[ -n "$db" ]]; then
        delete_db_via_cli "$owner" "$db"
    fi

    # Удаляем сайт если он был создан нами (не существовал до)
    if $ROLLBACK_SITE_CREATED; then
        delete_site_via_cli "$owner" "$domain"
    fi

    log_info "Откат завершён"
}

# ═══════════════════════════════════════════════════════════════
# ОСНОВНАЯ ФУНКЦИЯ КОПИРОВАНИЯ
# ═══════════════════════════════════════════════════════════════

copy_site() {
    local source_site="$1" new_site="$2"

    # Сброс состояния
    STEP=0
    ROLLBACK_SITE_CREATED=false
    ROLLBACK_DB_CREATED=false
    TEMP_DUMP_FILE=""
    rm -f /tmp/hestia_db.info /tmp/fp_new_user.info

    printf "\n${BOLD}  Копирую: ${CYAN}%s${NC}${BOLD} → ${CYAN}%s${NC}\n" "$source_site" "$new_site"

    # ──────────────────────────────────────────────────────────
    log_step "Анализ исходного сайта: $source_site"

    local src_path
    if ! src_path=$(find_site_directory "$source_site" 2>/dev/null); then
        log_warning "Директория не найдена автоматически"
        read -rp "  Введите полный путь к файлам сайта $source_site: " src_path
        [[ -d "$src_path" ]] || { log_error "Директория не существует: $src_path"; return 1; }
    fi
    log_success "Директория: $src_path"

    local src_owner
    src_owner=$(get_site_owner "$src_path")
    log_info "Владелец исходного сайта: $src_owner"

    local cms
    cms=$(detect_cms "$src_path")
    log_info "Обнаруженная CMS: $cms"

    if [[ "$cms" == "other" ]]; then
        printf "  Не удалось определить CMS автоматически.\n"
        printf "  1) WordPress\n  2) DLE\n  3) Joomla\n  4) OpenCart\n  5) Другая\n"
        read -rp "  Выберите CMS (1-5): " cms_choice
        case "$cms_choice" in
            1) cms="wordpress" ;; 2) cms="dle" ;; 3) cms="joomla" ;;
            4) cms="opencart" ;; *) cms="other" ;;
        esac
    fi

    # PHP версия сайта
    local php_bin
    php_bin=$(detect_site_php "$source_site")
    log_info "PHP бинарник для wp-cli: $php_bin"

    # FastPanel handler
    local src_handler=""
    if [[ "$CONTROL_PANEL" == "fastpanel" ]]; then
        src_handler=$(fp_get_handler "$source_site")
        log_info "FastPanel handler исходного сайта: $src_handler"
    fi

    # Данные БД из конфигов
    local old_db_name="" old_db_user="" old_db_pass="" wp_prefix="wp_"
    case $cms in
        wordpress)
            local db_info
            db_info=$(get_db_info_from_wp_config "$src_path/wp-config.php" 2>/dev/null || true)
            IFS='|' read -r old_db_name old_db_user old_db_pass <<< "$db_info"
            wp_prefix=$(get_wp_table_prefix "$src_path/wp-config.php")
            log_info "WordPress БД: $old_db_name (table prefix: $wp_prefix)"
            ;;
        dle)
            local db_info
            db_info=$(get_db_info_from_dle_config "$src_path/engine/data/dbconfig.php" 2>/dev/null || true)
            IFS='|' read -r old_db_name old_db_user old_db_pass <<< "$db_info"
            log_info "DLE БД: $old_db_name"
            ;;
        joomla)
            local db_info
            db_info=$(get_db_info_from_joomla_config "$src_path/configuration.php" 2>/dev/null || true)
            IFS='|' read -r old_db_name old_db_user old_db_pass <<< "$db_info"
            log_info "Joomla БД: $old_db_name"
            ;;
        opencart)
            local db_info
            db_info=$(get_db_info_from_opencart_config "$src_path" 2>/dev/null || true)
            IFS='|' read -r old_db_name old_db_user old_db_pass <<< "$db_info"
            log_info "OpenCart БД: $old_db_name"
            ;;
    esac

    if [[ -z "$old_db_name" && "$cms" != "other" ]]; then
        log_warning "Не удалось прочитать данные БД из конфига CMS"
        read -rp "  Продолжить без копирования БД? (y/N): " yn
        [[ "${yn,,}" == "y" ]] || return 1
        cms="other"
    fi

    # ──────────────────────────────────────────────────────────
    log_step "Настройка нового сайта: $new_site"

    local new_owner
    new_owner=$(suggest_site_owner "$src_path" "$new_site")

    printf "\n  Предлагаемый владелец: ${BOLD}%s${NC}\n" "$new_owner"
    local inp
    read -rp "  Владелец нового сайта [Enter = $new_owner]: " inp
    [[ -n "$inp" ]] && new_owner="$inp"
    log_info "Владелец: $new_owner"

    # Определяем IP
    local target_ip
    target_ip=$(get_target_ip "$source_site") || {
        log_error "Не удалось определить IP адрес"
        return 1
    }

    # Проверяем DNS нового домена
    # Если DNS не настроен — SSL не выпускаем (Let's Encrypt требует доступности домена)
    check_domain_dns "$new_site" "$target_ip"
    if ! $DNS_OK && ! $DNS_SKIP && ! $NO_SSL; then
        log_warning "DNS не направлен на сервер — Let's Encrypt работать не будет"
        log_warning "SSL выпуск отключён автоматически (используйте --no-ssl чтобы убрать это предупреждение)"
        NO_SSL=true
    fi

    # ──────────────────────────────────────────────────────────
    log_step "Создание сайта в панели управления"

    local new_site_path
    new_site_path=$(get_site_path_by_panel "$new_owner" "$new_site")

    if check_site_exists "$new_site"; then
        log_warning "Сайт $new_site уже существует в панели управления"
        if ! $FORCE; then
            read -rp "  Продолжить используя существующий сайт? (y/N): " yn
            [[ "${yn,,}" == "y" ]] || { log_info "Отменено пользователем"; return 1; }
        fi

        # Находим реальный путь существующего сайта
        local existing_path
        if existing_path=$(find_site_directory "$new_site" 2>/dev/null); then
            new_site_path="$existing_path"
            new_owner=$(get_site_owner "$new_site_path")
            log_info "Существующая директория: $new_site_path"
            log_info "Владелец: $new_owner"
        else
            log_warning "Сайт есть в панели, но директория не найдена. Используем: $new_site_path"
        fi
    else
        if ! create_site_via_cli "$new_owner" "$new_site" "$target_ip" "$src_handler"; then
            return 1
        fi
        ROLLBACK_SITE_CREATED=true

        # Ждём создания директории (панель может работать асинхронно)
        local attempts=0
        while [[ ! -d "$new_site_path" && $attempts -lt 15 ]]; do
            sleep 1; attempts=$(( attempts + 1 ))
        done

        # Если стандартный путь не появился — ищем
        if [[ ! -d "$new_site_path" ]]; then
            local found_path
            if found_path=$(find_site_directory "$new_site" 2>/dev/null); then
                new_site_path="$found_path"
            else
                log_error "Директория сайта не создалась: $new_site_path"
                do_rollback "site_created" "$new_owner" "$new_site" ""
                return 1
            fi
        fi
        log_success "Сайт создан: $new_site_path"
    fi

    # Проверяем место
    local base_dir
    base_dir=$(dirname "$new_site_path")
    [[ -d "$base_dir" ]] && check_disk_space "$src_path" "$base_dir"

    # ──────────────────────────────────────────────────────────
    # Шаг 4: База данных (если CMS поддерживается)
    local new_db_name="" new_db_user="" new_db_pass=""
    local actual_db_name="" actual_db_user=""

    if [[ -n "$old_db_name" && "$cms" != "other" ]]; then
        log_step "Настройка базы данных"

        # Автогенерация имён
        local base
        base=$(echo "$new_site" | sed 's/[.-]/_/g')
        if [[ "$CONTROL_PANEL" == "fastpanel" && ${#base} -gt 12 ]]; then
            base="${base:0:12}"
        fi
        new_db_name="${base}_db"
        new_db_user="${base}_usr"
        new_db_pass=$(generate_password 20)

        printf "\n  ${BOLD}Параметры новой БД:${NC}\n"
        printf "    ${BOLD}%-20s${NC} ${GREEN}%s${NC}\n" "Имя БД:"       "$new_db_name"
        printf "    ${BOLD}%-20s${NC} ${GREEN}%s${NC}\n" "Пользователь:" "$new_db_user"
        printf "    ${BOLD}%-20s${NC} ${GREEN}%s${NC}\n" "Пароль:"       "$new_db_pass"
        printf "\n"

        if ! $FORCE; then
            read -rp "  Изменить параметры БД? (y/N): " yn
            if [[ "${yn,,}" == "y" ]]; then
                read -rp "  Имя БД [$new_db_name]: " inp; [[ -n "$inp" ]] && new_db_name="$inp"
                read -rp "  Пользователь [$new_db_user]: " inp; [[ -n "$inp" ]] && new_db_user="$inp"
                read -rp "  Пароль [$new_db_pass]: " inp; [[ -n "$inp" ]] && new_db_pass="$inp"
            fi
        fi

        validate_db_name "$new_db_name"

        # Создаём дамп исходной БД
        TEMP_DUMP_FILE=$(create_db_dump "$old_db_name") || {
            do_rollback "db_dump" "$new_owner" "$new_site" ""
            return 1
        }

        # Создаём новую БД через CLI панели
        if ! create_db_via_cli "$new_owner" "$new_db_name" "$new_db_user" "$new_db_pass"; then
            do_rollback "db_created" "$new_owner" "$new_site" ""
            return 1
        fi
        ROLLBACK_DB_CREATED=true

        # Для Hestia — реальные имена с префиксом пользователя
        if [[ "$CONTROL_PANEL" == "hestia" && -f /tmp/hestia_db.info ]]; then
            IFS='|' read -r actual_db_name actual_db_user < /tmp/hestia_db.info
        else
            actual_db_name="$new_db_name"
            actual_db_user="$new_db_user"
        fi
        log_info "Фактическое имя БД: $actual_db_name / $actual_db_user"
    else
        TOTAL_STEPS=$(( TOTAL_STEPS - 1 ))
    fi

    # ──────────────────────────────────────────────────────────
    log_step "Копирование файлов"

    # Очищаем заглушки панели
    if [[ -d "$new_site_path" ]] && [[ -n "$(ls -A "$new_site_path" 2>/dev/null)" ]]; then
        log_info "Очищаю заглушки панели в $new_site_path..."
        dr rm -rf "${new_site_path:?}"/*
    fi

    log_info "rsync: $src_path/ → $new_site_path/"
    if $DRY_RUN; then
        log_info "[DRY-RUN] rsync -a --info=progress2 '$src_path/' '$new_site_path/'"
    else
        # Пайп с grep может вернуть 1 если нет совпадений — используем PIPESTATUS[0]
        rsync -a --info=progress2 "$src_path/" "$new_site_path/" 2>&1 \
            | tee -a "$LOG_FILE" | grep -E 'to-check|total size' | tail -2 >&2 || true
        local rsync_rc="${PIPESTATUS[0]}"
        if [[ $rsync_rc -ne 0 ]]; then
            log_error "Ошибка rsync (код: $rsync_rc)!"
            do_rollback "file_copy" "$new_owner" "$new_site" "$new_db_name"
            return 1
        fi
    fi

    # Права доступа
    dr chown -R "$new_owner:$new_owner" "$new_site_path"
    dr find "$new_site_path" -type d -exec chmod 755 {} \;
    dr find "$new_site_path" -type f -exec chmod 644 {} \;
    log_success "Файлы скопированы, права установлены"

    # Финальная проверка файлов
    if ! $DRY_RUN; then
        local n_files
        n_files=$(find "$new_site_path" -type f 2>/dev/null | wc -l)
        if [[ $n_files -eq 0 ]]; then
            log_error "После копирования файлов в $new_site_path не оказалось!"
            do_rollback "file_copy" "$new_owner" "$new_site" "$new_db_name"
            return 1
        fi
        local s_files
        s_files=$(find "$src_path" -type f 2>/dev/null | wc -l)
        log_success "Скопировано файлов: $n_files (исходных: $s_files)"
    fi

    # ──────────────────────────────────────────────────────────
    if [[ -n "$TEMP_DUMP_FILE" ]]; then
        log_step "Импорт БД и обновление конфигурации"

        # Импорт дампа
        import_db_dump "$actual_db_name" "$TEMP_DUMP_FILE" || {
            do_rollback "db_import" "$new_owner" "$new_site" "$new_db_name"
            return 1
        }

        # Обновление конфигов CMS
        case $cms in
            wordpress)
                update_wp_config "$new_site_path/wp-config.php" \
                    "$actual_db_name" "$actual_db_user" "$new_db_pass"
                update_wp_urls_in_db "$actual_db_name" "$source_site" "$new_site" "$wp_prefix"
                update_wordpress_domains "$new_site_path" "$source_site" "$new_site" "$php_bin"
                ;;
            dle)
                update_dle_config "$new_site_path" \
                    "$actual_db_name" "$actual_db_user" "$new_db_pass" "$new_site"
                ;;
            joomla)
                update_joomla_config "$new_site_path" \
                    "$actual_db_name" "$actual_db_user" "$new_db_pass" "$new_site"
                ;;
            opencart)
                update_opencart_config "$new_site_path" \
                    "$actual_db_name" "$actual_db_user" "$new_db_pass" "$new_site"
                ;;
        esac
        log_success "Конфигурация CMS обновлена"
    fi

    # ──────────────────────────────────────────────────────────
    # Итоговый отчёт
    show_summary "$CONTROL_PANEL" "$source_site" "$new_site" \
        "$new_site_path" "$new_owner" \
        "${actual_db_name:-}" "${actual_db_user:-}" "${new_db_pass:-}" "$cms"

    # FastPanel: пароль нового пользователя
    if [[ -f /tmp/fp_new_user.info ]]; then
        local fp_user fp_pass
        IFS='|' read -r fp_user fp_pass < /tmp/fp_new_user.info
        printf "  ${YELLOW}${BOLD}Новый пользователь FastPanel:${NC}\n"
        _row "  Логин:"  "$fp_user"
        _row "  Пароль:" "${YELLOW}${BOLD}${fp_pass}${NC}"
        printf "\n"
        rm -f /tmp/fp_new_user.info
    fi

    # Умные рекомендации на основе DNS-проверки
    show_next_steps "$new_site" "$target_ip" "$cms" "$NO_SSL"

    # Дополнительные напоминания
    if [[ "$cms" == "wordpress" ]] && ! command -v wp &>/dev/null; then
        printf "  ${DIM}wp-cli не установлен — для управления WordPress рекомендуется: https://wp-cli.org/${NC}\n\n"
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════
# ОЧИСТКА
# ═══════════════════════════════════════════════════════════════

cleanup() {
    [[ -n "$TEMP_DUMP_FILE" && -f "$TEMP_DUMP_FILE" ]] && rm -f "$TEMP_DUMP_FILE"
    rm -f /tmp/hestia_db.info /tmp/fp_new_user.info
}

trap cleanup EXIT

# ═══════════════════════════════════════════════════════════════
# ТОЧКА ВХОДА
# ═══════════════════════════════════════════════════════════════

main() {
    parse_args "$@"
    show_header

    check_root

    log_step "Инициализация"
    check_os_compatibility
    check_required_utilities
    $DRY_RUN || check_mysql_connection
    detect_control_panel
    check_panel_compatibility

    if [[ -n "$SOURCE_ARG" && -n "$TARGET_ARG" ]]; then
        # ─── Режим аргументов ────────────────────────────────
        local src target
        src=$(to_punycode "$SOURCE_ARG")
        target=$(to_punycode "$TARGET_ARG")
        validate_site_name "$src"
        validate_site_name "$target"

        TOTAL_STEPS=6
        copy_site "$src" "$target"
    else
        # ─── Интерактивный режим ─────────────────────────────
        printf "\n  ${DIM}Подсказка: для быстрого запуска используйте:${NC}\n"
        printf "  ${DIM}  $_SELF source.ru target.ru${NC}\n\n"

        local src target
        read -rp "  Исходный сайт (домен): " src
        [[ -z "$src" ]] && { log_error "Домен не может быть пустым"; exit 1; }
        src=$(to_punycode "$src")
        validate_site_name "$src"

        read -rp "  Новый сайт (домен):    " target
        [[ -z "$target" ]] && { log_error "Домен не может быть пустым"; exit 1; }
        target=$(to_punycode "$target")
        validate_site_name "$target"

        TOTAL_STEPS=6
        copy_site "$src" "$target"
    fi
}

main "$@"
