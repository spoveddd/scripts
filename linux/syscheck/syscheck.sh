#!/bin/bash

# System Security Check Script (syscheck.sh)
# Выполняет быструю проверку состояния системы перед началом работы
# Время выполнения: ~15-20 секунд

# Цвета для вывода
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Функция для вывода заголовков секций
print_section() {
    echo -e "\n${BOLD}${BLUE}=== $1 ===${NC}"
}

# Функция для вывода статуса
print_status() {
    local status=$1
    local message=$2
    
    case $status in
        "OK")
            echo -e "  ${GREEN}✓ $message${NC}"
            ;;
        "WARN")
            echo -e "  ${YELLOW}⚠ $message${NC}"
            ;;
        "CRIT")
            echo -e "  ${RED}✗ $message${NC}"
            ;;
    esac
}

# Функция для проверки критических портов
check_suspicious_ports() {
    local suspicious_ports="1337 9001 4444 31337 8080 8888"
    local found_suspicious=""
    
    for port in $suspicious_ports; do
        if ss -tuln | grep -q ":$port "; then
            found_suspicious="$found_suspicious $port"
        fi
    done
    
    if [ -n "$found_suspicious" ]; then
        print_status "CRIT" "Подозрительные порты: $found_suspicious"
        return 1
    else
        print_status "OK" "Подозрительные порты не обнаружены"
        return 0
    fi
}

# Функция для проверки использования диска
check_disk_usage() {
    local critical_usage=$(df -h | grep -E '(8[0-9]%|9[0-9]%|100%)')
    
    if [ -n "$critical_usage" ]; then
        print_status "CRIT" "Критическое использование диска:"
        echo "$critical_usage" | while read line; do
            echo -e "    ${RED}$line${NC}"
        done
        return 1
    else
        print_status "OK" "Использование диска в норме"
        return 0
    fi
}

# Функция для проверки недавних изменений файлов
check_recent_changes() {
    local recent_changes=$(find /etc -type f -mtime -2 2>/dev/null | head -10)
    
    if [ -n "$recent_changes" ]; then
        print_status "WARN" "Недавние изменения в /etc (последние 2 дня):"
        echo "$recent_changes" | while read file; do
            local mtime=$(stat -c %y "$file" 2>/dev/null | cut -d' ' -f1)
            echo -e "    ${YELLOW}$mtime: $file${NC}"
        done
        return 1
    else
        print_status "OK" "Недавних изменений в /etc не обнаружено"
        return 0
    fi
}

# Основная функция проверки
main_check() {
    local overall_status=0
    
    echo -e "${BOLD}${GREEN}🔍 Системная проверка безопасности${NC}"
    echo -e "${BOLD}Время: $(date)${NC}"
    echo -e "${BOLD}Система: $(hostname)${NC}"
    
    # 1. Активные сессии
    print_section "АКТИВНЫЕ СЕССИИ"
    echo -e "  ${BOLD}Текущие пользователи:${NC}"
    who | while read line; do
        echo -e "    $line"
    done
    
    echo -e "\n  ${BOLD}Последние логины:${NC}"
    last -a | head -5 | while read line; do
        echo -e "    $line"
    done
    
    # 2. Cron задания
    print_section "CRON ЗАДАНИЯ"
    echo -e "  ${BOLD}Пользовательские cron:${NC}"
    if crontab -l 2>/dev/null; then
        print_status "WARN" "Обнаружены пользовательские cron задания"
        overall_status=$((overall_status + 1))
    else
        print_status "OK" "Пользовательские cron задания отсутствуют"
    fi
    
    echo -e "\n  ${BOLD}Системные cron:${NC}"
    ls /etc/cron* -R 2>/dev/null | head -10
    
    echo -e "\n  ${BOLD}Systemd таймеры:${NC}"
    systemctl list-timers --all --no-pager | head -10
    
    # 3. Слушающие порты
    print_section "СЛУШАЮЩИЕ ПОРТЫ"
    echo -e "  ${BOLD}Все слушающие порты:${NC}"
    ss -tulnp | head -15
    
    # Проверка подозрительных портов
    if ! check_suspicious_ports; then
        overall_status=$((overall_status + 2))
    fi
    
    # 4. Запущенные процессы
    print_section "ЗАПУЩЕННЫЕ ПРОЦЕССЫ"
    echo -e "  ${BOLD}Топ процессов по памяти:${NC}"
    ps aux --sort=-%mem | head -10 | awk '{printf "  %-8s %-8s %-8s %-8s %s\n", $1, $2, $3, $4, $11}'
    
    # 5. Недавние изменения файлов
    print_section "НЕДАВНИЕ ИЗМЕНЕНИЯ"
    if ! check_recent_changes; then
        overall_status=$((overall_status + 1))
    fi
    
    # 6. Аптайм и перезагрузки
    print_section "СИСТЕМНАЯ ИНФОРМАЦИЯ"
    echo -e "  ${BOLD}Аптайм:${NC}"
    uptime
    
    echo -e "\n  ${BOLD}История перезагрузок:${NC}"
    last reboot | head -3
    
    # 7. Пользователи и sudo
    print_section "ПОЛЬЗОВАТЕЛИ И ПРАВА"
    echo -e "  ${BOLD}Пользователи с домашними директориями:${NC}"
    getent passwd | grep '/home' | cut -d: -f1,6
    
    echo -e "\n  ${BOLD}Группа sudo:${NC}"
    getent group sudo | cut -d: -f4
    
    # 8. Дополнительные проверки
    print_section "ДОПОЛНИТЕЛЬНЫЕ ПРОВЕРКИ"
    
    # Загрузка системы
    echo -e "  ${BOLD}Загрузка системы:${NC}"
    cat /proc/loadavg
    
    # Использование диска
    echo -e "\n  ${BOLD}Использование дисков:${NC}"
    df -h | grep -E '^/dev/'
    if ! check_disk_usage; then
        overall_status=$((overall_status + 2))
    fi
    
    # Логи ошибок
    echo -e "\n  ${BOLD}Ошибки в логах (последние сутки):${NC}"
    journalctl --since "1 day ago" --priority=err --no-pager -q | tail -5
    
    # Failed systemd units
    echo -e "\n  ${BOLD}Неудачные systemd units:${NC}"
    failed_units=$(systemctl --failed --no-pager -q)
    if [ -n "$failed_units" ]; then
        echo "$failed_units"
        print_status "WARN" "Обнаружены неудачные systemd units"
        overall_status=$((overall_status + 1))
    else
        print_status "OK" "Все systemd units работают корректно"
    fi
    
    # SSH конфигурация
    echo -e "\n  ${BOLD}SSH конфигурация:${NC}"
    if [ -d ~/.ssh ]; then
        ls -la ~/.ssh/
    else
        print_status "WARN" "Директория ~/.ssh не найдена"
    fi
    
    # Итоговая сводка
    print_section "ИТОГОВАЯ СВОДКА"
    
    if [ $overall_status -eq 0 ]; then
        print_status "OK" "Система в хорошем состоянии"
        echo -e "  ${GREEN}Все проверки пройдены успешно${NC}"
    elif [ $overall_status -le 3 ]; then
        print_status "WARN" "Обнаружены предупреждения"
        echo -e "  ${YELLOW}Рекомендуется обратить внимание на найденные проблемы${NC}"
    else
        print_status "CRIT" "Критические проблемы обнаружены"
        echo -e "  ${RED}Требуется немедленное вмешательство${NC}"
    fi
    
    echo -e "\n${BOLD}Время выполнения: $(date)${NC}"
    echo -e "${BOLD}Статус: $overall_status${NC}"
    
    return $overall_status
}

# Проверка прав на выполнение
if [ ! -x "$0" ]; then
    chmod +x "$0"
fi

# Запуск основной проверки
main_check
exit_code=$?

# Выход с соответствующим кодом
if [ $exit_code -eq 0 ]; then
    exit 0
elif [ $exit_code -le 3 ]; then
    exit 1
else
    exit 2
fi
