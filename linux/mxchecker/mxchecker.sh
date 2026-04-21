#!/usr/bin/env bash
# ============================================================================
#  mxchecker — комплексная проверка почтовой инфраструктуры домена
#  Version: 2.0.0
#  Author:  Vladislav Pavlovich (@sysadminctl), ревизия 2
#  License: MIT
#
#  Проверяет:
#    - DNS A/AAAA, MX (с сортировкой по приоритету), PTR (IPv4/IPv6, FCrDNS)
#    - SPF (множественные записи, лимит 10 DNS lookups, +all, ptr)
#    - DKIM (расширенный набор селекторов + пользовательские)
#    - DMARC (p=, sp=, pct=, rua=)
#    - MTA-STS (DNS + фактическая загрузка policy по HTTPS)
#    - TLS-RPT (_smtp._tls)
#    - SMTP-порты 25/465/587 (параллельно, IPv4 + IPv6)
#    - StartTLS/TLS: валидность цепочки, срок действия, SAN/CN
#    - DNSBL (параллельно, с корректной интерпретацией кодов)
#
#  Поведение:
#    - Параллельные DNSBL/порты/TLS-проверки
#    - Таймауты и retry для всех сетевых операций
#    - Автоматическая установка dig в CLI-режиме (с подтверждением)
#    - Цвета в TTY, NO_COLOR / --no-color
#    - --json для машинно-читаемого вывода
#    - Exit codes: 0=OK, 1=warnings, 2=critical, 3=ошибка запуска
# ============================================================================

set -uo pipefail

# ----------------------------------------------------------------------------
# Метаданные
# ----------------------------------------------------------------------------
readonly MXCHECKER_VERSION="2.0.0"
readonly MXCHECKER_AUTHOR="Vladislav Pavlovich"
readonly MXCHECKER_TG="@sysadminctl"

# ----------------------------------------------------------------------------
# Проверка версии bash (нужна 4.0+ из-за ассоциативных массивов и ${var,,})
# ----------------------------------------------------------------------------
if (( BASH_VERSINFO[0] < 4 )); then
    echo "Ошибка: требуется bash 4.0 или новее (текущая: $BASH_VERSION)" >&2
    echo "На macOS установите: brew install bash" >&2
    exit 3
fi

# ----------------------------------------------------------------------------
# Конфигурация (можно переопределить флагами/env)
# ----------------------------------------------------------------------------
DNS_SERVER="${MXCHECKER_DNS:-8.8.8.8}"
DNS_TIMEOUT="${MXCHECKER_DNS_TIMEOUT:-3}"
DNS_TRIES="${MXCHECKER_DNS_TRIES:-2}"
SMTP_TIMEOUT="${MXCHECKER_SMTP_TIMEOUT:-10}"
HTTP_TIMEOUT="${MXCHECKER_HTTP_TIMEOUT:-10}"
MAX_PARALLEL="${MXCHECKER_MAX_PARALLEL:-8}"
CHECK_IPV6=1
AUTO_INSTALL=0           # разрешаем авто-установку только в CLI-режиме
OUTPUT_FORMAT="text"     # text | json
QUIET=0
DOMAIN=""
declare -a EXTRA_DKIM_SELECTORS=()

# ----------------------------------------------------------------------------
# Временная директория + trap для очистки
# ----------------------------------------------------------------------------
TMPDIR_MXC="$(mktemp -d -t mxchecker.XXXXXX 2>/dev/null || mktemp -d)"
cleanup() {
    local rc=$?
    [[ -n "${TMPDIR_MXC:-}" ]] && [[ -d "$TMPDIR_MXC" ]] && rm -rf "$TMPDIR_MXC"
    exit "$rc"
}
trap cleanup EXIT
trap 'echo; echo "Прервано пользователем"; exit 130' INT TERM

# ----------------------------------------------------------------------------
# Возможности окружения
# ----------------------------------------------------------------------------
HAS_DIG=0
HAS_OPENSSL=0
HAS_CURL=0
HAS_NC_BIN=""
HAS_DEV_TCP=0
HAS_JQ=0

# ----------------------------------------------------------------------------
# Состояние проверок (глобальное для итогов/JSON)
# ----------------------------------------------------------------------------
declare -a DNS_A=()
declare -a DNS_AAAA=()
declare -a MX_PRIO=()            # параллельно с MX_HOSTS: приоритет
declare -a MX_HOSTS=()           # отсортировано по приоритету
declare -a MX_IPS_V4=()
declare -a MX_IPS_V6=()
declare -a MX_ALL_IPS=()
declare -A PTR_MAP=()            # ip -> ptr
declare -A PTR_FCRDNS=()         # ip -> 1 (forward-confirmed) | 0

HAS_MX=0
PTR_ANY_MISSING=0
PTR_ANY_MISMATCH=0

HAS_SPF=0
SPF_MULTIPLE=0
SPF_RECORD=""
SPF_ALL_MECH=""
SPF_LOOKUPS=0
SPF_HAS_PTR=0

DKIM_FOUND=0
declare -a DKIM_SELECTORS_FOUND=()

DMARC_FOUND=0
DMARC_POLICY=""
DMARC_SP=""
DMARC_PCT=""
DMARC_RUA=""

HAS_MTA_STS_DNS=0
HAS_MTA_STS_POLICY=0
MTA_STS_MODE=""

HAS_TLS_RPT=0
TLS_RPT_RUA=""

declare -A DNSBL_HIT=()          # "ip|zone" -> code
DNSBL_ANY_HIT=0

declare -A PORT_OPEN=()          # "ip|port" -> 1
PORT25_OPEN=0
PORT465_OPEN=0
PORT587_OPEN=0

declare -A SMTP_HOSTNAME=()      # ip -> hostname из баннера

declare -A TLS_STATUS=()         # "ip|port" -> ok|expired|mismatch|bad
declare -A TLS_EXPIRES=()        # "ip|port" -> days_left

declare -a ISSUES_CRITICAL=()
declare -a ISSUES_WARNING=()

# ----------------------------------------------------------------------------
# Цвета / вывод
# ----------------------------------------------------------------------------
setup_colors() {
    if [[ "$OUTPUT_FORMAT" == "json" ]] \
        || [[ -n "${NO_COLOR:-}" ]] \
        || [[ ! -t 1 ]]; then
        RED=""; GREEN=""; YELLOW=""; CYAN=""; BLUE=""; MAGENTA=""; NC=""; BOLD=""
    else
        RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"
        CYAN="\033[36m"; BLUE="\033[34m"; MAGENTA="\033[35m"
        NC="\033[0m"; BOLD="\033[1m"
    fi
}

# Вывод текстовых сообщений подавляется в JSON-режиме и с --quiet.
_out() {
    [[ "$OUTPUT_FORMAT" == "json" ]] && return
    [[ "$QUIET" -eq 1 ]] && return
    echo -e "$@"
}

step() { _out "${BLUE}[>]${NC} $1"; }
ok()   { _out "${GREEN}[OK]${NC} $1"; }
warn() { _out "${YELLOW}[!!]${NC} $1"; }
fail() { _out "${RED}[XX]${NC} $1"; }
info() { _out "    $1"; }

add_critical() { ISSUES_CRITICAL+=("$1"); }
add_warning()  { ISSUES_WARNING+=("$1"); }

# Лог в файл, если явно задан через --log
MXC_LOG=""
log_action() {
    [[ -z "$MXC_LOG" ]] && return
    {
        printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$MXC_LOG"
    } 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# Валидация
# ----------------------------------------------------------------------------
validate_domain() {
    local domain="$1"
    # FQDN из LDH-меток, без пустых меток, без завершающей точки для простоты
    if [[ ! "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]; then
        return 1
    fi
    # Длина в сумме не более 253
    [[ ${#domain} -le 253 ]]
}

is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_ipv6() { [[ "$1" == *:* ]] && [[ ! "$1" =~ [^0-9a-fA-F:.] ]]; }

# ----------------------------------------------------------------------------
# Детект менеджера пакетов (для опциональной установки dig)
# ----------------------------------------------------------------------------
detect_pkg_manager() {
    # Возвращаем "pm:package" или пустую строку
    if command -v apt-get >/dev/null 2>&1; then echo "apt-get:dnsutils"
    elif command -v dnf >/dev/null 2>&1; then echo "dnf:bind-utils"
    elif command -v yum >/dev/null 2>&1; then echo "yum:bind-utils"
    elif command -v apk >/dev/null 2>&1; then echo "apk:bind-tools"
    elif command -v pacman >/dev/null 2>&1; then echo "pacman:bind"
    elif command -v zypper >/dev/null 2>&1; then echo "zypper:bind-utils"
    elif command -v brew >/dev/null 2>&1; then echo "brew:bind"
    fi
}

install_dig() {
    local pm_info pm pkg sudo_cmd=""
    pm_info=$(detect_pkg_manager)
    if [[ -z "$pm_info" ]]; then
        fail "Не удалось определить менеджер пакетов. Установите dig (bind-utils / dnsutils) вручную."
        return 1
    fi
    pm="${pm_info%:*}"
    pkg="${pm_info#*:}"

    warn "Не найдена утилита dig. Требуется установить пакет: ${pm} → ${pkg}"
    read -rp "Установить автоматически? [y/N] " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { fail "Установка отменена."; return 1; }

    [[ "${EUID:-$(id -u)}" -ne 0 ]] && sudo_cmd="sudo"

    case "$pm" in
        apt-get) $sudo_cmd apt-get update -qq && $sudo_cmd apt-get install -y "$pkg" ;;
        dnf|yum) $sudo_cmd "$pm" install -y "$pkg" ;;
        apk)     $sudo_cmd apk add --no-cache "$pkg" ;;
        pacman)  $sudo_cmd pacman -S --noconfirm "$pkg" ;;
        zypper)  $sudo_cmd zypper -n install "$pkg" ;;
        brew)    brew install "$pkg" ;;
        *) return 1 ;;
    esac
}

# ----------------------------------------------------------------------------
# Проверка зависимостей
# ----------------------------------------------------------------------------
check_dependencies() {
    step "Проверяю зависимости..."

    command -v dig     >/dev/null 2>&1 && HAS_DIG=1
    command -v openssl >/dev/null 2>&1 && HAS_OPENSSL=1
    command -v curl    >/dev/null 2>&1 && HAS_CURL=1
    command -v jq      >/dev/null 2>&1 && HAS_JQ=1

    for c in nc ncat netcat; do
        if command -v "$c" >/dev/null 2>&1; then
            HAS_NC_BIN="$c"
            break
        fi
    done

    # /dev/tcp — это функция bash, а не файл
    if ( exec 3<>/dev/tcp/127.0.0.1/0 ) 2>/dev/null; then
        HAS_DEV_TCP=1
    else
        # Отсутствие 127.0.0.1:0 ещё не значит, что /dev/tcp не работает.
        # Проверяем синтаксис через help:
        if help | grep -q '/dev/tcp' 2>/dev/null; then
            HAS_DEV_TCP=1
        fi
    fi

    # dig — основа. В CLI-режиме пробуем установить.
    if [[ "$HAS_DIG" -eq 0 ]]; then
        if [[ "$AUTO_INSTALL" -eq 1 ]]; then
            if install_dig; then
                command -v dig >/dev/null 2>&1 && HAS_DIG=1
            fi
        fi
        if [[ "$HAS_DIG" -eq 0 ]]; then
            fail "dig не найден — DNS-проверки невозможны."
            info "Установите bind-utils / dnsutils вашим пакетным менеджером."
            exit 3
        fi
    fi

    ok "dig найден."
    if [[ "$HAS_OPENSSL" -eq 1 ]]; then ok "openssl найден."
    else warn "openssl не найден — TLS/StartTLS проверки будут пропущены."; fi
    if [[ "$HAS_CURL" -eq 1 ]]; then ok "curl найден."
    else warn "curl не найден — MTA-STS policy не будет загружаться."; fi
    if [[ -n "$HAS_NC_BIN" ]]; then ok "netcat: $HAS_NC_BIN"
    elif [[ "$HAS_DEV_TCP" -eq 1 ]]; then ok "bash /dev/tcp доступен (fallback для портов)."
    else warn "Нет ни nc, ни /dev/tcp — проверка SMTP-портов ограничена."; fi
    _out ""
}

# ----------------------------------------------------------------------------
# DNS wrappers
# ----------------------------------------------------------------------------
# dig с таймаутами и retry
_dig() {
    dig +time="$DNS_TIMEOUT" +tries="$DNS_TRIES" +short @"$DNS_SERVER" "$@" 2>/dev/null
}

dns_q() {
    # dns_q <name> <type>
    _dig "$1" "$2"
}

dns_txt() {
    # TXT: dig +short возвращает строки в кавычках, возможно много строк в одной RR.
    # Склеим многострочные части внутри одной RR (объединённые пробелами dig'ом уже
    # отдал как один ответ со вставленным "" — удаляем шов «"" »).
    _dig "$1" TXT | sed 's/" "//g; s/^"//; s/"$//'
}

dns_ptr() {
    # dns_ptr <ip>  — работает и для IPv4, и для IPv6
    _dig -x "$1" | sed 's/\.$//'
}

# ----------------------------------------------------------------------------
# Проверка A/AAAA
# ----------------------------------------------------------------------------
check_dns_basic() {
    local domain="$1"
    step "DNS: A/AAAA записи домена $domain"

    mapfile -t DNS_A < <(dns_q "$domain" A | grep -E '^[0-9.]+$')
    if [[ "$CHECK_IPV6" -eq 1 ]]; then
        mapfile -t DNS_AAAA < <(dns_q "$domain" AAAA | grep -E '^[0-9a-fA-F:]+$')
    fi

    if [[ ${#DNS_A[@]} -eq 0 && ${#DNS_AAAA[@]} -eq 0 ]]; then
        fail "Нет ни A, ни AAAA записей."
    else
        if [[ ${#DNS_A[@]} -gt 0 ]]; then
            ok "A-записи:"
            printf '   - %s\n' "${DNS_A[@]}" | sed 's/^/   - /' >/dev/null
            for ip in "${DNS_A[@]}"; do info "- $ip"; done
        else
            warn "A-записи отсутствуют."
        fi
        if [[ "$CHECK_IPV6" -eq 1 ]]; then
            if [[ ${#DNS_AAAA[@]} -gt 0 ]]; then
                ok "AAAA-записи:"
                for ip in "${DNS_AAAA[@]}"; do info "- $ip"; done
            else
                info "AAAA-записи отсутствуют (IPv6 не настроен для домена)."
            fi
        fi
    fi
    _out ""
}

# ----------------------------------------------------------------------------
# Проверка MX + PTR (IPv4 и IPv6, с сортировкой по приоритету)
# ----------------------------------------------------------------------------
check_mx_and_ptr() {
    local domain="$1"
    step "DNS: MX-записи домена $domain (сортировка по приоритету)"

    local raw
    raw=$(_dig "$domain" MX)
    if [[ -z "$raw" ]]; then
        warn "MX-записи не найдены — почта принимается напрямую на A/AAAA (или домен не принимает почту)."
        _out ""
        return
    fi

    HAS_MX=1

    # Формат строк: "10 mx.example.com."
    # Сортируем по первому полю (приоритет, число)
    local sorted
    sorted=$(echo "$raw" | sort -n -k1,1)

    MX_PRIO=()
    MX_HOSTS=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local prio host
        prio="${line%% *}"
        host="${line##* }"
        host="${host%.}"
        [[ -z "$host" ]] && continue
        MX_PRIO+=("$prio")
        MX_HOSTS+=("$host")
    done <<<"$sorted"

    if [[ ${#MX_HOSTS[@]} -eq 0 ]]; then
        warn "MX вернулись, но распарсить не удалось."
        _out ""
        return
    fi

    _out "   Найдено MX: ${#MX_HOSTS[@]}"
    local i
    for i in "${!MX_HOSTS[@]}"; do
        info "${MX_PRIO[$i]}  ${MX_HOSTS[$i]}"
    done
    _out ""

    step "DNS: IP и PTR для MX-хостов"

    MX_IPS_V4=()
    MX_IPS_V6=()
    MX_ALL_IPS=()

    for mx in "${MX_HOSTS[@]}"; do
        _out "${CYAN}[*] MX: ${BOLD}${mx}${NC}"
        local ipv4s ipv6s
        ipv4s=$(dns_q "$mx" A)
        if [[ "$CHECK_IPV6" -eq 1 ]]; then
            ipv6s=$(dns_q "$mx" AAAA)
        else
            ipv6s=""
        fi

        if [[ -z "$ipv4s" && -z "$ipv6s" ]]; then
            warn "   У $mx нет ни A, ни AAAA записей!"
            add_warning "MX $mx не резолвится ни в IPv4, ни в IPv6"
            _out ""
            continue
        fi

        # IPv4
        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            is_ipv4 "$ip" || continue
            MX_IPS_V4+=("$ip")
            MX_ALL_IPS+=("$ip")
            _check_one_ptr "$ip" "$mx"
        done <<<"$ipv4s"

        # IPv6
        if [[ "$CHECK_IPV6" -eq 1 ]]; then
            while IFS= read -r ip; do
                [[ -z "$ip" ]] && continue
                is_ipv6 "$ip" || continue
                MX_IPS_V6+=("$ip")
                MX_ALL_IPS+=("$ip")
                _check_one_ptr "$ip" "$mx"
            done <<<"$ipv6s"
        fi

        _out ""
    done
}

_check_one_ptr() {
    local ip="$1" mx="$2"
    _out "   IP: $ip"

    local ptr
    ptr=$(dns_ptr "$ip")
    if [[ -z "$ptr" ]]; then
        warn "   PTR-запись отсутствует"
        PTR_ANY_MISSING=1
        PTR_FCRDNS["$ip"]=0
        return
    fi

    PTR_MAP["$ip"]="$ptr"

    # Forward-confirmed: запросим прямую запись PTR-hostname и посмотрим, есть ли $ip
    local ptr_fwd rtype
    if is_ipv4 "$ip"; then rtype="A"; else rtype="AAAA"; fi
    ptr_fwd=$(dns_q "$ptr" "$rtype")

    if echo "$ptr_fwd" | grep -qxF "$ip"; then
        ok "   PTR: $ptr → $ip (forward-confirmed ✓)"
        PTR_FCRDNS["$ip"]=1
    else
        warn "   PTR: $ptr — forward-confirm не прошёл (A/AAAA PTR не содержит $ip)"
        PTR_ANY_MISMATCH=1
        PTR_FCRDNS["$ip"]=0
    fi
}

# ----------------------------------------------------------------------------
# SPF: множественные записи, лимит 10 lookups, ptr deprecated
# ----------------------------------------------------------------------------
check_spf() {
    local domain="$1"
    step "DNS: SPF для $domain"

    local all_txt
    all_txt=$(dns_txt "$domain")

    local -a spf_records=()
    while IFS= read -r line; do
        # ищем записи, начинающиеся (после возможных пробелов) с v=spf1
        local lc="${line,,}"
        if [[ "${lc#v=spf1}" != "$lc" ]] || [[ "${lc// v=spf1/}" != "$lc" ]]; then
            spf_records+=("$line")
        fi
    done <<<"$all_txt"

    if [[ ${#spf_records[@]} -eq 0 ]]; then
        warn "SPF-запись не найдена."
        add_critical "SPF не настроен (рекомендуется: v=spf1 mx -all)"
        _out ""
        return
    fi

    if [[ ${#spf_records[@]} -gt 1 ]]; then
        SPF_MULTIPLE=1
        fail "Обнаружено несколько SPF-записей (${#spf_records[@]}) — по RFC 7208 это permerror!"
        for r in "${spf_records[@]}"; do info "- $r"; done
        add_critical "Несколько SPF-записей — RFC 7208 permerror, SPF-проверки у получателей сломаются"
    fi

    HAS_SPF=1
    SPF_RECORD="${spf_records[0]}"
    ok "SPF найден:"
    info "$SPF_RECORD"

    # Окончание SPF
    if [[ "$SPF_RECORD" =~ (^|[[:space:]])-all($|[[:space:]]) ]]; then
        SPF_ALL_MECH="-all"
        ok "SPF: -all (strict) — максимальная строгость."
    elif [[ "$SPF_RECORD" =~ (^|[[:space:]])\~all($|[[:space:]]) ]]; then
        SPF_ALL_MECH="~all"
        ok "SPF: ~all (softfail)."
    elif [[ "$SPF_RECORD" =~ (^|[[:space:]])\?all($|[[:space:]]) ]]; then
        SPF_ALL_MECH="?all"
        warn "SPF: ?all (neutral) — фактически ничего не даёт."
        add_warning "SPF заканчивается на ?all (neutral), защиты нет"
    elif [[ "$SPF_RECORD" =~ (^|[[:space:]])\+all($|[[:space:]]) ]]; then
        SPF_ALL_MECH="+all"
        fail "SPF: +all — разрешает отправку с ЛЮБОГО хоста."
        add_critical "SPF содержит +all (разрешает всё)"
    else
        SPF_ALL_MECH=""
        warn "SPF не содержит явного окончания (-all/~all/?all/+all)."
        add_warning "SPF без финального механизма (neutral по умолчанию)"
    fi

    # Подсчёт DNS lookups (первый уровень, без рекурсии по include)
    # Считаем: include, a[:], mx[:], exists, redirect, ptr
    local token lookups=0 has_ptr=0
    for token in $SPF_RECORD; do
        local lc="${token,,}"
        case "$lc" in
            include:*|exists:*|redirect=*) ((lookups++)) ;;
            a|a:*|mx|mx:*)                ((lookups++)) ;;
            ptr|ptr:*)                    ((lookups++)); has_ptr=1 ;;
        esac
    done
    SPF_LOOKUPS="$lookups"
    SPF_HAS_PTR="$has_ptr"

    info "SPF DNS lookups (первый уровень): $lookups / 10"
    if (( lookups > 10 )); then
        fail "SPF: превышен лимит 10 DNS lookups (RFC 7208) — permerror."
        add_critical "SPF превышает лимит 10 DNS lookups"
    elif (( lookups > 8 )); then
        warn "SPF близок к лимиту 10 lookups — include-цепочки могут добавить ещё."
        add_warning "SPF $lookups/10 lookups — близко к лимиту"
    fi

    if [[ "$has_ptr" -eq 1 ]]; then
        warn "SPF использует механизм ptr — он deprecated (RFC 7208 §5.5)."
        add_warning "SPF использует устаревший механизм ptr"
    fi

    _out ""
}

# ----------------------------------------------------------------------------
# DKIM: перебор популярных селекторов + пользовательские
# ----------------------------------------------------------------------------
check_dkim() {
    local domain="$1"
    step "DNS: DKIM (популярные селекторы)"

    # Селекторы отсортированы по популярности
    local -a selectors=(
        # Общие
        default dkim mail email s1 s2 dkim1 dkim2 key1 key2 mx
        # Microsoft 365
        selector1 selector2
        # Google Workspace
        google
        # Яндекс 360 / Mail.ru / VK
        yandex mailru vk
        # SendGrid / Mailchimp / Mandrill / Mailgun / Postmark
        smtpapi k1 k2 k3 pic krs mta pm
        # Amazon SES / Zoho / ProtonMail / SparkPost
        amazonses zoho protonmail protonmail2 protonmail3 scph0922
        # MailerLite / Brevo (Sendinblue) / ActiveCampaign
        ml mail1 mail2
        # Дополнительные частые
        dkrnt fm1 fm2 fm3
    )

    # Добавим пользовательские
    if [[ ${#EXTRA_DKIM_SELECTORS[@]} -gt 0 ]]; then
        selectors+=("${EXTRA_DKIM_SELECTORS[@]}")
    fi

    info "Перебор: ${#selectors[@]} селекторов (общий список + пользовательские)"
    _out ""

    local sel name txt
    for sel in "${selectors[@]}"; do
        name="${sel}._domainkey.${domain}"
        txt=$(dns_txt "$name")
        if echo "$txt" | grep -qiE '(v=DKIM1|k=rsa|p=[A-Za-z0-9+/])'; then
            DKIM_FOUND=1
            DKIM_SELECTORS_FOUND+=("$sel")
            ok "DKIM найден: селектор ${BOLD}${sel}${NC}"
            # покажем усечённо, ключи бывают длинные
            local short="${txt:0:120}"
            [[ ${#txt} -gt 120 ]] && short="${short}..."
            info "$short"
        fi
    done

    if [[ "$DKIM_FOUND" -eq 0 ]]; then
        warn "DKIM не найден среди проверенных селекторов."
        info "Не равнозначно 'DKIM не настроен' — провайдер мог использовать кастомный селектор."
        info "Точнее всего селектор виден в заголовке DKIM-Signature у реального письма."
        info "Передать свой селектор: --dkim-selector=имя (можно несколько раз)"
        add_warning "DKIM не найден по типичным селекторам (может быть кастомный)"
    fi
    _out ""
}

# ----------------------------------------------------------------------------
# DMARC: разбор p, sp, pct, rua
# ----------------------------------------------------------------------------
check_dmarc() {
    local domain="$1"
    step "DNS: DMARC"

    local txt
    txt=$(dns_txt "_dmarc.${domain}")

    local dmarc_line=""
    while IFS= read -r line; do
        if [[ "${line,,}" =~ ^[[:space:]]*v=dmarc1 ]]; then
            dmarc_line="$line"
            break
        fi
    done <<<"$txt"

    if [[ -z "$dmarc_line" ]]; then
        warn "DMARC-запись не найдена."
        add_critical "DMARC не настроен"
        info "Рекомендация для старта:"
        info "  _dmarc.${domain}  IN TXT  \"v=DMARC1; p=none; rua=mailto:dmarc@${domain}\""
        _out ""
        return
    fi

    DMARC_FOUND=1
    ok "DMARC найден:"
    info "$dmarc_line"

    # Распарсим теги
    local pair key val
    while IFS=';' read -r -d ';' pair || [[ -n "$pair" ]]; do
        pair="${pair#"${pair%%[![:space:]]*}"}"  # ltrim
        pair="${pair%"${pair##*[![:space:]]}"}"  # rtrim
        [[ -z "$pair" ]] && continue
        key="${pair%%=*}"
        val="${pair#*=}"
        key="${key,,}"
        key="${key// /}"
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
        case "$key" in
            p)   DMARC_POLICY="${val,,}" ;;
            sp)  DMARC_SP="${val,,}" ;;
            pct) DMARC_PCT="$val" ;;
            rua) DMARC_RUA="$val" ;;
        esac
    done <<<"${dmarc_line};"

    case "$DMARC_POLICY" in
        reject|quarantine) ok "DMARC p=$DMARC_POLICY (строго)." ;;
        none)              warn "DMARC p=none — только мониторинг, без блокировки."
                           add_warning "DMARC p=none — только мониторинг" ;;
        *) warn "DMARC: неизвестная политика p='$DMARC_POLICY'" ;;
    esac

    if [[ -n "$DMARC_PCT" ]] && [[ "$DMARC_PCT" != "100" ]]; then
        warn "DMARC pct=$DMARC_PCT — политика применяется только к части писем."
        add_warning "DMARC pct=$DMARC_PCT (<100)"
    fi

    if [[ -n "$DMARC_SP" ]]; then
        info "Субдомены: sp=$DMARC_SP"
        if [[ "$DMARC_SP" == "none" ]] && [[ "$DMARC_POLICY" =~ ^(reject|quarantine)$ ]]; then
            warn "sp=none при строгом p=$DMARC_POLICY — субдомены не защищены."
            add_warning "DMARC sp=none ослабляет защиту субдоменов"
        fi
    else
        info "sp не задан — субдомены наследуют p=${DMARC_POLICY}."
    fi

    if [[ -z "$DMARC_RUA" ]]; then
        warn "rua= не задан — нет отчётов о состоянии DMARC."
        add_warning "DMARC без rua= (нет отчётов)"
    fi
    _out ""
}

# ----------------------------------------------------------------------------
# MTA-STS: DNS-запись + фактическая загрузка policy по HTTPS
# ----------------------------------------------------------------------------
check_mta_sts() {
    local domain="$1"
    step "DNS + HTTPS: MTA-STS"

    local txt
    txt=$(dns_txt "_mta-sts.${domain}")
    if echo "$txt" | grep -qi 'v=STSv1'; then
        HAS_MTA_STS_DNS=1
        ok "MTA-STS TXT-запись обнаружена:"
        info "$txt"
    else
        warn "MTA-STS TXT-запись не найдена."
        add_warning "MTA-STS не настроен (защита от StartTLS-downgrade отсутствует)"
        _out ""
        return
    fi

    if [[ "$HAS_CURL" -eq 0 ]]; then
        warn "curl не найден — policy по HTTPS не проверяю."
        _out ""
        return
    fi

    local url="https://mta-sts.${domain}/.well-known/mta-sts.txt"
    info "Загружаю policy: $url"
    local policy
    policy=$(curl -sSfL --max-time "$HTTP_TIMEOUT" --retry 1 \
            -H "User-Agent: mxchecker/${MXCHECKER_VERSION}" \
            "$url" 2>/dev/null || true)

    if [[ -z "$policy" ]]; then
        fail "MTA-STS policy недоступна по HTTPS (DNS есть, но файла нет)."
        add_critical "MTA-STS DNS есть, но policy по HTTPS недоступна (сломанная конфигурация)"
        _out ""
        return
    fi

    if echo "$policy" | grep -qE '^version:[[:space:]]*STSv1'; then
        HAS_MTA_STS_POLICY=1
        MTA_STS_MODE=$(echo "$policy" | awk -F: '/^mode:/ {gsub(/[[:space:]]/,"",$2); print $2; exit}')
        ok "MTA-STS policy загружена, mode=${MTA_STS_MODE}"
        case "$MTA_STS_MODE" in
            enforce) ok "MTA-STS включён в режиме enforce." ;;
            testing) warn "MTA-STS в режиме testing — нарушения логируются, но не блокируют."
                     add_warning "MTA-STS mode=testing (не блокирует)" ;;
            none)    warn "MTA-STS mode=none — политика неактивна."
                     add_warning "MTA-STS mode=none" ;;
            *)       warn "MTA-STS: неизвестный mode=$MTA_STS_MODE" ;;
        esac
    else
        fail "Содержимое policy не соответствует формату MTA-STS."
        add_critical "MTA-STS policy битая"
    fi
    _out ""
}

# ----------------------------------------------------------------------------
# TLS-RPT
# ----------------------------------------------------------------------------
check_tls_rpt() {
    local domain="$1"
    step "DNS: TLS-RPT (_smtp._tls)"

    local txt
    txt=$(dns_txt "_smtp._tls.${domain}")
    if echo "$txt" | grep -qi 'v=TLSRPTv1'; then
        HAS_TLS_RPT=1
        ok "TLS-RPT настроен:"
        info "$txt"
        TLS_RPT_RUA=$(echo "$txt" | sed -n 's/.*rua=\([^;]*\).*/\1/p')
    else
        info "TLS-RPT не настроен (не критично, но полезно для мониторинга TLS-ошибок)."
    fi
    _out ""
}

# ----------------------------------------------------------------------------
# SMTP-порты: параллельное сканирование 25/465/587 для всех MX IP
# ----------------------------------------------------------------------------
check_smtp_ports() {
    if [[ ${#MX_ALL_IPS[@]} -eq 0 ]]; then
        warn "Нет IP у MX — пропускаю проверку SMTP-портов."
        _out ""
        return
    fi

    step "SMTP: сканирование портов 25/465/587 (параллельно)"

    local -a pids=()
    local ip port
    local inflight=0

    for ip in "${MX_ALL_IPS[@]}"; do
        for port in 25 465 587; do
            _check_port_async "$ip" "$port" &
            pids+=($!)
            ((inflight++))
            # Простой регулятор параллелизма
            if (( inflight >= MAX_PARALLEL )); then
                wait -n 2>/dev/null || wait "${pids[0]}" 2>/dev/null
                ((inflight--))
            fi
        done
    done
    wait 2>/dev/null

    # Сбор результатов
    for ip in "${MX_ALL_IPS[@]}"; do
        _out "${CYAN}[*] MX IP: ${BOLD}${ip}${NC}"
        local -a open=() closed=()
        for port in 25 465 587; do
            local rfile="${TMPDIR_MXC}/port_$(safe_fname "$ip")_${port}"
            if [[ -s "$rfile" ]] && [[ "$(cat "$rfile")" == "open" ]]; then
                open+=("$port")
                PORT_OPEN["${ip}|${port}"]=1
                case "$port" in
                    25) PORT25_OPEN=1 ;;
                    465) PORT465_OPEN=1 ;;
                    587) PORT587_OPEN=1 ;;
                esac
            else
                closed+=("$port")
            fi
        done
        if [[ ${#open[@]} -eq 3 ]]; then
            ok "   Открыты все порты: 25, 465, 587."
        elif [[ ${#open[@]} -gt 0 ]]; then
            warn "   Открыты: ${open[*]}; закрыты/недоступны: ${closed[*]}."
        else
            fail "   Все порты 25/465/587 недоступны."
        fi
    done
    _out ""
}

_check_port_async() {
    local ip="$1" port="$2"
    local rfile="${TMPDIR_MXC}/port_$(safe_fname "$ip")_${port}"
    local ok=0

    # Для IPv6 /dev/tcp хочет чистый адрес без скобок (bash 5+)
    if [[ -n "$HAS_NC_BIN" ]]; then
        if "$HAS_NC_BIN" -z -w "$SMTP_TIMEOUT" "$ip" "$port" >/dev/null 2>&1; then
            ok=1
        fi
    fi

    if [[ "$ok" -eq 0 ]] && [[ "$HAS_DEV_TCP" -eq 1 ]]; then
        if timeout "$SMTP_TIMEOUT" bash -c "exec 3<>/dev/tcp/${ip}/${port}" 2>/dev/null; then
            ok=1
        fi
    fi

    if [[ "$ok" -eq 1 ]]; then
        echo "open" > "$rfile"
    else
        echo "closed" > "$rfile"
    fi
}

safe_fname() {
    # Приводим IP к строке, безопасной для имени файла (двоеточия и точки → подчёркивание)
    local s="$1"
    echo "${s//[:.]/_}"
}

# ----------------------------------------------------------------------------
# SMTP банер — аккуратно, с достаточным таймаутом
# ----------------------------------------------------------------------------
check_smtp_banners() {
    if [[ "$PORT25_OPEN" -eq 0 ]]; then
        return
    fi
    step "SMTP: чтение баннеров (порт 25)"

    for ip in "${MX_ALL_IPS[@]}"; do
        [[ -z "${PORT_OPEN[${ip}|25]:-}" ]] && continue
        local banner
        banner=$(_read_smtp_banner "$ip" 25)
        if [[ -n "$banner" ]]; then
            _out "${CYAN}[*] ${ip}:${NC} ${banner}"
            local host
            host=$(echo "$banner" | awk '{print $2}')
            if [[ -n "$host" ]]; then
                SMTP_HOSTNAME["$ip"]="$host"
            fi
        else
            info "${ip}: баннер не получен (возможно greylisting / taрpit)."
        fi
    done
    _out ""
}

_read_smtp_banner() {
    local ip="$1" port="$2"
    local banner=""

    # Через /dev/tcp — наиболее надёжно, без проблем с разными вариантами nc
    if [[ "$HAS_DEV_TCP" -eq 1 ]]; then
        banner=$(
            timeout "$SMTP_TIMEOUT" bash -c '
                exec 3<>/dev/tcp/'"$ip"'/'"$port"' || exit 1
                # Читаем первую строку 220 с таймаутом
                IFS= read -r -t 8 line <&3 || true
                printf "QUIT\r\n" >&3
                exec 3>&- 3<&-
                echo "$line"
            ' 2>/dev/null | tr -d '\r'
        )
    elif [[ -n "$HAS_NC_BIN" ]]; then
        banner=$(
            { sleep 3; printf 'QUIT\r\n'; sleep 1; } | \
            timeout "$SMTP_TIMEOUT" "$HAS_NC_BIN" -w "$SMTP_TIMEOUT" "$ip" "$port" 2>/dev/null | \
            grep -m1 '^220 ' | tr -d '\r'
        )
    fi

    echo "$banner"
}

# ----------------------------------------------------------------------------
# StartTLS/TLS: валидация цепочки, срок действия, CN/SAN
# ----------------------------------------------------------------------------
check_starttls() {
    if [[ "$HAS_OPENSSL" -eq 0 ]]; then return; fi
    if [[ ${#MX_ALL_IPS[@]} -eq 0 ]]; then return; fi

    step "SMTP/TLS: проверка StartTLS и сертификатов"

    for ip in "${MX_ALL_IPS[@]}"; do
        _out "${CYAN}[*] MX IP: ${BOLD}${ip}${NC}"

        # Имя для SNI и сверки — hostname MX, к которому принадлежит IP
        local sni
        sni=$(_mx_hostname_for_ip "$ip")
        [[ -z "$sni" ]] && sni="${PTR_MAP[$ip]:-}"

        local port
        for port in 25 465 587; do
            [[ -z "${PORT_OPEN[${ip}|${port}]:-}" ]] && continue
            _check_tls_single "$ip" "$port" "$sni"
        done
        _out ""
    done
}

_mx_hostname_for_ip() {
    local ip="$1"
    local mx
    for mx in "${MX_HOSTS[@]}"; do
        local ips
        ips=$(dns_q "$mx" A; dns_q "$mx" AAAA)
        if echo "$ips" | grep -qxF "$ip"; then
            echo "$mx"
            return
        fi
    done
}

_check_tls_single() {
    local ip="$1" port="$2" sni="$3"
    local starttls_flag=()
    local connect_host="$ip"

    # Для IPv6 openssl требует [::1]:port
    if is_ipv6 "$ip"; then
        connect_host="[${ip}]"
    fi

    if [[ "$port" == "25" || "$port" == "587" ]]; then
        starttls_flag=(-starttls smtp)
    fi

    local out
    out=$(printf 'EHLO mxchecker\r\nQUIT\r\n' | \
        timeout "$SMTP_TIMEOUT" openssl s_client \
            -connect "${connect_host}:${port}" \
            ${sni:+-servername "$sni"} \
            "${starttls_flag[@]}" \
            -crlf 2>/dev/null)

    if [[ -z "$out" ]]; then
        fail "   порт $port: TLS-handshake не удался."
        TLS_STATUS["${ip}|${port}"]="bad"
        add_critical "TLS handshake не проходит на ${ip}:${port}"
        return
    fi

    # Проверка цепочки
    local verify
    verify=$(echo "$out" | grep -m1 '^Verify return code:')

    # Разбор сертификата
    local cert_block
    cert_block=$(echo "$out" | awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/')

    local not_after subject_san days_left=""
    if [[ -n "$cert_block" ]]; then
        not_after=$(echo "$cert_block" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
        subject_san=$(echo "$cert_block" | openssl x509 -noout -ext subjectAltName 2>/dev/null | grep -Eo 'DNS:[^,]+' | sed 's/^DNS://; s/[[:space:]]//g')
        if [[ -z "$subject_san" ]]; then
            # fallback на CN
            subject_san=$(echo "$cert_block" | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*CN[[:space:]]*=[[:space:]]*\([^,\/]*\).*/\1/p')
        fi

        if [[ -n "$not_after" ]]; then
            local end_ts now_ts
            end_ts=$(date -d "$not_after" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$not_after" +%s 2>/dev/null || echo "")
            if [[ -n "$end_ts" ]]; then
                now_ts=$(date +%s)
                days_left=$(( (end_ts - now_ts) / 86400 ))
                TLS_EXPIRES["${ip}|${port}"]="$days_left"
            fi
        fi
    fi

    local chain_ok=0
    if echo "$verify" | grep -qi 'Verify return code: 0 (ok)'; then
        chain_ok=1
    fi

    # Сверка SNI/hostname
    local name_match=0
    if [[ -n "$sni" && -n "$subject_san" ]]; then
        while IFS= read -r san; do
            [[ -z "$san" ]] && continue
            if [[ "$san" == "$sni" ]]; then
                name_match=1; break
            fi
            # wildcard: *.example.com
            if [[ "$san" == \*.* ]]; then
                local suf="${san#\*}"
                if [[ "$sni" == *"$suf" ]]; then
                    name_match=1; break
                fi
            fi
        done <<<"$subject_san"
    fi

    local status="ok" msg=""
    if [[ "$chain_ok" -eq 0 ]]; then
        status="bad"
        msg="цепочка не валидна"
    fi
    if [[ -n "$days_left" ]] && (( days_left < 0 )); then
        status="expired"
        msg="сертификат ПРОСРОЧЕН ($days_left дней)"
    elif [[ -n "$days_left" ]] && (( days_left < 14 )); then
        [[ "$status" == "ok" ]] && status="warn"
        msg="${msg:+$msg; }истекает через $days_left дн."
    fi
    if [[ -n "$sni" ]] && [[ -n "$subject_san" ]] && [[ "$name_match" -eq 0 ]] && [[ "$chain_ok" -eq 1 ]]; then
        [[ "$status" == "ok" ]] && status="mismatch"
        msg="${msg:+$msg; }имя $sni не совпадает с SAN ($subject_san)"
    fi

    TLS_STATUS["${ip}|${port}"]="$status"

    case "$status" in
        ok)
            if [[ -n "$days_left" ]]; then
                ok "   порт $port: TLS OK (осталось $days_left дн.)"
            else
                ok "   порт $port: TLS OK"
            fi
            ;;
        warn)
            warn "   порт $port: $msg"
            add_warning "TLS ${ip}:${port}: $msg"
            ;;
        mismatch)
            warn "   порт $port: $msg"
            add_warning "TLS ${ip}:${port}: hostname mismatch"
            ;;
        expired)
            fail "   порт $port: $msg"
            add_critical "TLS ${ip}:${port}: просроченный сертификат"
            ;;
        bad)
            fail "   порт $port: $msg"
            add_critical "TLS ${ip}:${port}: невалидная цепочка"
            ;;
    esac
}

# ----------------------------------------------------------------------------
# DNSBL: параллельная проверка, корректная интерпретация кодов
# ----------------------------------------------------------------------------
check_dnsbl() {
    if [[ ${#MX_IPS_V4[@]} -eq 0 ]]; then
        info "Нет IPv4 MX — DNSBL проверка пропущена (большинство списков только IPv4)."
        _out ""
        return
    fi

    step "DNSBL: параллельная проверка IPv4 MX"

    local -a lists=(
        "zen.spamhaus.org"
        "bl.spamcop.net"
        "b.barracudacentral.org"
        "dnsbl.sorbs.net"
        "psbl.surriel.com"
    )

    # Диспетчер параллельных задач
    local -a pids=()
    local inflight=0
    local ip zone
    for ip in "${MX_IPS_V4[@]}"; do
        for zone in "${lists[@]}"; do
            _check_dnsbl_one "$ip" "$zone" &
            pids+=($!)
            ((inflight++))
            if (( inflight >= MAX_PARALLEL )); then
                wait -n 2>/dev/null || wait "${pids[0]}" 2>/dev/null
                ((inflight--))
            fi
        done
    done
    wait 2>/dev/null

    # Сбор результатов
    for ip in "${MX_IPS_V4[@]}"; do
        _out "${CYAN}[*] ${ip}${NC}"
        local any=0
        for zone in "${lists[@]}"; do
            local rfile="${TMPDIR_MXC}/dnsbl_$(safe_fname "$ip")_$(safe_fname "$zone")"
            [[ ! -s "$rfile" ]] && continue
            local code desc
            code=$(head -1 "$rfile")
            [[ "$code" == "none" ]] && continue
            desc=$(_dnsbl_decode "$zone" "$code")
            any=1
            DNSBL_HIT["${ip}|${zone}"]="$code"
            if [[ "$desc" == *"PBL"* ]]; then
                # PBL — это «это dynamic IP range», а не репутационная блокировка
                warn "   ${zone}: ${code} (${desc})"
                add_warning "DNSBL PBL: ${ip} в ${zone} (политика dynamic IP, не плохая репутация)"
            else
                fail "   ${zone}: ${code} (${desc})"
                DNSBL_ANY_HIT=1
                add_critical "DNSBL hit: ${ip} in ${zone} (${desc})"
            fi
        done
        [[ "$any" -eq 0 ]] && ok "   IP не найден в проверяемых DNSBL."
    done
    _out ""
}

_check_dnsbl_one() {
    local ip="$1" zone="$2"
    local rfile="${TMPDIR_MXC}/dnsbl_$(safe_fname "$ip")_$(safe_fname "$zone")"

    # reversed IPv4
    local a b c d
    IFS='.' read -r a b c d <<<"$ip"
    local q="${d}.${c}.${b}.${a}.${zone}"

    local ans
    # Две попытки с небольшим таймаутом (DNSBL часто rate-limit'ят публичные резолверы)
    ans=$(_dig "$q" A | head -1)
    if [[ -z "$ans" ]]; then
        sleep 1
        ans=$(_dig "$q" A | head -1)
    fi

    if [[ -n "$ans" ]] && is_ipv4 "$ans"; then
        echo "$ans" > "$rfile"
    else
        echo "none" > "$rfile"
    fi
}

_dnsbl_decode() {
    local zone="$1" code="$2"
    case "$zone" in
        zen.spamhaus.org)
            case "$code" in
                127.0.0.2) echo "SBL (spam source)" ;;
                127.0.0.3) echo "SBL CSS" ;;
                127.0.0.4|127.0.0.5|127.0.0.6|127.0.0.7) echo "XBL (exploits/botnet)" ;;
                127.0.0.9)  echo "SBL DROP" ;;
                127.0.0.10) echo "PBL ISP-maintained" ;;
                127.0.0.11) echo "PBL Spamhaus-maintained" ;;
                *) echo "Spamhaus: $code" ;;
            esac
            ;;
        b.barracudacentral.org) echo "Barracuda: $code" ;;
        bl.spamcop.net)         echo "SpamCop: $code" ;;
        dnsbl.sorbs.net)        echo "SORBS: $code" ;;
        psbl.surriel.com)       echo "PSBL: $code" ;;
        *)                      echo "$zone: $code" ;;
    esac
}

# ============================================================================
#                              ИТОГИ (TEXT)
# ============================================================================
print_summary() {
    local domain="$1"
    _out "${MAGENTA}──────────── Итоги для ${BOLD}${domain}${NC}${MAGENTA} ────────────${NC}"

    local crit=${#ISSUES_CRITICAL[@]}
    local warns=${#ISSUES_WARNING[@]}

    if (( crit == 0 && warns == 0 )); then
        ok "Общая оценка: всё в порядке."
    elif (( crit == 0 )); then
        warn "Общая оценка: базовая конфигурация работает, но есть рекомендации ($warns)."
    else
        fail "Общая оценка: есть критичные проблемы ($crit крит. / $warns предупр.)."
    fi
    _out ""

    # Аутентификация
    _out "${BOLD}Аутентификация отправителя:${NC}"
    if [[ "$HAS_SPF" -eq 1 ]]; then
        case "$SPF_ALL_MECH" in
            -all) ok "SPF: -all (strict), lookups=${SPF_LOOKUPS}/10" ;;
            \~all) ok "SPF: ~all (softfail), lookups=${SPF_LOOKUPS}/10" ;;
            \?all) warn "SPF: ?all (neutral)" ;;
            \+all) fail "SPF: +all — КРИТИЧНО" ;;
            *)     warn "SPF: нет финального механизма" ;;
        esac
        [[ "$SPF_MULTIPLE" -eq 1 ]] && fail "SPF: несколько записей (permerror)"
        (( SPF_LOOKUPS > 10 )) && fail "SPF: превышен лимит 10 lookups"
    else
        fail "SPF: отсутствует"
    fi

    if [[ "$DKIM_FOUND" -eq 1 ]]; then
        ok "DKIM: найден (${#DKIM_SELECTORS_FOUND[@]} селектор(ов): ${DKIM_SELECTORS_FOUND[*]})"
    else
        warn "DKIM: не найден по типичным селекторам (может быть кастомный)"
    fi

    if [[ "$DMARC_FOUND" -eq 1 ]]; then
        case "$DMARC_POLICY" in
            reject|quarantine) ok "DMARC: p=$DMARC_POLICY${DMARC_SP:+, sp=$DMARC_SP}" ;;
            none) warn "DMARC: p=none (только мониторинг)" ;;
            *)    warn "DMARC: p=$DMARC_POLICY" ;;
        esac
    else
        fail "DMARC: отсутствует"
    fi
    _out ""

    # Транспорт
    _out "${BOLD}Transport security:${NC}"
    if [[ "$HAS_MTA_STS_POLICY" -eq 1 ]]; then
        case "$MTA_STS_MODE" in
            enforce) ok "MTA-STS: enforce (policy загружена)" ;;
            testing) warn "MTA-STS: testing" ;;
            *)       warn "MTA-STS: mode=${MTA_STS_MODE:-?}" ;;
        esac
    elif [[ "$HAS_MTA_STS_DNS" -eq 1 ]]; then
        fail "MTA-STS: DNS есть, policy по HTTPS недоступна"
    else
        warn "MTA-STS: не настроен"
    fi

    if [[ "$HAS_TLS_RPT" -eq 1 ]]; then
        ok "TLS-RPT: настроен"
    else
        info "TLS-RPT: не настроен (рекомендуется)"
    fi

    # TLS summary по всем портам
    local tls_ok=0 tls_bad=0 tls_warn=0
    local k
    for k in "${!TLS_STATUS[@]}"; do
        case "${TLS_STATUS[$k]}" in
            ok) ((tls_ok++)) ;;
            warn|mismatch) ((tls_warn++)) ;;
            bad|expired) ((tls_bad++)) ;;
        esac
    done
    if (( tls_ok + tls_bad + tls_warn > 0 )); then
        if (( tls_bad == 0 && tls_warn == 0 )); then
            ok "TLS: все проверенные порты валидны (${tls_ok})"
        elif (( tls_bad == 0 )); then
            warn "TLS: ok=${tls_ok}, warn=${tls_warn}"
        else
            fail "TLS: ok=${tls_ok}, warn=${tls_warn}, bad=${tls_bad}"
        fi
    fi
    _out ""

    # DNS и маршрутизация
    _out "${BOLD}DNS и маршрутизация:${NC}"
    if [[ "$HAS_MX" -eq 1 ]]; then
        ok "MX: ${#MX_HOSTS[@]} хост(ов), IPv4: ${#MX_IPS_V4[@]}, IPv6: ${#MX_IPS_V6[@]}"
        [[ "$PTR_ANY_MISMATCH" -eq 1 ]] && warn "PTR: есть несовпадения forward-confirm"
        [[ "$PTR_ANY_MISSING"  -eq 1 ]] && warn "PTR: есть отсутствующие записи"
    else
        warn "MX: нет записей"
    fi

    # Порты
    local open_list=()
    [[ "$PORT25_OPEN"  -eq 1 ]] && open_list+=("25")
    [[ "$PORT465_OPEN" -eq 1 ]] && open_list+=("465")
    [[ "$PORT587_OPEN" -eq 1 ]] && open_list+=("587")
    if [[ ${#open_list[@]} -gt 0 ]]; then
        ok "SMTP-порты открыты: ${open_list[*]}"
    elif [[ "$HAS_MX" -eq 1 ]]; then
        fail "SMTP-порты 25/465/587 недоступны"
    fi

    if [[ "$DNSBL_ANY_HIT" -eq 1 ]]; then
        fail "DNSBL: есть попадания (см. выше)"
    elif [[ ${#MX_IPS_V4[@]} -gt 0 ]]; then
        ok "DNSBL: чисто"
    fi
    _out ""

    # Детальные списки проблем
    if (( crit > 0 )); then
        _out "${RED}${BOLD}Критичные проблемы:${NC}"
        for msg in "${ISSUES_CRITICAL[@]}"; do
            _out "  • $msg"
        done
        _out ""
    fi
    if (( warns > 0 )); then
        _out "${YELLOW}${BOLD}Предупреждения:${NC}"
        for msg in "${ISSUES_WARNING[@]}"; do
            _out "  • $msg"
        done
        _out ""
    fi
}

# ============================================================================
#                              ИТОГИ (JSON)
# ============================================================================
json_esc() {
    # JSON-escape строки (минимально)
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '"%s"' "$s"
}

json_array_strs() {
    # Печатает JSON-массив строк из аргументов
    local first=1 item
    printf '['
    for item in "$@"; do
        [[ "$first" -eq 1 ]] || printf ','
        first=0
        json_esc "$item"
    done
    printf ']'
}

print_json() {
    local domain="$1"
    local crit=${#ISSUES_CRITICAL[@]}
    local warns=${#ISSUES_WARNING[@]}
    local status="ok"
    (( warns > 0 )) && status="warning"
    (( crit  > 0 )) && status="critical"

    {
        printf '{'
        printf '"domain":%s,'         "$(json_esc "$domain")"
        printf '"mxchecker_version":%s,' "$(json_esc "$MXCHECKER_VERSION")"
        printf '"timestamp":%s,'      "$(json_esc "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
        printf '"status":%s,'         "$(json_esc "$status")"
        printf '"summary":{"critical":%d,"warning":%d},' "$crit" "$warns"

        printf '"dns":{'
        printf '"a":'; json_array_strs "${DNS_A[@]}"
        printf ',"aaaa":'; json_array_strs "${DNS_AAAA[@]}"
        printf '},'

        printf '"mx":{'
        printf '"has_mx":%s,' "$([[ $HAS_MX -eq 1 ]] && echo true || echo false)"
        printf '"hosts":'; json_array_strs "${MX_HOSTS[@]}"
        printf ',"priorities":['
        local first=1 p
        for p in "${MX_PRIO[@]}"; do
            [[ "$first" -eq 1 ]] || printf ','
            first=0
            printf '%s' "$p"
        done
        printf '],"ipv4":'; json_array_strs "${MX_IPS_V4[@]}"
        printf ',"ipv6":'; json_array_strs "${MX_IPS_V6[@]}"
        printf ',"ptr_any_missing":%s,' "$([[ $PTR_ANY_MISSING -eq 1 ]] && echo true || echo false)"
        printf '"ptr_any_mismatch":%s' "$([[ $PTR_ANY_MISMATCH -eq 1 ]] && echo true || echo false)"
        printf '},'

        printf '"spf":{'
        printf '"present":%s,'  "$([[ $HAS_SPF -eq 1 ]] && echo true || echo false)"
        printf '"multiple":%s,' "$([[ $SPF_MULTIPLE -eq 1 ]] && echo true || echo false)"
        printf '"record":%s,'   "$(json_esc "$SPF_RECORD")"
        printf '"all":%s,'      "$(json_esc "$SPF_ALL_MECH")"
        printf '"lookups":%d,'  "$SPF_LOOKUPS"
        printf '"uses_ptr":%s'  "$([[ $SPF_HAS_PTR -eq 1 ]] && echo true || echo false)"
        printf '},'

        printf '"dkim":{'
        printf '"found":%s,' "$([[ $DKIM_FOUND -eq 1 ]] && echo true || echo false)"
        printf '"selectors":'; json_array_strs "${DKIM_SELECTORS_FOUND[@]}"
        printf '},'

        printf '"dmarc":{'
        printf '"present":%s,' "$([[ $DMARC_FOUND -eq 1 ]] && echo true || echo false)"
        printf '"policy":%s,'  "$(json_esc "$DMARC_POLICY")"
        printf '"sp":%s,'      "$(json_esc "$DMARC_SP")"
        printf '"pct":%s,'     "$(json_esc "$DMARC_PCT")"
        printf '"rua":%s'      "$(json_esc "$DMARC_RUA")"
        printf '},'

        printf '"mta_sts":{'
        printf '"dns":%s,'      "$([[ $HAS_MTA_STS_DNS    -eq 1 ]] && echo true || echo false)"
        printf '"policy":%s,'   "$([[ $HAS_MTA_STS_POLICY -eq 1 ]] && echo true || echo false)"
        printf '"mode":%s'      "$(json_esc "$MTA_STS_MODE")"
        printf '},'

        printf '"tls_rpt":{"present":%s},' "$([[ $HAS_TLS_RPT -eq 1 ]] && echo true || echo false)"

        printf '"smtp_ports":{'
        printf '"p25":%s,'  "$([[ $PORT25_OPEN  -eq 1 ]] && echo true || echo false)"
        printf '"p465":%s,' "$([[ $PORT465_OPEN -eq 1 ]] && echo true || echo false)"
        printf '"p587":%s'  "$([[ $PORT587_OPEN -eq 1 ]] && echo true || echo false)"
        printf '},'

        # TLS-детали по endpoint'ам
        printf '"tls":{'
        local first_tls=1 k
        for k in "${!TLS_STATUS[@]}"; do
            [[ "$first_tls" -eq 1 ]] || printf ','
            first_tls=0
            printf '%s:{"status":%s,"days_left":%s}' \
                "$(json_esc "$k")" \
                "$(json_esc "${TLS_STATUS[$k]}")" \
                "${TLS_EXPIRES[$k]:-null}"
        done
        printf '},'

        # DNSBL-хиты
        printf '"dnsbl":{"any":%s,"hits":{' \
            "$([[ $DNSBL_ANY_HIT -eq 1 ]] && echo true || echo false)"
        local first_bl=1
        for k in "${!DNSBL_HIT[@]}"; do
            [[ "$first_bl" -eq 1 ]] || printf ','
            first_bl=0
            printf '%s:%s' \
                "$(json_esc "$k")" \
                "$(json_esc "${DNSBL_HIT[$k]}")"
        done
        printf '}},'

        printf '"issues":{"critical":'
        json_array_strs "${ISSUES_CRITICAL[@]}"
        printf ',"warning":'
        json_array_strs "${ISSUES_WARNING[@]}"
        printf '}'

        printf '}\n'
    } | { if [[ "$HAS_JQ" -eq 1 ]]; then jq .; else cat; fi; }
}

# ============================================================================
#                              ЗАПУСК ПРОВЕРОК
# ============================================================================
run_checks() {
    local domain="$1"
    log_action "scan start: $domain"

    check_dns_basic  "$domain"
    check_mx_and_ptr "$domain"
    check_spf        "$domain"
    check_dkim       "$domain"
    check_dmarc      "$domain"
    check_mta_sts    "$domain"
    check_tls_rpt    "$domain"
    check_smtp_ports
    check_smtp_banners
    check_starttls
    check_dnsbl

    log_action "scan done: $domain"
}

# ============================================================================
#                              CLI
# ============================================================================
print_header() {
    [[ "$OUTPUT_FORMAT" == "json" ]] && return
    [[ "$QUIET" -eq 1 ]] && return
    _out "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    _out "  ${BOLD}mxchecker v${MXCHECKER_VERSION}${NC} — проверка почтового домена"
    _out "  Автор: ${BOLD}${MXCHECKER_AUTHOR}${NC}  TG: ${BOLD}${MXCHECKER_TG}${NC}"
    _out "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    _out ""
}

print_help() {
    cat <<EOF
mxchecker v${MXCHECKER_VERSION} — проверка почтовой инфраструктуры домена

Использование:
  mxchecker [опции] <домен>

Опции:
  --json                 Машинно-читаемый вывод (JSON)
  --quiet                Только итоги, без пошагового вывода
  --no-color             Отключить цвета
  --no-ipv6              Не проверять AAAA и IPv6 PTR
  --dns=<server>         DNS-сервер (по умолчанию: 8.8.8.8)
  --dns-timeout=<sec>    Таймаут DNS-запроса (по умолчанию: ${DNS_TIMEOUT})
  --smtp-timeout=<sec>   Таймаут SMTP/TLS (по умолчанию: ${SMTP_TIMEOUT})
  --parallel=<N>         Max параллельных сетевых задач (по умолчанию: ${MAX_PARALLEL})
  --dkim-selector=<s>    Дополнительный DKIM-селектор (можно несколько раз)
  --log=<path>           Записывать действия в указанный файл
  -h, --help             Эта справка
  -v, --version          Версия

Exit codes:
  0  — всё хорошо
  1  — есть предупреждения
  2  — есть критичные проблемы
  3  — ошибка запуска/зависимостей

Примеры:
  mxchecker example.com
  mxchecker --json example.com | jq '.summary'
  mxchecker --dns=1.1.1.1 --no-ipv6 example.com
  mxchecker --dkim-selector=mycorp2024 example.com

Переменные окружения:
  MXCHECKER_DNS, MXCHECKER_DNS_TIMEOUT, MXCHECKER_SMTP_TIMEOUT,
  MXCHECKER_HTTP_TIMEOUT, MXCHECKER_MAX_PARALLEL, NO_COLOR

При запуске через 'bash <(curl ...)' авто-установка dig отключена —
это сделано намеренно: установка пакетов без прямого CLI-контекста
рискованна. Установите dnsutils/bind-utils вручную при необходимости.
EOF
}

parse_args() {
    # Если скрипт получает аргументы (не интерактивный запуск) — можно пытаться
    # авто-установить dig, иначе — нет (см. анализ безопасности bash <(curl ...)).
    if [[ $# -gt 0 ]]; then
        AUTO_INSTALL=1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) print_help; exit 0 ;;
            -v|--version) echo "mxchecker ${MXCHECKER_VERSION}"; exit 0 ;;
            --json) OUTPUT_FORMAT="json"; QUIET=1 ;;
            --quiet) QUIET=1 ;;
            --no-color) NO_COLOR=1 ;;
            --no-ipv6)  CHECK_IPV6=0 ;;
            --dns=*)          DNS_SERVER="${1#*=}" ;;
            --dns-timeout=*)  DNS_TIMEOUT="${1#*=}" ;;
            --smtp-timeout=*) SMTP_TIMEOUT="${1#*=}" ;;
            --parallel=*)     MAX_PARALLEL="${1#*=}" ;;
            --dkim-selector=*) EXTRA_DKIM_SELECTORS+=("${1#*=}") ;;
            --log=*)          MXC_LOG="${1#*=}" ;;
            --)               shift; break ;;
            -*)               echo "Неизвестная опция: $1" >&2; exit 3 ;;
            *)
                if [[ -z "$DOMAIN" ]]; then
                    DOMAIN="$1"
                else
                    echo "Лишний аргумент: $1" >&2; exit 3
                fi
                ;;
        esac
        shift
    done

    if [[ -z "$DOMAIN" ]]; then
        if [[ -t 0 ]]; then
            read -rp "Введите домен для проверки: " DOMAIN
        fi
    fi

    if [[ -z "$DOMAIN" ]]; then
        echo "Не указан домен. Используйте: mxchecker <домен>" >&2
        exit 3
    fi

    if ! validate_domain "$DOMAIN"; then
        echo "Некорректный формат домена: '$DOMAIN'" >&2
        exit 3
    fi
}

main() {
    parse_args "$@"
    setup_colors
    print_header

    check_dependencies

    step "Запуск проверки для ${BOLD}${DOMAIN}${NC} (DNS: ${DNS_SERVER})"
    _out ""
    run_checks "$DOMAIN"

    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        print_json "$DOMAIN"
    else
        print_summary "$DOMAIN"
    fi

    # Exit code
    if (( ${#ISSUES_CRITICAL[@]} > 0 )); then
        exit 2
    elif (( ${#ISSUES_WARNING[@]} > 0 )); then
        exit 1
    else
        exit 0
    fi
}

main "$@"