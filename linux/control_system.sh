#!/bin/bash

# Скрипт для управления системой через меню выбора функций
# Доступные возможности:
# - Обновление системы
# - Настройка SSH
# - Проверка состояния системы
# - Проверка доступности хостов
# - Мониторинг процесса
# - Управление правилами iptables и ufw
# - Управление пользователями
# - Очистка логов
# - Управление сервисами
# - Поиск файлов
# Выбирайте нужную функцию из меню и взаимодействуйте с вашей системой!

echo "Добро пожаловать в скрипт управления Linux-системой"
echo "Выберите пункт для продолжения работы:"
# Обновление системы
update_system() {
    echo "Обновляем список пакетов..."
    sudo apt update
    
    echo "Обновляем установленные пакеты..."
    sudo apt upgrade -y

    echo "Удаляем ненужные пакеты..."
    sudo apt autoremove -y
    sudo apt autoclean

    echo "Система успешно обновлена."
}

# Настройка SSH-доступа
setup_ssh() {
    echo "Введите новый порт для SSH (по умолчанию 22):"
    read ssh_port
    ssh_port=${ssh_port:-22}

    echo "Настраиваем SSH..."
    sudo sed -i "s/^#Port 22/Port $ssh_port/" /etc/ssh/sshd_config
    sudo sed -i "s/^PermitRootLogin yes/PermitRootLogin no/" /etc/ssh/sshd_config
    sudo sed -i "s/^#PasswordAuthentication yes/PasswordAuthentication no/" /etc/ssh/sshd_config

    echo "Перезапускаем сервис SSH..."
    sudo systemctl restart sshd
    echo "SSH настроен. Новый порт: $ssh_port."
}

# Проверка состояния системы
check_system() {
    echo "Загрузка процессора:"
    top -bn1 | grep "%Cpu" | awk '{print "CPU Load: " 100 - $8 "%"}'

    echo "Использование памяти:"
    free -h | grep Mem | awk '{print "Used/Total Memory: " $3 "/" $2}'

    echo "Использование диска:"
    df -h --total | grep total | awk '{print "Disk Usage: " $3 "/" $2 " (" $5 ")"}'

    echo "Сетевые интерфейсы:"
    ip -brief addr | grep UP

    echo "Температура системы:"
    sensors | grep 'Package id 0' | awk '{print "CPU Temperature: " $4}'
}

# Проверка доступности хостов
ping_hosts() {
    echo "Введите список хостов через пробел:"
    read -a hosts

    for host in "${hosts[@]}"; do
        echo "Проверяем доступность: $host"
        if ping -c 1 "$host" &>/dev/null; then
            echo "$host доступен."
        else
            echo "$host недоступен."
        fi
    done
}

# Мониторинг процесса
monitor_process() {
    echo "Введите имя процесса для мониторинга:"
    read process_name

    echo "Информация о процессе $process_name:"
    ps aux | grep "$process_name" | grep -v grep
}

# Управление пользователями
manage_users() {
    echo "Что вы хотите сделать?"
    echo "1. Добавить пользователя"
    echo "2. Удалить пользователя"
    echo "3. Изменить пароль пользователя"
    echo "4. Вернуться в меню"
    read user_choice

    case $user_choice in
        1)
            echo "Введите имя нового пользователя:"
            read username
            sudo adduser "$username"
            echo "Пользователь $username добавлен."
            ;;
        2)
            echo "Введите имя пользователя для удаления:"
            read username
            sudo deluser "$username"
            echo "Пользователь $username удалён."
            ;;
        3)
            echo "Введите имя пользователя для изменения пароля:"
            read username
            sudo passwd "$username"
            ;;
        4)
            return
            ;;
        *)
            echo "Неверный выбор."
            ;;
    esac
}

# Очистка логов
clear_logs() {
    echo "Очистка логов в /var/log..."
    sudo find /var/log -type f -name "*.log" -exec truncate -s 0 {} \;
    echo "Все логи очищены."
}

# Управление сервисами
manage_services() {
    echo "Введите имя сервиса:"
    read service_name

    echo "Что вы хотите сделать с сервисом $service_name?"
    echo "1. Запустить"
    echo "2. Остановить"
    echo "3. Перезапустить"
    echo "4. Статус"
    echo "5. Вернуться в меню"
    read service_choice

    case $service_choice in
        1)
            sudo systemctl start "$service_name"
            echo "Сервис $service_name запущен."
            ;;
        2)
            sudo systemctl stop "$service_name"
            echo "Сервис $service_name остановлен."
            ;;
        3)
            sudo systemctl restart "$service_name"
            echo "Сервис $service_name перезапущен."
            ;;
        4)
            sudo systemctl status "$service_name"
            ;;
        5)
            return
            ;;
        *)
            echo "Неверный выбор."
            ;;
    esac
}

# Поиск файлов
find_files() {
    echo "Введите имя файла или маску для поиска (например, *.log):"
    read file_pattern

    echo "Введите директорию для поиска (по умолчанию /):"
    read directory
    directory=${directory:-/}

    echo "Ищем файлы..."
    sudo find "$directory" -name "$file_pattern"
}

# Меню выбора функций
while true; do
    echo "1. Обновить систему"
    echo "2. Настроить SSH"
    echo "3. Проверить состояние системы"
    echo "4. Проверить доступность хостов"
    echo "5. Мониторинг процесса"
    echo "6. Управление пользователями"
    echo "7. Очистка логов"
    echo "8. Управление сервисами"
    echo "9. Поиск файлов"
    echo "10. Выйти"
    read choice

    case $choice in
        1) update_system ;;
        2) setup_ssh ;;
        3) check_system ;;
        4) ping_hosts ;;
        5) monitor_process ;;
        6) manage_users ;;
        7) clear_logs ;;
        8) manage_services ;;
        9) find_files ;;
        10) echo "Спасибо за использование!."; break ;;
        *) echo "Неверный выбор. Повторите попытку." ;;
    esac
done
