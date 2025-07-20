#!/bin/bash
# Универсальный скрипт для анализа и управления firewall в Linux
# Поддержка: iptables, ip6tables, nftables, ufw, firewalld
# Цветной вывод, интерактивное меню, поддержка systemd и init

# Цвета
RED="$(tput setaf 1)"
GREEN="$(tput setaf 2)"
YELLOW="$(tput setaf 3)"
BLUE="$(tput setaf 4)"
MAGENTA="$(tput setaf 5)"
CYAN="$(tput setaf 6)"
RESET="$(tput sgr0)"
BOLD="$(tput bold)"

# Проверка наличия команды
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# Определение init-системы
if pidof systemd >/dev/null 2>&1; then
    INIT=systemd
else
    INIT=init
fi

# Определение активных firewall
FIREWALLS=""
ACTIVE_FIREWALL=""

has_cmd firewalld && systemctl is-active firewalld >/dev/null 2>&1 && FIREWALLS="$FIREWALLS firewalld"
# Всегда добавляем ufw, если установлен
has_cmd ufw && FIREWALLS="$FIREWALLS ufw"
has_cmd nft && nft list ruleset >/dev/null 2>&1 && FIREWALLS="$FIREWALLS nftables"
has_cmd iptables && iptables -L >/dev/null 2>&1 && FIREWALLS="$FIREWALLS iptables"
has_cmd ip6tables && ip6tables -L >/dev/null 2>&1 && FIREWALLS="$FIREWALLS ip6tables"

# Вывод заголовка
print_header() {
    printf "${BOLD}${CYAN}===== Linux Firewall Analyzer =====${RESET}\n"
    printf "${BOLD}${CYAN}===== by Vladislav Pavlovich =====${RESET}\n"
    printf "${YELLOW}Обнаружены firewall-системы:${RESET} ${GREEN}%s${RESET}\n" "$FIREWALLS"
    printf "${CYAN}Init-система:${RESET} $INIT\n\n"
    # Предупреждение о дублировании
    if echo "$FIREWALLS" | grep -q 'nftables' && echo "$FIREWALLS" | grep -q 'iptables'; then
        printf "${YELLOW}ВНИМАНИЕ:${RESET} nftables и iptables могут дублировать правила! Если nftables использует iptables как backend, правила будут одинаковы.\n\n"
    fi
}

# Получить список активных firewall как массив
get_firewalls() {
    FWS=()
    for fw in $FIREWALLS; do
        FWS+=("$fw")
    done
}

# Универсальный выбор по цифре (с возвратом по 0, 0 внизу)
select_from_list() {
    local prompt="$1"
    shift
    local arr=("$@")
    local i
    printf "%s\n" "$prompt"
    for i in "${!arr[@]}"; do
        printf "  %s) %s\n" "$((i+1))" "${arr[$i]}"
    done
    printf "  0) Вернуться в меню\n"
    local num
    while true; do
        read -p "Номер: " num
        if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 0 ] && [ "$num" -le "${#arr[@]}" ]; then
            break
        fi
        printf "${RED}Некорректный номер!${RESET}\n"
    done
    if [ "$num" = "0" ]; then
        SELECTED_INDEX=-1
        SELECTED_VALUE=""
        return 1
    fi
    SELECTED_INDEX=$((num-1))
    SELECTED_VALUE="${arr[$SELECTED_INDEX]}"
    return 0
}

# Выбор firewall по номеру
select_firewall() {
    get_firewalls
    select_from_list "Выберите firewall:" "${FWS[@]}"
    if [ $? -ne 0 ]; then
        return 1
    fi
    FW_SELECTED="$SELECTED_VALUE"
}

# Выбор действия (например, allow/deny/reject или start/stop)
select_action() {
    local prompt="$1"
    shift
    local actions=("$@")
    # Если действия — стандартные для firewall, показываем на русском
    if [ "${actions[*]}" = "allow deny reject" ]; then
        select_from_list "$prompt" "Разрешить" "Запретить" "Отклонить"
        if [ $? -ne 0 ]; then
            return 1
        fi
        case $SELECTED_INDEX in
            0) ACTION_SELECTED="allow" ;;
            1) ACTION_SELECTED="deny" ;;
            2) ACTION_SELECTED="reject" ;;
        esac
        return 0
    fi
    select_from_list "$prompt" "${actions[@]}"
    if [ $? -ne 0 ]; then
        return 1
    fi
    ACTION_SELECTED="$SELECTED_VALUE"
    return 0
}

# Универсальный выбор протокола (tcp/udp)
select_protocol() {
    select_from_list "Выберите протокол:" "tcp" "udp"
    if [ $? -ne 0 ]; then
        return 1
    fi
    PROTO_SELECTED="$SELECTED_VALUE"
}

# Парсинг iptables/ip6tables (разделяю адреса и подсети, /32 и /128 считаю адресом)
parse_iptables() {
    local cmd="$1"
    local allow_ports=""
    local deny_ports=""
    local allow_ips=""
    local deny_ips=""
    local allow_subnets=""
    local deny_subnets=""
    while read -r line; do
        case "$line" in
            -A*ACCEPT*)
                port=$(echo "$line" | grep -o -- '--dport [0-9]*' | awk '{print $2}')
                proto=$(echo "$line" | grep -o -- '-p [a-z]*' | awk '{print $2}')
                ip=$(echo "$line" | grep -o -- '-s [^ ]*' | awk '{print $2}')
                [ -n "$port" ] && allow_ports="$allow_ports $port/${proto:-tcp}"
                if [ -n "$ip" ]; then
                  if echo "$ip" | grep -q '/'; then
                    mask=$(echo "$ip" | cut -d'/' -f2)
                    if [ "$mask" = "32" ] || [ "$mask" = "128" ]; then
                      allow_ips="$allow_ips $(echo "$ip" | cut -d'/' -f1)"
                    else
                      allow_subnets="$allow_subnets $ip"
                    fi
                  else
                    allow_ips="$allow_ips $ip"
                  fi
                fi
                ;;
            -A*DROP*|-A*REJECT*)
                port=$(echo "$line" | grep -o -- '--dport [0-9]*' | awk '{print $2}')
                proto=$(echo "$line" | grep -o -- '-p [a-z]*' | awk '{print $2}')
                ip=$(echo "$line" | grep -o -- '-s [^ ]*' | awk '{print $2}')
                [ -n "$port" ] && deny_ports="$deny_ports $port/${proto:-tcp}"
                if [ -n "$ip" ]; then
                  if echo "$ip" | grep -q '/'; then
                    mask=$(echo "$ip" | cut -d'/' -f2)
                    if [ "$mask" = "32" ] || [ "$mask" = "128" ]; then
                      deny_ips="$deny_ips $(echo "$ip" | cut -d'/' -f1)"
                    else
                      deny_subnets="$deny_subnets $ip"
                    fi
                  else
                    deny_ips="$deny_ips $ip"
                  fi
                fi
                ;;
        esac
    done <<EOF
$($cmd -S)
EOF
    printf "${BOLD}${MAGENTA}--- $cmd ---${RESET}\n"
    printf "${GREEN}Разрешены:${RESET}\n  Порты: $allow_ports\n  Адреса: $allow_ips\n  Подсети: $allow_subnets\n"
    printf "${RED}Заблокированы:${RESET}\n  Порты: $deny_ports\n  Адреса: $deny_ips\n  Подсети: $deny_subnets\n\n"
}

# Парсинг nftables (разделяю адреса и подсети)
parse_nftables() {
    local allow_ports=""
    local deny_ports=""
    local allow_ips=""
    local deny_ips=""
    local allow_subnets=""
    local deny_subnets=""
    while read -r line; do
        case "$line" in
            *accept*)
                port=$(echo "$line" | grep -oE 'dport [0-9]+' | awk '{print $2}')
                proto=$(echo "$line" | grep -oE 'ip protocol [a-z]+' | awk '{print $3}')
                ip=$(echo "$line" | grep -oE 'ip saddr [^ ]+' | awk '{print $3}')
                [ -n "$port" ] && allow_ports="$allow_ports $port/${proto:-tcp}"
                if [ -n "$ip" ]; then
                  if echo "$ip" | grep -q '/'; then
                    allow_subnets="$allow_subnets $ip"
                  else
                    allow_ips="$allow_ips $ip"
                  fi
                fi
                ;;
            *drop*|*reject*)
                port=$(echo "$line" | grep -oE 'dport [0-9]+' | awk '{print $2}')
                proto=$(echo "$line" | grep -oE 'ip protocol [a-z]+' | awk '{print $3}')
                ip=$(echo "$line" | grep -oE 'ip saddr [^ ]+' | awk '{print $3}')
                [ -n "$port" ] && deny_ports="$deny_ports $port/${proto:-tcp}"
                if [ -n "$ip" ]; then
                  if echo "$ip" | grep -q '/'; then
                    deny_subnets="$deny_subnets $ip"
                  else
                    deny_ips="$deny_ips $ip"
                  fi
                fi
                ;;
        esac
    done <<EOF
$(nft list ruleset)
EOF
    printf "${BOLD}${MAGENTA}--- nftables ---${RESET}\n"
    printf "${GREEN}Разрешены:${RESET}\n  Порты: $allow_ports\n  Адреса: $allow_ips\n  Подсети: $allow_subnets\n"
    printf "${RED}Заблокированы:${RESET}\n  Порты: $deny_ports\n  Адреса: $deny_ips\n  Подсети: $deny_subnets\n\n"
}

# Парсинг ufw (разделяю адреса и подсети, показываю статус)
parse_ufw() {
    local allow_ports=""
    local deny_ports=""
    local allow_ips=""
    local deny_ips=""
    local allow_subnets=""
    local deny_subnets=""
    local status=""
    status=$(ufw status | grep 'Status:')
    printf "${BOLD}${MAGENTA}--- ufw ---${RESET}\n"
    printf "${CYAN}%s${RESET}\n" "$status"
    if echo "$status" | grep -qi inactive; then
        printf "${YELLOW}ufw выключен. Правила неактивны.${RESET}\n\n"
        return
    fi
    while read -r line; do
        case "$line" in
            *ALLOW*)
                port=$(echo "$line" | awk '{print $1}')
                proto=$(echo "$line" | grep -oE '/[a-z]+' | tr -d '/')
                ip=$(echo "$line" | awk '{print $3}')
                [ -n "$port" ] && allow_ports="$allow_ports $port/${proto:-tcp}"
                if [ "$ip" != "Anywhere" ] && [ -n "$ip" ]; then
                  if echo "$ip" | grep -q '/'; then
                    allow_subnets="$allow_subnets $ip"
                  else
                    allow_ips="$allow_ips $ip"
                  fi
                fi
                ;;
            *DENY*|*REJECT*)
                port=$(echo "$line" | awk '{print $1}')
                proto=$(echo "$line" | grep -oE '/[a-z]+' | tr -d '/')
                ip=$(echo "$line" | awk '{print $3}')
                [ -n "$port" ] && deny_ports="$deny_ports $port/${proto:-tcp}"
                if [ "$ip" != "Anywhere" ] && [ -n "$ip" ]; then
                  if echo "$ip" | grep -q '/'; then
                    deny_subnets="$deny_subnets $ip"
                  else
                    deny_ips="$deny_ips $ip"
                  fi
                fi
                ;;
        esac
    done <<EOF
$(ufw status numbered | grep -E 'ALLOW|DENY|REJECT')
EOF
    printf "${GREEN}Разрешены:${RESET}\n  Порты: $allow_ports\n  Адреса: $allow_ips\n  Подсети: $allow_subnets\n"
    printf "${RED}Заблокированы:${RESET}\n  Порты: $deny_ports\n  Адреса: $deny_ips\n  Подсети: $deny_subnets\n\n"
}

# Парсинг firewalld (оставляем как было)
parse_firewalld() {
    printf "${BOLD}${MAGENTA}--- firewalld ---${RESET}\n"
    firewall-cmd --get-active-zones | while read -r zone; do
        [ -z "$zone" ] && continue
        printf "${CYAN}Зона: $zone${RESET}\n"
        ports=$(firewall-cmd --zone=$zone --list-ports)
        sources=$(firewall-cmd --zone=$zone --list-sources)
        rich=$(firewall-cmd --zone=$zone --list-rich-rules)
        printf "${GREEN}Разрешены:${RESET}\n  Порты: $ports\n  Адреса: $sources\n"
        if [ -n "$rich" ]; then
            printf "${RED}Rich rules:${RESET}\n  $rich\n"
        fi
        printf "\n"
    done
}

# Проверка: iptables использует backend nf_tables?
is_iptables_nft_backend() {
    iptables -V 2>/dev/null | grep -qi nf_tables && return 0
    iptables -L -v 2>&1 | grep -qi nf_tables && return 0
    return 1
}

# Универсальный вывод всех правил (сначала анализ, потом меню)
show_all_rules() {
    print_header
    for fw in $FIREWALLS; do
        parse_rules_for_removal $fw
        local allow_ports=""; local deny_ports=""; local allow_ips=""; local deny_ips=""; local allow_subnets=""; local deny_subnets=""
        local first_allow_port=1; local first_deny_port=1; local first_allow_ip=1; local first_deny_ip=1; local first_allow_subnet=1; local first_deny_subnet=1
        local ufw_inactive=0
        for rule in "${RULES[@]}"; do
            IFS='|' read -r type value action _ ip_or_subnet <<< "$rule"
            case $type in
                ufw_inactive)
                    printf "${BOLD}${MAGENTA}--- ufw ---${RESET}\n"
                    printf "${CYAN}%s${RESET}\n" "$value"
                    printf "${YELLOW}ufw выключен. Правила неактивны.${RESET}\n\n"
                    ufw_inactive=1
                    ;;
                port)
                    if [ "$action" = "ACCEPT" ]; then
                        [ $first_allow_port -eq 0 ] && allow_ports+=", "
                        allow_ports+="$value"; first_allow_port=0
                    else
                        [ $first_deny_port -eq 0 ] && deny_ports+=", "
                        deny_ports+="$value"; first_deny_port=0
                    fi
                    ;;
                address)
                    if [ "$action" = "ACCEPT" ]; then
                        [ $first_allow_ip -eq 0 ] && allow_ips+=", "
                        allow_ips+="$value"; first_allow_ip=0
                    else
                        [ $first_deny_ip -eq 0 ] && deny_ips+=", "
                        deny_ips+="$value"; first_deny_ip=0
                    fi
                    ;;
                subnet)
                    if [ "$action" = "ACCEPT" ]; then
                        [ $first_allow_subnet -eq 0 ] && allow_subnets+=", "
                        allow_subnets+="$value"; first_allow_subnet=0
                    else
                        [ $first_deny_subnet -eq 0 ] && deny_subnets+=", "
                        deny_subnets+="$value"; first_deny_subnet=0
                    fi
                    ;;
                portip)
                    if [ "$action" = "ACCEPT" ]; then
                        [ $first_allow_port -eq 0 ] && allow_ports+=", "
                        allow_ports+="$value(для адреса $ip_or_subnet)"; first_allow_port=0
                    else
                        [ $first_deny_port -eq 0 ] && deny_ports+=", "
                        deny_ports+="$value(для адреса $ip_or_subnet)"; first_deny_port=0
                    fi
                    ;;
                portsubnet)
                    if [ "$action" = "ACCEPT" ]; then
                        [ $first_allow_port -eq 0 ] && allow_ports+=", "
                        allow_ports+="$value(для подсети $ip_or_subnet)"; first_allow_port=0
                    else
                        [ $first_deny_port -eq 0 ] && deny_ports+=", "
                        deny_ports+="$value(для подсети $ip_or_subnet)"; first_deny_port=0
                    fi
                    ;;
            esac
        done
        # Если ufw неактивен — уже выведено, пропускаем
        if [ "$fw" = "ufw" ] && [ $ufw_inactive -eq 1 ]; then
            continue
        fi
        printf "${BOLD}${MAGENTA}--- $fw ---${RESET}\n"
        printf "${GREEN}Разрешены:${RESET}\n  Порты: $allow_ports\n  Адреса: $allow_ips\n  Подсети: $allow_subnets\n"
        printf "${RED}Заблокированы:${RESET}\n  Порты: $deny_ports\n  Адреса: $deny_ips\n  Подсети: $deny_subnets\n\n"
    done
}

# Проверка валидности IP-адреса или подсети (IPv4/IPv6)
is_valid_ip() {
    local ip="$1"
    # IPv4
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then return 0; fi
    # IPv4 subnet
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]]; then return 0; fi
    # IPv6
    if [[ "$ip" =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$ ]]; then return 0; fi
    # IPv6 subnet
    if [[ "$ip" =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}/([0-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8])$ ]]; then return 0; fi
    return 1
}

# Добавление правила (выбор firewall и действия по номеру, с проверкой ошибок, выбор протокола по цифре, проверка IP)
add_rule() {
    printf "${BOLD}${GREEN}Добавление правила${RESET}\n"
    select_firewall || return
    read -p "Порт: " port
    select_protocol || return
    proto="$PROTO_SELECTED"
    while true; do
        read -p "IP [Enter для всех]: " ip
        [ -z "$ip" ] && break
        if is_valid_ip "$ip"; then
            break
        else
            printf "${RED}Некорректный IP-адрес или подсеть!${RESET}\n"
        fi
    done
    select_action "Действие:" "allow" "deny" "reject" || return
    action="$ACTION_SELECTED"
    local cmd_result=0
    local cmd_out=""
    case $FW_SELECTED in
        iptables)
            if [ "$action" = "allow" ]; then
                iptables -A INPUT -p $proto --dport $port ${ip:+-s $ip} -j ACCEPT 2>err.log
            else
                iptables -A INPUT -p $proto --dport $port ${ip:+-s $ip} -j DROP 2>err.log
            fi
            cmd_result=$?
            cmd_out=$(cat err.log)
            rm -f err.log
            ;;
        ip6tables)
            if [ "$action" = "allow" ]; then
                ip6tables -A INPUT -p $proto --dport $port ${ip:+-s $ip} -j ACCEPT 2>err.log
            else
                ip6tables -A INPUT -p $proto --dport $port ${ip:+-s $ip} -j DROP 2>err.log
            fi
            cmd_result=$?
            cmd_out=$(cat err.log)
            rm -f err.log
            ;;
        nftables)
            # Формируем команду корректно
            nft_family="ip"
            [ "$proto" = "udp" ] && proto_part="udp" || proto_part="tcp"
            if [ -z "$ip" ]; then
                rule="nft add rule inet filter input $proto_part dport $port"
            else
                rule="nft add rule inet filter input $nft_family saddr $ip $proto_part dport $port"
            fi
            if [ "$action" = "allow" ]; then
                rule="$rule accept"
            else
                rule="$rule drop"
            fi
            eval "$rule" 2>err.log
            cmd_result=$?
            cmd_out=$(cat err.log)
            rm -f err.log
            ;;
        ufw)
            if [ "$action" = "allow" ]; then
                ufw allow $port/$proto 2>err.log
            else
                ufw deny $port/$proto 2>err.log
            fi
            cmd_result=$?
            cmd_out=$(cat err.log)
            rm -f err.log
            ;;
        firewalld)
            if [ "$action" = "allow" ]; then
                firewall-cmd --add-port=$port/$proto --permanent 2>err.log
            else
                firewall-cmd --remove-port=$port/$proto --permanent 2>err.log
            fi
            firewall-cmd --reload 2>>err.log
            cmd_result=$?
            cmd_out=$(cat err.log)
            rm -f err.log
            ;;
        *) printf "${RED}Неизвестный firewall${RESET}\n"; return ;;
    esac
    if [ $cmd_result -eq 0 ]; then
        printf "${GREEN}Правило добавлено!${RESET}\n"
    else
        printf "${RED}Ошибка при добавлении правила:${RESET}\n$cmd_out\n"
    fi
}

# Универсальный парсер правил для удаления (возвращает массив RULES: type|value|action|orig_num|ip_or_subnet)
parse_rules_for_removal() {
    local fw="$1"
    RULES=()
    case $fw in
        iptables|ip6tables)
            local cmd="$fw -L INPUT --line-numbers -n"
            while read -r line; do
                [[ "$line" =~ ^Chain ]] && continue
                [[ "$line" =~ ^num ]] && continue
                num=$(echo "$line" | awk '{print $1}')
                action=$(echo "$line" | awk '{print $2}')
                proto=$(echo "$line" | awk '{print $3}')
                src=$(echo "$line" | awk '{print $5}')
                dport=$(echo "$line" | grep -oE 'dpt:[0-9]+' | cut -d: -f2)
                if [[ "$action" =~ ACCEPT|DROP|REJECT ]]; then
                    if [ -n "$dport" ] && [ "$src" != "0.0.0.0/0" ] && [ "$src" != "::/0" ]; then
                        # Порт + адрес/подсеть
                        if echo "$src" | grep -q '/'; then
                            mask=$(echo "$src" | cut -d'/' -f2)
                            if [ "$mask" = "32" ] || [ "$mask" = "128" ]; then
                                RULES+=("portip|$dport/$proto|$action|$num|$(echo "$src" | cut -d'/' -f1)")
                            else
                                RULES+=("portsubnet|$dport/$proto|$action|$num|$src")
                            fi
                        else
                            RULES+=("portip|$dport/$proto|$action|$num|$src")
                        fi
                    elif [ -n "$dport" ]; then
                        RULES+=("port|$dport/$proto|$action|$num|")
                    elif [ "$src" != "0.0.0.0/0" ] && [ "$src" != "::/0" ]; then
                        if echo "$src" | grep -q '/'; then
                            mask=$(echo "$src" | cut -d'/' -f2)
                            if [ "$mask" = "32" ] || [ "$mask" = "128" ]; then
                                RULES+=("address|$(echo "$src" | cut -d'/' -f1)|$action|$num|")
                            else
                                RULES+=("subnet|$src|$action|$num|")
                            fi
                        else
                            RULES+=("address|$src|$action|$num|")
                        fi
                    fi
                fi
            done < <(eval $cmd)
            ;;
        nftables)
            local i=1
            # Проверяем наличие цепочки
            if ! nft list chain inet filter input 2>/dev/null | grep -q .; then
                RULES+=("nft_no_rules|Нет правил|Нет правил|Нет правил|Нет правил")
                return
            fi
            nft list chain inet filter input | grep -v '^table' | grep -v '^chain' | while read -r line; do
                action=""
                proto=""
                dport=""
                src=""
                if echo "$line" | grep -q 'accept'; then action="ACCEPT"; fi
                if echo "$line" | grep -q 'drop'; then action="DROP"; fi
                if echo "$line" | grep -q 'reject'; then action="REJECT"; fi
                proto=$(echo "$line" | grep -oE 'tcp|udp')
                dport=$(echo "$line" | grep -oE 'dport [0-9]+' | awk '{print $2}')
                src=$(echo "$line" | grep -oE 'saddr [^ ]+' | awk '{print $2}')
                if [ -n "$dport" ] && [ -n "$src" ] && [ "$src" != "0.0.0.0/0" ] && [ "$src" != "::/0" ]; then
                    if echo "$src" | grep -q '/'; then
                        mask=$(echo "$src" | cut -d'/' -f2)
                        if [ "$mask" = "32" ] || [ "$mask" = "128" ]; then
                            RULES+=("portip|$dport/$proto|$action|$i|$(echo "$src" | cut -d'/' -f1)")
                        else
                            RULES+=("portsubnet|$dport/$proto|$action|$i|$src")
                        fi
                    else
                        RULES+=("portip|$dport/$proto|$action|$i|$src")
                    fi
                elif [ -n "$dport" ]; then
                    RULES+=("port|$dport/$proto|$action|$i|")
                elif [ -n "$src" ] && [ "$src" != "0.0.0.0/0" ] && [ "$src" != "::/0" ]; then
                    if echo "$src" | grep -q '/'; then
                        mask=$(echo "$src" | cut -d'/' -f2)
                        if [ "$mask" = "32" ] || [ "$mask" = "128" ]; then
                            RULES+=("address|$(echo "$src" | cut -d'/' -f1)|$action|$i|")
                        else
                            RULES+=("subnet|$src|$action|$i|")
                        fi
                    else
                        RULES+=("address|$src|$action|$i|")
                    fi
                fi
                i=$((i+1))
            done
            ;;
        ufw)
            local status=""
            status=$(ufw status | grep 'Status:')
            if echo "$status" | grep -qi inactive; then
                RULES+=("ufw_inactive|$status||||")
                return
            fi
            local i=1
            ufw status numbered | grep -E 'ALLOW|DENY|REJECT' | while read -r line; do
                action=""
                proto=""
                dport=""
                src=""
                if echo "$line" | grep -q 'ALLOW'; then action="ACCEPT"; fi
                if echo "$line" | grep -q 'DENY'; then action="DROP"; fi
                if echo "$line" | grep -q 'REJECT'; then action="REJECT"; fi
                dport=$(echo "$line" | awk '{print $1}' | cut -d'/' -f1)
                proto=$(echo "$line" | grep -oE '/[a-z]+' | tr -d '/')
                src=$(echo "$line" | awk '{print $3}')
                if [ -n "$dport" ] && [ "$src" != "Anywhere" ] && [ -n "$src" ]; then
                    if echo "$src" | grep -q '/'; then
                        mask=$(echo "$src" | cut -d'/' -f2)
                        if [ "$mask" = "32" ] || [ "$mask" = "128" ]; then
                            RULES+=("portip|$dport/$proto|$action|$i|$(echo "$src" | cut -d'/' -f1)")
                        else
                            RULES+=("portsubnet|$dport/$proto|$action|$i|$src")
                        fi
                    else
                        RULES+=("portip|$dport/$proto|$action|$i|$src")
                    fi
                elif [ -n "$dport" ]; then
                    RULES+=("port|$dport/$proto|$action|$i|")
                elif [ "$src" != "Anywhere" ] && [ -n "$src" ]; then
                    if echo "$src" | grep -q '/'; then
                        mask=$(echo "$src" | cut -d'/' -f2)
                        if [ "$mask" = "32" ] || [ "$mask" = "128" ]; then
                            RULES+=("address|$(echo "$src" | cut -d'/' -f1)|$action|$i|")
                        else
                            RULES+=("subnet|$src|$action|$i|")
                        fi
                    else
                        RULES+=("address|$src|$action|$i|")
                    fi
                fi
                i=$((i+1))
            done
            ;;
        firewalld)
            local i=1
            for zone in $(firewall-cmd --get-active-zones | awk 'NR%2==1'); do
                for port in $(firewall-cmd --zone=$zone --list-ports); do
                    RULES+=("port|$port|ACCEPT|$i|")
                    i=$((i+1))
                done
                for src in $(firewall-cmd --zone=$zone --list-sources); do
                    if echo "$src" | grep -q '/'; then
                        mask=$(echo "$src" | cut -d'/' -f2)
                        if [ "$mask" = "32" ] || [ "$mask" = "128" ]; then
                            RULES+=("address|$(echo "$src" | cut -d'/' -f1)|ACCEPT|$i|")
                        else
                            RULES+=("subnet|$src|ACCEPT|$i|")
                        fi
                    else
                        RULES+=("address|$src|ACCEPT|$i|")
                    fi
                    i=$((i+1))
                done
                for rich in $(firewall-cmd --zone=$zone --list-rich-rules); do
                    if echo "$rich" | grep -q 'reject'; then
                        src=$(echo "$rich" | grep -oE 'address=\"[^\"]+\"' | cut -d'"' -f2)
                        if [ -n "$src" ]; then
                            if echo "$src" | grep -q '/'; then
                                mask=$(echo "$src" | cut -d'/' -f2)
                                if [ "$mask" = "32" ] || [ "$mask" = "128" ]; then
                                    RULES+=("address|$(echo "$src" | cut -d'/' -f1)|DROP|$i|")
                                else
                                    RULES+=("subnet|$src|DROP|$i|")
                                fi
                            else
                                RULES+=("address|$src|DROP|$i|")
                            fi
                        fi
                        i=$((i+1))
                    fi
                done
            done
            ;;
    esac
}

# Универсальное удаление правила по номеру из списка (с возвратом по 0)
remove_rule() {
    printf "${BOLD}${RED}Удаление правила${RESET}\n"
    select_firewall || return
    while true; do
        parse_rules_for_removal $FW_SELECTED
        if [ ${#RULES[@]} -eq 0 ]; then
            printf "${YELLOW}Нет правил для удаления.${RESET}\n"
            return
        fi
        printf "Выберите правило для удаления:\n"
        local i=1
        for rule in "${RULES[@]}"; do
            IFS='|' read -r type value action orig_num ip_or_subnet <<< "$rule"
            case $type in
                ufw_inactive) desc="ufw выключен: $value" ;;
                port)    desc="Порт: $value ($action)" ;;
                address) desc="Адрес: $value ($action)" ;;
                subnet)  desc="Подсеть: $value ($action)" ;;
                portip)  desc="Порт: $value ($action, адрес $ip_or_subnet)" ;;
                portsubnet) desc="Порт: $value ($action, подсеть $ip_or_subnet)" ;;
            esac
            printf "  %d) %s\n" "$i" "$desc"
            i=$((i+1))
        done
        printf "  0) Вернуться в меню\n"
        local num
        while true; do
            read -p "Номер: " num
            if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 0 ] && [ "$num" -le ${#RULES[@]} ]; then
                break
            fi
            printf "${RED}Некорректный номер!${RESET}\n"
        done
        if [ "$num" = "0" ]; then
            return
        fi
        IFS='|' read -r type value action orig_num ip_or_subnet <<< "${RULES[$((num-1))]}"
        case $FW_SELECTED in
            iptables|ip6tables)
                $FW_SELECTED -D INPUT $orig_num
                ;;
            nftables)
                printf "Удаление вручную: используйте 'nft delete rule ...'\n"
                ;;
            ufw)
                ufw delete $orig_num
                ;;
            firewalld)
                printf "Удаление вручную: используйте firewall-cmd ...\n"
                ;;
        esac
        printf "${GREEN}Правило удалено!${RESET}\n"
    done
}

# Сохранение изменений (создаю /etc/iptables если нужно, для ufw показываю предупреждение если неактивен)
save_rules() {
    printf "${BOLD}${CYAN}Сохранение изменений${RESET}\n"
    for fw in $FIREWALLS; do
        case $fw in
            iptables)
                if [ ! -d /etc/iptables ]; then
                    mkdir -p /etc/iptables || { printf "${RED}Не удалось создать /etc/iptables${RESET}\n"; continue; }
                fi
                service iptables save 2>/dev/null || iptables-save > /etc/iptables/rules.v4 ;;
            ip6tables)
                if [ ! -d /etc/iptables ]; then
                    mkdir -p /etc/iptables || { printf "${RED}Не удалось создать /etc/iptables${RESET}\n"; continue; }
                fi
                service ip6tables save 2>/dev/null || ip6tables-save > /etc/iptables/rules.v6 ;;
            nftables) nft list ruleset > /etc/nftables.conf ;;
            ufw)
                status=$(ufw status | grep 'Status:')
                if echo "$status" | grep -qi inactive; then
                    printf "${YELLOW}ufw выключен, перезагрузка не требуется.${RESET}\n"
                else
                    ufw reload
                    printf "${GREEN}Изменения ufw сохранены!${RESET}\n"
                fi
                ;;
            firewalld) firewall-cmd --reload ;;
        esac
    done
    printf "${GREEN}Изменения сохранены!${RESET}\n"
}

# Получить имя файла для бэкапа iptables
iptables_backup_file() {
    echo "/root/iptables_backup_$(date +%Y%m%d_%H%M%S).rules"
}

ip6tables_backup_file() {
    echo "/root/ip6tables_backup_$(date +%Y%m%d_%H%M%S).rules"
}

# Сохранить правила iptables/ip6tables в бэкап
backup_iptables() {
    local file=$(iptables_backup_file)
    iptables-save > "$file"
    printf "${YELLOW}Бэкап iptables сохранён: $file${RESET}\n"
}

backup_ip6tables() {
    local file=$(ip6tables_backup_file)
    ip6tables-save > "$file"
    printf "${YELLOW}Бэкап ip6tables сохранён: $file${RESET}\n"
}

# Найти последние бэкапы
latest_iptables_backup() {
    ls -1t /root/iptables_backup_*.rules 2>/dev/null | head -n1
}

latest_ip6tables_backup() {
    ls -1t /root/ip6tables_backup_*.rules 2>/dev/null | head -n1
}

# Восстановить правила из бэкапа
restore_iptables_backup() {
    local file="$1"
    if [ -f "$file" ]; then
        iptables-restore < "$file"
        printf "${GREEN}iptables восстановлены из $file${RESET}\n"
    else
        printf "${RED}Файл не найден: $file${RESET}\n"
    fi
}

restore_ip6tables_backup() {
    local file="$1"
    if [ -f "$file" ]; then
        ip6tables-restore < "$file"
        printf "${GREEN}ip6tables восстановлены из $file${RESET}\n"
    else
        printf "${RED}Файл не найден: $file${RESET}\n"
    fi
}

# Восстановление из бэкапа (с возвратом по 0)
restore_menu() {
    printf "${BOLD}${CYAN}Восстановление правил из бэкапа${RESET}\n"
    select_firewall || return
    case $FW_SELECTED in
        iptables)
            files=(/root/iptables_backup_*.rules)
            if [ ! -e "${files[0]}" ]; then
                printf "${RED}Бэкапы не найдены!${RESET}\n"; return
            fi
            select_from_list "Выберите файл для восстановления:" "${files[@]}" || return
            restore_iptables_backup "$SELECTED_VALUE"
            ;;
        ip6tables)
            files=(/root/ip6tables_backup_*.rules)
            if [ ! -e "${files[0]}" ]; then
                printf "${RED}Бэкапы не найдены!${RESET}\n"; return
            fi
            select_from_list "Выберите файл для восстановления:" "${files[@]}" || return
            restore_ip6tables_backup "$SELECTED_VALUE"
            ;;
        *) printf "${RED}Восстановление поддерживается только для iptables и ip6tables${RESET}\n" ;;
    esac
}

# Включение/отключение firewall (выбор по номеру, действия start/stop или enable/disable)
set_firewall_state() {
    printf "${BOLD}${YELLOW}Включение/отключение firewall${RESET}\n"
    select_firewall
    case $FW_SELECTED in
        iptables)
            select_action "Действие:" "start" "stop"
            state="$ACTION_SELECTED"
            if [ "$state" = "stop" ]; then
                backup_iptables
            fi
            if [ "$INIT" = "systemd" ]; then
                systemctl $state iptables
            else
                service iptables $state
            fi
            if [ "$state" = "start" ]; then
                last_bak=$(latest_iptables_backup)
                if [ -n "$last_bak" ]; then
                    read -p "Восстановить правила из последнего бэкапа ($last_bak)? [y/N]: " ans
                    if [[ "$ans" =~ ^[Yy]$ ]]; then
                        restore_iptables_backup "$last_bak"
                    fi
                fi
            fi
            ;;
        ip6tables)
            select_action "Действие:" "start" "stop"
            state="$ACTION_SELECTED"
            if [ "$state" = "stop" ]; then
                backup_ip6tables
            fi
            if [ "$INIT" = "systemd" ]; then
                systemctl $state ip6tables
            else
                service ip6tables $state
            fi
            if [ "$state" = "start" ]; then
                last_bak=$(latest_ip6tables_backup)
                if [ -n "$last_bak" ]; then
                    read -p "Восстановить правила из последнего бэкапа ($last_bak)? [y/N]: " ans
                    if [[ "$ans" =~ ^[Yy]$ ]]; then
                        restore_ip6tables_backup "$last_bak"
                    fi
                fi
            fi
            ;;
        nftables|firewalld)
            select_action "Действие:" "start" "stop"
            state="$ACTION_SELECTED"
            if [ "$INIT" = "systemd" ]; then
                systemctl $state $FW_SELECTED
            else
                service $FW_SELECTED $state
            fi
            ;;
        ufw)
            select_action "Действие:" "enable" "disable"
            state="$ACTION_SELECTED"
            ufw $state
            ;;
        *) printf "${RED}Неизвестный firewall${RESET}\n" ;;
    esac
    printf "${GREEN}Операция выполнена!${RESET}\n"
}

# Новый пункт: Заблокировать адрес полностью (с проверкой IP)
block_ip_menu() {
    printf "${BOLD}${RED}Заблокировать адрес полностью${RESET}\n"
    select_firewall || return
    while true; do
        read -p "IP-адрес или подсеть для блокировки: " ip
        if is_valid_ip "$ip"; then
            break
        else
            printf "${RED}Некорректный IP-адрес или подсеть!${RESET}\n"
        fi
    done
    local cmd_result=0
    local cmd_out=""
    case $FW_SELECTED in
        iptables)
            iptables -A INPUT -s $ip -j DROP 2>err.log
            cmd_result=$?
            cmd_out=$(cat err.log)
            rm -f err.log
            ;;
        ip6tables)
            ip6tables -A INPUT -s $ip -j DROP 2>err.log
            cmd_result=$?
            cmd_out=$(cat err.log)
            rm -f err.log
            ;;
        nftables)
            rule="nft add rule inet filter input ip saddr $ip drop"
            eval "$rule" 2>err.log
            cmd_result=$?
            cmd_out=$(cat err.log)
            rm -f err.log
            ;;
        ufw)
            ufw deny from $ip 2>err.log
            cmd_result=$?
            cmd_out=$(cat err.log)
            rm -f err.log
            ;;
        firewalld)
            firewall-cmd --add-rich-rule="rule family=\"ipv4\" source address=\"$ip\" reject" --permanent 2>err.log
            firewall-cmd --reload 2>>err.log
            cmd_result=$?
            cmd_out=$(cat err.log)
            rm -f err.log
            ;;
        *) printf "${RED}Неизвестный firewall${RESET}\n"; return ;;
    esac
    if [ $cmd_result -eq 0 ]; then
        printf "${GREEN}Адрес $ip заблокирован!${RESET}\n"
    else
        printf "${RED}Ошибка при блокировке адреса:${RESET}\n$cmd_out\n"
    fi
}

reset_firewall() {
    printf "${BOLD}${YELLOW}Сброс всех правил firewall${RESET}\n"
    for fw in $FIREWALLS; do
        case $fw in
            iptables)
                iptables -F
                iptables -X
                iptables -P INPUT ACCEPT
                iptables -P OUTPUT ACCEPT
                iptables -P FORWARD ACCEPT
                printf "${GREEN}iptables: все правила удалены, политика ACCEPT${RESET}\n"
                ;;
            ip6tables)
                ip6tables -F
                ip6tables -X
                ip6tables -P INPUT ACCEPT
                ip6tables -P OUTPUT ACCEPT
                ip6tables -P FORWARD ACCEPT
                printf "${GREEN}ip6tables: все правила удалены, политика ACCEPT${RESET}\n"
                ;;
            nftables)
                nft flush ruleset
                printf "${GREEN}nftables: все правила удалены${RESET}\n"
                ;;
            ufw)
                ufw --force reset
                printf "${GREEN}ufw: все правила удалены, firewall выключен${RESET}\n"
                ;;
            firewalld)
                firewall-cmd --complete-reload
                printf "${GREEN}firewalld: все правила сброшены (complete-reload)${RESET}\n"
                ;;
        esac
    done
    printf "${GREEN}Все firewall сброшены к разрешающим правилам!${RESET}\n"
}

# Главное меню (добавляю пункт блокировки адреса)
main_menu() {
    show_all_rules
    while true; do
        printf "\n${BOLD}${CYAN}Меню:${RESET}\n"
        printf "${YELLOW}1${RESET} - Показать правила\n"
        printf "${YELLOW}2${RESET} - Добавить правило\n"
        printf "${YELLOW}3${RESET} - Удалить правило\n"
        printf "${YELLOW}4${RESET} - Заблокировать адрес полностью\n"
        printf "${YELLOW}5${RESET} - Сохранить изменения\n"
        printf "${YELLOW}6${RESET} - Включить/отключить firewall\n"
        printf "${YELLOW}7${RESET} - Восстановить правила из бэкапа\n"
        printf "${YELLOW}8${RESET} - Сбросить firewall (очистить все правила)\n"
        printf "${YELLOW}0${RESET} - Выход\n"
        read -p "Выберите действие: " choice
        case $choice in
            1) show_all_rules ;;
            2) add_rule ;;
            3) remove_rule ;;
            4) block_ip_menu ;;
            5) save_rules ;;
            6) set_firewall_state ;;
            7) restore_menu ;;
            8) reset_firewall ;;
            0) exit 0 ;;
            *) printf "${RED}Неверный выбор!${RESET}\n" ;;
        esac
    done
}

# Запуск
main_menu
