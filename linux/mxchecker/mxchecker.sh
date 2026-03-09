#!/bin/bash
set -uo pipefail

# Цвета
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
BLUE="\033[34m"
MAGENTA="\033[35m"
WHITE="\033[97m"
NC="\033[0m"
BOLD="\033[1m"

DNS_SERVER="8.8.8.8"

# Глобальные флаги/состояния для итогового анализа
HAS_DIG=0
HAS_HOST=0
HAS_NC=0
HAS_OPENSSL=0

DNS_A_FOUND=0

HAS_MX=0
MX_PTR_MISMATCH=0
PTR_MISSING=0
declare -a MX_IPS=()

HAS_SPF=0
SPF_STRICT=0
SPF_PLUS_ALL=0

DKIM_FOUND=0
DKIM_SELECTORS=""

DMARC_FOUND=0
DMARC_POLICY=""
DMARC_POLICY_STRICT=0
DMARC_SP=""

HAS_MTA_STS=0

DNSBL_LISTED=0

PORT25_OPEN=0
PORT465_OPEN=0
PORT587_OPEN=0

TLS_ANY_OK=0
TLS_ANY_PROBLEM=0


# логирование
LOG_FILE="/var/log/mxchecker_script.log"

log_action() {
    local msg="$1"
    # Пишем лог, но не падаем, если нет прав на запись
    {
        echo "$(date '+%F %T') $msg" >> "$LOG_FILE"
    } 2>/dev/null || true
}

validate_domain() {
    local domain="$1"
    # Простая валидация FQDN: буквы/цифры/дефисы, точки как разделители
    if [[ ! "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]; then
        fail "Некорректный формат домена: '$domain'"
        exit 1
    fi
}

validate_ipv4() {
    local ip="$1"
    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi
    local IFS='.'
    # shellcheck disable=SC2206
    local parts=($ip)
    for octet in "${parts[@]}"; do
        if (( octet < 0 || octet > 255 )); then
            return 1
        fi
    done
    return 0
}

print_header() {
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${BOLD}mxchecker${NC} : проверка почтового домена на корректность настроек"
    echo -e "  Создано ${BOLD}Vladislav Pavlovich${NC} для технической поддержки."
    echo -e "  По вопросам в TG: ${BOLD}@sysadminctl${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo
}

print_help() {
    cat <<EOF
Использование:
  mxchecker <домен>

Если домен не указан, будет интерактивный режим с вопросами.

Примеры:
  mxchecker example.com

При запуске через:
  bash <(curl -s https://raw.githubusercontent.com/spoveddd/scripts/main/linux/mxchecker/mxchecker.sh)
будет предложено ввести домен и будет выполнена полная проверка.
EOF
}

step() {
    local label="$1"
    echo -e "${BLUE}[>]${NC} $label"
}

ok() {
    local label="$1"
    echo -e "${GREEN}[OK]${NC} $label"
}

warn() {
    local label="$1"
    echo -e "${YELLOW}[!!]${NC} $label"
}

fail() {
    local label="$1"
    echo -e "${RED}[XX]${NC} $label"
}

check_command() {
    local cmd="$1"
    if command -v "$cmd" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

check_dependencies() {
    step "Проверяю зависимости..."

    # Сбрасываем флаги перед проверкой
    HAS_DIG=0
    HAS_HOST=0
    HAS_NC=0
    HAS_OPENSSL=0

    if check_command dig; then
        HAS_DIG=1
    fi
    if check_command host; then
        HAS_HOST=1
    fi
    if check_command nc || check_command netcat || check_command ncat; then
        HAS_NC=1
    fi
    if check_command openssl; then
        HAS_OPENSSL=1
    fi

    local all_ok=1

    if [[ "$HAS_DIG" -eq 0 && "$HAS_HOST" -eq 0 ]]; then
        fail "Не найдено ни dig, ни host. DNS-проверки недоступны."
        all_ok=0
    fi

    if [[ "$HAS_NC" -eq 0 ]]; then
        warn "Не найден netcat (nc/netcat/ncat). Проверка SMTP-портов будет ограничена."
        all_ok=0
    fi

    if [[ "$HAS_OPENSSL" -eq 0 ]]; then
        warn "Не найден openssl. Проверки StartTLS/TLS сертификатов будут частично недоступны."
        all_ok=0
    fi

    if [[ "$all_ok" -eq 1 ]]; then
        ok "Все необходимые утилиты найдены (dig/host, nc, openssl)."
    fi

    echo
}

dns_query() {
    # dns_query <name> <type>
    local name="$1"
    local type="$2"

    if [[ "$HAS_DIG" -eq 1 ]]; then
        dig +short @"$DNS_SERVER" "$name" "$type" 2>/dev/null
    elif [[ "$HAS_HOST" -eq 1 ]]; then
        host -t "$type" "$name" "$DNS_SERVER" 2>/dev/null | awk '/has.*address/ {print $NF} /descriptive text/ {sub(/\"/,"",$4); sub(/\"/,"",$4); print $4}'
    fi
}

dns_txt_query_raw() {
    local name="$1"
    if [[ "$HAS_DIG" -eq 1 ]]; then
        dig +short @"$DNS_SERVER" "$name" TXT 2>/dev/null | sed 's/^"//; s/"$//'
    elif [[ "$HAS_HOST" -eq 1 ]]; then
        host -t TXT "$name" "$DNS_SERVER" 2>/dev/null | sed -n 's/.*descriptive text "\(.*\)".*/\1/p'
    fi
}

check_dns_basic() {
    local domain="$1"
    step "DNS: A-записи домена $domain"
    local a_records
    a_records=$(dns_query "$domain" A)
    if [[ -z "$a_records" ]]; then
        fail "A-записи не найдены."
    else
        DNS_A_FOUND=1
        ok "A-записи:"
        echo "$a_records" | sed "s/^/   - /"
    fi
    echo
}

check_mx_and_ptr() {
    local domain="$1"
    step "DNS: MX-записи домена $domain"

    local mx_raw mx_hosts
    mx_raw=$(dns_query "$domain" MX)

    if [[ -z "$mx_raw" ]]; then
        warn "MX-записи не найдены. Почта может приниматься напрямую на A-запись."
        echo
        return 1
    fi

    HAS_MX=1

    echo "$mx_raw" | sed "s/^/   - /"

    mx_hosts=()
    while read -r line; do
        # dig +short MX example.com -> "10 mx1.example.com."
        local host
        host="${line##* }"
        host=${host%.}
        [[ -n "$host" ]] && mx_hosts+=("$host")
    done <<<"$mx_raw"

    echo
    step "DNS: A/PTR-записи для MX-хостов"

    MX_IPS=()

    for mx in "${mx_hosts[@]}"; do
        echo -e "${CYAN}[*] MX: ${BOLD}$mx${NC}"
        local ips
        ips=$(dns_query "$mx" A)
        if [[ -z "$ips" ]]; then
            warn "   Нет A-записей для $mx"
            continue
        fi
        while read -r ip; do
            [[ -z "$ip" ]] && continue
            if ! validate_ipv4 "$ip"; then
                warn "   IP '$ip' не выглядит корректным IPv4, пропускаю."
                continue
            fi
            MX_IPS+=("$ip")
            echo -e "   IP: $ip"
            local ptr
            if [[ "$HAS_DIG" -eq 1 ]]; then
                ptr=$(dig +short -x "$ip" @"$DNS_SERVER" 2>/dev/null | sed 's/\.$//')
            elif [[ "$HAS_HOST" -eq 1 ]]; then
                ptr=$(host "$ip" "$DNS_SERVER" 2>/dev/null | awk '/domain name pointer/ {print $5}' | sed 's/\.$//')
            fi
            if [[ -n "$ptr" ]]; then
                if [[ "$ptr" == "$mx" ]]; then
                    ok "   PTR: $ptr (совпадает с MX)"
                else
                    MX_PTR_MISMATCH=1
                    warn "   PTR: $ptr (НЕ совпадает с MX: $mx)"
                fi
            else
                PTR_MISSING=1
                warn "   PTR-запись не найдена"
            fi
        done <<<"$ips"
        echo
    done

    return 0
}

check_spf() {
    local domain="$1"
    step "DNS: SPF для домена $domain"

    local txt
    txt=$(dns_txt_query_raw "$domain")
    local spf=""

    while IFS= read -r line; do
        # Ищем первую строку, содержащую v=spf1 (без учёта регистра)
        if [[ "${line,,}" == *"v=spf1"* ]]; then
            spf="$line"
            break
        fi
    done <<< "$txt"

    if [[ -z "$spf" ]]; then
        warn "SPF-запись не найдена."
        echo "   Рекомендация: добавить SPF, ограничивающий отправку с доверенных хостов."
    else
        HAS_SPF=1
        ok "SPF найден:"
        echo "$spf" | sed "s/^/   /"
        # Анализ окончания SPF
        if [[ "$spf" =~ [[:space:]]-all ]]; then
            SPF_STRICT=2
            ok "SPF: -all (reject) — максимальная строгость."
        elif [[ "$spf" =~ [[:space:]]~all ]]; then
            SPF_STRICT=1
            ok "SPF: ~all (softfail) — хорошо, но -all надёжнее."
        elif [[ "$spf" =~ [[:space:]]\+all ]]; then
            SPF_STRICT=0
            SPF_PLUS_ALL=1
            fail "SPF содержит +all — разрешает отправку с любого хоста, это хуже, чем отсутствие SPF."
        else
            SPF_STRICT=0
            warn "SPF не содержит явного окончания (~all/-all)."
        fi
    fi
    echo
}

check_dkim_common_selectors() {
    local domain="$1"
    step "DNS: DKIM (популярные селекторы)"

    DKIM_FOUND=0
    DKIM_SELECTORS=""

    # Набор распространённых селекторов, которые часто используются
    local selectors=(
        # Общие
        "default"
        "dkim"
        "mail"
        "s1"
        "s2"

        # Microsoft 365
        "selector1"
        "selector2"

        # Google Workspace
        "google"

        # Яндекс 360
        "yandex"

        # Mailchimp / Mandrill
        "k1"
        "k2"
        "k3"

        # SendGrid
        "smtpapi"

        # Mailgun
        "pic"
        "krs"
        "mta"

        # Postmark
        "pm"

        # Amazon SES
        "amazonses"

        # Zoho
        "zoho"

        # ProtonMail
        "protonmail"
        "protonmail2"
        "protonmail3"

        # Общие/кастомные
        "dkim1"
        "dkim2"
        "key1"
        "key2"
        "mx"
        "email"
    )

    echo "Пробуем селекторы: ${selectors[*]}"
    echo

    for sel in "${selectors[@]}"; do
        local name="${sel}._domainkey.${domain}"
        local txt
        txt=$(dns_txt_query_raw "$name")

        if echo "$txt" | grep -qi "v=DKIM1"; then
            DKIM_FOUND=1
            if [[ -z "$DKIM_SELECTORS" ]]; then
                DKIM_SELECTORS="$sel"
            else
                DKIM_SELECTORS+=", $sel"
            fi
            ok "Найден DKIM (селектор: ${BOLD}$sel${NC}):"
            echo "$txt" | sed "s/^/   /"
            echo
        fi
    done

    if [[ "$DKIM_FOUND" -eq 0 ]]; then
        warn "DKIM не найден по типичным селекторам (например: default._domainkey, dkim._domainkey и др.)."
        echo "   Возможные причины:"
        echo "   - DKIM выключен или ещё не настроен;"
        echo "   - используется нестандартный селектор (уточните у провайдера)."
        echo
    fi
}

check_dmarc() {
    local domain="$1"
    step "DNS: DMARC"

    local name="_dmarc.${domain}"
    local txt
    txt=$(dns_txt_query_raw "$name")

    if echo "$txt" | grep -qi "v=DMARC1"; then
        DMARC_FOUND=1
        ok "DMARC найден:"
        echo "$txt" | sed "s/^/   /"

        # Вытащим политику p= и sp= (аккуратно, без захвата sp= в p=)
        DMARC_POLICY=$(echo "$txt" | sed -n 's/.*[[:space:];]p=\([^;[:space:]]*\).*/\1/Ip' | head -1)
        DMARC_SP=$(echo "$txt" | sed -n 's/.*[[:space:];]sp=\([^;[:space:]]*\).*/\1/Ip' | head -1)

        if echo "$txt" | grep -qi "p=none"; then
            DMARC_POLICY_STRICT=0
            warn "DMARC политика p=none — только мониторинг, без жёсткого отклонения."
        elif echo "$txt" | grep -qi "p=quarantine\|p=reject"; then
            DMARC_POLICY_STRICT=1
            ok "DMARC политика строгая (quarantine/reject)."
        fi
    else
        warn "DMARC-запись не найдена."
        echo "   Рекомендация: добавить DMARC для защиты от подделки домена."
    fi
    echo
}

check_mta_sts() {
    local domain="$1"
    step "DNS: MTA-STS"

    local name="_mta-sts.${domain}"
    local txt
    txt=$(dns_txt_query_raw "$name")

    if echo "$txt" | grep -qi "v=STSv1"; then
        HAS_MTA_STS=1
        ok "MTA-STS обнаружен:"
        echo "$txt" | sed "s/^/   /"
    else
        warn "MTA-STS не обнаружен."
        echo "   Рекомендация: внедрить MTA-STS для защиты StartTLS от downgrade-атак."
    fi
    echo
}

check_smtp_ports() {
    local domain="$1"

    if [[ "${#MX_IPS[@]}" -eq 0 ]]; then
        warn "Нет IP MX-хостов, пропускаю проверку SMTP-портов."
        return
    fi

    step "SMTP: сканирование портов 25/465/587 (по IP MX)"

    local port
    for ip in "${MX_IPS[@]}"; do
        echo -e "${CYAN}[*] MX IP: ${BOLD}$ip${NC}"

        local open_ports=()
        local closed_ports=()

        for port in 25 465 587; do
            local port_open=0
            if [[ "$HAS_NC" -eq 1 ]]; then
                if nc -z -w3 "$ip" "$port" >/dev/null 2>&1 || ncat -z -w3 "$ip" "$port" >/dev/null 2>&1 || netcat -z -w3 "$ip" "$port" >/dev/null 2>&1; then
                    port_open=1
                fi
            else
                if timeout 3 bash -c "echo > /dev/tcp/$ip/$port" 2>/dev/null; then
                    port_open=1
                fi
            fi

            if [[ "$port_open" -eq 1 ]]; then
                open_ports+=("$port")
                case "$port" in
                    25) PORT25_OPEN=1 ;;
                    465) PORT465_OPEN=1 ;;
                    587) PORT587_OPEN=1 ;;
                esac
            else
                closed_ports+=("$port")
            fi
        done

        if [[ "${#open_ports[@]}" -eq 3 ]]; then
            ok "   Почтовые порты открыты (25, 465, 587)."
        elif [[ "${#open_ports[@]}" -gt 0 ]]; then
            warn "   Открыты порты: ${open_ports[*]}; закрыты или недоступны: ${closed_ports[*]}."
        else
            fail "   Все проверенные почтовые порты закрыты или недоступны (25, 465, 587)."
        fi

        echo
    done
}

check_starttls_and_cert() {
    local domain="$1"

    if [[ "$HAS_OPENSSL" -eq 0 ]]; then
        return
    fi
    if [[ "${#MX_IPS[@]}" -eq 0 ]]; then
        warn "Нет IP MX-хостов, пропускаю проверку StartTLS/TLS."
        return
    fi

    step "SMTP/TLS: StartTLS и сертификаты"

    for ip in "${MX_IPS[@]}"; do
        echo -e "${CYAN}[*] MX IP: ${BOLD}$ip${NC}"

        local good_ports=()
        local bad_ports=()

        for port in 25 587; do
            local out
            out=$(printf 'EHLO %s\r\nQUIT\r\n' "$domain" | timeout 10 openssl s_client -starttls smtp -crlf -connect "${ip}:${port}" -servername "$domain" 2>/dev/null)
            if [[ $? -ne 0 || -z "$out" ]]; then
                bad_ports+=("$port")
                continue
            fi

            if echo "$out" | grep -qi "Verify return code: 0 (ok)"; then
                good_ports+=("$port")
                TLS_ANY_OK=1
            else
                bad_ports+=("$port")
                TLS_ANY_PROBLEM=1
            fi
        done

        # SMTPS 465 — проверяем только если порт 465 реально открыт
        if [[ "$PORT465_OPEN" -eq 1 ]]; then
            local out465
            out465=$(printf 'QUIT\r\n' | timeout 10 openssl s_client -crlf -connect "${ip}:465" -servername "$domain" 2>/dev/null)
            if [[ -z "$out465" ]]; then
                bad_ports+=("465")
                TLS_ANY_PROBLEM=1
            elif echo "$out465" | grep -qi "Verify return code: 0 (ok)"; then
                good_ports+=("465")
                TLS_ANY_OK=1
            else
                bad_ports+=("465")
                TLS_ANY_PROBLEM=1
            fi
        fi

        if [[ "${#good_ports[@]}" -gt 0 && "${#bad_ports[@]}" -eq 0 ]]; then
            ok "   TLS/StartTLS сертификаты валидны на портах: ${good_ports[*]}."
        elif [[ "${#good_ports[@]}" -gt 0 && "${#bad_ports[@]}" -gt 0 ]]; then
            warn "   Сертификаты валидны на портах: ${good_ports[*]}; есть проблемы на портах: ${bad_ports[*]}."
        else
            fail "   Не удалось подтвердить валидность сертификатов на проверенных портах (25, 465, 587)."
        fi

        echo
    done
}

check_dnsbl() {
    if [[ "${#MX_IPS[@]}" -eq 0 ]]; then
        warn "Нет IP MX-хостов, пропускаю проверку DNSBL."
        return
    fi

    step "DNSBL: проверка MX IP в чёрных списках"

    local lists=(
        "zen.spamhaus.org"
        "bl.spamcop.net"
        "b.barracudacentral.org"
    )

    for ip in "${MX_IPS[@]}"; do
        echo -e "${CYAN}[*] MX IP: ${BOLD}$ip${NC}"
        local rev
        IFS='.' read -r a b c d <<< "$ip"
        rev="${d}.${c}.${b}.${a}"
        local any_listed=0
        for zone in "${lists[@]}"; do
            local q="${rev}.${zone}"
            local ans
            ans=$(dns_query "$q" A)
            if [[ -n "$ans" ]]; then
                any_listed=1
                DNSBL_LISTED=1
                fail "   В ЧС: $zone ($q)"
            fi
        done
        if [[ "$any_listed" -eq 0 ]]; then
            ok "   IP не найден в проверяемых DNSBL."
        fi
        echo
    done
}

print_summary() {
    local domain="$1"
    echo -e "${MAGENTA}──────────────────────────── Итоги для ${BOLD}$domain${NC}${MAGENTA} ────────────────────────────${NC}"

    # Общая оценка
    local critical_issues=0
    local warning_issues=0

    if [[ "$HAS_MX" -eq 0 && "$DNS_A_FOUND" -eq 0 ]]; then
        critical_issues=1
    fi

    # SPF и DMARC — критично
    if [[ "$HAS_SPF" -eq 0 || "$SPF_PLUS_ALL" -eq 1 ]]; then
        critical_issues=1
    fi
    if [[ "$DMARC_FOUND" -eq 0 ]]; then
        critical_issues=1
    fi

    # DKIM — сначала как предупреждение (нестандартный селектор возможен)
    if [[ "$DKIM_FOUND" -eq 0 ]]; then
        warning_issues=1
    fi

    # SPF с +all или без явного окончания уже учтён в текстах выше, но можно считать это предупреждением
    # DNSBL — критично
    if [[ "$DNSBL_LISTED" -eq 1 ]]; then
        critical_issues=1
    fi

    # Порты SMTP только если есть MX
    if [[ "$HAS_MX" -eq 1 && "$PORT25_OPEN" -eq 0 && "$PORT587_OPEN" -eq 0 && "$PORT465_OPEN" -eq 0 ]]; then
        critical_issues=1
    fi

    # TLS: если везде проблемы и нет ни одного успешного соединения
    if [[ "${#MX_IPS[@]}" -gt 0 && "$TLS_ANY_PROBLEM" -eq 1 && "$TLS_ANY_OK" -eq 0 ]]; then
        critical_issues=1
    elif [[ "${#MX_IPS[@]}" -gt 0 && "$TLS_ANY_OK" -eq 1 && "$TLS_ANY_PROBLEM" -eq 1 ]]; then
        warning_issues=1
    fi

    if [[ "$critical_issues" -eq 0 && "$warning_issues" -eq 0 ]]; then
        echo "Общая оценка: отправка и приём почты должны работать корректно."
    elif [[ "$critical_issues" -eq 0 && "$warning_issues" -eq 1 ]]; then
        echo "Общая оценка: базовая конфигурация в порядке, но есть рекомендации ниже."
    elif [[ "$critical_issues" -eq 1 && "$warning_issues" -eq 0 ]]; then
        echo "Общая оценка: есть критичные моменты, влияющие на доставку — см. детали ниже."
    else
        echo "Общая оценка: есть критичные и предупреждающие проблемы — рекомендуется детально проработать настройки ниже."
    fi

    echo
    echo "- Общий статус:"
    if [[ "$HAS_MX" -eq 1 ]]; then
        echo "  * MX-записи найдены."
        if [[ "$MX_PTR_MISMATCH" -eq 1 ]]; then
            echo "    ! Есть MX, у которых PTR не совпадает — лучше привести PTR к виду mx-хоста."
            echo "      Решение: у хостинг-провайдера сервера запросите изменение PTR на FQDN MX-сервера."
        fi
        if [[ "$PTR_MISSING" -eq 1 ]]; then
            echo "    ! Для части IP MX PTR-запись отсутствует — желательно настроить PTR на FQDN почтового сервера."
            echo "      Решение: обратитесь к хостинг-провайдеру, выдавшему IP-адрес MX-сервера, и попросите настроить обратную DNS-запись (PTR) вида: IP → ${domain}."
        fi
    else
        echo "  * MX-записи отсутствуют — почта, вероятно, идёт напрямую на A-запись или домен не принимает почту."
    fi

    echo
    echo "- Аутентификация отправителя:"
    if [[ "$HAS_SPF" -eq 1 ]]; then
        case "$SPF_STRICT" in
            2)
                echo "  * SPF: настроен с жёсткой политикой (-all) — максимально надёжно."
                ;;
            1)
                echo "  * SPF: настроен с ~all (softfail) — хорошо, но можно усилить до -all."
                ;;
            0)
                if [[ "$SPF_PLUS_ALL" -eq 1 ]]; then
                    echo "  * SPF: содержит +all — КРИТИЧНО: разрешает отправку с любого сервера в мире."
                    echo "    Решение: удалите +all и добавьте в конец записи -all или ~all, предварительно перечислив легитимные источники (ip4:/ip6:/include:)."
                else
                    echo "  * SPF: нет явного окончания (~all/-all) — политика для неизвестных источников не определена."
                    echo "    Решение: добавьте в конец записи -all (или временно ~all) для ограничения отправителей."
                fi
                ;;
        esac
    else
        echo "  * SPF: не найден — HIGH PRIORITY: настроить SPF, чтобы ограничить подделку домена."
        echo "    Решение: добавьте TXT-запись для домена, например:"
        echo "    v=spf1 mx -all"
        echo "    или включите нужные ip4:/ip6:/include: перед -all."
    fi

    if [[ "$DKIM_FOUND" -eq 1 ]]; then
        echo "  * DKIM: найден (селекторы: $DKIM_SELECTORS)."
    else
        echo "  * DKIM: не найден по типичным селекторам — HIGH PRIORITY: включить DKIM на почтовом сервере (или проверить нестандартный селектор)."
        echo "    Решение: включите DKIM и добавьте TXT-запись вида:"
        echo "    <selector>._domainkey.${domain}  TXT  \"v=DKIM1; k=rsa; p=<публичный ключ>\""
    fi

    if [[ "$DMARC_FOUND" -eq 1 ]]; then
        if [[ "$DMARC_POLICY_STRICT" -eq 1 ]]; then
            echo "  * DMARC: включён с жёсткой политикой (p=${DMARC_POLICY})."
            if [[ -z "$DMARC_SP" ]]; then
                echo "    * Субдомены наследуют политику p=${DMARC_POLICY} (sp= не задан явно)."
            fi
        else
            echo "  * DMARC: включён с мягкой политикой (p=${DMARC_POLICY:-none}) — можно постепенно ужесточать до quarantine/reject."
        fi
    else
        echo "  * DMARC: отсутствует — HIGH PRIORITY: добавить DMARC для защиты домена."
        echo "    Решение: добавьте TXT-запись _dmarc.${domain}, например для начала:"
        echo "    v=DMARC1; p=none; rua=mailto:dmarc@${domain}"
        echo "    После мониторинга можно перейти на p=quarantine или p=reject."
    fi

    # Дополнительная информация по sp=, если задан
    if [[ "$DMARC_FOUND" -eq 1 && -n "$DMARC_SP" ]]; then
        echo "    * Политика для субдоменов: sp=${DMARC_SP}."
        if [[ "${DMARC_SP,,}" == "none" && "$DMARC_POLICY_STRICT" -eq 1 ]]; then
            echo "      ! Субдомены не защищены несмотря на строгий p=${DMARC_POLICY}."
            echo "      Решение: измените sp=none на sp=reject/quarantine или удалите sp= для наследования политики p=."
        fi
    fi

    echo
    echo "- Transport security:"
    if [[ "$HAS_MTA_STS" -eq 1 ]]; then
        echo "  * MTA-STS: есть — защита от StartTLS-downgrade реализована."
    else
        echo "  * MTA-STS: отсутствует — рекомендация: внедрить MTA-STS с режимом enforce после тестов."
        echo "    Решение: разместите политику по адресу https://mta-sts.${domain}/.well-known/mta-sts.txt"
        echo "    и добавьте TXT-запись _mta-sts.${domain}: \"v=STSv1; id=<уникальный идентификатор>\"."
    fi

    if [[ "$HAS_OPENSSL" -eq 0 ]]; then
        echo "  * TLS/StartTLS: openssl не найден, проверка сертификатов не выполнялась."
    elif [[ "${#MX_IPS[@]}" -eq 0 ]]; then
        echo "  * TLS/StartTLS: нет IP MX-хостов, проверка сертификатов не выполнялась."
    else
        if [[ "$TLS_ANY_OK" -eq 1 && "$TLS_ANY_PROBLEM" -eq 0 ]]; then
            echo "  * TLS/StartTLS: сертификаты валидны на всех проверенных портах."
        elif [[ "$TLS_ANY_OK" -eq 1 && "$TLS_ANY_PROBLEM" -eq 1 ]]; then
            echo "  * TLS/StartTLS: сертификаты валидны частично — есть порты с проблемами."
        elif [[ "$TLS_ANY_PROBLEM" -eq 1 ]]; then
            echo "  * TLS/StartTLS: проблемы с сертификатами на всех проверенных портах — HIGH PRIORITY."
        else
            echo "  * TLS/StartTLS: все SMTP-порты недоступны, проверка сертификатов не проводилась."
        fi
    fi

    if [[ "$DNSBL_LISTED" -eq 1 ]]; then
        echo "  * DNSBL: есть попадания в чёрные списки — критично, разберите и запросите делистинг."
        echo "    Решение: проверьте IP на сайте соответствующего списка и следуйте процедуре делистинга (удаления из списка)."
    else
        echo "  * DNSBL: в проверяемых списках попаданий не обнаружено."
    fi

    echo
    echo "- SMTP-порты:"
    if [[ "$HAS_MX" -eq 0 ]]; then
        echo "  * Проверка портов не применима — MX-записи отсутствуют."
    elif [[ "$PORT25_OPEN" -eq 1 || "$PORT465_OPEN" -eq 1 || "$PORT587_OPEN" -eq 1 ]]; then
        local open_list=()
        [[ "$PORT25_OPEN" -eq 1 ]] && open_list+=("25")
        [[ "$PORT465_OPEN" -eq 1 ]] && open_list+=("465")
        [[ "$PORT587_OPEN" -eq 1 ]] && open_list+=("587")
        echo "  * Открыты почтовые порты: ${open_list[*]}."
    else
        echo "  * Все стандартные почтовые порты (25, 465, 587) выглядят недоступными — приём почты под вопросом."
    fi

    echo
}

run_checks() {
    local domain="$1"
    log_action "FULL scan for $domain"

    check_dns_basic "$domain"
    check_mx_and_ptr "$domain"
    check_spf "$domain"
    check_dkim_common_selectors "$domain"
    check_dmarc "$domain"
    check_mta_sts "$domain"
    check_smtp_ports "$domain"
    check_starttls_and_cert "$domain"
    check_dnsbl
}

interactive_prompt() {
    local domain

    read -rp "Введите домен для проверки (например: example.com): " domain
    while [[ -z "$domain" ]]; do
        read -rp "Домен не может быть пустым, введите ещё раз: " domain
    done

    validate_domain "$domain"
    DOMAIN="$domain"
}

parse_args() {
    DOMAIN=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                print_header
                print_help
                exit 0
                ;;
            *)
                if [[ -z "$DOMAIN" ]]; then
                    DOMAIN="$1"
                else
                    warn "Неожиданный аргумент: $1 (будет проигнорирован)"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$DOMAIN" ]]; then
        interactive_prompt
    else
        validate_domain "$DOMAIN"
    fi
}

main() {
    print_header
    parse_args "$@"
    check_dependencies

    step "Запускаю проверку для домена ${BOLD}$DOMAIN${NC}..."
    echo
    run_checks "$DOMAIN"

    print_summary "$DOMAIN"
}

main "$@"

