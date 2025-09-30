#!/bin/bash

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

# Лог-файл
LOG_FILE="/var/log/ddoser_script.log"
log_action() {
    echo "$(date '+%F %T') $1" >> "$LOG_FILE"
}

# Определение ОС
os_name=$(grep -E "^NAME=" /etc/*release* 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d '"')
os_version=$(grep -E "^VERSION_ID=" /etc/*release* 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d '"')
if [[ -z "$os_version" ]]; then os_version=0; fi

# Цвет ОС
if [[ "$os_name" == *"Debian"* ]]; then
    if echo "$os_version <= 9" | bc -l | grep -q 1; then os_color="$WHITE";
    elif echo "$os_version == 10" | bc -l | grep -q 1; then os_color="$BLUE";
    else os_color="$GREEN"; fi
elif [[ "$os_name" == *"Ubuntu"* ]]; then
    if echo "$os_version <= 18" | bc -l | grep -q 1; then os_color="$WHITE";
    elif echo "$os_version == 20" | bc -l | grep -q 1; then os_color="$BLUE";
    else os_color="$GREEN"; fi
elif [[ "$os_name" == *"CentOS"* ]]; then
    if echo "$os_version <= 7" | bc -l | grep -q 1; then os_color="$MAGENTA";
    elif echo "$os_version == 8" | bc -l | grep -q 1; then os_color="$CYAN";
    else os_color="$WHITE"; fi
else
    os_color="$CYAN";
fi

# Определение панели управления
CONTROL_PANEL="none"
PANEL_LOG_PATHS=()
panel_login_url=""
CPIP=$(hostname -I | awk '{print $1}')

detect_control_panel() {
    if systemctl is-active --quiet hestia.service 2>/dev/null || systemctl list-units --type=service | grep -q hestia.service; then
        CONTROL_PANEL="hestia"
        PANEL_LOG_PATHS=(/var/log/apache2/domains/*.log)
        return
    fi
    if systemctl is-active --quiet ihttpd.service 2>/dev/null || systemctl list-units --type=service | grep -q ihttpd.service; then
        CONTROL_PANEL="ispmanager"
        PANEL_LOG_PATHS=(/var/www/httpd-logs/*access.log)
        return
    fi
    if systemctl is-active --quiet fastpanel2.service 2>/dev/null || systemctl list-units --type=service | grep -q fastpanel2.service; then
        CONTROL_PANEL="fastpanel"
        PANEL_LOG_PATHS=(/var/www/*/data/logs/*access.log)
        return
    fi
    if [[ -d "/usr/local/mgr5" ]] || [[ -d "/usr/local/fastpanel" ]]; then
        CONTROL_PANEL="fastpanel"
        PANEL_LOG_PATHS=(/var/www/*/data/logs/*access.log)
        return
    fi
    if [[ -d "/usr/local/vesta" ]]; then
        CONTROL_PANEL="vesta"
        PANEL_LOG_PATHS=(/var/log/nginx/domains/*.log)
        return
    fi
    if [[ -d "/usr/local/directadmin" ]]; then
        CONTROL_PANEL="directadmin"
        PANEL_LOG_PATHS=(/var/log/httpd/domains/*.log)
        return
    fi
    if [[ -d "/usr/local/cpanel" ]]; then
        CONTROL_PANEL="cpanel"
        PANEL_LOG_PATHS=(/usr/local/apache/domlogs/*.log)
        return
    fi
    # По умолчанию
    if [[ -f "/var/log/nginx/access.log" ]]; then
        PANEL_LOG_PATHS=(/var/log/nginx/access.log)
    elif [[ -f "/var/log/apache2/access.log" ]]; then
        PANEL_LOG_PATHS=(/var/log/apache2/access.log)
    fi
}

detect_control_panel

# Генерация ссылки на панель (пример для ISPmanager/FastPanel)
isplogin() {
    local CPIP="$1"
    FVK=$(date | md5sum | head -c16)
    if [ -f "/usr/local/mgr5/sbin/mgrctl" ]; then
        /usr/local/mgr5/sbin/mgrctl -m ispmgr session.newkey username=root key="$FVK" sok=o >/dev/null 2>&1
        echo "https://${CPIP}:1500/manager/ispmgr?func=auth&username=root&key=${FVK}&checkcookie=no"
    fi
}
fp2login() {
    local CPIP="$1"
    echo "https://${CPIP}:8888/"
}
vestalogin() {
    local CPIP="$1"
    echo "https://${CPIP}:8083/"
}
dalogin() {
    local CPIP="$1"
    echo "https://${CPIP}:2222/"
}
whmlogin() {
    local CPIP="$1"
    echo "https://${CPIP}:2087/"
}

case "$CONTROL_PANEL" in
    ispmanager) panel_login_url=$(isplogin "$CPIP");;
    fastpanel) panel_login_url=$(fp2login "$CPIP");;
    vesta) panel_login_url=$(vestalogin "$CPIP");;
    directadmin) panel_login_url=$(dalogin "$CPIP");;
    cpanel) panel_login_url=$(whmlogin "$CPIP");;
    hestia) panel_login_url="(ручной вход, порт 8083)";;
    *) panel_login_url="(не определено)";;
esac

# Определение сегодняшней даты для логов
TODAY=$(date '+%d/%b/%Y')
HOUR=$(date '+%H')

# Анализ логов: топ IP, топ URI, топ User-Agent с геолокацией
analyze_logs() {
    local log_paths=("${PANEL_LOG_PATHS[@]}")
    echo -e "${YELLOW}${BOLD}Анализирую логи за сегодня...${NC}"
    
    # Показываем прогресс
    show_progress 1 4 "Подготовка данных"
    sleep 0.5
    
    show_progress 2 4 "Обработка логов"
    sleep 0.3
    
    show_progress 3 4 "Анализ результатов"
    sleep 0.3
    
    show_progress 4 4 "Формирование отчёта"
    sleep 0.2
    echo # Новая строка после прогресс-бара
    
    # Топ IP с геолокацией
    echo -e "\n${YELLOW}${BOLD}Топ IP по логам за сегодня:${NC}"
    grep -h "$TODAY" ${log_paths[@]} 2>/dev/null | awk '{print $1}' | sort | uniq -c | sort -nr | head -20 | while read count ip; do
        if [[ -n "$ip" ]]; then
            local ip_info=$(get_ip_info "$ip")
            printf "%8s %-15s %s\n" "$count" "$ip" "$ip_info"
        fi
    done | tee /tmp/ddoser_top_ip.log
    
    # Топ URI
    echo -e "\n${CYAN}${BOLD}Топ URI за сегодня:${NC}"
    grep -h "$TODAY" ${log_paths[@]} 2>/dev/null | awk '{print $7}' | sort | uniq -c | sort -nr | head -20 | tee /tmp/ddoser_top_uri.log
    
    # Топ User-Agent
    echo -e "\n${MAGENTA}${BOLD}Топ User-Agent за сегодня:${NC}"
    grep -h "$TODAY" ${log_paths[@]} 2>/dev/null | awk -F'"' '{print $6}' | sort | uniq -c | sort -nr | head -15 | tee /tmp/ddoser_top_ua.log
    
    # Простой анализ SQL injection в URI
    local sql_attacks=$(grep -h "$TODAY" ${log_paths[@]} 2>/dev/null | grep -i "union\|select\|insert\|delete\|update" | awk '{print $1}' | sort | uniq -c | sort -nr)
    if [[ -n "$sql_attacks" ]]; then
        echo -e "\n${RED}${BOLD}🔴 Обнаружены потенциальные SQL injection атаки (топ-10):${NC}"
        echo "$sql_attacks" | head -10 | while read count ip; do
            if [[ -n "$ip" ]]; then
                local ip_info=$(get_ip_info "$ip")
                printf "%8s %-15s %s\n" "$count" "$ip" "$ip_info"
            fi
        done
    fi
    
    # Простой анализ XSS в URI
    local xss_attacks=$(grep -h "$TODAY" ${log_paths[@]} 2>/dev/null | grep -i "script\|alert\|onerror\|onload\|javascript" | awk '{print $1}' | sort | uniq -c | sort -nr)
    if [[ -n "$xss_attacks" ]]; then
        echo -e "\n${RED}${BOLD}🔴 Обнаружены потенциальные XSS атаки (топ-10):${NC}"
        echo "$xss_attacks" | head -10 | while read count ip; do
            if [[ -n "$ip" ]]; then
                local ip_info=$(get_ip_info "$ip")
                printf "%8s %-15s %s\n" "$count" "$ip" "$ip_info"
            fi
        done
    fi
    
    # Простой анализ ботов в User-Agent
    local bot_agents=$(grep -h "$TODAY" ${log_paths[@]} 2>/dev/null | awk -F'"' '{print $6}' | grep -i "bot\|crawler\|spider\|scraper\|scanner" | sort | uniq -c | sort -nr)
    if [[ -n "$bot_agents" ]]; then
        echo -e "\n${BLUE}${BOLD}🤖 Обнаружены боты (топ-10):${NC}"
        echo "$bot_agents" | head -10
    fi
}

# Анализ сетевых соединений
analyze_connections() {
    echo -e "\n${GREEN}${BOLD}Топ IP по активным соединениям (netstat):${NC}"
    netstat -ntu 2>/dev/null | awk 'NR>2{print $5}' | cut -d: -f1 | grep -v '^$' | sort | uniq -c | sort -nr | head -20 | tee /tmp/ddoser_top_conn.log
    echo -e "\n${BLUE}${BOLD}Топ IP по активным соединениям (ss):${NC}"
    ss -ntu 2>/dev/null | awk 'NR>1{print $5}' | cut -d: -f1 | grep -v '^$' | sort | uniq -c | sort -nr | head -20
}

# Показать нагрузку
show_load() {
    echo -e "\n${YELLOW}${BOLD}Нагрузка на сервер:${NC}"
    uptime
    echo -e "${CYAN}Топ процессов по CPU:${NC}"
    ps aux --sort=-%cpu | head -10
    echo -e "${CYAN}Топ процессов по памяти:${NC}"
    ps aux --sort=-%mem | head -10
}

# Блокировка IP (генерация команд)
block_ip() {
    local ip="$1"
    local ip_info=$(get_ip_info "$ip")
    echo -e "${RED}${BOLD}Команды для блокировки IP $ip $ip_info:${NC}"
    echo -e "${YELLOW}iptables:${NC} iptables -I INPUT -s $ip -j DROP"
    echo -e "${YELLOW}ipset:${NC} ipset add blacklist $ip"
    echo -e "${YELLOW}ufw:${NC} ufw deny from $ip"
    echo -e "${YELLOW}Чтобы выполнить:${NC}"
    echo -e "${CYAN}iptables -I INPUT -s $ip -j DROP && echo 'IP $ip заблокирован'${NC}"
    log_action "Сгенерирована команда блокировки для $ip $ip_info"
}

# Сохранить действия
save_report() {
    local now="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "\n==============================" >> "$LOG_FILE"
    echo -e "DDoSer Report | $now" >> "$LOG_FILE"
    echo -e "==============================" >> "$LOG_FILE"
    echo -e "Топ IP по логам за сегодня:" >> "$LOG_FILE"
    cat /tmp/ddoser_top_ip.log >> "$LOG_FILE"
    echo -e "\nТоп URI за сегодня:" >> "$LOG_FILE"
    cat /tmp/ddoser_top_uri.log >> "$LOG_FILE"
    echo -e "\nТоп User-Agent за сегодня:" >> "$LOG_FILE"
    cat /tmp/ddoser_top_ua.log >> "$LOG_FILE"
    echo -e "\nТоп IP по активным соединениям (netstat):" >> "$LOG_FILE"
    cat /tmp/ddoser_top_conn.log >> "$LOG_FILE"
    echo -e "\n==============================\n" >> "$LOG_FILE"
    log_action "Отчёт сохранён"
}

# Реальный мониторинг (N секунд)
real_time_monitoring() {
    local log_paths=("${PANEL_LOG_PATHS[@]}")
    local tmpfile="/tmp/ddoser_realtime.log"
    read -p "Введите время мониторинга в секундах (по умолчанию 30): " monitor_time
    if [[ -z "$monitor_time" ]]; then monitor_time=30; fi
    echo -e "${YELLOW}${BOLD}В течение $monitor_time секунд буду собирать информацию о текущих соединениях и логах. Пожалуйста, ожидайте...${NC}"
    rm -f "$tmpfile"
    (for log in "${log_paths[@]}"; do tail -F "$log" 2>/dev/null; done) | tee "$tmpfile" &
    TAIL_PID=$!
    sleep $monitor_time
    kill $TAIL_PID 2>/dev/null
    echo -e "\n${CYAN}${BOLD}Анализ за последние $monitor_time секунд:${NC}"
    if [[ -s "$tmpfile" ]]; then
        echo -e "${YELLOW}Топ IP:${NC}"
        awk '{print $1}' "$tmpfile" | sort | uniq -c | sort -nr | head -10
        echo -e "\n${CYAN}Топ URI:${NC}"
        awk '{print $7}' "$tmpfile" | sort | uniq -c | sort -nr | head -10
        echo -e "\n${RED}Подозрительные IP (более 100 запросов):${NC}"
        awk '{print $1}' "$tmpfile" | sort | uniq -c | awk '$1>100' | sort -nr
    else
        echo -e "${RED}Нет новых записей в логах за $monitor_time секунд.${NC}"
    fi
    rm -f "$tmpfile"
}

# Прогресс-бар
show_progress() {
    local current=$1
    local total=$2
    local message=$3
    local width=50
    local progress=$((current * width / total))
    local percentage=$((current * 100 / total))
    
    printf "\r${CYAN}$message: [${NC}"
    for ((i=0; i<progress; i++)); do printf "${GREEN}█${NC}"; done
    for ((i=progress; i<width; i++)); do printf "░"; done
    printf "${CYAN}] %d%%${NC}" $percentage
}

# Глобальная переменная для отслеживания статуса whois
WHOIS_STATUS="unknown"
WHOIS_INSTALL_ATTEMPTED=false
WHOIS_FAILED_COUNT=0

# Функция для получения информации о IP
get_ip_info() {
    local ip="$1"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        # Проверяем наличие whois
        if ! command -v whois >/dev/null 2>&1; then
            # Пытаемся установить whois автоматически только один раз
            if [[ "$WHOIS_INSTALL_ATTEMPTED" == "false" ]]; then
                WHOIS_INSTALL_ATTEMPTED=true
                echo -e "${YELLOW}Устанавливаю whois...${NC}" >&2
                
                if command -v apt-get >/dev/null 2>&1; then
                    if apt-get update >/dev/null 2>&1 && apt-get install -y whois >/dev/null 2>&1; then
                        WHOIS_STATUS="installed"
                    else
                        WHOIS_STATUS="install_failed"
                    fi
                elif command -v yum >/dev/null 2>&1; then
                    if yum install -y whois >/dev/null 2>&1; then
                        WHOIS_STATUS="installed"
                    else
                        WHOIS_STATUS="install_failed"
                    fi
                elif command -v dnf >/dev/null 2>&1; then
                    if dnf install -y whois >/dev/null 2>&1; then
                        WHOIS_STATUS="installed"
                    else
                        WHOIS_STATUS="install_failed"
                    fi
                else
                    WHOIS_STATUS="no_package_manager"
                fi
            fi
        else
            WHOIS_STATUS="available"
        fi
        
        # Пытаемся получить информацию через whois
        if command -v whois >/dev/null 2>&1 && [[ "$WHOIS_STATUS" != "install_failed" ]]; then
            local country=$(timeout 5 whois "$ip" 2>/dev/null | grep -i "country:\|Country:" | head -1 | awk '{print $2}' | tr -d '\r')
            local org=$(timeout 5 whois "$ip" 2>/dev/null | grep -i "org:\|organisation:\|OrgName:" | head -1 | sed 's/^[^:]*://g' | sed 's/^[ \t]*//g' | cut -c1-30 | tr -d '\r')
            
            if [[ -n "$country" && -n "$org" ]]; then
                echo "[$country/$org]"
                return
            elif [[ -n "$country" ]]; then
                echo "[$country]"
                return
            elif [[ -n "$org" ]]; then
                echo "[$org]"
                return
            else
                # whois не вернул данные
                WHOIS_FAILED_COUNT=$((WHOIS_FAILED_COUNT + 1))
                echo "[Unknown]"
                return
            fi
        else
            # whois недоступен
            echo "[No data]"
            return
        fi
    else
        echo "[IPv6/Local]"
    fi
}

# Показать статус whois в конце работы
show_whois_status() {
    echo -e "\n${BOLD}${WHITE}=========================================${NC}"
    case "$WHOIS_STATUS" in
        "available")
            echo -e "${GREEN}✓ Геолокация IP: whois доступен, страны определяются${NC}"
            ;;
        "installed")
            echo -e "${GREEN}✓ Геолокация IP: whois успешно установлен, страны определяются${NC}"
            ;;
        "install_failed")
            echo -e "${YELLOW}⚠  Геолокация IP: не удалось установить whois (старая ОС/репозитории?)${NC}"
            echo -e "${CYAN}   Для получения стран установите whois вручную${NC}"
            ;;
        "no_package_manager")
            echo -e "${YELLOW}⚠  Геолокация IP: неизвестный пакетный менеджер${NC}"
            echo -e "${CYAN}   Установите whois вручную для получения стран${NC}"
            ;;
        "unknown")
            if [[ "$WHOIS_FAILED_COUNT" -gt 0 ]]; then
                echo -e "${YELLOW}⚠  Геолокация IP: whois доступен, но $WHOIS_FAILED_COUNT IP не определились${NC}"
            fi
            ;;
    esac
    
    if [[ "$WHOIS_STATUS" == "install_failed" || "$WHOIS_STATUS" == "no_package_manager" ]]; then
        echo -e "${WHITE}   Команды для установки:${NC}"
        echo -e "${CYAN}   Ubuntu/Debian: apt-get install whois${NC}"
        echo -e "${CYAN}   CentOS/RHEL:   yum install whois${NC}"
        echo -e "${CYAN}   Fedora:        dnf install whois${NC}"
    fi
    echo -e "${BOLD}${WHITE}=========================================${NC}"
}

# Основной анализ при запуске
clear
printf "\033[1m\033[%sm==============================\n" "32"
printf " DDoSer: Анализ подозрительной активности\n"
printf " ОС: %s %s\n" "$os_name" "$os_version"
printf " Панель: %s\n" "$CONTROL_PANEL"
printf "==============================\033[0m\n"
if [[ "$panel_login_url" != "" ]]; then
    echo -e "${CYAN}Ссылка для входа в панель: $panel_login_url${NC}"
fi

analyze_logs
analyze_connections
show_load
show_whois_status

# Меню для дальнейших действий
while true; do
    echo -e "\n${BOLD}${WHITE}+------------------------------------------+${NC}"
    echo -e "${BOLD}${WHITE}|              МЕНЮ ДЕЙСТВИЙ               |${NC}"
    echo -e "${BOLD}${WHITE}+------------------------------------------+${NC}"
    echo -e "${BOLD}${WHITE}| ${YELLOW}1${WHITE}. Заблокировать IP                    |${NC}"
    echo -e "${BOLD}${WHITE}| ${CYAN}2${WHITE}. Сохранить отчёт                     |${NC}"
    echo -e "${BOLD}${WHITE}| ${BLUE}3${WHITE}. Показать ссылку на панель           |${NC}"
    echo -e "${BOLD}${WHITE}| ${MAGENTA}4${WHITE}. Мониторинг в реальном времени       |${NC}"
    echo -e "${BOLD}${WHITE}| ${GREEN}5${WHITE}. Повторный анализ                    |${NC}"
    echo -e "${BOLD}${WHITE}| ${RED}0${WHITE}. Выход                               |${NC}"
    echo -e "${BOLD}${WHITE}+------------------------------------------+${NC}"
    echo -ne "${BOLD}Ваш выбор: ${NC}"
    read choice
    case $choice in
        1)
            echo -ne "${YELLOW}Введите IP для блокировки: ${NC}"
            read ip
            if [[ -n "$ip" ]]; then
                block_ip "$ip"
            else
                echo -e "${RED}Ошибка: IP не указан!${NC}"
            fi
            ;;
        2)
            save_report
            echo -e "${GREEN}Отчёт сохранён в $LOG_FILE${NC}"
            ;;
        3)
            echo -e "${CYAN}Ссылка для входа в панель: $panel_login_url${NC}"
            ;;
        4)
            real_time_monitoring
            ;;
        5)
            echo -e "${YELLOW}Повторный анализ...${NC}"
            analyze_logs
            analyze_connections
            show_load
            show_whois_status
            ;;
        0)
            echo -e "${GREEN}Спасибо за использование DDoSer! До свидания.${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Неверный выбор! Пожалуйста, выберите от 0 до 5.${NC}"
            ;;
    esac
done
