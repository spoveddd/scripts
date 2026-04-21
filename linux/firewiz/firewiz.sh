#!/bin/bash
# firewiz — универсальный интерактивный менеджер firewall для Linux
# Поддержка: iptables, ip6tables, nftables, ufw, firewalld
# by Vladislav Pavlovich

set -o pipefail

# ---------- Цвета ----------
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    RED="$(tput setaf 1)";    GREEN="$(tput setaf 2)"
    YELLOW="$(tput setaf 3)"; BLUE="$(tput setaf 4)"
    MAGENTA="$(tput setaf 5)";CYAN="$(tput setaf 6)"
    RESET="$(tput sgr0)";     BOLD="$(tput bold)"
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; RESET=""; BOLD=""
fi

# ---------- Глобальное состояние ----------
BACKUP_DIR="/var/backups/firewiz"
BACKUP_KEEP=20                # сколько последних бэкапов хранить на каждый firewall
FIREWALLS=()                  # список активных firewall-систем
INIT="init"                   # systemd или init

# ---------- Служебное ----------
has_cmd() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
    # Зарезервировано под возможные будущие временные файлы.
    :
}
trap cleanup EXIT INT TERM

msg_ok()    { printf "${GREEN}%s${RESET}\n" "$*"; }
msg_err()   { printf "${RED}%s${RESET}\n"   "$*"; }
msg_warn()  { printf "${YELLOW}%s${RESET}\n" "$*"; }
msg_info()  { printf "${CYAN}%s${RESET}\n"  "$*"; }

# Запуск команды с захватом stdout+stderr и кодом возврата.
# Использование: run_cmd cmd arg1 arg2 ...
# После вызова: $RUN_OUT и $RUN_RC.
run_cmd() {
    local out rc
    out="$("$@" 2>&1)"
    rc=$?
    RUN_OUT="$out"
    RUN_RC=$rc
    return $rc
}

# Требуем root
require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        msg_err "Этот скрипт требует root-прав. Запустите через sudo."
        exit 1
    fi
}

# Определение init-системы
detect_init() {
    if pidof systemd >/dev/null 2>&1 || [ -d /run/systemd/system ]; then
        INIT="systemd"
    else
        INIT="init"
    fi
}

# Проверка: iptables использует nf_tables как backend?
is_iptables_nft_backend() {
    has_cmd iptables || return 1
    iptables -V 2>/dev/null | grep -qi nf_tables
}

# Определение активных firewall
detect_firewalls() {
    FIREWALLS=()
    # firewalld — активен, если запущен
    if has_cmd firewall-cmd && systemctl is-active firewalld >/dev/null 2>&1; then
        FIREWALLS+=("firewalld")
    fi
    # ufw — считаем активным только если status active
    if has_cmd ufw; then
        if ufw status 2>/dev/null | grep -qi 'Status: active'; then
            FIREWALLS+=("ufw")
        fi
    fi
    # nftables — активен, если есть непустой ruleset
    if has_cmd nft; then
        if nft list ruleset 2>/dev/null | grep -q .; then
            FIREWALLS+=("nftables")
        fi
    fi
    # iptables / ip6tables — добавляем, только если бинарники работают.
    # Избегаем `iptables -L` — используем -S, который менее инвазивный.
    if has_cmd iptables && iptables -S >/dev/null 2>&1; then
        FIREWALLS+=("iptables")
    fi
    if has_cmd ip6tables && ip6tables -S >/dev/null 2>&1; then
        FIREWALLS+=("ip6tables")
    fi
}

print_header() {
    printf "${BOLD}${CYAN}===== firewiz — Linux Firewall Manager =====${RESET}\n"
    printf "${BOLD}${CYAN}===== by Vladislav Pavlovich           =====${RESET}\n"
    if [ ${#FIREWALLS[@]} -eq 0 ]; then
        msg_warn "Активных firewall не обнаружено."
    else
        printf "${YELLOW}Обнаружены firewall-системы:${RESET} ${GREEN}%s${RESET}\n" "${FIREWALLS[*]}"
    fi
    printf "${CYAN}Init-система:${RESET} %s\n" "$INIT"
    if is_iptables_nft_backend; then
        msg_info "iptables использует nf_tables backend — правила iptables и nftables могут пересекаться."
    fi
    printf "\n"
}

# ---------- Валидация ввода ----------
is_valid_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

# IPv4-адрес (без маски)
is_ipv4_addr() {
    local ip="$1" oct
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for oct in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
        [ "$oct" -le 255 ] || return 1
    done
    return 0
}

# IPv4 подсеть a.b.c.d/m
is_ipv4_cidr() {
    local s="$1"
    [[ "$s" =~ ^(.+)/([0-9]+)$ ]] || return 1
    local ip="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}"
    is_ipv4_addr "$ip" || return 1
    [ "$m" -ge 0 ] && [ "$m" -le 32 ]
}

# Упрощённая проверка IPv6 (пропускает "::", сжатие, опциональный /prefix 0..128).
# Не 100% корректна, но отсекает явный мусор и принимает валидные сокращения.
is_ipv6_any() {
    local s="$1" addr prefix
    if [[ "$s" == */* ]]; then
        addr="${s%/*}"; prefix="${s#*/}"
        [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
        [ "$prefix" -ge 0 ] && [ "$prefix" -le 128 ] || return 1
    else
        addr="$s"
    fi
    # Должна быть хотя бы одна ':' и только допустимые символы
    [[ "$addr" == *:* ]] || return 1
    [[ "$addr" =~ ^[0-9a-fA-F:]+$ ]] || return 1
    # Не более одного "::"
    local dc="${addr//[^:]/}"
    # если есть "::", проверим что оно ровно одно
    if [[ "$addr" == *::* ]]; then
        local tmp="${addr//::/ }"
        [[ "$tmp" == *" "*" "* ]] && return 1
    fi
    # Ограничим число групп
    local groups_line="${addr//:/ }"
    local -a groups
    read -r -a groups <<< "$groups_line"
    [ "${#groups[@]}" -le 8 ] || return 1
    return 0
}

is_valid_ip_or_cidr() {
    local s="$1"
    is_ipv4_addr "$s" && return 0
    is_ipv4_cidr "$s" && return 0
    is_ipv6_any  "$s" && return 0
    return 1
}

# Определение семейства: "ipv4" или "ipv6" (предполагается, что is_valid_ip_or_cidr уже прошёл)
ip_family() {
    local s="$1"
    [[ "$s" == *:* ]] && echo "ipv6" || echo "ipv4"
}

# ---------- Универсальный выбор из списка ----------
# Использование: select_from_list "Вопрос:" "opt1" "opt2" ...
# Устанавливает SELECTED_INDEX и SELECTED_VALUE. Возврат по 0 -> rc=1.
select_from_list() {
    local prompt="$1"; shift
    local -a arr=("$@")
    local i num
    printf "%s\n" "$prompt"
    for i in "${!arr[@]}"; do
        printf "  %d) %s\n" "$((i+1))" "${arr[$i]}"
    done
    printf "  0) Вернуться\n"
    while true; do
        read -r -p "Номер: " num
        if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 0 ] && [ "$num" -le "${#arr[@]}" ]; then
            break
        fi
        msg_err "Некорректный номер."
    done
    if [ "$num" = "0" ]; then
        SELECTED_INDEX=-1; SELECTED_VALUE=""
        return 1
    fi
    SELECTED_INDEX=$((num-1))
    SELECTED_VALUE="${arr[$SELECTED_INDEX]}"
    return 0
}

select_firewall() {
    if [ ${#FIREWALLS[@]} -eq 0 ]; then
        msg_err "Активных firewall не обнаружено."
        return 1
    fi
    select_from_list "Выберите firewall:" "${FIREWALLS[@]}" || return 1
    FW_SELECTED="$SELECTED_VALUE"
    return 0
}

select_protocol() {
    select_from_list "Выберите протокол:" "tcp" "udp" || return 1
    PROTO_SELECTED="$SELECTED_VALUE"
    return 0
}

select_action_allow_deny() {
    select_from_list "Действие:" "Разрешить (allow)" "Запретить (drop)" "Отклонить (reject)" || return 1
    case "$SELECTED_INDEX" in
        0) ACTION_SELECTED="allow" ;;
        1) ACTION_SELECTED="deny"  ;;
        2) ACTION_SELECTED="reject";;
    esac
    return 0
}

# Ввод IP с валидацией, пустой ввод -> "любой"
read_ip_optional() {
    local ip
    while true; do
        read -r -p "IP или CIDR [Enter — любой]: " ip
        if [ -z "$ip" ]; then
            IP_INPUT=""
            return 0
        fi
        if is_valid_ip_or_cidr "$ip"; then
            IP_INPUT="$ip"
            return 0
        fi
        msg_err "Некорректный IP-адрес или подсеть."
    done
}

read_port_required() {
    local p
    while true; do
        read -r -p "Порт (1-65535): " p
        if is_valid_port "$p"; then
            PORT_INPUT="$p"
            return 0
        fi
        msg_err "Порт должен быть числом от 1 до 65535."
    done
}

read_ip_required() {
    local ip
    while true; do
        read -r -p "IP или CIDR: " ip
        if is_valid_ip_or_cidr "$ip"; then
            IP_INPUT="$ip"
            return 0
        fi
        msg_err "Некорректный IP-адрес или подсеть."
    done
}

# ---------- Просмотр правил ----------
show_policy_iptables() {
    local fw="$1"   # iptables | ip6tables
    local out
    out="$($fw -S 2>/dev/null | grep -E '^-P ' || true)"
    if [ -n "$out" ]; then
        printf "${BOLD}Политика по умолчанию:${RESET}\n"
        printf "%s\n" "$out" | sed 's/^/  /'
    fi
}

show_rules_iptables() {
    local fw="$1"
    printf "${BOLD}${MAGENTA}--- %s ---${RESET}\n" "$fw"
    show_policy_iptables "$fw"
    printf "${BOLD}Правила (INPUT/FORWARD/OUTPUT):${RESET}\n"
    $fw -S 2>/dev/null | grep -E '^-A (INPUT|FORWARD|OUTPUT)' | sed 's/^/  /' || true
    printf "\n"
}

show_rules_nftables() {
    printf "${BOLD}${MAGENTA}--- nftables ---${RESET}\n"
    if ! nft list ruleset 2>/dev/null | grep -q .; then
        msg_warn "Ruleset пуст."
        printf "\n"
        return
    fi
    nft list ruleset 2>/dev/null | sed 's/^/  /'
    printf "\n"
}

show_rules_ufw() {
    printf "${BOLD}${MAGENTA}--- ufw ---${RESET}\n"
    local status
    status="$(ufw status 2>/dev/null | head -n1)"
    printf "  %s\n" "$status"
    if echo "$status" | grep -qi inactive; then
        msg_warn "ufw выключен — правила неактивны."
        printf "\n"
        return
    fi
    ufw status numbered 2>/dev/null | sed '1,/^$/d' | sed 's/^/  /' || true
    printf "\n"
}

show_rules_firewalld() {
    printf "${BOLD}${MAGENTA}--- firewalld ---${RESET}\n"
    local zones zone
    zones="$(firewall-cmd --get-active-zones 2>/dev/null | awk 'NR%2==1')"
    if [ -z "$zones" ]; then
        msg_warn "Нет активных зон."
        printf "\n"
        return
    fi
    while IFS= read -r zone; do
        [ -z "$zone" ] && continue
        printf "  ${CYAN}Зона: %s${RESET}\n" "$zone"
        printf "    services : %s\n" "$(firewall-cmd --zone="$zone" --list-services 2>/dev/null)"
        printf "    ports    : %s\n" "$(firewall-cmd --zone="$zone" --list-ports    2>/dev/null)"
        printf "    sources  : %s\n" "$(firewall-cmd --zone="$zone" --list-sources  2>/dev/null)"
        local rich
        rich="$(firewall-cmd --zone="$zone" --list-rich-rules 2>/dev/null)"
        if [ -n "$rich" ]; then
            printf "    rich-rules:\n"
            printf "%s\n" "$rich" | sed 's/^/      /'
        fi
    done <<< "$zones"
    printf "\n"
}

show_all_rules() {
    print_header
    local fw
    for fw in "${FIREWALLS[@]}"; do
        case "$fw" in
            iptables|ip6tables) show_rules_iptables "$fw" ;;
            nftables)           show_rules_nftables ;;
            ufw)                show_rules_ufw ;;
            firewalld)          show_rules_firewalld ;;
        esac
    done
}

# ---------- Сбор правил для удаления ----------
# Заполняет массив RULES_DESC (человекочитаемо) и RULES_KEY (машиночитаемо).
# Формат RULES_KEY:
#   iptables|ip6tables : "chain:NUM"
#   ufw                : "NUM"
#   nftables           : "handle:TABLE:CHAIN:FAMILY:HANDLE"
#   firewalld          : "port:ZONE:port/proto" | "src:ZONE:cidr" | "rich:ZONE:<full_rich_rule>"
RULES_DESC=()
RULES_KEY=()

collect_rules_iptables() {
    local fw="$1" chain line num rest
    RULES_DESC=(); RULES_KEY=()
    for chain in INPUT FORWARD OUTPUT; do
        # -L с номерами даёт отформатированный вывод; используем -S для чистого и нумеруем сами,
        # но для удаления удобнее номера из -L --line-numbers.
        while IFS= read -r line; do
            # Формат: "NUM TARGET PROT OPT SRC DST [...]"
            if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]+(.*)$ ]]; then
                num="${BASH_REMATCH[1]}"
                rest="${BASH_REMATCH[2]}"
                RULES_DESC+=("[$chain #$num] $rest")
                RULES_KEY+=("$chain:$num")
            fi
        done < <($fw -L "$chain" --line-numbers -n 2>/dev/null | tail -n +3)
    done
}

collect_rules_ufw() {
    local line num body
    RULES_DESC=(); RULES_KEY=()
    # ufw status numbered выводит строки вида "[ 1] 22/tcp    ALLOW IN    Anywhere"
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[[[:space:]]*([0-9]+)\][[:space:]]+(.*)$ ]]; then
            num="${BASH_REMATCH[1]}"
            body="${BASH_REMATCH[2]}"
            RULES_DESC+=("[#$num] $body")
            RULES_KEY+=("$num")
        fi
    done < <(ufw status numbered 2>/dev/null)
}

collect_rules_nftables() {
    local line table chain family handle body
    RULES_DESC=(); RULES_KEY=()
    # Используем -a чтобы получить handle каждого правила.
    # Парсим контекст (table/chain/family) по ходу дела.
    table=""; chain=""; family=""
    while IFS= read -r line; do
        # Начало таблицы: "table inet filter {"
        if [[ "$line" =~ ^[[:space:]]*table[[:space:]]+([a-z0-9]+)[[:space:]]+([A-Za-z0-9_-]+) ]]; then
            family="${BASH_REMATCH[1]}"
            table="${BASH_REMATCH[2]}"
            continue
        fi
        # Начало chain: "        chain input {"
        if [[ "$line" =~ ^[[:space:]]*chain[[:space:]]+([A-Za-z0-9_-]+) ]]; then
            chain="${BASH_REMATCH[1]}"
            continue
        fi
        # Правило с handle: "... # handle 12"
        if [[ "$line" =~ \#[[:space:]]*handle[[:space:]]+([0-9]+)[[:space:]]*$ ]]; then
            handle="${BASH_REMATCH[1]}"
            # Тело правила — всё до "# handle"
            body="$(echo "$line" | sed -E 's/[[:space:]]*#[[:space:]]*handle[[:space:]]+[0-9]+[[:space:]]*$//' | sed -E 's/^[[:space:]]+//')"
            # Пропускаем строки, не являющиеся правилами (type hook priority и т.п. не имеют handle в такой позиции, но на всякий случай)
            if [ -n "$table" ] && [ -n "$chain" ] && [ -n "$body" ]; then
                RULES_DESC+=("[$family $table/$chain h=$handle] $body")
                RULES_KEY+=("handle:$table:$chain:$family:$handle")
            fi
        fi
    done < <(nft -a list ruleset 2>/dev/null)
}

collect_rules_firewalld() {
    local zones zone port src rich
    RULES_DESC=(); RULES_KEY=()
    zones="$(firewall-cmd --get-active-zones 2>/dev/null | awk 'NR%2==1')"
    while IFS= read -r zone; do
        [ -z "$zone" ] && continue
        while IFS= read -r port; do
            [ -z "$port" ] && continue
            RULES_DESC+=("[zone=$zone] port $port")
            RULES_KEY+=("port:$zone:$port")
        done < <(firewall-cmd --zone="$zone" --list-ports 2>/dev/null | tr ' ' '\n')
        while IFS= read -r src; do
            [ -z "$src" ] && continue
            RULES_DESC+=("[zone=$zone] source $src")
            RULES_KEY+=("src:$zone:$src")
        done < <(firewall-cmd --zone="$zone" --list-sources 2>/dev/null | tr ' ' '\n')
        while IFS= read -r rich; do
            [ -z "$rich" ] && continue
            RULES_DESC+=("[zone=$zone] rich: $rich")
            RULES_KEY+=("rich:$zone:$rich")
        done < <(firewall-cmd --zone="$zone" --list-rich-rules 2>/dev/null)
    done <<< "$zones"
}

collect_rules_for() {
    case "$1" in
        iptables|ip6tables) collect_rules_iptables "$1" ;;
        ufw)                collect_rules_ufw ;;
        nftables)           collect_rules_nftables ;;
        firewalld)          collect_rules_firewalld ;;
    esac
}

# ---------- Бэкапы ----------
ensure_backup_dir() {
    if [ ! -d "$BACKUP_DIR" ]; then
        mkdir -p "$BACKUP_DIR" || {
            msg_err "Не удалось создать $BACKUP_DIR"
            return 1
        }
        chmod 700 "$BACKUP_DIR" 2>/dev/null || true
    fi
}

rotate_backups() {
    local pattern="$1"  # например: iptables_*.rules
    ensure_backup_dir || return
    local -a files
    mapfile -t files < <(ls -1t "$BACKUP_DIR"/$pattern 2>/dev/null)
    local total="${#files[@]}"
    if [ "$total" -gt "$BACKUP_KEEP" ]; then
        local i
        for ((i=BACKUP_KEEP; i<total; i++)); do
            rm -f "${files[$i]}"
        done
    fi
}

backup_firewall() {
    local fw="$1" ts file
    ensure_backup_dir || return 1
    ts="$(date +%Y%m%d_%H%M%S)"
    case "$fw" in
        iptables)
            has_cmd iptables-save || { msg_err "iptables-save не найден"; return 1; }
            file="$BACKUP_DIR/iptables_$ts.rules"
            iptables-save > "$file" && msg_info "Бэкап: $file"
            rotate_backups "iptables_*.rules"
            ;;
        ip6tables)
            has_cmd ip6tables-save || { msg_err "ip6tables-save не найден"; return 1; }
            file="$BACKUP_DIR/ip6tables_$ts.rules"
            ip6tables-save > "$file" && msg_info "Бэкап: $file"
            rotate_backups "ip6tables_*.rules"
            ;;
        nftables)
            file="$BACKUP_DIR/nftables_$ts.nft"
            nft list ruleset > "$file" && msg_info "Бэкап: $file"
            rotate_backups "nftables_*.nft"
            ;;
        ufw)
            # ufw хранит правила в /etc/ufw; сохраним tarball
            file="$BACKUP_DIR/ufw_$ts.tar.gz"
            tar -czf "$file" -C / etc/ufw 2>/dev/null && msg_info "Бэкап: $file"
            rotate_backups "ufw_*.tar.gz"
            ;;
        firewalld)
            file="$BACKUP_DIR/firewalld_$ts.tar.gz"
            tar -czf "$file" -C / etc/firewalld 2>/dev/null && msg_info "Бэкап: $file"
            rotate_backups "firewalld_*.tar.gz"
            ;;
        *) msg_err "Бэкап для $fw не поддерживается"; return 1 ;;
    esac
}

restore_menu() {
    printf "${BOLD}${CYAN}Восстановление из бэкапа${RESET}\n"
    select_firewall || return
    local pattern ext
    case "$FW_SELECTED" in
        iptables)  pattern="iptables_*.rules" ;;
        ip6tables) pattern="ip6tables_*.rules" ;;
        nftables)  pattern="nftables_*.nft" ;;
        ufw)       pattern="ufw_*.tar.gz" ;;
        firewalld) pattern="firewalld_*.tar.gz" ;;
        *) msg_err "Неподдерживаемый firewall"; return ;;
    esac
    ensure_backup_dir || return
    local -a files
    mapfile -t files < <(ls -1t "$BACKUP_DIR"/$pattern 2>/dev/null)
    if [ ${#files[@]} -eq 0 ]; then
        msg_warn "Бэкапов не найдено."
        return
    fi
    select_from_list "Выберите файл:" "${files[@]}" || return
    local file="$SELECTED_VALUE"
    case "$FW_SELECTED" in
        iptables)
            if iptables-restore < "$file" 2>/dev/null; then
                msg_ok "iptables восстановлены из $file"
            else
                msg_err "Ошибка восстановления iptables из $file"
            fi
            ;;
        ip6tables)
            if ip6tables-restore < "$file" 2>/dev/null; then
                msg_ok "ip6tables восстановлены из $file"
            else
                msg_err "Ошибка восстановления ip6tables из $file"
            fi
            ;;
        nftables)
            if nft -f "$file" 2>/dev/null; then
                msg_ok "nftables восстановлены из $file"
            else
                msg_err "Ошибка восстановления nftables из $file"
            fi
            ;;
        ufw)
            msg_warn "Автовосстановление ufw отключит и перезапишет /etc/ufw."
            read -r -p "Продолжить? [y/N]: " ans
            [[ "$ans" =~ ^[Yy]$ ]] || return
            ufw --force disable >/dev/null 2>&1 || true
            if tar -xzf "$file" -C / ; then
                ufw --force enable >/dev/null 2>&1 || true
                msg_ok "ufw восстановлен из $file"
            else
                msg_err "Ошибка распаковки $file"
            fi
            ;;
        firewalld)
            msg_warn "Автовосстановление firewalld перезапишет /etc/firewalld."
            read -r -p "Продолжить? [y/N]: " ans
            [[ "$ans" =~ ^[Yy]$ ]] || return
            if tar -xzf "$file" -C / ; then
                firewall-cmd --reload >/dev/null 2>&1 || true
                msg_ok "firewalld восстановлен из $file"
            else
                msg_err "Ошибка распаковки $file"
            fi
            ;;
    esac
}

# ---------- Добавление правила ----------
add_rule() {
    printf "${BOLD}${GREEN}Добавление правила${RESET}\n"
    select_firewall     || return
    read_port_required  || return
    select_protocol     || return
    read_ip_optional    || return
    select_action_allow_deny || return

    local port="$PORT_INPUT"
    local proto="$PROTO_SELECTED"
    local ip="$IP_INPUT"
    local action="$ACTION_SELECTED"

    case "$FW_SELECTED" in
        iptables)
            if [ -n "$ip" ] && [ "$(ip_family "$ip")" = "ipv6" ]; then
                msg_err "Для IPv6 используйте ip6tables."
                return
            fi
            local target
            case "$action" in
                allow)  target="ACCEPT" ;;
                deny)   target="DROP"   ;;
                reject) target="REJECT" ;;
            esac
            local -a args=(-A INPUT -p "$proto" --dport "$port")
            [ -n "$ip" ] && args+=(-s "$ip")
            args+=(-j "$target")
            if run_cmd iptables "${args[@]}"; then
                msg_ok "Правило добавлено в iptables."
            else
                msg_err "Ошибка: $RUN_OUT"
            fi
            ;;
        ip6tables)
            if [ -n "$ip" ] && [ "$(ip_family "$ip")" = "ipv4" ]; then
                msg_err "Для IPv4 используйте iptables."
                return
            fi
            local target
            case "$action" in
                allow)  target="ACCEPT" ;;
                deny)   target="DROP"   ;;
                reject) target="REJECT" ;;
            esac
            local -a args=(-A INPUT -p "$proto" --dport "$port")
            [ -n "$ip" ] && args+=(-s "$ip")
            args+=(-j "$target")
            if run_cmd ip6tables "${args[@]}"; then
                msg_ok "Правило добавлено в ip6tables."
            else
                msg_err "Ошибка: $RUN_OUT"
            fi
            ;;
        nftables)
            # Создадим таблицу/цепочку при необходимости
            nft list table inet filter >/dev/null 2>&1 || \
                nft add table inet filter 2>/dev/null
            nft list chain inet filter input >/dev/null 2>&1 || \
                nft add chain inet filter input '{ type filter hook input priority 0; }' 2>/dev/null

            local verdict
            case "$action" in
                allow)  verdict="accept" ;;
                deny)   verdict="drop"   ;;
                reject) verdict="reject" ;;
            esac
            local -a args=(add rule inet filter input)
            if [ -n "$ip" ]; then
                if [ "$(ip_family "$ip")" = "ipv6" ]; then
                    args+=(ip6 saddr "$ip")
                else
                    args+=(ip saddr "$ip")
                fi
            fi
            args+=("$proto" dport "$port" "$verdict")
            if run_cmd nft "${args[@]}"; then
                msg_ok "Правило добавлено в nftables."
            else
                msg_err "Ошибка: $RUN_OUT"
            fi
            ;;
        ufw)
            local -a args
            case "$action" in
                allow)  args=(allow)  ;;
                deny)   args=(deny)   ;;
                reject) args=(reject) ;;
            esac
            if [ -n "$ip" ]; then
                args+=(from "$ip" to any port "$port" proto "$proto")
            else
                args+=("$port/$proto")
            fi
            if run_cmd ufw "${args[@]}"; then
                msg_ok "Правило добавлено в ufw."
            else
                msg_err "Ошибка: $RUN_OUT"
            fi
            ;;
        firewalld)
            local zone
            zone="$(firewall-cmd --get-default-zone 2>/dev/null)"
            if [ -z "$zone" ]; then
                msg_err "Не удалось определить зону firewalld."
                return
            fi
            if [ -z "$ip" ]; then
                if [ "$action" = "allow" ]; then
                    run_cmd firewall-cmd --zone="$zone" --add-port="$port/$proto" --permanent
                else
                    # В firewalld нет «запрета порта» в общем виде — делаем rich rule
                    local rr="rule port port=\"$port\" protocol=\"$proto\" "
                    [ "$action" = "reject" ] && rr+="reject" || rr+="drop"
                    run_cmd firewall-cmd --zone="$zone" --add-rich-rule="$rr" --permanent
                fi
            else
                local fam
                fam="$(ip_family "$ip")"
                local rr="rule family=\"$fam\" source address=\"$ip\" port port=\"$port\" protocol=\"$proto\" "
                case "$action" in
                    allow)  rr+="accept" ;;
                    deny)   rr+="drop"   ;;
                    reject) rr+="reject" ;;
                esac
                run_cmd firewall-cmd --zone="$zone" --add-rich-rule="$rr" --permanent
            fi
            if [ "$RUN_RC" -eq 0 ]; then
                firewall-cmd --reload >/dev/null 2>&1
                msg_ok "Правило добавлено в firewalld (zone=$zone)."
            else
                msg_err "Ошибка: $RUN_OUT"
            fi
            ;;
    esac
}

# ---------- Удаление правила ----------
remove_rule() {
    printf "${BOLD}${RED}Удаление правила${RESET}\n"
    select_firewall || return

    while true; do
        collect_rules_for "$FW_SELECTED"
        if [ ${#RULES_DESC[@]} -eq 0 ]; then
            msg_warn "Нет правил для удаления."
            return
        fi
        select_from_list "Выберите правило:" "${RULES_DESC[@]}" || return
        local key="${RULES_KEY[$SELECTED_INDEX]}"

        case "$FW_SELECTED" in
            iptables|ip6tables)
                local chain num
                chain="${key%%:*}"
                num="${key##*:}"
                if run_cmd "$FW_SELECTED" -D "$chain" "$num"; then
                    msg_ok "Правило $chain #$num удалено."
                else
                    msg_err "Ошибка: $RUN_OUT"
                fi
                ;;
            ufw)
                # ufw delete требует подтверждения; подаём "y"
                if echo "y" | ufw delete "$key" >/dev/null 2>&1; then
                    msg_ok "Правило #$key удалено."
                else
                    msg_err "Не удалось удалить правило #$key."
                fi
                ;;
            nftables)
                # key: handle:TABLE:CHAIN:FAMILY:HANDLE
                local _ table chain family handle
                IFS=':' read -r _ table chain family handle <<< "$key"
                if run_cmd nft delete rule "$family" "$table" "$chain" handle "$handle"; then
                    msg_ok "Правило handle=$handle удалено."
                else
                    msg_err "Ошибка: $RUN_OUT"
                fi
                ;;
            firewalld)
                # key: TYPE:ZONE:VALUE (TYPE = port|src|rich)
                local rtype zone value
                rtype="${key%%:*}"
                local rest="${key#*:}"
                zone="${rest%%:*}"
                value="${rest#*:}"
                case "$rtype" in
                    port) run_cmd firewall-cmd --zone="$zone" --remove-port="$value" --permanent ;;
                    src)  run_cmd firewall-cmd --zone="$zone" --remove-source="$value" --permanent ;;
                    rich) run_cmd firewall-cmd --zone="$zone" --remove-rich-rule="$value" --permanent ;;
                esac
                if [ "$RUN_RC" -eq 0 ]; then
                    firewall-cmd --reload >/dev/null 2>&1
                    msg_ok "Правило удалено (zone=$zone)."
                else
                    msg_err "Ошибка: $RUN_OUT"
                fi
                ;;
        esac
    done
}

# ---------- Блокировка адреса ----------
block_ip_menu() {
    printf "${BOLD}${RED}Полная блокировка адреса${RESET}\n"
    select_firewall  || return
    read_ip_required || return
    local ip="$IP_INPUT"
    local fam
    fam="$(ip_family "$ip")"

    case "$FW_SELECTED" in
        iptables)
            if [ "$fam" = "ipv6" ]; then msg_err "Для IPv6 используйте ip6tables."; return; fi
            run_cmd iptables -I INPUT -s "$ip" -j DROP
            ;;
        ip6tables)
            if [ "$fam" = "ipv4" ]; then msg_err "Для IPv4 используйте iptables."; return; fi
            run_cmd ip6tables -I INPUT -s "$ip" -j DROP
            ;;
        nftables)
            nft list table inet filter >/dev/null 2>&1 || nft add table inet filter 2>/dev/null
            nft list chain inet filter input >/dev/null 2>&1 || \
                nft add chain inet filter input '{ type filter hook input priority 0; }' 2>/dev/null
            if [ "$fam" = "ipv6" ]; then
                run_cmd nft add rule inet filter input ip6 saddr "$ip" drop
            else
                run_cmd nft add rule inet filter input ip  saddr "$ip" drop
            fi
            ;;
        ufw)
            run_cmd ufw deny from "$ip"
            ;;
        firewalld)
            local zone
            zone="$(firewall-cmd --get-default-zone 2>/dev/null)"
            [ -z "$zone" ] && { msg_err "Не удалось определить зону."; return; }
            run_cmd firewall-cmd --zone="$zone" \
                --add-rich-rule="rule family=\"$fam\" source address=\"$ip\" drop" --permanent
            [ "$RUN_RC" -eq 0 ] && firewall-cmd --reload >/dev/null 2>&1
            ;;
    esac
    if [ "$RUN_RC" -eq 0 ]; then
        msg_ok "Адрес $ip заблокирован."
    else
        msg_err "Ошибка: $RUN_OUT"
    fi
}

# ---------- Сохранение изменений ----------
save_rules() {
    printf "${BOLD}${CYAN}Сохранение изменений${RESET}\n"
    local fw ok=1
    for fw in "${FIREWALLS[@]}"; do
        case "$fw" in
            iptables)
                if [ -d /etc/iptables ] || mkdir -p /etc/iptables 2>/dev/null; then
                    iptables-save > /etc/iptables/rules.v4 && \
                        msg_ok "iptables → /etc/iptables/rules.v4" || { msg_err "iptables save failed"; ok=0; }
                else
                    msg_err "Не удалось создать /etc/iptables"; ok=0
                fi
                ;;
            ip6tables)
                if [ -d /etc/iptables ] || mkdir -p /etc/iptables 2>/dev/null; then
                    ip6tables-save > /etc/iptables/rules.v6 && \
                        msg_ok "ip6tables → /etc/iptables/rules.v6" || { msg_err "ip6tables save failed"; ok=0; }
                else
                    msg_err "Не удалось создать /etc/iptables"; ok=0
                fi
                ;;
            nftables)
                if [ -w /etc/nftables.conf ] || [ ! -e /etc/nftables.conf ]; then
                    {
                        echo "#!/usr/sbin/nft -f"
                        echo "flush ruleset"
                        nft list ruleset
                    } > /etc/nftables.conf && msg_ok "nftables → /etc/nftables.conf" \
                      || { msg_err "nftables save failed"; ok=0; }
                else
                    msg_err "/etc/nftables.conf недоступен для записи"; ok=0
                fi
                ;;
            ufw)
                # ufw применяет изменения сразу; просто reload
                if ufw status | grep -qi active; then
                    ufw reload >/dev/null 2>&1 && msg_ok "ufw перезагружен"
                else
                    msg_warn "ufw неактивен — reload не требуется"
                fi
                ;;
            firewalld)
                if run_cmd firewall-cmd --runtime-to-permanent; then
                    msg_ok "firewalld: runtime → permanent"
                else
                    # Может быть, изменения уже permanent — просто reload
                    firewall-cmd --reload >/dev/null 2>&1 && msg_ok "firewalld reload" || { msg_err "$RUN_OUT"; ok=0; }
                fi
                ;;
        esac
    done
    [ "$ok" -eq 1 ] && msg_ok "Готово." || msg_warn "Завершено с ошибками."
}

# ---------- Старт / стоп firewall ----------
service_action() {
    local svc="$1" action="$2"
    if [ "$INIT" = "systemd" ]; then
        run_cmd systemctl "$action" "$svc"
    else
        run_cmd service "$svc" "$action"
    fi
}

set_firewall_state() {
    printf "${BOLD}${YELLOW}Включение/отключение firewall${RESET}\n"
    select_firewall || return
    local svc="$FW_SELECTED"

    case "$svc" in
        ufw)
            select_from_list "Действие:" "enable" "disable" || return
            if [ "$SELECTED_VALUE" = "disable" ]; then
                backup_firewall ufw
            fi
            if run_cmd ufw --force "$SELECTED_VALUE"; then
                msg_ok "ufw: $SELECTED_VALUE выполнено."
            else
                msg_err "Ошибка: $RUN_OUT"
            fi
            ;;
        iptables|ip6tables)
            select_from_list "Действие:" "start" "stop" "restart" || return
            local act="$SELECTED_VALUE"
            if [ "$act" = "stop" ] || [ "$act" = "restart" ]; then
                backup_firewall "$svc"
            fi
            # На многих системах systemd-юнита iptables нет; предложим вариант:
            # - при "stop" просто флушим правила и ставим ACCEPT
            # - при "start" — восстанавливаем последний бэкап (с подтверждением)
            if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
                if service_action "$svc" "$act"; then
                    msg_ok "$svc: $act выполнено."
                else
                    msg_warn "systemctl $act $svc не удалось: $RUN_OUT"
                    msg_info "Применяю ручной режим..."
                    manual_iptables_action "$svc" "$act"
                fi
            else
                msg_info "Юнит $svc отсутствует — применяю ручной режим."
                manual_iptables_action "$svc" "$act"
            fi
            ;;
        nftables|firewalld)
            select_from_list "Действие:" "start" "stop" "restart" || return
            if service_action "$svc" "$SELECTED_VALUE"; then
                msg_ok "$svc: $SELECTED_VALUE выполнено."
            else
                msg_err "Ошибка: $RUN_OUT"
            fi
            ;;
    esac
}

manual_iptables_action() {
    local svc="$1" act="$2"
    case "$act" in
        stop)
            "$svc" -F
            "$svc" -X
            "$svc" -P INPUT   ACCEPT
            "$svc" -P OUTPUT  ACCEPT
            "$svc" -P FORWARD ACCEPT
            msg_ok "$svc: правила очищены, политика ACCEPT."
            ;;
        start|restart)
            local pattern last
            [ "$svc" = "iptables" ] && pattern="iptables_*.rules" || pattern="ip6tables_*.rules"
            last="$(ls -1t "$BACKUP_DIR"/$pattern 2>/dev/null | head -n1)"
            if [ -n "$last" ]; then
                read -r -p "Восстановить правила из $last? [y/N]: " ans
                if [[ "$ans" =~ ^[Yy]$ ]]; then
                    if [ "$svc" = "iptables" ]; then
                        iptables-restore < "$last"  && msg_ok "iptables восстановлены из $last"
                    else
                        ip6tables-restore < "$last" && msg_ok "ip6tables восстановлены из $last"
                    fi
                fi
            else
                msg_warn "Бэкап не найден — нечего восстанавливать."
            fi
            ;;
    esac
}

# ---------- Сброс ----------
reset_firewall() {
    printf "${BOLD}${YELLOW}Сброс правил firewall${RESET}\n"
    msg_warn "Перед сбросом будет сделан бэкап."
    read -r -p "Продолжить? [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]] || return

    local fw
    for fw in "${FIREWALLS[@]}"; do
        case "$fw" in
            iptables)
                backup_firewall iptables
                iptables -F; iptables -X
                iptables -P INPUT ACCEPT
                iptables -P OUTPUT ACCEPT
                iptables -P FORWARD ACCEPT
                msg_ok "iptables сброшен."
                ;;
            ip6tables)
                backup_firewall ip6tables
                ip6tables -F; ip6tables -X
                ip6tables -P INPUT ACCEPT
                ip6tables -P OUTPUT ACCEPT
                ip6tables -P FORWARD ACCEPT
                msg_ok "ip6tables сброшен."
                ;;
            nftables)
                backup_firewall nftables
                nft flush ruleset
                msg_ok "nftables: ruleset очищен."
                ;;
            ufw)
                backup_firewall ufw
                ufw --force reset  >/dev/null 2>&1
                ufw --force disable >/dev/null 2>&1
                msg_ok "ufw: правила сброшены и ufw отключён."
                ;;
            firewalld)
                backup_firewall firewalld
                local zones zone
                zones="$(firewall-cmd --get-active-zones 2>/dev/null | awk 'NR%2==1')"
                while IFS= read -r zone; do
                    [ -z "$zone" ] && continue
                    # Удаляем все порты, источники и rich-правила
                    local p
                    for p in $(firewall-cmd --zone="$zone" --list-ports 2>/dev/null); do
                        firewall-cmd --zone="$zone" --remove-port="$p" --permanent >/dev/null 2>&1
                    done
                    for p in $(firewall-cmd --zone="$zone" --list-sources 2>/dev/null); do
                        firewall-cmd --zone="$zone" --remove-source="$p" --permanent >/dev/null 2>&1
                    done
                    # rich rules
                    local rr
                    while IFS= read -r rr; do
                        [ -z "$rr" ] && continue
                        firewall-cmd --zone="$zone" --remove-rich-rule="$rr" --permanent >/dev/null 2>&1
                    done < <(firewall-cmd --zone="$zone" --list-rich-rules 2>/dev/null)
                done <<< "$zones"
                firewall-cmd --reload >/dev/null 2>&1
                msg_ok "firewalld: правила во всех активных зонах сброшены."
                ;;
        esac
    done
}

# ---------- Главное меню ----------
main_menu() {
    show_all_rules
    while true; do
        printf "\n${BOLD}${CYAN}Меню:${RESET}\n"
        printf "  ${YELLOW}1${RESET} — Показать правила\n"
        printf "  ${YELLOW}2${RESET} — Добавить правило\n"
        printf "  ${YELLOW}3${RESET} — Удалить правило\n"
        printf "  ${YELLOW}4${RESET} — Заблокировать адрес\n"
        printf "  ${YELLOW}5${RESET} — Сохранить изменения\n"
        printf "  ${YELLOW}6${RESET} — Включить/отключить firewall\n"
        printf "  ${YELLOW}7${RESET} — Восстановить из бэкапа\n"
        printf "  ${YELLOW}8${RESET} — Сбросить правила (с бэкапом)\n"
        printf "  ${YELLOW}9${RESET} — Обновить список активных firewall\n"
        printf "  ${YELLOW}0${RESET} — Выход\n"
        local choice
        read -r -p "Выбор: " choice
        case "$choice" in
            1) show_all_rules ;;
            2) add_rule ;;
            3) remove_rule ;;
            4) block_ip_menu ;;
            5) save_rules ;;
            6) set_firewall_state ;;
            7) restore_menu ;;
            8) reset_firewall ;;
            9) detect_firewalls; show_all_rules ;;
            0) exit 0 ;;
            *) msg_err "Неверный выбор." ;;
        esac
    done
}

# ---------- Точка входа ----------
require_root
detect_init
detect_firewalls
main_menu