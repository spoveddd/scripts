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

# Блокировка IP (автоматическая)
block_ip_auto() {
    echo -e "\n${YELLOW}${BOLD}Топ IP по логам за сегодня:${NC}"
    local ip_list=()
    local counter=1
    
    # Читаем топ IP из временного файла
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            # Извлекаем IP из строки (формат: количество IP информация)
            local ip=$(echo "$line" | awk '{print $2}')
            if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                ip_list+=("$ip")
                echo -e "${counter}. $line"
                counter=$((counter + 1))
            fi
        fi
    done < /tmp/ddoser_top_ip.log
    
    if [[ ${#ip_list[@]} -eq 0 ]]; then
        echo -e "${RED}Не найдено IP для блокировки${NC}"
        return
    fi
    
    echo -ne "\n${YELLOW}Введите номера IP для блокировки (например: 1, 3, 5 или 1-3): ${NC}"
    read ip_choices
    
    if [[ -z "$ip_choices" ]]; then
        echo -e "${RED}Ошибка: Не выбраны IP для блокировки!${NC}"
        return
    fi
    
    # Парсим выбор пользователя
    local selected_ips=()
    IFS=','',' read -ra choices <<< "$ip_choices"
    for choice in "${choices[@]}"; do
        choice=$(echo "$choice" | tr -d ' ')
        if [[ "$choice" =~ ^[0-9]+-[0-9]+$ ]]; then
            # Диапазон
            local start=$(echo "$choice" | cut -d'-' -f1)
            local end=$(echo "$choice" | cut -d'-' -f2)
            for ((i=start; i<=end; i++)); do
                if [[ $i -ge 1 && $i -le ${#ip_list[@]} ]]; then
                    selected_ips+=("${ip_list[$((i-1))]}")
                fi
            done
        elif [[ "$choice" =~ ^[0-9]+$ ]]; then
            # Одиночный выбор
            if [[ $choice -ge 1 && $choice -le ${#ip_list[@]} ]]; then
                selected_ips+=("${ip_list[$((choice-1))]}")
            fi
        fi
    done
    
    # Блокируем выбранные IP
    for ip in "${selected_ips[@]}"; do
        echo -e "${CYAN}Блокирую IP: $ip${NC}"
        iptables -I INPUT -s "$ip" -j DROP 2>/dev/null
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}✓ IP $ip успешно заблокирован${NC}"
            log_action "Заблокирован IP $ip"
        else
            echo -e "${RED}✗ Ошибка блокировки IP $ip${NC}"
        fi
    done
}

# Блокировка User-Agent
block_user_agent() {
    echo -e "\n${MAGENTA}${BOLD}Топ User-Agent за сегодня:${NC}"
    local ua_list=()
    local counter=1
    
    # Читаем топ User-Agent из временного файла и показываем в оригинальном формате
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            # Сохраняем всю строку для последующего использования
            ua_list+=("$line")
            # Показываем как в оригинале (количество + User-Agent)
            echo -e "${counter}. $line"
            counter=$((counter + 1))
        fi
    done < /tmp/ddoser_top_ua.log
    
    if [[ ${#ua_list[@]} -eq 0 ]]; then
        echo -e "${RED}Не найдено User-Agent для блокировки${NC}"
        return
    fi
    
    echo -ne "\n${MAGENTA}Введите номера User-Agent для блокировки (например: 1, 3, 5 или 1-3): ${NC}"
    read ua_choices
    
    if [[ -z "$ua_choices" ]]; then
        echo -e "${RED}Ошибка: Не выбраны User-Agent для блокировки!${NC}"
        return
    fi
    
    # Парсим выбор пользователя
    local selected_uas=()
    IFS=',' read -ra choices <<< "$ua_choices"
    for choice in "${choices[@]}"; do
        choice=$(echo "$choice" | tr -d ' ')
        if [[ "$choice" =~ ^[0-9]+-[0-9]+$ ]]; then
            # Диапазон
            local start=$(echo "$choice" | cut -d'-' -f1)
            local end=$(echo "$choice" | cut -d'-' -f2)
            for ((i=start; i<=end; i++)); do
                if [[ $i -ge 1 && $i -le ${#ua_list[@]} ]]; then
                    selected_uas+=("${ua_list[$((i-1))]}")
                fi
            done
        elif [[ "$choice" =~ ^[0-9]+$ ]]; then
            # Одиночный выбор
            if [[ $choice -ge 1 && $choice -le ${#ua_list[@]} ]]; then
                selected_uas+=("${ua_list[$((choice-1))]}")
            fi
        fi
    done
    
    if [[ ${#selected_uas[@]} -eq 0 ]]; then
        echo -e "${RED}Ошибка: Не выбраны корректные User-Agent для блокировки!${NC}"
        return
    fi
    
    # Извлекаем только User-Agent из выбранных строк (убираем количество в начале)
    local clean_uas=()
    for ua_line in "${selected_uas[@]}"; do
        # Извлекаем User-Agent из строки формата: "количество User-Agent"
        # Удаляем ведущие пробелы и цифры в начале строки
        local clean_ua=$(echo "$ua_line" | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]*//')
        clean_uas+=("$clean_ua")
    done
    
    # Определяем путь для конфигурации в зависимости от панели управления
    local config_path=""
    local config_file=""
    case "$CONTROL_PANEL" in
        fastpanel)
            config_path="/etc/nginx/fastpanel2-includes"
            config_file="blockua.conf"
            ;;
        ispmanager)
            config_path="/etc/nginx/vhosts-includes"
            config_file="blockua.conf"
            ;;
        hestia)
            # Для Hestia создаем файлы в домашних директориях пользователей
            echo -e "${CYAN}Создаю конфигурационные файлы для Hestia...${NC}"
            local hestia_count=0
            
            # Находим все файлы nginx.ssl.conf
            while IFS= read -r -d '' file; do
                if [[ -f "$file" ]]; then
                    local badbot_file="${file}_badbot"
                    
                    # Создаем или обновляем файл _badbot
                    if [[ -f "$badbot_file" ]]; then
                        echo -e "${YELLOW}Файл $badbot_file уже существует. Добавляю новые правила.${NC}"
                        # Добавляем маркер начала новых правил
                        echo "" >> "$badbot_file"
                        echo "# Добавлены правила $(date)" >> "$badbot_file"
                    else
                        echo -e "${CYAN}Создаю новый файл: $badbot_file${NC}"
                        # Создаем новый файл с заголовком
                        {
                            echo "# Блокировка User-Agent (сгенерировано DDoSer)"
                            echo "# Дата: $(date)"
                        } > "$badbot_file"
                    fi
                    
                    # Добавляем правила блокировки
                    for ua in "${clean_uas[@]}"; do
                        # Экранируем специальные символы в User-Agent
                        local escaped_ua=$(echo "$ua" | sed 's/[[\.*^$()+?{|]/\\&/g')
                        echo "if (\$http_user_agent ~ \"^${escaped_ua}$\") { return 444; }" >> "$badbot_file"
                    done
                    
                    hestia_count=$((hestia_count + 1))
                fi
            done < <(find /home -type f -name "nginx.ssl.conf" -print0 2>/dev/null)
            
            if [[ $hestia_count -eq 0 ]]; then
                echo -e "${RED}Не найдено файлов nginx.ssl.conf для Hestia${NC}"
                return
            else
                echo -e "${GREEN}✓ Обработано доменов Hestia: $hestia_count${NC}"
                
                # Перезагружаем nginx
                echo -e "${CYAN}Перезагружаю nginx...${NC}"
                if systemctl reload nginx 2>/dev/null || service nginx reload 2>/dev/null; then
                    echo -e "${GREEN}✓ Nginx успешно перезагружен${NC}"
                    echo -e "${GREEN}✓ Добавлены User-Agent: ${#clean_uas[@]} шт. для $hestia_count доменов${NC}"
                    log_action "Добавлены User-Agent: ${#clean_uas[@]} шт. для $hestia_count доменов (Hestia)"
                else
                    echo -e "${RED}✗ Ошибка перезагрузки nginx${NC}"
                fi
            fi
            return
            ;;
        *)
            echo -e "${RED}Блокировка User-Agent поддерживается только для FastPanel, ISPmanager и Hestia${NC}"
            return
            ;;
    esac
    
    # Создаем конфигурационный файл для FastPanel и ISPmanager
    local full_path="$config_path/$config_file"
    echo -e "${CYAN}Работаю с конфигурационным файлом: $full_path${NC}"
    
    # Создаем директорию если она не существует
    mkdir -p "$config_path" 2>/dev/null
    
    # Проверяем, существует ли файл
    if [[ -f "$full_path" ]]; then
        echo -e "${YELLOW}Файл уже существует. Добавляю новые правила в конец файла.${NC}"
        # Создаем временный файл с новыми правилами
        local tmp_file="/tmp/blockua_new.rules"
        {
            echo ""
            echo "# Добавлены правила $(date)"
            echo ""
            
            # Добавляем новые правила
            for ua in "${clean_uas[@]}"; do
                # Экранируем специальные символы в User-Agent
                local escaped_ua=$(echo "$ua" | sed 's/[[\.*^$()+?{|]/\\&/g')
                echo "if (\$http_user_agent ~ \"^${escaped_ua}$\") {"
                echo "    return 403;"
                echo "}"
            done
        } > "$tmp_file"
        
        # Добавляем новые правила в существующий файл
        cat "$tmp_file" >> "$full_path"
        rm -f "$tmp_file"
    else
        echo -e "${CYAN}Создаю новый конфигурационный файл: $full_path${NC}"
        # Создаем новый файл с заголовком и правилами
        {
            echo "# Блокировка User-Agent (сгенерировано DDoSer)"
            echo "# Дата: $(date)"
            echo ""
            
            # Добавляем правила
            for ua in "${clean_uas[@]}"; do
                # Экранируем специальные символы в User-Agent
                local escaped_ua=$(echo "$ua" | sed 's/[[\.*^$()+?{|]/\\&/g')
                echo "if (\$http_user_agent ~ \"^${escaped_ua}$\") {"
                echo "    return 403;"
                echo "}"
            done
        } > "$full_path"
    fi
    
    # Проверяем конфигурацию nginx
    echo -e "${CYAN}Проверяю конфигурацию nginx...${NC}"
    if nginx -t 2>/dev/null; then
        echo -e "${GREEN}✓ Конфигурация nginx корректна${NC}"
        
        # Перезагружаем nginx
        echo -e "${CYAN}Перезагружаю nginx...${NC}"
        if systemctl reload nginx 2>/dev/null || service nginx reload 2>/dev/null; then
            echo -e "${GREEN}✓ Nginx успешно перезагружен${NC}"
            echo -e "${GREEN}✓ Добавлены User-Agent: ${#clean_uas[@]} шт.${NC}"
            log_action "Добавлены User-Agent: ${#clean_uas[@]} шт."
        else
            echo -e "${RED}✗ Ошибка перезагрузки nginx${NC}"
        fi
    else
        echo -e "${RED}✗ Ошибка в конфигурации nginx. Отмена.${NC}"
        # Показываем содержимое файла для отладки
        echo -e "${YELLOW}Содержимое конфигурационного файла:${NC}"
        cat "$full_path"
        # Если файл новый, удаляем его в случае ошибки
        if [[ ! -f "$full_path.backup" ]]; then
            rm -f "$full_path"
        fi
    fi
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
printf " DDoSer: DDoS Protection - Анализ логов на предмет атак\n"
echo -e " ${CYAN}Создано Vladislav Pavlovich для технической поддержки. По вопросам в TG @sysadminctl${NC}"
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
    echo -e "${BOLD}${WHITE}| ${MAGENTA}2${WHITE}. Заблокировать UA                    |${NC}"
    echo -e "${BOLD}${WHITE}| ${CYAN}3${WHITE}. Сохранить отчёт                     |${NC}"
    echo -e "${BOLD}${WHITE}| ${BLUE}4${WHITE}. Показать ссылку на панель           |${NC}"
    echo -e "${BOLD}${WHITE}| ${MAGENTA}5${WHITE}. Мониторинг в реальном времени       |${NC}"
    echo -e "${BOLD}${WHITE}| ${GREEN}6${WHITE}. Повторный анализ                    |${NC}"
    echo -e "${BOLD}${WHITE}| ${RED}0${WHITE}. Выход                               |${NC}"
    echo -e "${BOLD}${WHITE}+------------------------------------------+${NC}"
    echo -ne "${BOLD}Ваш выбор: ${NC}"
    read choice
    case $choice in
        1)
            block_ip_auto
            ;;
        2)
            block_user_agent
            ;;
        3)
            save_report
            echo -e "${GREEN}Отчёт сохранён в $LOG_FILE${NC}"
            ;;
        4)
            echo -e "${CYAN}Ссылка для входа в панель: $panel_login_url${NC}"
            ;;
        5)
            real_time_monitoring
            ;;
        6)
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
            echo -e "${RED}Неверный выбор! Пожалуйста, выберите от 0 до 6.${NC}"
            ;;
    esac
done
