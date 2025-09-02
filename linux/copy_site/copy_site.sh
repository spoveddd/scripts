#!/bin/bash
# Site Copy Script
# Автор: Vladislav Pavlovich
# Версия: 3.0
# Поддерживает: FastPanel, ISPManager, Hestia

set -e

# Определяю цвета для вывода в консоль
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# global переменные
LOG_FILE="/var/log/site_copy_script_$(date +%Y%m%d_%H%M%S).log"
TEMP_DUMP_FILE=""
CONTROL_PANEL=""

# Возвращает корректный email для LE: если домен технический (.copy, .local и т.п.),
# используем admin@example.com, иначе admin@<domain>
choose_admin_email() {
    local domain="$1"
    local tld="${domain##*.}"
    local invalid_tlds=("local" "copy" "test" "localhost" "lan" "isp" "hestia")
    for bad in "${invalid_tlds[@]}"; do
        if [[ "$tld" == "$bad" ]]; then
            echo "admin@example.com"
            return 0
        fi
    done
    # если домен без точки, тоже используем example.com
    if [[ "$domain" != *.* ]]; then
        echo "admin@example.com"
        return 0
    fi
    echo "admin@$domain"
}

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
    
    # Очищаем временные файлы FastPanel
    if [[ -f /tmp/fastpanel_site_user.info ]]; then
        rm -f /tmp/fastpanel_site_user.info
    fi
    
    # Очищаем временные файлы Hestia
    if [[ -f /tmp/hestia_actual_db_name.info ]]; then
        rm -f /tmp/hestia_actual_db_name.info
    fi
    
    # Очищаем временные файлы ошибок
    rm -f /tmp/*_error.log
    rm -f /tmp/ispmanager_ssl_error.log
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
    log_info "Проверяю подключение к MySQL..."
    if ! mysql -e "SELECT 1;" &>/dev/null; then
        log_error "Не удается подключиться к MySQL!"
        log_info "Проверьте, что MySQL запущен и доступен через сокет"
        exit 1
    fi
    log_success "Подключение к MySQL установлено, продолжаю работу"
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
    
    # Дополнительная проверка для FastPanel - ограничение длины
    if [[ "$CONTROL_PANEL" == "fastpanel" ]]; then
        if [[ ${#db_name} -gt 16 ]]; then
            log_error "Имя базы данных слишком длинное для FastPanel (максимум 16 символов): $db_name (${#db_name} символов)"
            return 1
        fi
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
    log_info "Определяю панель управления сервером..."
    
    # Проверяем наличие Hestia по сервисам
    if systemctl is-active --quiet hestia.service 2>/dev/null || systemctl list-units --type=service | grep -q hestia.service; then
        CONTROL_PANEL="hestia"
        log_success "Обнаружена панель управления: Hestia"
        return 0
    fi
    
    # Проверяем наличие ISPManager по сервису ihttpd
    if systemctl is-active --quiet ihttpd.service 2>/dev/null || systemctl list-units --type=service | grep -q ihttpd.service; then
        CONTROL_PANEL="ispmanager"
        log_success "Обнаружена панель управления: ISPManager"
        return 0
    fi
    
    # Проверяем наличие FastPanel по сервисам (приоритет)
    if systemctl is-active --quiet fastpanel2.service 2>/dev/null || systemctl list-units --type=service | grep -q fastpanel2.service; then
        CONTROL_PANEL="fastpanel"
        log_success "Обнаружена панель управления: FastPanel"
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
    
    log_info "Ищем сайт $site_name и его директорию на сервере..."
    
    case $CONTROL_PANEL in
        "hestia")
            # Для Hestia сайты в /home/пользователь/web/сайт/public_html/
            for user_dir in /home/*/; do
                if [[ -d "${user_dir}web/${site_name}/public_html" ]]; then
                    found_path="${user_dir}web/${site_name}/public_html"
                    log_success "Найден сайт с панелью управления Hestia: $found_path"
                    break
                fi
            done
            ;;
        "ispmanager")
            # Для ISPManager сайты обычно в /var/www/www-root/data/www/
            if [[ -d "/var/www/www-root/data/www/${site_name}" ]]; then
                found_path="/var/www/www-root/data/www/${site_name}"
                log_success "Найден сайт с панелью управления ISPManager: $found_path"
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
                    log_success "Найден сайт с панелью управления FastPanel: $found_path"
                    break
                fi
            done
            ;;
    esac
    
    echo "$found_path"
}

# Функция для получения владельца сайта из пути 
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
                # Для FastPanel используем логику как раньше с исправленной заменой дефисов
                local source_owner=$(get_site_owner "$source_site_path")
                # Заменяем точки и дефисы на подчеркивания для соблюдения логики FastPanel
                suggested_owner=$(echo "${new_site_name}" | sed 's/[.-]/_/g')"_usr"
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

# Функция для установки wp-cli
install_wp_cli() {
    log_info "Устанавливаем wp-cli..."
    
    # Скачиваем wp-cli
    if curl -o /tmp/wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar 2>/dev/null; then
        log_success "wp-cli скачан успешно"
        
        # Проверяем работоспособность
        if php /tmp/wp-cli.phar --info &>/dev/null; then
            # Делаем исполняемым и перемещаем в /usr/local/bin
            chmod +x /tmp/wp-cli.phar
            if mv /tmp/wp-cli.phar /usr/local/bin/wp 2>/dev/null; then
                log_success "wp-cli установлен в /usr/local/bin/wp"
                return 0
            else
                log_error "Не удалось переместить wp-cli в /usr/local/bin/"
                rm -f /tmp/wp-cli.phar
                return 1
            fi
        else
            log_error "wp-cli не работает корректно"
            rm -f /tmp/wp-cli.phar
            return 1
        fi
    else
        log_error "Не удалось скачать wp-cli"
        return 1
    fi
}

# Функция для замены доменов в WordPress через wp-cli
update_wordpress_domains() {
    local site_path="$1"
    local old_domain="$2"
    local new_domain="$3"
    
    log_info "Выполняем замену доменов в WordPress через wp-cli..."
    log_info "Старый домен: $old_domain"
    log_info "Новый домен: $new_domain"
    
    # Проверяем что wp-cli доступен
    if ! command -v wp &> /dev/null; then
        log_warning "wp-cli не найден, пытаемся установить автоматически..."
        if install_wp_cli; then
            log_success "wp-cli установлен автоматически, продолжаем замену доменов"
        else
            log_warning "Автоматическая установка wp-cli не удалась, пропускаем замену доменов"
            return 0
        fi
    fi
    
    # Переходим в директорию сайта
    cd "$site_path" || {
        log_error "Не удалось перейти в директорию сайта: $site_path"
        return 1
    }
    
    # Выполняем замену доменов
    log_info "Выполняем команду: wp search-replace \"$old_domain\" \"$new_domain\" --allow-root"
    
    if wp search-replace "$old_domain" "$new_domain" --allow-root >/dev/null 2>/tmp/wp_search_replace_error.log; then
        log_success "Замена доменов в WordPress выполнена успешно"
        return 0
    else
        log_warning "Ошибка при замене доменов в WordPress"
        if [[ -f /tmp/wp_search_replace_error.log ]]; then
            log_warning "Детали ошибки:"
            cat /tmp/wp_search_replace_error.log
            rm -f /tmp/wp_search_replace_error.log
        fi
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
        sed -i "s|'http_home_url' => '[^']*'|'http_home_url' => 'https://$new_site_url'|" "$config_file"
        
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

# =============================================================================
# НОВЫЕ ФУНКЦИИ ДЛЯ CLI ИНТЕГРАЦИИ И IP ОПРЕДЕЛЕНИЯ
# =============================================================================

# Функция для генерации случайного пароля
generate_random_password() {
    local length="${1:-16}"
    local password=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w "$length" | head -n1)
    echo "$password"
}

# Функция для определения IP исходного сайта из конфигурации
get_source_site_ip() {
    local site_name="$1"
    local ip=""
    
    case $CONTROL_PANEL in
        "hestia")
            # Hestia: /etc/nginx/conf.d/domains/*.conf
            local config_file="/etc/nginx/conf.d/domains/${site_name}.conf"
            if [[ -f "$config_file" ]]; then
                ip=$(grep -E "listen.*:" "$config_file" | grep -v "::" | head -1 | awk '{print $2}' | sed 's/:[0-9]*;//' | sed 's/:[0-9]*$//')
                log_info "Найден IP в Hestia конфиге: $ip"
            fi
            ;;
            
        "ispmanager")
            # ISPManager: /etc/nginx/vhosts/www-root/*.conf
            local config_file="/etc/nginx/vhosts/www-root/${site_name}.conf"
            if [[ -f "$config_file" ]]; then
                # Ищем строку listen и извлекаем IP адрес
                ip=$(grep -E "listen.*:" "$config_file" | grep -v "::" | head -1 | sed 's/.*listen[[:space:]]*\([0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+\)[^0-9].*/\1/')
                if [[ -n "$ip" ]] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    log_info "Найден IP в ISPManager конфиге: $ip"
                else
                    log_warning "Не удалось корректно извлечь IP из конфига ISPManager"
                    ip=""
                fi
            fi
            ;;
            
        "fastpanel")
            # FastPanel: /etc/nginx/fastpanel2-sites/владелец/сайт.conf
            # Извлекаем владельца из пути сайта
            local site_owner=$(get_site_owner "$(find /var/www/*/data/www/${site_name} 2>/dev/null | head -1)")
            if [[ -n "$site_owner" ]]; then
                local config_file="/etc/nginx/fastpanel2-sites/${site_owner}/${site_name}.conf"
                if [[ -f "$config_file" ]]; then
                    ip=$(grep -E "listen.*:" "$config_file" | grep -v "::" | head -1 | awk '{print $2}' | sed 's/:[0-9]*;//' | sed 's/:[0-9]*$//')
                    log_info "Найден IP в FastPanel конфиге: $ip"
                else
                    log_warning "Конфиг FastPanel не найден: $config_file"
                fi
            else
                log_warning "Не удалось определить владельца сайта $site_name для FastPanel"
            fi
            ;;
    esac
    
    # Если IP не найден, возвращаем пустую строку
    if [[ -z "$ip" ]]; then
        log_warning "IP для сайта $site_name не найден в конфигурации"
        return 1
    fi
    
    # Дополнительная валидация IP адреса
    if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_warning "Получен некорректный IP адрес: $ip"
        return 1
    fi
    
    echo "$ip"
    return 0
}

# Функция для проверки доступности IP
ip_is_available() {
    local ip="$1"
    
    # Проверяем что IP не используется другими сайтами
    local used_by=0
    case $CONTROL_PANEL in
        "hestia")
            # Проверяем в Hestia конфигах
            used_by=$(grep -r "listen.*$ip:" /etc/nginx/conf.d/domains/ 2>/dev/null | wc -l)
            ;;
        "ispmanager")
            # Проверяем в ISPManager конфигах
            used_by=$(grep -r "listen.*$ip:" /etc/nginx/vhosts/www-root/ 2>/dev/null | wc -l)
            ;;
        "fastpanel")
            # Проверяем в FastPanel конфигах
            used_by=$(grep -r "listen.*$ip:" /etc/nginx/fastpanel2-sites/ 2>/dev/null | wc -l)
            ;;
    esac
    
    # Если IP используется менее чем 2 сайтами, считаем доступным
    if [[ $used_by -lt 2 ]]; then
        return 0
    else
        return 1
    fi
}

# Функция для получения доступных IP
get_available_ips() {
    local available_ips=""
    
    case $CONTROL_PANEL in
        "hestia")
            # Получаем IP из Hestia конфигов
            available_ips=$(grep -r "listen.*:" /etc/nginx/conf.d/domains/ 2>/dev/null | \
                          grep -v "::" | awk '{print $2}' | sed 's/:[0-9]*;//' | sed 's/:[0-9]*$//' | sort -u)
            ;;
        "ispmanager")
            # Получаем IP из ISPManager конфигов
            # Извлекаем только корректные IPv4 из директив listen (без слова 'listen' и без IPv6)
            available_ips=$(grep -r "listen" /etc/nginx/vhosts/www-root/ 2>/dev/null | \
                          grep -v "::" | sed -E 's/.*listen[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+).*/\1/' | \
                          grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u)
            ;;
        "fastpanel")
            # Получаем IP из FastPanel конфигов
            available_ips=$(grep -r "listen.*:" /etc/nginx/fastpanel2-sites/ 2>/dev/null | \
                          grep -v "::" | awk '{print $2}' | sed 's/:[0-9]*;//' | sed 's/:[0-9]*$//' | sort -u)
            ;;
    esac
    
    echo "$available_ips"
}

# Функция для умного выбора IP
get_target_ip() {
    local source_site_name="$1"
    local target_ip=""
    
    # 1. Пытаемся получить IP исходного сайта
    log_info "Определяем IP исходного сайта $source_site_name..."
    source_ip=$(get_source_site_ip "$source_site_name")
    
    if [[ $? -eq 0 ]] && [[ -n "$source_ip" ]]; then
        # 2. Проверяем доступность этого IP
        if ip_is_available "$source_ip"; then
            target_ip="$source_ip"
            log_success "Используем IP исходного сайта: $target_ip"
        else
            log_warning "IP исходного сайта $source_ip недоступен"
        fi
    fi
    
    # 3. Если IP исходного сайта недоступен или не найден
    if [[ -z "$target_ip" ]]; then
        log_info "Выбираем IP из доступных..."
        available_ips=$(get_available_ips)
        
        if [[ $(echo "$available_ips" | wc -w) -eq 1 ]]; then
            # Если доступен только один IP
            target_ip="$available_ips"
            log_info "Автоматически выбран единственный доступный IP: $target_ip"
        else
            # Если доступно несколько IP - спрашиваем пользователя
            echo "Доступные IP адреса:"
            select ip in $available_ips; do
                if [[ -n "$ip" ]]; then
                    target_ip="$ip"
                    log_info "Выбран IP: $target_ip"
                    break
                else
                    echo "Неверный выбор. Попробуйте еще раз."
                fi
            done
        fi
    fi
    
    echo "$target_ip"
}

# Функция для создания сайта через CLI Hestia
create_hestia_site() {
    local user="$1"
    local domain="$2"
    local ip="$3"
    
    log_info "Создаем сайт $domain в Hestia через CLI..."
    
    if v-add-web-domain "$user" "$domain" "$ip" "yes" 2>/tmp/hestia_site_error.log; then
        log_success "Сайт $domain успешно создан в Hestia"
        # Пытаемся выпустить Let's Encrypt SSL сертификат
        # 1) Регистрируем LE-пользователя (если уже зарегистрирован — не считаем ошибкой)
        if v-add-letsencrypt-user "$user" >/dev/null 2>&1; then
            :
        fi
        
        # 2) Пробуем мгновенный выпуск для домена
        log_info "Генерируем Let's Encrypt SSL сертификат для $domain..."
        # Не включаем почтовый SSL (MAIL=no), чтобы не требовалось наличие mail-домена
        if v-add-letsencrypt-domain "$user" "$domain" "" no 2>/tmp/hestia_ssl_error.log; then
            log_success "SSL сертификат для $domain успешно сгенерирован (Hestia)"
        else
            log_warning "Не удалось сразу сгенерировать SSL сертификат для $domain (Hestia)"
            if [[ -f /tmp/hestia_ssl_error.log ]]; then
                log_warning "Детали ошибки SSL (Hestia):"
                cat /tmp/hestia_ssl_error.log
                rm -f /tmp/hestia_ssl_error.log
            fi
            # 3) Планируем отложенную установку сертификата
            if v-schedule-letsencrypt-domain "$user" "$domain" "" >/dev/null 2>&1; then
                log_info "Запланирована отложенная генерация SSL Let's Encrypt для $domain"
            else
                log_info "Сайт создан, но SSL сертификат не сгенерирован. Можно попробовать вручную через панель Hestia"
            fi
        fi
        return 0
    else
        log_error "Ошибка создания сайта в Hestia!"
        if [[ -f /tmp/hestia_site_error.log ]]; then
            log_error "Детали ошибки:"
            cat /tmp/hestia_site_error.log
            rm -f /tmp/hestia_site_error.log
        fi
        return 1
    fi
}

# Функция для создания БД через CLI Hestia
create_hestia_database() {
    local user="$1"
    local db_name="$2"
    local db_user="$3"
    local db_pass="$4"
    
    log_info "Создаем базу данных $db_name в Hestia через CLI..."
    
    if v-add-database "$user" "$db_name" "$db_user" "$db_pass" 2>/tmp/hestia_db_error.log; then
        # Hestia создает БД с префиксом пользователя
        local actual_db_name="${user}_${db_name}"
        # Hestia также создает пользователя БД с префиксом
        local actual_db_user="${user}_${db_user}"
        log_success "База данных $actual_db_name успешно создана в Hestia"
        log_info "Пользователь БД создан как: $actual_db_user"
        # Сохраняем реальные имена для последующего использования
        echo "$actual_db_name|$actual_db_user" > /tmp/hestia_actual_db_name.info
        return 0
    else
        log_error "Ошибка создания базы данных в Hestia!"
        if [[ -f /tmp/hestia_db_error.log ]]; then
            log_error "Детали ошибки:"
            cat /tmp/hestia_db_error.log
            rm -f /tmp/hestia_db_error.log
        fi
        return 1
    fi
}

# Функция для создания сайта через CLI FastPanel
create_fastpanel_site() {
    local domain="$1"
    local ip="$2"
    local site_user="$3"  # Добавляем параметр для имени пользователя
    local php_mode="${4:-mpm_itk}"  # PHP режим, по умолчанию mpm_itk
    
    log_info "Создаем сайт $domain в FastPanel через CLI..."
    log_info "PHP режим: $php_mode"
    
    # Используем переданное имя пользователя, если оно задано
    if [[ -z "$site_user" ]]; then
        # Fallback: генерируем имя пользователя на основе домена
        site_user="${domain//./_}_usr"
        # Ограничиваем длину для FastPanel
        if [[ ${#site_user} -gt 16 ]]; then
            local base_name="${domain//./_}"
            if [[ ${#base_name} -gt 12 ]]; then
                base_name="${base_name:0:12}"
            fi
            site_user="${base_name}_usr"
        fi
    fi
    local random_pass=$(generate_random_password)
    
    log_info "Создаем пользователя $site_user для сайта..."
    if mogwai users create --username="$site_user" --password="$random_pass" 2>/tmp/fastpanel_user_error.log; then
        log_success "Пользователь $site_user создан"
    else
        log_error "Ошибка создания пользователя в FastPanel!"
        if [[ -f /tmp/fastpanel_user_error.log ]]; then
            log_error "Детали ошибки:"
            cat /tmp/fastpanel_user_error.log
            rm -f /tmp/fastpanel_user_error.log
        fi
        return 1
    fi
    
    # Создаем сайт с указанием PHP режима
    if mogwai sites create --server-name="$domain" --owner="$site_user" --ip="$ip" --php-mode="$php_mode" 2>/tmp/fastpanel_site_error.log; then
        log_success "Сайт $domain успешно создан в FastPanel"
        # Сохраняем информацию о пользователе для вывода в конце
        echo "$site_user|$random_pass" > /tmp/fastpanel_site_user.info
        
        # Пытаемся выпустить Let's Encrypt SSL сертификат для сайта в FastPanel
        log_info "Генерируем Let's Encrypt SSL сертификат для $domain..."
        local admin_email_fast=$(choose_admin_email "$domain")
        local fp_ssl_out
        fp_ssl_out=$(mogwai certificates create-le --server-name="$domain" --email="$admin_email_fast" 2>&1) || true
        # Проверяем вывод/наличие сертификата, т.к. утилита может завершаться с 0 при предупреждениях
        if echo "$fp_ssl_out" | grep -qiE "Cannot create certificate|err:"; then
            log_warning "Не удалось сгенерировать SSL сертификат для $domain (FastPanel)"
            echo "$fp_ssl_out" | sed 's/^/  /'
            log_info "Сайт создан, но SSL сертификат не сгенерирован. Можно попробовать позже через FastPanel"
        else
            # Верифицируем, что сертификат появился в списке
            if mogwai certificates list 2>/dev/null | grep -q "$domain"; then
                log_success "SSL сертификат для $domain успешно сгенерирован (FastPanel)"
            else
                log_warning "Сертификат для $domain не найден в списке после выпуска (FastPanel)"
                echo "$fp_ssl_out" | sed 's/^/  /'
            fi
        fi
        return 0
    else
        log_error "Ошибка создания сайта в FastPanel!"
        if [[ -f /tmp/fastpanel_site_error.log ]]; then
            log_error "Детали ошибки:"
            cat /tmp/fastpanel_site_error.log
            rm -f /tmp/fastpanel_site_error.log
        fi
        return 1
    fi
}

# Функция для создания БД через CLI FastPanel
create_fastpanel_database() {
    local site_user="$1"
    local db_name="$2"
    local db_user="$3"
    local db_pass="$4"
    
    log_info "Создаем базу данных $db_name в FastPanel через CLI..."
    
    if mogwai databases create --server=1 -n "$db_name" -o "$site_user" -u "$db_user" -p "$db_pass" 2>/tmp/fastpanel_db_error.log; then
        log_success "База данных $db_name успешно создана в FastPanel"
        return 0
    else
        log_error "Ошибка создания базы данных в FastPanel!"
        if [[ -f /tmp/fastpanel_db_error.log ]]; then
            log_error "Детали ошибки:"
            cat /tmp/fastpanel_db_error.log
            rm -f /tmp/fastpanel_db_error.log
        fi
        return 1
    fi
}

# Функция для создания сайта через CLI ISPManager
create_ispmanager_site() {
    local user="$1"
    local domain="$2"
    local ip="$3"
    
    log_info "Создаем сайт $domain в ISPManager через CLI..."
    
    # Для ISPManager нужно указать email администратора — подбираем валидный
    local admin_email=$(choose_admin_email "$domain")
    
    if /usr/local/mgr5/sbin/mgrctl -m ispmgr webdomain.edit sok=ok name="$domain" owner="$user" ip="$ip" email="$admin_email" 2>/tmp/ispmanager_site_error.log; then
        log_success "Сайт $domain успешно создан в ISPManager"
        
        # Автоматически генерируем Let's Encrypt SSL сертификат
        #log_info "Генерируем Let's Encrypt SSL сертификат для $domain..."
        
        # Генерируем Let's Encrypt SSL сертификат
        log_info "Генерируем Let's Encrypt SSL сертификат для $domain..."
        local ssl_success=false
        
        # Создаем SSL сертификат с правильными параметрами из справки
        if /usr/local/mgr5/sbin/mgrctl -m ispmgr letsencrypt.generate sok=ok domain_name="$domain" email="$admin_email" 2>/tmp/ispmanager_ssl_error.log; then
            log_success "SSL сертификат для $domain успешно сгенерирован"
            ssl_success=true
        else
            log_warning "Не удалось сгенерировать SSL сертификат для $domain"
            if [[ -f /tmp/ispmanager_ssl_error.log ]]; then
                log_warning "Детали ошибки SSL:"
                cat /tmp/ispmanager_ssl_error.log
                rm -f /tmp/ispmanager_ssl_error.log
            fi
            log_info "Сайт создан, но SSL сертификат не сгенерирован"
            log_info "Попробуйте сгенерировать SSL вручную через панель управления"
        fi
        
        if [[ "$ssl_success" == false ]]; then
            log_warning "Не удалось сгенерировать SSL сертификат для $domain"
            if [[ -f /tmp/ispmanager_ssl_error.log ]]; then
                log_warning "Детали ошибки SSL:"
                cat /tmp/ispmanager_ssl_error.log
                rm -f /tmp/ispmanager_ssl_error.log
            fi
            log_info "Сайт создан, но SSL сертификат не сгенерирован"
            log_info "Попробуйте сгенерировать SSL вручную через панель управления"
        fi
        
        return 0
    else
        log_error "Ошибка создания сайта в ISPManager!"
        if [[ -f /tmp/ispmanager_site_error.log ]]; then
            log_error "Детали ошибки:"
            cat /tmp/ispmanager_site_error.log
            rm -f /tmp/ispmanager_site_error.log
        fi
        return 1
    fi
}

# Функция для создания БД через CLI ISPManager
create_ispmanager_database() {
    local user="$1"
    local db_name="$2"
    local db_user="$3"
    local db_pass="$4"
    
    log_info "Создаем базу данных $db_name в ISPManager через CLI..."
    
    # Для ISPManager нужно указать username (имя пользователя БД)
    if /usr/local/mgr5/sbin/mgrctl -m ispmgr db.edit sok=ok name="$db_name" owner="$user" username="$db_user" password="$db_pass" 2>/tmp/ispmanager_db_error.log; then
        log_success "База данных $db_name успешно создана в ISPManager"
        return 0
    else
        log_error "Ошибка создания базы данных в ISPManager!"
        if [[ -f /tmp/ispmanager_db_error.log ]]; then
            log_error "Детали ошибки:"
            cat /tmp/ispmanager_db_error.log
            rm -f /tmp/ispmanager_db_error.log
        fi
        return 1
    fi
}

# Функция для проверки существования сайта в панели управления
check_site_exists() {
    local domain="$1"
    
    case $CONTROL_PANEL in
        "hestia")
            # Для Hestia проверяем наличие конфигурационного файла
            if [[ -f "/etc/nginx/conf.d/domains/${domain}.conf" ]]; then
                return 0
            fi
            ;;
        "ispmanager")
            # Для ISPManager проверяем наличие конфигурационного файла
            if [[ -f "/etc/nginx/vhosts/www-root/${domain}.conf" ]]; then
                return 0
            fi
            ;;
        "fastpanel")
            # Для FastPanel проверяем через CLI
            if mogwai sites list 2>/dev/null | grep -q "^$domain"; then
                return 0
            fi
            # Дополнительная проверка по файлам конфигурации
            if find /etc/nginx/fastpanel2-sites -name "${domain}.conf" 2>/dev/null | grep -q "${domain}.conf"; then
                return 0
            fi
            ;;
    esac
    
    return 1
}

# Функция для создания сайта через CLI (общая)
create_site_via_cli() {
    local user="$1"
    local domain="$2"
    local ip="$3"
    
    case $CONTROL_PANEL in
        "hestia")
            create_hestia_site "$user" "$domain" "$ip"
            ;;
        "fastpanel")
            create_fastpanel_site "$domain" "$ip" "$user"
            ;;
        "ispmanager")
            create_ispmanager_site "$user" "$domain" "$ip"
            ;;
        *)
            log_error "Неизвестная панель управления: $CONTROL_PANEL"
            return 1
            ;;
    esac
}

# Функция для создания БД через CLI (общая)
create_database_via_cli() {
    local user="$1"
    local db_name="$2"
    local db_user="$3"
    local db_pass="$4"
    
    case $CONTROL_PANEL in
        "hestia")
            create_hestia_database "$user" "$db_name" "$db_user" "$db_pass"
            ;;
        "fastpanel")
            # Для FastPanel используем переданного пользователя или из временного файла
            local site_user="$user"
            if [[ -f /tmp/fastpanel_site_user.info ]]; then
                site_user=$(cat /tmp/fastpanel_site_user.info | cut -d'|' -f1)
                log_info "Используем пользователя из временного файла: $site_user"
            else
                log_info "Используем переданного пользователя для FastPanel: $site_user"
            fi
            create_fastpanel_database "$site_user" "$db_name" "$db_user" "$db_pass"
            ;;
        "ispmanager")
            create_ispmanager_database "$user" "$db_name" "$db_user" "$db_pass"
            ;;
        *)
            log_error "Неизвестная панель управления: $CONTROL_PANEL"
            return 1
            ;;
    esac
}

# Функция для отката при ошибках
rollback_on_error() {
    local error_stage="$1"
    local user="$2"
    local domain="$3"
    local db_name="$4"
    
    log_error "Произошла ошибка на этапе: $error_stage"
    log_info "Выполняем откат..."
    
    case $error_stage in
        "site_creation_failed")
            log_error "Создание сайта не удалось"
            # Ничего не удаляем, сайт не создался
            ;;
        "database_creation_failed")
            log_error "Создание БД не удалось"
            # Удаляем созданный сайт, БД не создалась
            delete_site_via_cli "$user" "$domain"
            ;;
        "file_copy_failed")
            log_error "Копирование файлов не удалось"
            # Удаляем БД и сайт, файлы не скопировались
            delete_database_via_cli "$user" "$db_name"
            delete_site_via_cli "$user" "$domain"
            ;;
        "config_update_failed")
            log_error "Обновление конфигурации не удалось"
            # Удаляем БД, сайт и файлы
            delete_database_via_cli "$user" "$db_name"
            delete_site_via_cli "$user" "$domain"
            ;;
    esac
}

# Функция для удаления сайта через CLI (заглушка)
delete_site_via_cli() {
    local user="$1"
    local domain="$2"
    
    log_warning "Удаляем сайт $domain (функция удаления пока не реализована)"
    # TODO: Реализовать удаление сайта через CLI
}

# Функция для удаления БД через CLI (заглушка)
delete_database_via_cli() {
    local user="$1"
    local db_name="$2"
    
    log_warning "Удаляем базу данных $db_name (функция удаления пока не реализована)"
    # TODO: Реализовать удаление БД через CLI
}

# Функция для расширенной валидации
validate_creation() {
    local user="$1"
    local domain="$2"
    local db_name="$3"
    local site_path="$4"
    
    log_info "Выполняем валидацию созданных объектов..."
    
    # 1. Проверка директорий
    if [[ -d "$site_path" ]]; then
        log_success "Директория сайта существует: $site_path"
    else
        log_error "Директория сайта не найдена: $site_path"
        return 1
    fi
    
    # 2. Проверка БД (если CMS поддерживается)
    if [[ "$detected_cms" != "other" ]] && [[ -n "$db_name" ]]; then
        # Для Hestia нужно учитывать префикс пользователя
        local actual_db_name="$db_name"
        local actual_db_user="$db_user"
        if [[ "$CONTROL_PANEL" == "hestia" ]]; then
            # Получаем имя пользователя из пути сайта
            local user_from_path=$(echo "$site_path" | sed -n 's|/home/\([^/]*\)/.*|\1|p')
            if [[ -n "$user_from_path" ]]; then
                actual_db_name="${user_from_path}_${db_name}"
                actual_db_user="${user_from_path}_${db_user}"
                log_info "Для Hestia проверяем БД с префиксом пользователя: $actual_db_name"
                log_info "Для Hestia используем пользователя БД с префиксом: $actual_db_user"
            fi
        fi
        
        if mysql -e "USE $actual_db_name;" 2>/dev/null; then
            log_success "База данных $actual_db_name доступна"
        else
            log_error "База данных $actual_db_name недоступна"
            return 1
        fi
    fi
    
    # 3. Проверка конфигурационных файлов
    case $detected_cms in
        "wordpress")
            if [[ -f "$site_path/wp-config.php" ]]; then
                log_success "WordPress конфигурация найдена"
            else
                log_error "WordPress конфигурация не найдена"
                return 1
            fi
            ;;
        "dle")
            if [[ -f "$site_path/engine/data/dbconfig.php" ]]; then
                log_success "DLE конфигурация найдена"
            else
                # Пытаемся найти конфиг в альтернативных местах внутри директории сайта
                local dle_cfg_path
                dle_cfg_path=$(find "$site_path" -maxdepth 4 -type f -name "dbconfig.php" 2>/dev/null | head -1)
                if [[ -n "$dle_cfg_path" ]]; then
                    log_success "DLE конфигурация найдена: $dle_cfg_path"
                else
                    log_warning "DLE конфигурация не найдена внутри $site_path. Проверьте структуру DLE на исходном сайте"
                    # Не считаем критической ошибкой, продолжаем
                fi
            fi
            ;;
    esac
    
    log_success "Валидация завершена успешно"
    return 0
}

# Функция для проверки необходимых утилит
check_required_utilities() {
    log_info "Проверяю наличие необходимых утилит для работы..."
    
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
    # Компактный заголовок по центру на ширину сообщений
    local header_width=60
    local title="🚀 Site Copy Script v3.0 🚀"
    local author="by Vladislav Pavlovich"
    local purpose="for technical support"
    local contact="📱 Telegram: @femid00"
    
    # Функция для центрирования текста
    center_text() {
        local text="$1"
        local width="$2"
        local padding=$(( (width - ${#text}) / 2 ))
        printf '%*s%s%*s\n' "$padding" '' "$text" "$padding" ''
    }
    
    # Создаем линию нужной длины
    local line=$(printf '%*s' "$header_width" '' | tr ' ' '=')
    
    echo "$line"
    center_text "$title" "$header_width"
    echo "$line"
    center_text "$author" "$header_width"
    center_text "$purpose" "$header_width"
    center_text "$contact" "$header_width"
    echo "$line"
    echo ""
    
    log_info "Начинаем процесс копирования сайта на сервере, следи за выводом в консоль"
    log_info "Лог файл пишу здесь: $LOG_FILE"
    
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
        log_success "Найдена его директория: $source_site_path"
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
            echo "Для Hestia рекомендую использовать того же пользователя что и у исходного сайта"
            read -p "Введите имя пользователя нового сайта (по умолчанию: $suggested_owner): " new_site_user
            ;;
        "ispmanager")
            echo "Для ISPManager рекомендую использовать того же пользователя что и у исходного сайта"
            read -p "Введите имя пользователя нового сайта (по умолчанию: $suggested_owner): " new_site_user
            ;;
        "fastpanel")
            echo "Для FastPanel будет создан отдельный пользователь для сайта"
            read -p "Введите имя пользователя нового сайта (по умолчанию: $suggested_owner): " new_site_user
            ;;
    esac
    
    # Если пользователь ничего не ввел, используем предложенное значение
    if [[ -z "$new_site_user" ]]; then
        new_site_user="$suggested_owner"
        log_info "Используем владельца по умолчанию: $new_site_user"
    fi
    
    # Шаг 2.1: Определяем IP для нового сайта
    echo
    echo -e "${BLUE}Шаг 2.1: Определение IP адреса${NC}"
    target_ip=$(get_target_ip "$source_site_name")
    
    if [[ -z "$target_ip" ]]; then
        log_error "Не удалось определить IP для нового сайта!"
        exit 1
    fi
    
    log_success "Выбран IP для нового сайта: $target_ip"
    
    # Шаг 2.2: Проверяем существование сайта и создаем при необходимости
    echo
    echo -e "${BLUE}Шаг 2.2: Проверка существования и создание сайта${NC}"
    
    # Сначала проверяем, существует ли сайт уже в панели управления
    if check_site_exists "$new_site_name"; then
        log_warning "Сайт $new_site_name уже существует в панели управления"
        log_info "Продолжаем с использованием существующего сайта..."
        
        # Проверяем, существует ли директория сайта
        case $CONTROL_PANEL in
            "hestia")
                new_site_path="/home/${new_site_user}/web/${new_site_name}/public_html"
                ;;
            "ispmanager"|"fastpanel")
                new_site_path="/var/www/${new_site_user}/data/www/${new_site_name}"
                ;;
        esac
        
        # Если стандартный путь не найден, ищем альтернативные пути
        if [[ ! -d "$new_site_path" ]]; then
            log_info "Стандартная директория не найдена, ищем альтернативные пути..."
            existing_site_path=$(find_site_directory "$new_site_name")
            
            if [[ -n "$existing_site_path" ]]; then
                new_site_path="$existing_site_path"
                # Извлекаем владельца из найденного пути
                new_site_user=$(get_site_owner "$new_site_path")
                log_success "Найдена существующая директория сайта: $new_site_path"
                log_info "Владелец сайта: $new_site_user"
            else
                log_error "Не удалось найти директорию существующего сайта $new_site_name!"
                log_error "Сайт создан в панели, но директория недоступна"
                exit 1
            fi
        else
            log_success "Найдена директория существующего сайта: $new_site_path"
        fi
    else
        log_info "Сайт $new_site_name не существует, создаем новый..."
        
        # Создаем сайт через CLI панели
        if ! create_site_via_cli "$new_site_user" "$new_site_name" "$target_ip"; then
            rollback_on_error "site_creation_failed" "$new_site_user" "$new_site_name" ""
            exit 1
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
        
        # Проверяем что сайт действительно создался
        if [[ ! -d "$new_site_path" ]]; then
            log_error "Сайт не был создан корректно! Директория не найдена: $new_site_path"
            rollback_on_error "site_creation_failed" "$new_site_user" "$new_site_name" ""
            exit 1
        fi
        
        log_success "Сайт успешно создан: $new_site_path"
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
    
    # Шаг 3: Настройка БД (если CMS поддерживается)
    if [[ "$detected_cms" != "other" ]] && [[ -n "$old_db_name" ]]; then
        echo
        echo -e "${BLUE}Шаг 3: Настройка базы данных${NC}"
        
        # Автоматически генерируем имена для БД
        if [[ "$CONTROL_PANEL" == "fastpanel" ]]; then
            # Для FastPanel ограничиваем длину имен БД до 16 символов
            local base_name=$(echo "${new_site_name}" | sed 's/[.-]/_/g')
            # Если имя слишком длинное, обрезаем его для БД
            if [[ ${#base_name} -gt 12 ]]; then
                base_name="${base_name:0:12}"
                log_info "Имя БД обрезано до 12 символов для соблюдения ограничений FastPanel"
            fi
            new_db_name="${base_name}_db"
            new_db_user="${base_name}_usr"
        else
            # Для других панелей используем стандартную логику с заменой дефисов и точек
            local base_name=$(echo "${new_site_name}" | sed 's/[.-]/_/g')
            new_db_name="${base_name}_db"
            new_db_user="${base_name}_usr"
        fi
        new_db_pass=$(generate_random_password)
        
        log_info "Автоматически сгенерированы параметры БД:"
        echo "  Имя БД: $new_db_name"
        echo "  Пользователь БД: $new_db_user"
        echo "  Пароль БД: $new_db_pass"
        
        # Спрашиваем подтверждение
        read -p "Использовать эти параметры? (Y/n): " confirm_db
        if [[ "$confirm_db" =~ ^[Nn]$ ]]; then
            # Ручной ввод параметров
            while true; do
                read -p "Введите имя новой базы данных: " new_db_name
                if [[ -n "$new_db_name" ]]; then
                    break
                else
                    log_error "Имя базы данных не может быть пустым!"
                    echo "Попробуйте еще раз."
                fi
            done
            
            while true; do
                read -p "Введите имя пользователя БД: " new_db_user
                if [[ -n "$new_db_user" ]]; then
                    break
                else
                    log_error "Имя пользователя БД не может быть пустым!"
                    echo "Попробуйте еще раз."
                fi
            done
            
            while true; do
                read -p "Введите пароль для БД: " new_db_pass
                if [[ -n "$new_db_pass" ]]; then
                    break
                else
                    log_error "Пароль БД не может быть пустым!"
                    echo "Попробуйте еще раз."
                fi
            done
        fi
        
        validate_db_name "$new_db_name"
        
        # Валидация имени пользователя БД для FastPanel
        if [[ "$CONTROL_PANEL" == "fastpanel" ]]; then
            if [[ ${#new_db_user} -gt 16 ]]; then
                log_error "Имя пользователя БД слишком длинное для FastPanel (максимум 16 символов): $new_db_user (${#new_db_user} символов)"
                exit 1
            fi
        fi

        
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
        
        # Создаем новую БД через CLI панели
        log_info "Создаем базу данных через панель управления..."
        if ! create_database_via_cli "$new_site_user" "$new_db_name" "$new_db_user" "$new_db_pass"; then
            rollback_on_error "database_creation_failed" "$new_site_user" "$new_site_name" "$new_db_name"
            exit 1
        fi
        
        log_success "База данных успешно создана через панель управления"
    fi
    
    # Шаг 4: Копирование файлов
    echo
    echo -e "${BLUE}Шаг 4: Копирование файлов${NC}"
    
    # Очищаем директорию нового сайта от заглушек панели управления
    log_info "Очищаем директорию нового сайта от заглушек панели управления..."
    if [[ -d "$new_site_path" ]] && [[ "$(ls -A "$new_site_path" 2>/dev/null)" ]]; then
        log_info "Найдены файлы в директории нового сайта, очищаем..."
        rm -rf "$new_site_path"/*
        log_success "Директория очищена"
    else
        log_info "Директория нового сайта пуста, очистка не требуется"
    fi
    
    log_info "Копируем файлы из $source_site_path в $new_site_path..."
    
    if rsync -avz "$source_site_path/" "$new_site_path/" >/dev/null 2>&1; then
        log_success "Файлы успешно скопированы"
        
        # Проверяем что файлы действительно скопировались
        local copied_files_count=$(find "$new_site_path" -type f 2>/dev/null | wc -l)
        local source_files_count=$(find "$source_site_path" -type f 2>/dev/null | wc -l)
        
        if [[ $copied_files_count -gt 0 ]]; then
            log_success "Скопировано файлов: $copied_files_count (исходных: $source_files_count)"
        else
            log_error "Файлы не были скопированы!"
            rollback_on_error "file_copy_failed" "$new_site_user" "$new_site_name" "$new_db_name"
            exit 1
        fi
    else
        log_error "Ошибка при копировании файлов!"
        rollback_on_error "file_copy_failed" "$new_site_user" "$new_site_name" "$new_db_name"
        exit 1
    fi
    
    # Устанавливаем права доступа
    log_info "Устанавливаем права доступа..."
    chown -R "$new_site_user:$new_site_user" "$new_site_path"
    find "$new_site_path" -type d -exec chmod 755 {} \;
    find "$new_site_path" -type f -exec chmod 644 {} \;
    log_success "Права доступа установлены"
    
    # Валидация копирования файлов
    log_info "Проверяем корректность копирования файлов..."
    if ! validate_creation "$new_site_user" "$new_site_name" "$new_db_name" "$new_site_path"; then
        log_error "Валидация не прошла!"
        rollback_on_error "file_copy_failed" "$new_site_user" "$new_site_name" "$new_db_name"
        exit 1
    fi
    
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
        # Для Hestia используем реальное имя БД с префиксом
        local import_db_name="$new_db_name"
        if [[ "$CONTROL_PANEL" == "hestia" ]] && [[ -f /tmp/hestia_actual_db_name.info ]]; then
            import_db_name=$(cat /tmp/hestia_actual_db_name.info | cut -d'|' -f1)
            log_info "Для Hestia используем БД с префиксом: $import_db_name"
        fi
        
        import_db_dump "$import_db_name" "$TEMP_DUMP_FILE"
        if [[ $? -ne 0 ]]; then
            exit 1
        fi
        
        # Обновляем конфигурацию в зависимости от CMS
        # Для Hestia используем реальное имя БД с префиксом
        local config_db_name="$new_db_name"
        local config_db_user="$new_db_user"
        if [[ "$CONTROL_PANEL" == "hestia" ]] && [[ -f /tmp/hestia_actual_db_name.info ]]; then
            config_db_name=$(cat /tmp/hestia_actual_db_name.info | cut -d'|' -f1)
            config_db_user=$(cat /tmp/hestia_actual_db_name.info | cut -d'|' -f2)
            log_info "Для Hestia используем БД с префиксом в конфигурации: $config_db_name"
            log_info "Для Hestia используем пользователя БД с префиксом в конфигурации: $config_db_user"
        fi
        
        case $detected_cms in
            "wordpress")
                if ! update_wp_config "$new_site_path/wp-config.php" "$config_db_name" "$config_db_user" "$new_db_pass"; then
                    log_error "Ошибка обновления WordPress конфигурации!"
                    rollback_on_error "config_update_failed" "$new_site_user" "$new_site_name" "$new_db_name"
                    exit 1
                fi
                
                # Выполняем замену доменов через wp-cli (с автоматической установкой)
                if ! update_wordpress_domains "$new_site_path" "$source_site_name" "$new_site_name"; then
                    log_warning "Замена доменов в WordPress не удалась, но продолжаем выполнение"
                fi
                
                # Обновляем URL в БД WordPress
                if ! update_wp_urls_in_db "$config_db_name" "$source_site_name" "$new_site_name"; then
                    log_error "Ошибка обновления URL в WordPress БД!"
                    rollback_on_error "config_update_failed" "$new_site_user" "$new_site_name" "$new_db_name"
                    exit 1
                fi
                
                # Показываем итоговый статус для WordPress
                if command -v wp &> /dev/null; then
                    log_success "WordPress: конфигурация обновлена, домены заменены через wp-cli, URL в БД обновлены"
                else
                    log_warning "WordPress: конфигурация обновлена, домены НЕ заменены (wp-cli недоступен), URL в БД обновлены"
                    log_info "Рекомендуется установить wp-cli для автоматической замены доменов"
                fi
                ;;
            "dle")
                if ! update_dle_config "$new_site_path" "$config_db_name" "$config_db_user" "$new_db_pass" "$new_site_name"; then
                    log_error "Ошибка обновления DLE конфигурации!"
                    rollback_on_error "config_update_failed" "$new_site_user" "$new_site_name" "$new_db_name"
                    exit 1
                fi
                ;;
        esac
        
        log_success "Конфигурации успешно обновлены"
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
    
    # Выводим информацию о FastPanel пользователе если это FastPanel
    if [[ "$CONTROL_PANEL" == "fastpanel" ]] && [[ -f /tmp/fastpanel_site_user.info ]]; then
        local site_user=$(cat /tmp/fastpanel_site_user.info | cut -d'|' -f1)
        local site_pass=$(cat /tmp/fastpanel_site_user.info | cut -d'|' -f2)
        echo "Создан пользователь FastPanel: $site_user"
        echo "Пароль пользователя: $site_pass"
        # Очищаем временный файл
        rm -f /tmp/fastpanel_site_user.info
    fi
    
    if [[ "$detected_cms" != "other" ]]; then
        echo "CMS: $detected_cms"
        if [[ -n "$new_db_name" ]]; then
            # Для Hestia показываем реальные имена БД и пользователя с префиксом
            local display_db_name="$new_db_name"
            local display_db_user="$new_db_user"
            if [[ "$CONTROL_PANEL" == "hestia" ]] && [[ -f /tmp/hestia_actual_db_name.info ]]; then
                display_db_name=$(cat /tmp/hestia_actual_db_name.info | cut -d'|' -f1)
                display_db_user=$(cat /tmp/hestia_actual_db_name.info | cut -d'|' -f2)
            fi
            echo "База данных: $display_db_name"
            echo "Пользователь БД: $display_db_user"
            echo "Пароль БД: $new_db_pass"
        fi
        
        # Дополнительная информация для WordPress
        if [[ "$detected_cms" == "wordpress" ]]; then
            if command -v wp &> /dev/null; then
                echo "WordPress: домены заменены через wp-cli ✅"
            else
                echo "WordPress: домены НЕ заменены (wp-cli недоступен) ⚠️"
            fi
        fi
        
        # Дополнительная информация для ISPManager
        if [[ "$CONTROL_PANEL" == "ispmanager" ]]; then
            echo "ISPManager: SSL сертификат генерируется автоматически 🔒"
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