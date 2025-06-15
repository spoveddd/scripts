#!/bin/bash
# Site Copy Script
# Автор: Vladislav Pavlovich
# Версия: 2.5
# Поддерживает: FastPanel, ISPManager, Hestia

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Глобальные переменные
LOG_FILE="/var/log/site_copy_script_$(date +%Y%m%d_%H%M%S).log"
TEMP_DUMP_FILE=""
CONTROL_PANEL=""

# Функция для вывода сообщений с логированием
log_info() {
    local message="$1"
    echo -e "${BLUE}[INFO]${NC} $message" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $message" >> "$LOG_FILE"
}

log_success() {
    local message="$1"
    echo -e "${GREEN}[SUCCESS]${NC} $message" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] $message" >> "$LOG_FILE"
}

log_warning() {
    local message="$1"
    echo -e "${YELLOW}[WARNING]${NC} $message" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING] $message" >> "$LOG_FILE"
}

log_error() {
    local message="$1"
    echo -e "${RED}[ERROR]${NC} $message" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $message" >> "$LOG_FILE"
}

# Функция очистки при выходе
cleanup() {
    if [[ -n "$TEMP_DUMP_FILE" ]] && [[ -f "$TEMP_DUMP_FILE" ]]; then
        log_info "Удаляем временный файл дампа..."
        rm -f "$TEMP_DUMP_FILE"
    fi
}

# Устанавливаем обработчик сигналов
trap cleanup EXIT

# Функция для проверки прав root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Этот скрипт должен быть запущен от имени root"
        exit 1
    fi
}

# Функция проверки подключения к MySQL
check_mysql_connection() {
    log_info "Проверяем подключение к MySQL..."
    if ! mysql -e "SELECT 1;" &>/dev/null; then
        log_error "Не удается подключиться к MySQL!"
        log_info "Проверьте, что MySQL запущен и доступен через сокет"
        exit 1
    fi
    log_success "Подключение к MySQL установлено"
}

# Функция для проверки свободного места
check_disk_space() {
    local source_path="$1"
    local target_path="$2"
    
    log_info "Проверяем свободное место на диске..."
    
    # Получаем размер исходной директории в KB
    local source_size=$(du -sk "$source_path" | cut -f1)
    local source_size_mb=$((source_size / 1024))
    
    # Получаем свободное место на целевом разделе в KB
    local target_partition=$(df "$target_path" | tail -1 | awk '{print $4}')
    local target_free_mb=$((target_partition / 1024))
    
    log_info "Размер исходного сайта: ${source_size_mb} MB"
    log_info "Свободное место на целевом разделе: ${target_free_mb} MB"
    
    # Добавляем 20% запас
    local required_space=$((source_size_mb * 120 / 100))
    
    if [[ $target_free_mb -lt $required_space ]]; then
        log_error "Недостаточно свободного места!"
        log_error "Требуется: ${required_space} MB, доступно: ${target_free_mb} MB"
        exit 1
    fi
    
    log_success "Свободного места достаточно"
}

# Функция валидации имени сайта
validate_site_name() {
    local site_name="$1"
    if [[ ! "$site_name" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        log_error "Имя сайта содержит недопустимые символы!"
        return 1
    fi
}

# Функция валидации имени БД
validate_db_name() {
    local db_name="$1"
    if [[ ! "$db_name" =~ ^[a-zA-Z0-9_]+$ ]]; then
        log_error "Имя базы данных содержит недопустимые символы!"
        return 1
    fi
}

# Функция для определения CMS
detect_cms() {
    local site_path="$1"
    
    # Проверка на WordPress
    if [[ -f "$site_path/wp-config.php" ]]; then
        echo "wordpress"
        return 0
    fi
    
    # Дополнительная проверка WP по файлам
    if [[ $(find "$site_path" -maxdepth 1 -name "wp-*" -type f 2>/dev/null | wc -l) -gt 3 ]]; then
        echo "wordpress"
        return 0
    fi
    
    # Проверка на DLE - исправленная версия
    if [[ -d "$site_path/engine" ]] && [[ -d "$site_path/engine/data" ]] && [[ -f "$site_path/engine/data/dbconfig.php" ]]; then
        echo "dle"
        return 0
    fi
    
    # Дополнительная проверка DLE по характерным файлам
    if [[ -f "$site_path/admin.php" ]] && [[ -f "$site_path/cron.php" ]] && [[ -d "$site_path/engine" ]]; then
        echo "dle"
        return 0
    fi
    
    # Проверка на Joomla
    if [[ -f "$site_path/configuration.php" ]] && [[ -d "$site_path/administrator" ]]; then
        echo "joomla"
        return 0
    fi
    
    echo "unknown"
}

# Функция для определения панели управления
detect_control_panel() {
    log_info "Определяем тип панели управления..."
    
    # Проверяем наличие Hestia по сервисам
    if systemctl is-active --quiet hestia.service 2>/dev/null || systemctl list-units --type=service | grep -q hestia.service; then
        CONTROL_PANEL="hestia"
        log_success "Обнаружена панель: Hestia"
        return 0
    fi
    
    # Проверяем наличие ISPManager по сервису ihttpd
    if systemctl is-active --quiet ihttpd.service 2>/dev/null || systemctl list-units --type=service | grep -q ihttpd.service; then
        CONTROL_PANEL="ispmanager"
        log_success "Обнаружена панель: ISPManager"
        return 0
    fi
    
    # Проверяем наличие FastPanel по сервисам (приоритет)
    if systemctl is-active --quiet fastpanel2.service 2>/dev/null || systemctl list-units --type=service | grep -q fastpanel2.service; then
        CONTROL_PANEL="fastpanel"
        log_success "Обнаружена панель: FastPanel"
        return 0
    fi
    
    # Проверяем наличие FastPanel по характерным директориям
    if [[ -d "/usr/local/mgr5" ]] || [[ -d "/usr/local/fastpanel" ]]; then
        CONTROL_PANEL="fastpanel"
        log_success "Обнаружена панель: FastPanel"
        return 0
    fi
    
    # Дополнительная проверка по структуре директорий
    if find /var/www -maxdepth 2 -type d -name "data" 2>/dev/null | head -1 | grep -q "/var/www/.*/data"; then
        # Если есть структура /var/www/*/data, скорее всего FastPanel или ISPManager
        # Проверяем есть ли www-root (характерно для ISPManager)
        if [[ -d "/var/www/www-root" ]]; then
            CONTROL_PANEL="ispmanager"
            log_success "Обнаружена панель: ISPManager (по структуре директорий)"
        else
            CONTROL_PANEL="fastpanel"
            log_success "Обнаружена панель: FastPanel (по структуре директорий)"
        fi
        return 0
    fi
    
    # Проверяем структуру Hestia по директориям
    if find /home -maxdepth 3 -type d -name "public_html" 2>/dev/null | head -1 | grep -q "/home/.*/web/.*/public_html"; then
        CONTROL_PANEL="hestia"
        log_success "Обнаружена панель: Hestia (по структуре директорий)"
        return 0
    fi
    
    # Если ничего не найдено, по умолчанию FastPanel
    CONTROL_PANEL="fastpanel"
    log_warning "Не удалось определить панель управления, используем FastPanel по умолчанию"
}

# Функция для поиска директории сайта (обновленная)
find_site_directory() {
    local site_name="$1"
    local found_path=""
    
    log_info "Ищем директорию сайта $site_name для панели $CONTROL_PANEL..."
    
    case $CONTROL_PANEL in
        "hestia")
            # Для Hestia сайты в /home/пользователь/web/сайт/public_html/
            for user_dir in /home/*/; do
                if [[ -d "${user_dir}web/${site_name}/public_html" ]]; then
                    found_path="${user_dir}web/${site_name}/public_html"
                    log_success "Найден сайт Hestia: $found_path"
                    break
                fi
            done
            ;;
        "ispmanager")
            # Для ISPManager сайты обычно в /var/www/www-root/data/www/
            if [[ -d "/var/www/www-root/data/www/${site_name}" ]]; then
                found_path="/var/www/www-root/data/www/${site_name}"
                log_success "Найден сайт ISPManager: $found_path"
            else
                # Дополнительный поиск по всем пользователям (на случай если есть другие)
                for user_dir in /var/www/*/; do
                    if [[ -d "${user_dir}data/www/${site_name}" ]]; then
                        found_path="${user_dir}data/www/${site_name}"
                        log_success "Найден сайт ISPManager (альтернативный путь): $found_path"
                        break
                    fi
                done
            fi
            ;;
        "fastpanel")
            # Для FastPanel поиск по стандартному пути
            for user_dir in /var/www/*/; do
                if [[ -d "${user_dir}data/www/${site_name}" ]]; then
                    found_path="${user_dir}data/www/${site_name}"
                    log_success "Найден сайт FastPanel: $found_path"
                    break
                fi
            done
            ;;
    esac
    
    echo "$found_path"
}

# Функция для получения владельца сайта из пути (обновленная)
get_site_owner() {
    local site_path="$1"
    local owner=""
    
    case $CONTROL_PANEL in
        "hestia")
            # Для Hestia извлекаем пользователя из пути /home/пользователь/web/сайт/public_html
            owner=$(echo "$site_path" | sed -n 's|/home/\([^/]*\)/.*|\1|p')
            ;;
        "ispmanager")
            # Для ISPManager обычно www-root
            owner=$(echo "$site_path" | sed -n 's|/var/www/\([^/]*\)/.*|\1|p')
            # Если не удалось извлечь, по умолчанию www-root
            if [[ -z "$owner" ]]; then
                owner="www-root"
            fi
            ;;
        "fastpanel")
            # Для FastPanel извлекаем из пути
            owner=$(echo "$site_path" | sed -n 's|/var/www/\([^/]*\)/.*|\1|p')
            ;;
    esac
    
    echo "$owner"
}

# Функция для предложения владельца нового сайта
suggest_site_owner() {
    local source_site_path="$1"
    local new_site_name="$2"
    local suggested_owner=""
    
    # Сначала проверяем, существует ли уже директория нового сайта
    local existing_target_path=""
    case $CONTROL_PANEL in
        "hestia")
            # Для Hestia ищем в /home/*/web/сайт/public_html
            for user_dir in /home/*/; do
                if [[ -d "${user_dir}web/${new_site_name}/public_html" ]]; then
                    existing_target_path="${user_dir}web/${new_site_name}/public_html"
                    break
                fi
            done
            ;;
        "ispmanager"|"fastpanel")
            # Для ISPManager и FastPanel ищем в /var/www/*/data/www/сайт
            for user_dir in /var/www/*/; do
                if [[ -d "${user_dir}data/www/${new_site_name}" ]]; then
                    existing_target_path="${user_dir}data/www/${new_site_name}"
                    break
                fi
            done
            ;;
    esac
    
    # Если директория нового сайта уже существует, извлекаем владельца оттуда
    if [[ -n "$existing_target_path" ]]; then
        suggested_owner=$(get_site_owner "$existing_target_path")
        log_info "Найдена существующая директория нового сайта: $existing_target_path"
        log_info "Предлагаем владельца из существующей директории: $suggested_owner"
    else
        # Если директории нет, используем стандартную логику
        case $CONTROL_PANEL in
            "hestia")
                # Для Hestia используем владельца исходного сайта
                local source_owner=$(get_site_owner "$source_site_path")
                suggested_owner="$source_owner"
                log_info "Для Hestia предлагаем владельца: $suggested_owner"
                ;;
            "ispmanager")
                # Для ISPManager используем владельца исходного сайта (как у Hestia)
                local source_owner=$(get_site_owner "$source_site_path")
                suggested_owner="$source_owner"
                log_info "Для ISPManager предлагаем владельца: $suggested_owner"
                ;;
            "fastpanel")
                # Для FastPanel используем логику как раньше
                local source_owner=$(get_site_owner "$source_site_path")
                suggested_owner="${new_site_name}_usr"
                log_info "Для FastPanel предлагаем владельца: $suggested_owner"
                ;;
        esac
    fi
    
    echo "$suggested_owner"
}

# Функция для проверки и создания структуры директорий
ensure_site_directory_structure() {
    local site_owner="$1"
    local site_name="$2"
    
    case $CONTROL_PANEL in
        "hestia")
            local base_dir="/home/${site_owner}/web"
            ;;
        "ispmanager")
            local base_dir="/var/www/${site_owner}/data/www"
            ;;
        "fastpanel")
            local base_dir="/var/www/${site_owner}/data/www"
            ;;
    esac
    
    # Проверяем существование базовой структуры
    if [[ ! -d "$base_dir" ]]; then
        case $CONTROL_PANEL in
            "hestia")
                log_error "Директория $base_dir не существует!"
                log_error "Для Hestia убедитесь что пользователь $site_owner создан"
                return 1
                ;;
            "ispmanager")
                log_error "Директория $base_dir не существует!"
                log_error "Для ISPManager убедитесь что пользователь www-root создан"
                return 1
                ;;
            "fastpanel")
                log_error "Директория пользователя $base_dir не существует!"
                log_error "Создайте пользователя $site_owner в FastPanel"
                return 1
                ;;
        esac
    fi
    
    log_success "Структура директорий для $CONTROL_PANEL корректна"
    return 0
}

# Функция для извлечения данных БД из WordPress конфига
get_db_info_from_wp_config() {
    local config_file="$1"
    if [[ -f "$config_file" ]]; then
        # Извлекаем значения из строк вида define('DB_NAME', 'value');
        local db_name=$(grep "DB_NAME" "$config_file" | grep -o "'[^']*'" | tail -1 | tr -d "'")
        local db_user=$(grep "DB_USER" "$config_file" | grep -o "'[^']*'" | tail -1 | tr -d "'")
        local db_pass=$(grep "DB_PASSWORD" "$config_file" | grep -o "'[^']*'" | tail -1 | tr -d "'")
        
        # Если не получилось с одинарными кавычками, пробуем двойные
        if [[ -z "$db_name" ]]; then
            db_name=$(grep "DB_NAME" "$config_file" | grep -o '"[^"]*"' | tail -1 | tr -d '"')
        fi
        if [[ -z "$db_user" ]]; then
            db_user=$(grep "DB_USER" "$config_file" | grep -o '"[^"]*"' | tail -1 | tr -d '"')
        fi
        if [[ -z "$db_pass" ]]; then
            db_pass=$(grep "DB_PASSWORD" "$config_file" | grep -o '"[^"]*"' | tail -1 | tr -d '"')
        fi
        
        echo "$db_name|$db_user|$db_pass"
    fi
}

# Функция для извлечения данных БД из DLE конфига
get_db_info_from_dle_config() {
    local config_file="$1"
    if [[ -f "$config_file" ]]; then
        # Извлекаем данные из формата define ("DBNAME", "value");
        local db_name=$(grep 'define ("DBNAME"' "$config_file" | sed 's/.*define ("DBNAME", "\([^"]*\)");.*/\1/' | head -1)
        local db_user=$(grep 'define ("DBUSER"' "$config_file" | sed 's/.*define ("DBUSER", "\([^"]*\)");.*/\1/' | head -1)
        local db_pass=$(grep 'define ("DBPASS"' "$config_file" | sed 's/.*define ("DBPASS", "\([^"]*\)");.*/\1/' | head -1)
        
        # Если не получилось с двойными кавычками, пробуем одинарные
        if [[ -z "$db_name" ]]; then
            db_name=$(grep "define ('DBNAME'" "$config_file" | sed "s/.*define ('DBNAME', '\([^']*\)');.*/\1/" | head -1)
        fi
        if [[ -z "$db_user" ]]; then
            db_user=$(grep "define ('DBUSER'" "$config_file" | sed "s/.*define ('DBUSER', '\([^']*\)');.*/\1/" | head -1)
        fi
        if [[ -z "$db_pass" ]]; then
            db_pass=$(grep "define ('DBPASS'" "$config_file" | sed "s/.*define ('DBPASS', '\([^']*\)');.*/\1/" | head -1)
        fi
        
        echo "$db_name|$db_user|$db_pass"
    fi
}

# Функция для создания дампа БД
create_db_dump() {
    local db_name="$1"
    local dump_file="/tmp/${db_name}_$(date +%Y%m%d_%H%M%S).sql"
    
    log_info "Создаем дамп базы данных $db_name..."
    
    # Проверяем существование БД
    if ! mysql -e "USE $db_name;" 2>/dev/null; then
        log_error "База данных $db_name не существует!"
        return 1
    fi
    
    # Создаем дамп с подавлением вывода в stderr
    if mysqldump --routines --triggers --events --single-transaction "$db_name" > "$dump_file" 2>/dev/null; then
        # Проверяем что файл действительно создался и не пустой
        if [[ -f "$dump_file" ]] && [[ -s "$dump_file" ]]; then
            local file_size=$(du -h "$dump_file" | cut -f1)
            log_success "Дамп создан: $dump_file (размер: $file_size)"
            # Выводим только путь к файлу в stdout
            echo "$dump_file"
            return 0
        else
            log_error "Дамп создан, но файл пустой или не существует!"
            return 1
        fi
    else
        log_error "Ошибка создания дампа БД!"
        return 1
    fi
}

# Функция для создания новой БД
create_database() {
    local db_name="$1"
    local db_user="$2"
    local db_pass="$3"
    
    log_info "Создаем базу данных $db_name..."
    
    # Проверяем не существует ли уже БД
    if mysql -e "USE $db_name;" 2>/dev/null; then
        log_warning "База данных $db_name уже существует"
        read -p "Очистить существующую базу данных? (y/N): " clear_db
        if [[ "$clear_db" =~ ^[Yy]$ ]]; then
            log_info "Очищаем существующую базу данных..."
            mysql -e "DROP DATABASE \`$db_name\`;" 2>/dev/null
        else
            log_info "Используем существующую базу данных"
        fi
    fi
    
    # Создаем БД
    if mysql -e "CREATE DATABASE IF NOT EXISTS \`$db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/tmp/mysql_create_error.log; then
        log_success "База данных $db_name создана"
    else
        log_error "Ошибка создания базы данных!"
        if [[ -f /tmp/mysql_create_error.log ]]; then
            log_error "Детали ошибки:"
            cat /tmp/mysql_create_error.log
            rm -f /tmp/mysql_create_error.log
        fi
        return 1
    fi
    
    # Проверяем существует ли уже пользователь
    local user_exists=$(mysql -e "SELECT User FROM mysql.user WHERE User='$db_user' AND Host='localhost';" 2>/dev/null | grep -c "$db_user")
    
    if [[ $user_exists -gt 0 ]]; then
        log_warning "Пользователь $db_user уже существует"
        read -p "Пересоздать пользователя БД? (y/N): " recreate_user
        if [[ "$recreate_user" =~ ^[Yy]$ ]]; then
            log_info "Удаляем существующего пользователя..."
            mysql -e "DROP USER '$db_user'@'localhost';" 2>/dev/null
        else
            log_info "Используем существующего пользователя"
            # Просто обновляем права для существующего пользователя
            if mysql -e "GRANT ALL PRIVILEGES ON \`$db_name\`.* TO '$db_user'@'localhost';" 2>/dev/null; then
                mysql -e "FLUSH PRIVILEGES;" 2>/dev/null
                log_success "Права для существующего пользователя $db_user обновлены"
            else
                log_error "Ошибка обновления прав для существующего пользователя!"
                return 1
            fi
            return 0
        fi
    fi
    
    # Создаем пользователя и даем права
    log_info "Создаем пользователя БД $db_user..."
    
    # Создаем нового пользователя
    if mysql -e "CREATE USER '$db_user'@'localhost' IDENTIFIED BY '$db_pass';" 2>/tmp/mysql_user_error.log; then
        log_success "Пользователь $db_user создан"
    else
        log_error "Ошибка создания пользователя БД!"
        if [[ -f /tmp/mysql_user_error.log ]]; then
            log_error "Детали ошибки:"
            cat /tmp/mysql_user_error.log
            rm -f /tmp/mysql_user_error.log
        fi
        return 1
    fi
    
    # Назначаем права
    if mysql -e "GRANT ALL PRIVILEGES ON \`$db_name\`.* TO '$db_user'@'localhost';" 2>/dev/null; then
        mysql -e "FLUSH PRIVILEGES;" 2>/dev/null
        log_success "Права для пользователя $db_user назначены"
    else
        log_error "Ошибка назначения прав пользователю БД!"
        return 1
    fi
    
    # Проверяем что БД доступна для нового пользователя
    if mysql -u"$db_user" -p"$db_pass" -e "USE $db_name;" 2>/dev/null; then
        log_success "Подключение к БД под новым пользователем успешно"
    else
        log_warning "Не удается подключиться к БД под новым пользователем"
    fi
}

# Функция для импорта дампа в новую БД
import_db_dump() {
    local new_db_name="$1"
    local dump_file="$2"
    
    log_info "Импортируем дамп в базу $new_db_name..."
    
    # Проверяем существование файла дампа
    if [[ ! -f "$dump_file" ]]; then
        log_error "Файл дампа $dump_file не найден!"
        return 1
    fi
    
    # Проверяем что файл не пустой
    if [[ ! -s "$dump_file" ]]; then
        log_error "Файл дампа $dump_file пустой!"
        return 1
    fi
    
    log_info "Размер файла дампа: $(du -h "$dump_file" | cut -f1)"
    
    # Проверяем существование целевой БД
    if ! mysql -e "USE $new_db_name;" 2>/dev/null; then
        log_error "Целевая база данных $new_db_name не существует!"
        return 1
    fi
    
    # Импортируем дамп с детальной диагностикой
    if mysql "$new_db_name" < "$dump_file" 2>/tmp/mysql_import_error.log; then
        log_success "Дамп успешно импортирован"
        # Удаляем файл с ошибками если импорт прошел успешно
        rm -f /tmp/mysql_import_error.log
        return 0
    else
        log_error "Ошибка импорта дампа!"
        if [[ -f /tmp/mysql_import_error.log ]]; then
            log_error "Детали ошибки:"
            cat /tmp/mysql_import_error.log | head -10
            rm -f /tmp/mysql_import_error.log
        fi
        return 1
    fi
}

# Функция для обновления URL в WordPress БД
update_wp_urls_in_db() {
    local db_name="$1"
    local old_url="$2"
    local new_url="$3"
    
    log_info "Обновляем URL в базе данных WordPress..."
    
    mysql "$db_name" <<EOF 2>/dev/null
UPDATE wp_options SET option_value = 'http://$new_url' WHERE option_name = 'home';
UPDATE wp_options SET option_value = 'http://$new_url' WHERE option_name = 'siteurl';
UPDATE wp_posts SET post_content = REPLACE(post_content, 'http://$old_url', 'http://$new_url');
UPDATE wp_posts SET post_content = REPLACE(post_content, 'https://$old_url', 'http://$new_url');
EOF
    
    log_success "URL в базе данных WordPress обновлены"
}

# Функция для очистки директории
clean_directory() {
    local dir_path="$1"
    if [[ -d "$dir_path" ]] && [[ "$(ls -A "$dir_path" 2>/dev/null)" ]]; then
        log_warning "Директория $dir_path не пуста. Очищаем..."
        rm -rf "$dir_path"/*
        log_success "Директория очищена"
    fi
}

# Функция для обновления конфигурации WordPress
update_wp_config() {
    local config_file="$1"
    local new_db_name="$2"
    local new_db_user="$3"
    local new_db_pass="$4"
    
    if [[ -f "$config_file" ]]; then
        log_info "Обновляем конфигурацию WordPress..."
        
        # Создаем резервную копию
        cp "$config_file" "${config_file}.bak"
        
        # Показываем текущие настройки для диагностики
        log_info "Текущие настройки БД в конфиге:"
        grep -E "DB_NAME|DB_USER|DB_PASSWORD" "$config_file" >&2
        
        # Создаем временный файл
        local temp_file="${config_file}.tmp"
        cp "$config_file" "$temp_file"
        
        # Обновляем каждую строку отдельно
        sed -i "/DB_NAME/c\define( 'DB_NAME', '$new_db_name' );" "$temp_file"
        sed -i "/DB_USER/c\define( 'DB_USER', '$new_db_user' );" "$temp_file"
        sed -i "/DB_PASSWORD/c\define( 'DB_PASSWORD', '$new_db_pass' );" "$temp_file"
        
        # Заменяем оригинальный файл
        mv "$temp_file" "$config_file"
        
        # Показываем обновленные настройки для проверки
        log_info "Обновленные настройки БД в конфиге:"
        grep -E "DB_NAME|DB_USER|DB_PASSWORD" "$config_file" >&2
        
        log_success "Конфигурация WordPress обновлена"
    else
        log_error "Файл wp-config.php не найден!"
        return 1
    fi
}

# Функция для обновления конфигурации DLE
update_dle_config() {
    local site_path="$1"
    local new_db_name="$2"
    local new_db_user="$3"
    local new_db_pass="$4"
    local new_site_url="$5"
    
    local dbconfig_file="$site_path/engine/data/dbconfig.php"
    local config_file="$site_path/engine/data/config.php"
    
    # Обновляем dbconfig.php
    if [[ -f "$dbconfig_file" ]]; then
        log_info "Обновляем конфигурацию БД DLE..."
        
        # Создаем резервную копию
        cp "$dbconfig_file" "${dbconfig_file}.bak"
        
        # Показываем текущие настройки для диагностики
        log_info "Текущие настройки БД в DLE конфиге:"
        grep -E "DBNAME|DBUSER|DBPASS" "$dbconfig_file" >&2
        
        # Экранируем специальные символы в пароле для sed
        local escaped_db_pass=$(printf '%s\n' "$new_db_pass" | sed 's/[\.*^$()+?{|\\]/\\&/g')
        
        # Обновляем настройки БД с учетом формата define ("DBNAME", "value");
        sed -i "s/define (\"DBNAME\", \"[^\"]*\")/define (\"DBNAME\", \"$new_db_name\")/" "$dbconfig_file"
        sed -i "s/define (\"DBUSER\", \"[^\"]*\")/define (\"DBUSER\", \"$new_db_user\")/" "$dbconfig_file"
        sed -i "s/define (\"DBPASS\", \"[^\"]*\")/define (\"DBPASS\", \"$escaped_db_pass\")/" "$dbconfig_file"
        
        # Также обрабатываем формат с одинарными кавычками (на всякий случай)
        sed -i "s/define ('DBNAME', '[^']*')/define ('DBNAME', '$new_db_name')/" "$dbconfig_file"
        sed -i "s/define ('DBUSER', '[^']*')/define ('DBUSER', '$new_db_user')/" "$dbconfig_file"
        sed -i "s/define ('DBPASS', '[^']*')/define ('DBPASS', '$escaped_db_pass')/" "$dbconfig_file"
        
        # Показываем обновленные настройки для проверки
        log_info "Обновленные настройки БД в DLE конфиге:"
        grep -E "DBNAME|DBUSER|DBPASS" "$dbconfig_file" >&2
        
        log_success "Конфигурация БД DLE обновлена"
    else
        log_error "Файл engine/data/dbconfig.php не найден!"
        return 1
    fi
    
    # Обновляем config.php
    if [[ -f "$config_file" ]]; then
        log_info "Обновляем основную конфигурацию DLE..."
        
        # Создаем резервную копию
        cp "$config_file" "${config_file}.bak"
        
        # Показываем текущие настройки URL
        log_info "Текущий URL в DLE конфиге:"
        grep "http_home_url" "$config_file" >&2
        
        # Обновляем URL сайта
        sed -i "s|'http_home_url' => '[^']*'|'http_home_url' => 'http://$new_site_url'|" "$config_file"
        
        # Показываем обновленный URL
        log_info "Обновленный URL в DLE конфиге:"
        grep "http_home_url" "$config_file" >&2
        
        log_success "Основная конфигурация DLE обновлена"
    else
        log_error "Файл engine/data/config.php не найден!"
        return 1
    fi
}

# Функция для тестирования обновления wp-config (для отладки)
test_wp_config_update() {
    local config_file="$1"
    local new_db_name="$2"
    local new_db_user="$3"
    local new_db_pass="$4"
    
    if [[ -f "$config_file" ]]; then
        log_info "Тестируем обновление конфигурации WordPress..."
        
        # Показываем что будем менять
        log_info "Исходные строки:"
        grep -E "DB_NAME|DB_USER|DB_PASSWORD" "$config_file" >&2
        
        # Создаем временную копию для теста
        local temp_file="/tmp/wp-config-test.php"
        cp "$config_file" "$temp_file"
        
        # Применяем изменения к временному файлу
        sed -i "s/define( 'DB_NAME', '[^']*' );/define( 'DB_NAME', '$new_db_name' );/" "$temp_file"
        sed -i "s/define( 'DB_USER', '[^']*' );/define( 'DB_USER', '$new_db_user' );/" "$temp_file"
        sed -i "s/define( 'DB_PASSWORD', '[^']*' );/define( 'DB_PASSWORD', '$new_db_pass' );/" "$temp_file"
        
        log_info "Результат изменений:"
        grep -E "DB_NAME|DB_USER|DB_PASSWORD" "$temp_file" >&2
        
        # Удаляем временный файл
        rm -f "$temp_file"
        
        log_info "Тест завершен"
    fi
}

# Функция для тестирования обновления DLE конфигурации (для отладки)
test_dle_config_update() {
    local site_path="$1"
    local new_db_name="$2"
    local new_db_user="$3"
    local new_db_pass="$4"
    local new_site_url="$5"
    
    local dbconfig_file="$site_path/engine/data/dbconfig.php"
    local config_file="$site_path/engine/data/config.php"
    
    if [[ -f "$dbconfig_file" ]]; then
        log_info "Тестируем обновление конфигурации DLE БД..."
        
        # Показываем что будем менять
        log_info "Исходные строки БД:"
        grep -E "DBNAME|DBUSER|DBPASS" "$dbconfig_file" >&2
        
        # Создаем временную копию для теста
        local temp_file="/tmp/dle-dbconfig-test.php"
        cp "$dbconfig_file" "$temp_file"
        
        # Применяем изменения к временному файлу
        sed -i "s/define (\"DBNAME\", \"[^\"]*\")/define (\"DBNAME\", \"$new_db_name\")/" "$temp_file"
        sed -i "s/define (\"DBUSER\", \"[^\"]*\")/define (\"DBUSER\", \"$new_db_user\")/" "$temp_file"
        sed -i "s/define (\"DBPASS\", \"[^\"]*\")/define (\"DBPASS\", \"$new_db_pass\")/" "$temp_file"
        
        log_info "Результат изменений БД:"
        grep -E "DBNAME|DBUSER|DBPASS" "$temp_file" >&2
        
        # Удаляем временный файл
        rm -f "$temp_file"
    fi
    
    if [[ -f "$config_file" ]]; then
        log_info "Тестируем обновление URL DLE..."
        
        # Показываем что будем менять
        log_info "Исходный URL:"
        grep "http_home_url" "$config_file" >&2
        
        # Создаем временную копию для теста
        local temp_file="/tmp/dle-config-test.php"
        cp "$config_file" "$temp_file"
        
        # Применяем изменения к временному файлу
        sed -i "s|'http_home_url' => '[^']*'|'http_home_url' => 'http://$new_site_url'|" "$temp_file"
        
        log_info "Результат изменения URL:"
        grep "http_home_url" "$temp_file" >&2
        
        # Удаляем временный файл
        rm -f "$temp_file"
    fi
    
    log_info "Тест DLE завершен"
}

# Функция для проверки необходимых утилит
check_required_utilities() {
    log_info "Проверяем наличие необходимых утилит..."
    
    local required_utils=("rsync" "mysqldump" "mysql" "sed" "grep" "find" "systemctl" "du" "df" "awk")
    local missing_utils=()
    
    for util in "${required_utils[@]}"; do
        if ! command -v "$util" &>/dev/null; then
            missing_utils+=("$util")
        fi
    done
    
    if [[ ${#missing_utils[@]} -gt 0 ]]; then
        log_error "Отсутствуют необходимые утилиты:"
        for util in "${missing_utils[@]}"; do
            log_error "  - $util"
        done
        log_error "Установите недостающие утилиты и запустите скрипт снова"
        exit 1
    fi
    
    log_success "Все необходимые утилиты найдены"
}

# Основная функция
main() {
    echo "=============================================="
    echo "  Site Copy Script v2.5"
    echo "=============================================="
    echo
    
    log_info "Начинаем процесс копирования сайта"
    log_info "Лог файл: $LOG_FILE"
    
    check_root
    check_required_utilities
    check_mysql_connection
    
    # Определяем панель управления
    detect_control_panel
    
    # Шаг 1: Получаем информацию об исходном сайте
    echo -e "${BLUE}Шаг 1: Определение исходного сайта${NC}"
    read -p "Введите имя исходного сайта (например, test.local): " source_site_name
    
    if [[ -z "$source_site_name" ]]; then
        log_error "Имя сайта не может быть пустым!"
        exit 1
    fi
    
    validate_site_name "$source_site_name"
    
    # Поиск директории исходного сайта
    source_site_path=$(find_site_directory "$source_site_name")
    
    if [[ -z "$source_site_path" ]]; then
        log_warning "Автоматически найти директорию не удалось"
        read -p "Введите полный путь к директории сайта: " source_site_path
        
        if [[ ! -d "$source_site_path" ]]; then
            log_error "Директория $source_site_path не существует!"
            exit 1
        fi
    else
        log_success "Найдена директория: $source_site_path"
    fi
    
    # Определяем CMS
    detected_cms=$(detect_cms "$source_site_path")
    log_info "Обнаруженная CMS: $detected_cms"
    
    if [[ "$detected_cms" == "unknown" ]]; then
        echo "Не удалось автоматически определить CMS."
        echo "1) WordPress"
        echo "2) DLE"
        echo "3) Другая/Неизвестная"
        read -p "Выберите CMS (1-3): " cms_choice
        
        case $cms_choice in
            1) detected_cms="wordpress" ;;
            2) detected_cms="dle" ;;
            *) detected_cms="other" ;;
        esac
    fi
    
    # Получаем информацию о БД из конфигов
    old_db_info=""
    if [[ "$detected_cms" == "wordpress" ]]; then
        old_db_info=$(get_db_info_from_wp_config "$source_site_path/wp-config.php")
    elif [[ "$detected_cms" == "dle" ]]; then
        old_db_info=$(get_db_info_from_dle_config "$source_site_path/engine/data/dbconfig.php")
    fi
    
    if [[ -n "$old_db_info" ]]; then
        IFS='|' read -r old_db_name old_db_user old_db_pass <<< "$old_db_info"
        log_success "Найдена информация о БД: $old_db_name"
    fi
    
    # Шаг 2: Получаем информацию о новом сайте
    echo
    echo -e "${BLUE}Шаг 2: Настройка нового сайта${NC}"
    read -p "Введите имя нового сайта (например, copy.local): " new_site_name
    
    if [[ -z "$new_site_name" ]]; then
        log_error "Имя сайта не может быть пустым!"
        exit 1
    fi
    
    validate_site_name "$new_site_name"
    
    # Предлагаем владельца в зависимости от панели управления
    suggested_owner=$(suggest_site_owner "$source_site_path" "$new_site_name")
    
    case $CONTROL_PANEL in
        "hestia")
            echo "Для Hestia обычно используется тот же пользователь что и у исходного сайта"
            read -p "Введите имя пользователя нового сайта (по умолчанию: $suggested_owner): " new_site_user
            ;;
        "ispmanager")
            echo "Для ISPManager обычно используется тот же пользователь что и у исходного сайта"
            read -p "Введите имя пользователя нового сайта (по умолчанию: $suggested_owner): " new_site_user
            ;;
        "fastpanel")
            read -p "Введите имя пользователя нового сайта (по умолчанию: $suggested_owner): " new_site_user
            ;;
    esac
    
    # Если пользователь ничего не ввел, используем предложенное значение
    if [[ -z "$new_site_user" ]]; then
        new_site_user="$suggested_owner"
        log_info "Используем владельца по умолчанию: $new_site_user"
    fi
    
    # Формируем путь к новому сайту в зависимости от панели
    case $CONTROL_PANEL in
        "hestia")
            new_site_path="/home/${new_site_user}/web/${new_site_name}/public_html"
            ;;
        "ispmanager"|"fastpanel")
            new_site_path="/var/www/${new_site_user}/data/www/${new_site_name}"
            ;;
    esac
    
    # Проверяем структуру директорий
    ensure_site_directory_structure "$new_site_user" "$new_site_name"
    if [[ $? -ne 0 ]]; then
        exit 1
    fi
    
    # Проверяем свободное место
    case $CONTROL_PANEL in
        "hestia")
            check_disk_space "$source_site_path" "/home/${new_site_user}/web"
            ;;
        "ispmanager"|"fastpanel")
            check_disk_space "$source_site_path" "/var/www/${new_site_user}/data/www"
            ;;
    esac
    
    # Создаем директорию сайта если её нет
    if [[ ! -d "$new_site_path" ]]; then
        mkdir -p "$new_site_path"
        log_success "Создана директория: $new_site_path"
    else
        clean_directory "$new_site_path"
    fi
    
    # Шаг 3: Настройка БД (если CMS поддерживается)
    if [[ "$detected_cms" != "other" ]] && [[ -n "$old_db_name" ]]; then
        echo
        echo -e "${BLUE}Шаг 3: Настройка базы данных${NC}"
        
        # Ввод имени БД с проверкой
        while true; do
            read -p "Введите имя новой базы данных: " new_db_name
            if [[ -n "$new_db_name" ]]; then
                break
            else
                log_error "Имя базы данных не может быть пустым!"
                echo "Попробуйте еще раз."
            fi
        done
        
        # Ввод пользователя БД с проверкой
        while true; do
            read -p "Введите имя пользователя БД: " new_db_user
            if [[ -n "$new_db_user" ]]; then
                break
            else
                log_error "Имя пользователя БД не может быть пустым!"
                echo "Попробуйте еще раз."
            fi
        done
        
        # Ввод пароля БД с проверкой
        while true; do
            read -p "Введите пароль для БД: " new_db_pass
            if [[ -n "$new_db_pass" ]]; then
                break
            else
                log_error "Пароль БД не может быть пустым!"
                echo "Попробуйте еще раз."
            fi
        done
        
        validate_db_name "$new_db_name"
        
        # Создаем дамп старой БД
        TEMP_DUMP_FILE=$(create_db_dump "$old_db_name")
        if [[ $? -ne 0 ]]; then
            exit 1
        fi
        
        # Проверяем что переменная TEMP_DUMP_FILE установлена корректно
        if [[ -z "$TEMP_DUMP_FILE" ]]; then
            log_error "Не удалось получить путь к файлу дампа!"
            exit 1
        fi
        
        log_info "Путь к файлу дампа: $TEMP_DUMP_FILE"
        
        # Создаем новую БД
        create_database "$new_db_name" "$new_db_user" "$new_db_pass"
        if [[ $? -ne 0 ]]; then
            exit 1
        fi
    fi
    
    # Шаг 4: Копирование файлов
    echo
    echo -e "${BLUE}Шаг 4: Копирование файлов${NC}"
    log_info "Копируем файлы из $source_site_path в $new_site_path..."
    
    if rsync -avz "$source_site_path/" "$new_site_path/" >/dev/null 2>&1; then
        log_success "Файлы успешно скопированы"
    else
        log_error "Ошибка при копировании файлов!"
        exit 1
    fi
    
    # Устанавливаем права доступа
    log_info "Устанавливаем права доступа..."
    chown -R "$new_site_user:$new_site_user" "$new_site_path"
    find "$new_site_path" -type d -exec chmod 755 {} \;
    find "$new_site_path" -type f -exec chmod 644 {} \;
    log_success "Права доступа установлены"
    
    # Шаг 5: Обновление конфигураций и импорт БД
    if [[ "$detected_cms" != "other" ]] && [[ -n "$TEMP_DUMP_FILE" ]]; then
        echo
        echo -e "${BLUE}Шаг 5: Обновление конфигураций и импорт БД${NC}"
        
        # Дополнительная проверка файла дампа перед импортом
        log_info "Проверяем файл дампа перед импортом..."
        if [[ ! -f "$TEMP_DUMP_FILE" ]]; then
            log_error "Файл дампа $TEMP_DUMP_FILE не найден перед импортом!"
            exit 1
        fi
        
        log_info "Файл дампа существует: $TEMP_DUMP_FILE"
        log_info "Размер файла: $(ls -lh "$TEMP_DUMP_FILE" | awk '{print $5}')"
        
        # Импортируем дамп в новую БД
        import_db_dump "$new_db_name" "$TEMP_DUMP_FILE"
        if [[ $? -ne 0 ]]; then
            exit 1
        fi
        
        # Обновляем конфигурацию в зависимости от CMS
        case $detected_cms in
            "wordpress")
                update_wp_config "$new_site_path/wp-config.php" "$new_db_name" "$new_db_user" "$new_db_pass"
                # Обновляем URL в БД WordPress
                update_wp_urls_in_db "$new_db_name" "$source_site_name" "$new_site_name"
                ;;
            "dle")
                update_dle_config "$new_site_path" "$new_db_name" "$new_db_user" "$new_db_pass" "$new_site_name"
                ;;
        esac
    fi
    
    # Финальные сообщения
    echo
    echo "=============================================="
    log_success "Копирование сайта завершено успешно!"
    echo "=============================================="
    echo "Панель управления: $CONTROL_PANEL"
    echo "Исходный сайт: $source_site_name"
    echo "Новый сайт: $new_site_name"
    echo "Путь: $new_site_path"
    echo "Владелец: $new_site_user"
    if [[ "$detected_cms" != "other" ]]; then
        echo "CMS: $detected_cms"
        if [[ -n "$new_db_name" ]]; then
            echo "База данных: $new_db_name"
            echo "Пользователь БД: $new_db_user"
        fi
    fi
    echo "Лог файл: $LOG_FILE"
    echo "=============================================="
    echo
    log_info "Процесс копирования завершен успешно!"
    
    if [[ "$detected_cms" != "other" ]]; then
        log_info "Не забудьте:"
        case $CONTROL_PANEL in
            "hestia")
                echo "1. Настроить веб-сервер для нового сайта в Hestia"
                echo "2. Проверить работу сайта"
                echo "3. При необходимости обновить дополнительные настройки"
                ;;
            "ispmanager")
                echo "1. Настроить веб-сервер для нового сайта в ISPManager"
                echo "2. Проверить работу сайта"
                echo "3. При необходимости обновить дополнительные настройки"
                ;;
            "fastpanel")
                echo "1. Настроить веб-сервер для нового сайта в FastPanel"
                echo "2. Проверить работу сайта"
                echo "3. При необходимости обновить дополнительные настройки"
                ;;
        esac
    else
        log_info "Не забудьте:"
        case $CONTROL_PANEL in
            "hestia")
                echo "1. Создать и настроить базу данных в Hestia (если требуется)"
                echo "2. Обновить конфигурационные файлы"
                echo "3. Настроить веб-сервер для нового сайта"
                ;;
            "ispmanager")
                echo "1. Создать и настроить базу данных в ISPManager (если требуется)"
                echo "2. Обновить конфигурационные файлы"
                echo "3. Настроить веб-сервер для нового сайта"
                ;;
            "fastpanel")
                echo "1. Создать и настроить базу данных в FastPanel (если требуется)"
                echo "2. Обновить конфигурационные файлы"
                echo "3. Настроить веб-сервер для нового сайта"
                ;;
        esac
    fi
}

# Запуск основной функции
main "$@"