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

# Анализ логов: топ IP, топ URI, топ User-Agent
analyze_logs() {
    local log_paths=("${PANEL_LOG_PATHS[@]}")
    echo -e "${YELLOW}${BOLD}Топ IP по логам за сегодня:${NC}"
    grep -h "$TODAY" ${log_paths[@]} 2>/dev/null | awk '{print $1}' | sort | uniq -c | sort -nr | head -20 | tee /tmp/ddoser_top_ip.log
    echo -e "\n${CYAN}${BOLD}Топ URI за сегодня:${NC}"
    grep -h "$TODAY" ${log_paths[@]} 2>/dev/null | awk '{print $7}' | sort | uniq -c | sort -nr | head -20 | tee /tmp/ddoser_top_uri.log
    echo -e "\n${MAGENTA}${BOLD}Топ User-Agent за сегодня:${NC}"
    grep -h "$TODAY" ${log_paths[@]} 2>/dev/null | awk -F'"' '{print $6}' | sort | uniq -c | sort -nr | head -10 | tee /tmp/ddoser_top_ua.log
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
    echo -e "${RED}${BOLD}Команды для блокировки IP $ip:${NC}"
    echo "iptables -I INPUT -s $ip -j DROP"
    echo "ipset add blacklist $ip"
    echo "ufw deny from $ip"
    log_action "Сгенерирована команда блокировки для $ip"
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

# Основной анализ при запуске
clear
cat <<EOF
${BOLD}${os_color}==============================
 DDoSer: Анализ подозрительной активности
 ОС: $os_name $os_version
 Панель: $CONTROL_PANEL
==============================${NC}
EOF
if [[ "$panel_login_url" != "" ]]; then
    echo -e "${CYAN}Ссылка для входа в панель: $panel_login_url${NC}"
fi

analyze_logs
analyze_connections
show_load

# Выводим меню для дальнейших действий
while true; do
    echo -e "\n${BOLD}${WHITE}Выберите действие:${NC}"
    echo "1. Заблокировать IP"
    echo "2. Сохранить отчёт"
    echo "3. Показать ссылку на панель"
    echo "4. Мониторинг в реальном времени"
    echo "0. Выход"
    read -p "Ваш выбор: " choice
    case $choice in
        1)
            read -p "Введите IP для блокировки: " ip
            block_ip "$ip"
            ;;
        2)
            save_report
            ;;
        3)
            echo -e "${CYAN}Ссылка для входа в панель: $panel_login_url${NC}"
            ;;
        4)
            real_time_monitoring
            ;;
        0)
            echo -e "${GREEN}Выход.${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Неверный выбор!${NC}"
            ;;
    esac
done
