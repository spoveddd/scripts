#!/bin/bash
#=====================================================================
# LEMP/LAMP Stack 
#=====================================================================
# Автор: Павлович Владислав - pavlovich.live
# Версия: 2.3.5
#
# Описание: Этот скрипт автоматизирует развертывание и настройку
# LEMP или LAMP стека с оптимизацией производительности и функциями
# безопасности. Поддерживает дистрибутивы Ubuntu и CentOS.
# Позволяет выбрать между различными конфигурациями, включая
# Nginx+Apache в режиме прокси, и добавление новых сайтов в
# существующую конфигурацию.
# Кроме того добавлена поддержка установки панелей управления 
#=====================================================================

# Строгий режим выполнения
set -e

# Цвета для лучшей читаемости
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # Без цвета

# Лог-файл
LOG_FILE="/var/log/lemp_automate.log"

# Переменные конфигурации со значениями по умолчанию
OPERATION="install" # install или add_site
WEB_SERVER="nginx"  # nginx, apache или nginx_apache_proxy
PHP_VERSION="8.2"
DATABASE="mariadb"
DB_VERSION=""
DOMAIN=""
SITE_DIR=""
ENABLE_SSL=false
ENABLE_SWAP=false
SWAP_SIZE=2G
CREATE_DB=false
DB_NAME=""
DB_USER=""
DB_PASS=""
OS_TYPE=""
PACKAGE_MANAGER=""
SERVICE_MANAGER=""
PHP_HANDLER="fpm" # fpm, fcgi или proxy
PANEL_TYPE=""


#=====================================================================
# Служебные функции
#=====================================================================

log() {
    local message="$1"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo -e "${timestamp} - ${message}" | tee -a "${LOG_FILE}"
}

log_success() {
    log "${GREEN}УСПЕШНО: $1${NC}"
}

log_info() {
    log "${BLUE}ИНФО: $1${NC}"
}

log_warning() {
    log "${YELLOW}ПРЕДУПРЕЖДЕНИЕ: $1${NC}"
}

log_error() {
    log "${RED}ОШИБКА: $1${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Этот скрипт должен быть запущен с правами root"
        exit 1
    fi
}

detect_os() {
    log_info "Определение операционной системы..."
    
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_NAME=$ID
        OS_VERSION=$VERSION_ID
        
        case $OS_NAME in
            ubuntu)
                OS_TYPE="debian"
                PACKAGE_MANAGER="apt"
                SERVICE_MANAGER="systemctl"
                log_success "Обнаружена Ubuntu $OS_VERSION"
                ;;
            debian)
                OS_TYPE="debian"
                PACKAGE_MANAGER="apt"
                SERVICE_MANAGER="systemctl"
                log_success "Обнаружена Debian $OS_VERSION"
                ;;
            centos|rhel|rocky|almalinux)
                OS_TYPE="rhel"
                PACKAGE_MANAGER="yum"
                SERVICE_MANAGER="systemctl"
                log_success "Обнаружена CentOS/RHEL-based система $OS_VERSION"
                ;;
            *)
                log_error "Неподдерживаемая операционная система: $OS_NAME"
                exit 1
                ;;
        esac
    else
        log_error "Не удалось определить операционную систему"
        exit 1
    fi
}

prompt_yes_no() {
    local prompt="$1"
    local default="$2"
    local answer
    
    if [[ "$default" == "y" ]]; then
        prompt="${prompt} [Y/n]"
    else
        prompt="${prompt} [y/N]"
    fi
    
    read -p "$prompt " answer
    
    if [[ -z "$answer" ]]; then
        answer="$default"
    fi
    
    if [[ ${answer,,} == "y" || ${answer,,} == "yes" ]]; then
        return 0 # true
    else
        return 1 # false
    fi
}

#=====================================================================
# Функции обнаружения установленного ПО
#=====================================================================

check_installed_webserver() {
    log_info "Проверка установленного веб-сервера..."
    
    local nginx_installed=false
    local apache_installed=false
    
    # Проверка Nginx
    if command -v nginx &> /dev/null || [[ -d /etc/nginx ]]; then
        nginx_installed=true
        log_info "Обнаружен установленный Nginx"
    fi
    
    # Проверка Apache
    if command -v apache2 &> /dev/null || command -v httpd &> /dev/null || [[ -d /etc/apache2 ]] || [[ -d /etc/httpd ]]; then
        apache_installed=true
        log_info "Обнаружен установленный Apache"
    fi
    
    # Определение текущей конфигурации
    if $nginx_installed && $apache_installed; then
        # Проверяем, используется ли Nginx как прокси для Apache
        if grep -q "proxy_pass" /etc/nginx/sites-enabled/* 2>/dev/null || grep -q "proxy_pass" /etc/nginx/conf.d/* 2>/dev/null; then
            log_info "Обнаружена конфигурация Nginx+Apache в режиме прокси"
            WEB_SERVER="nginx_apache_proxy"
        else
            log_info "Обнаружены оба веб-сервера, но не в конфигурации прокси"
            # Определяем, какой сервер активно используется (слушает порт 80)
            if netstat -tulpn | grep ":80" | grep -q nginx; then
                WEB_SERVER="nginx"
            elif netstat -tulpn | grep ":80" | grep -q apache2 || netstat -tulpn | grep ":80" | grep -q httpd; then
                WEB_SERVER="apache"
            else
                # По умолчанию выбираем Nginx, если оба установлены, но порт 80 не прослушивается
                WEB_SERVER="nginx"
            fi
        fi
    elif $nginx_installed; then
        WEB_SERVER="nginx"
    elif $apache_installed; then
        WEB_SERVER="apache"
    else
        WEB_SERVER="" # Не установлен ни один веб-сервер
    fi
    
    # Возвращаем статус наличия установленного веб-сервера
    if [[ -n "$WEB_SERVER" ]]; then
        return 0 # true - веб-сервер установлен
    else
        return 1 # false - веб-сервер не установлен
    fi
}

check_installed_php() {
    log_info "Проверка установленного PHP..."
    
    # Проверка наличия PHP и определение версии
    if command -v php &> /dev/null; then
        local php_detected_version=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
        PHP_VERSION=$php_detected_version
        log_info "Обнаружен установленный PHP версии $PHP_VERSION"
        
        # Определение типа обработчика PHP
        if systemctl is-active --quiet php${PHP_VERSION}-fpm || systemctl is-active --quiet php-fpm; then
            PHP_HANDLER="fpm"
            log_info "Обнаружен PHP-FPM"
        elif [[ -d /etc/php/${PHP_VERSION}/cgi ]] || [[ -d /etc/php/cgi ]]; then
            PHP_HANDLER="fcgi"
            log_info "Обнаружен PHP-FCGI"
        else
            PHP_HANDLER="mod_php"
            log_info "Обнаружен mod_php (Apache)"
        fi
        
        return 0 # true - PHP установлен
    else
        PHP_VERSION="8.2" # Значение по умолчанию, если PHP не установлен
        PHP_HANDLER="fpm" # Значение по умолчанию, если PHP не установлен
        return 1 # false - PHP не установлен
    fi
}

check_installed_database() {
    log_info "Проверка установленной базы данных..."
    
    local mysql_installed=false
    local mariadb_installed=false
    
    # Проверка MariaDB по наличию команды mariadb
    if command -v mariadb &> /dev/null; then
        mariadb_installed=true
        log_info "Обнаружен установленный MariaDB"
        
        # Определение версии с помощью команды mariadb
        DB_VERSION=$(mariadb --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 | cut -d. -f1,2)
        log_info "Версия MariaDB: $DB_VERSION"
        DATABASE="mariadb"
        
    # Проверка другими методами, если команда mariadb не найдена
    elif command -v mysql &> /dev/null; then
        # Проверяем, является ли mysql на самом деле MariaDB
        if mysql --version 2>/dev/null | grep -q MariaDB; then
            mariadb_installed=true
            log_info "Обнаружен установленный MariaDB (через команду mysql)"
            
            # Сохраняем вывод mysql --version в файл, чтобы не вызывать команду дважды
            mysql --version > /tmp/mysql_version 2>/dev/null
            DB_VERSION=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' /tmp/mysql_version | head -n 1 | cut -d. -f1,2)
            rm -f /tmp/mysql_version
            
            log_info "Версия MariaDB: $DB_VERSION"
            DATABASE="mariadb"
        else
            mysql_installed=true
            log_info "Обнаружен установленный MySQL"
            
            # Определение версии MySQL
            DB_VERSION=$(mysql --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 | cut -d. -f1,2)
            log_info "Версия MySQL: $DB_VERSION"
            DATABASE="mysql"
        fi
    else
        DATABASE="mariadb" # Значение по умолчанию, если база данных не установлена
        DB_VERSION="" # Значение по умолчанию, если база данных не установлена
    fi
    
    # Возвращаем статус наличия установленной базы данных
    if $mysql_installed || $mariadb_installed; then
        return 0 # true - база данных установлена
    else
        return 1 # false - база данных не установлена
    fi
}

detect_installed_panel() {
    log_info "Проверка установленных панелей управления..."
    
    # Проверка ISPManager
    if [ -d "/usr/local/mgr5" ] || [ -d "/usr/local/ispmgr" ] || [ -f "/usr/bin/ispmgr" ]; then
        log_info "Обнаружена панель управления: ISPManager"
        PANEL_TYPE="ispmanager"
        return 0
    fi
    
    # Проверка Hestia Control Panel
    if [ -d "/usr/local/hestia" ] || [ -d "/etc/hestiacp" ]; then
        log_info "Обнаружена панель управления: Hestia Control Panel"
        PANEL_TYPE="hestia"
        return 0
    fi
    
    # Проверка FastPanel
    if [ -d "/usr/local/fastpanel2" ] || [ -f "/usr/bin/fpctl" ]; then
        log_info "Обнаружена панель управления: FastPanel"
        PANEL_TYPE="fastpanel"
        return 0
    fi
    
    # Проверка aaPanel
    if [ -d "/www/server/panel" ] || [ -f "/etc/init.d/bt" ]; then
        log_info "Обнаружена панель управления: aaPanel"
        PANEL_TYPE="aapanel"
        return 0
    fi
    
    log_info "Панели управления не обнаружены"
    return 1
}

detect_installed_software() {
    log_info "Проверка установленного программного обеспечения..."
    
    local webserver_installed=false
    local php_installed=false
    local database_installed=false
    
    # Проверка компонентов
    check_installed_webserver && webserver_installed=true
    check_installed_php && php_installed=true
    check_installed_database && database_installed=true
    
    # Определение доступных операций
    if $webserver_installed && $php_installed && $database_installed; then
        log_info "Обнаружен полностью установленный стек"
        return 0 # true - стек установлен
    else
        log_info "Стек не установлен полностью"
        return 1 # false - стек не установлен полностью
    fi
}

#=====================================================================
# Функции установки компонентов
#=====================================================================

update_system() {
    # Запрос пользователя о типе обновления
    echo -e "${CYAN}=== Обновление системы ===${NC}"
    echo "1) Только обновить индексы пакетов (быстро, рекомендуется)"
    echo "2) Обновить только необходимые пакеты (средне)"
    echo "3) Полное обновление всей системы (долго)"
    echo "4) Пропустить обновление (не рекомендуется)"
    read -p "Выберите вариант обновления [1-4] (по умолчанию: 1): " choice
    
    case $choice in
        2)
            log_info "Обновление только необходимых пакетов..."
            if [[ "$OS_TYPE" == "debian" ]]; then
                apt update
                apt install -y --only-upgrade curl wget gnupg2 ca-certificates lsb-release software-properties-common apt-transport-https
            elif [[ "$OS_TYPE" == "rhel" ]]; then
                yum update -y curl wget gnupg2 ca-certificates epel-release
            fi
            ;;
        3)
            log_info "Полное обновление системных пакетов..."
            if [[ "$OS_TYPE" == "debian" ]]; then
                apt update && apt upgrade -y
            elif [[ "$OS_TYPE" == "rhel" ]]; then
                yum update -y
            fi
            ;;
        4)
            log_info "Обновление системы пропущено по запросу пользователя"
            return
            ;;
        *)
            # Вариант по умолчанию - только обновление индексов
            log_info "Обновление индексов пакетов..."
            if [[ "$OS_TYPE" == "debian" ]]; then
                apt update
            elif [[ "$OS_TYPE" == "rhel" ]]; then
                yum check-update
            fi
            ;;
    esac
    
    log_success "Обновление системы завершено"
}

install_dependencies() {
    log_info "Установка зависимостей..."
    
    if [[ "$OS_TYPE" == "debian" ]]; then
        apt install -y curl wget gnupg2 ca-certificates lsb-release software-properties-common apt-transport-https
    elif [[ "$OS_TYPE" == "rhel" ]]; then
        yum install -y curl wget gnupg2 ca-certificates epel-release
    fi
    
    log_success "Зависимости успешно установлены"
}

install_nginx() {
    log_info "Установка Nginx..."
    
    if [[ "$OS_TYPE" == "debian" ]]; then
        apt install -y nginx
    elif [[ "$OS_TYPE" == "rhel" ]]; then
        yum install -y nginx
    fi
    
    # Запуск и включение Nginx
    $SERVICE_MANAGER start nginx
    $SERVICE_MANAGER enable nginx
    
    log_success "Nginx успешно установлен и запущен"
}

install_apache() {
    log_info "Установка Apache..."
    
    # Подготавливаем конфигурацию перед установкой пакетов
    if [[ "$WEB_SERVER" == "nginx_apache_proxy" ]]; then
        # Создаем директории, если их ещё нет
        mkdir -p /etc/apache2/
        
        # Создаем ports.conf до установки пакета
        echo "Listen 127.0.0.1:8080" > /etc/apache2/ports.conf.new
    fi
    
    # Устанавливаем Apache
    if [[ "$OS_TYPE" == "debian" ]]; then
        apt install -y apache2
    elif [[ "$OS_TYPE" == "rhel" ]]; then
        yum install -y httpd
    fi
    
    # Настройка для режима прокси - сразу после установки
    if [[ "$WEB_SERVER" == "nginx_apache_proxy" ]]; then
        if [[ "$OS_TYPE" == "debian" ]]; then
            # Применяем изменения порта
            if [[ -f /etc/apache2/ports.conf.new ]]; then
                mv /etc/apache2/ports.conf.new /etc/apache2/ports.conf
            else
                # Если файл не создался заранее, редактируем существующий
                sed -i 's/Listen 80/Listen 127.0.0.1:8080/g' /etc/apache2/ports.conf
            fi
            
            # Перенастраиваем виртуальные хосты
            sed -i 's/VirtualHost \*:80/VirtualHost 127.0.0.1:8080/g' /etc/apache2/sites-available/000-default.conf
            
            # Перезапуск Apache с новыми настройками
            $SERVICE_MANAGER restart apache2
        elif [[ "$OS_TYPE" == "rhel" ]]; then
            # Перенастраиваем Apache на порт 8080
            sed -i 's/Listen 80/Listen 127.0.0.1:8080/g' /etc/httpd/conf/httpd.conf
            
            # Перезапуск Apache с новыми настройками
            $SERVICE_MANAGER restart httpd
        fi
    fi
    
    # Запуск и включение Apache (если не в режиме прокси)
    if [[ "$WEB_SERVER" != "nginx_apache_proxy" ]]; then
        if [[ "$OS_TYPE" == "debian" ]]; then
            $SERVICE_MANAGER restart apache2
            $SERVICE_MANAGER enable apache2
        elif [[ "$OS_TYPE" == "rhel" ]]; then
            $SERVICE_MANAGER restart httpd
            $SERVICE_MANAGER enable httpd
        fi
    fi
    
    log_success "Apache успешно установлен и запущен"
}

install_php() {
    log_info "Установка PHP ${PHP_VERSION}..."
    
    if [[ "$OS_TYPE" == "debian" ]]; then
        # Добавление PPA для PHP
        if ! grep -q "^deb .*ppa:ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d/*; then
            add-apt-repository -y ppa:ondrej/php
            apt update
        fi
        
        # Выбор пакетов в зависимости от обработчика PHP
        if [[ "$PHP_HANDLER" == "fpm" ]]; then
            # Установка PHP-FPM
            apt install -y php${PHP_VERSION} php${PHP_VERSION}-fpm php${PHP_VERSION}-common php${PHP_VERSION}-mysql \
                php${PHP_VERSION}-xml php${PHP_VERSION}-xmlrpc php${PHP_VERSION}-curl php${PHP_VERSION}-gd \
                php${PHP_VERSION}-imagick php${PHP_VERSION}-cli php${PHP_VERSION}-dev php${PHP_VERSION}-imap \
                php${PHP_VERSION}-mbstring php${PHP_VERSION}-opcache php${PHP_VERSION}-soap php${PHP_VERSION}-zip \
                php${PHP_VERSION}-intl
                
            # Запуск и включение PHP-FPM
            $SERVICE_MANAGER start php${PHP_VERSION}-fpm
            $SERVICE_MANAGER enable php${PHP_VERSION}-fpm
            
        elif [[ "$PHP_HANDLER" == "fcgi" ]]; then
            # Установка PHP-CGI
            apt install -y php${PHP_VERSION} php${PHP_VERSION}-cgi php${PHP_VERSION}-common php${PHP_VERSION}-mysql \
                php${PHP_VERSION}-xml php${PHP_VERSION}-xmlrpc php${PHP_VERSION}-curl php${PHP_VERSION}-gd \
                php${PHP_VERSION}-imagick php${PHP_VERSION}-cli php${PHP_VERSION}-dev php${PHP_VERSION}-imap \
                php${PHP_VERSION}-mbstring php${PHP_VERSION}-opcache php${PHP_VERSION}-soap php${PHP_VERSION}-zip \
                php${PHP_VERSION}-intl
                
        elif [[ "$PHP_HANDLER" == "mod_php" ]]; then
            # Установка модуля PHP для Apache
            apt install -y php${PHP_VERSION} libapache2-mod-php${PHP_VERSION} php${PHP_VERSION}-common php${PHP_VERSION}-mysql \
                php${PHP_VERSION}-xml php${PHP_VERSION}-xmlrpc php${PHP_VERSION}-curl php${PHP_VERSION}-gd \
                php${PHP_VERSION}-imagick php${PHP_VERSION}-cli php${PHP_VERSION}-dev php${PHP_VERSION}-imap \
                php${PHP_VERSION}-mbstring php${PHP_VERSION}-opcache php${PHP_VERSION}-soap php${PHP_VERSION}-zip \
                php${PHP_VERSION}-intl
                
            # Активация модуля PHP в Apache
            a2enmod php${PHP_VERSION}
            $SERVICE_MANAGER restart apache2
        fi
        
    elif [[ "$OS_TYPE" == "rhel" ]]; then
        # Добавление репозитория Remi для PHP
        yum install -y http://rpms.remirepo.net/enterprise/remi-release-$(rpm -E %rhel).rpm
        yum module reset php -y
        yum module enable php:remi-${PHP_VERSION} -y
        
        # Выбор пакетов в зависимости от обработчика PHP
        if [[ "$PHP_HANDLER" == "fpm" ]]; then
            # Установка PHP-FPM
            yum install -y php php-fpm php-common php-mysqlnd php-xml php-xmlrpc php-curl php-gd \
                php-imagick php-cli php-devel php-imap php-mbstring php-opcache php-soap php-zip php-intl
                
            # Запуск и включение PHP-FPM
            $SERVICE_MANAGER start php-fpm
            $SERVICE_MANAGER enable php-fpm
            
        elif [[ "$PHP_HANDLER" == "fcgi" ]]; then
            # Установка PHP-CGI
            yum install -y php php-common php-mysqlnd php-xml php-xmlrpc php-curl php-gd \
                php-imagick php-cli php-devel php-imap php-mbstring php-opcache php-soap php-zip php-intl
                
        elif [[ "$PHP_HANDLER" == "mod_php" ]]; then
            # Установка модуля PHP для Apache
            yum install -y php php-common php-mysqlnd php-xml php-xmlrpc php-curl php-gd \
                php-imagick php-cli php-devel php-imap php-mbstring php-opcache php-soap php-zip php-intl
                
            # Перезапуск Apache
            $SERVICE_MANAGER restart httpd
        fi
    fi
    
    log_success "PHP ${PHP_VERSION} успешно установлен с обработчиком ${PHP_HANDLER}"
}

install_mysql() {
    log_info "Установка MySQL..."
    
    if [[ "$OS_TYPE" == "debian" ]]; then
        # Добавление репозитория MySQL, если указана версия
        if [[ -n "$DB_VERSION" ]]; then
            # Скачивание конфигурационного пакета через https
            if ! wget https://dev.mysql.com/get/mysql-apt-config_0.8.24-1_all.deb; then
                log_warning "Не удалось скачать конфигурационный пакет MySQL. Будет использована версия из стандартного репозитория."
            else
                # Установка конфигурационного пакета
                DEBIAN_FRONTEND=noninteractive dpkg -i mysql-apt-config_0.8.24-1_all.deb
                rm -f mysql-apt-config_0.8.24-1_all.deb
                apt update
            fi
        fi
        
        # Предустановка параметров для MySQL
        # Устанавливаем пароль root заранее для неинтерактивной установки
        debconf-set-selections <<< "mysql-server mysql-server/root_password password $DB_PASS"
        debconf-set-selections <<< "mysql-server mysql-server/root_password_again password $DB_PASS"
        
        # Установка MySQL сервера
        apt install -y mysql-server mysql-client
        
    elif [[ "$OS_TYPE" == "rhel" ]]; then
        # Добавление репозитория MySQL, если указана версия
        if [[ -n "$DB_VERSION" ]]; then
            # Проверяем, существует ли уже репозиторий
            if ! rpm -q mysql80-community-release; then
                # Скачиваем и устанавливаем репозиторий
                if [[ -f /etc/redhat-release ]]; then
                    RHEL_VERSION=$(rpm -E %rhel)
                    if ! rpm -Uvh https://repo.mysql.com/mysql80-community-release-el${RHEL_VERSION}-1.noarch.rpm; then
                        log_warning "Не удалось добавить репозиторий MySQL. Попытка использования стандартного репозитория."
                    else
                        # Отключаем модуль MySQL, чтобы избежать конфликтов
                        yum module disable mysql -y
                    fi
                fi
            fi
        fi
        
        # Установка MySQL сервера
        yum install -y mysql-server mysql || yum install -y community-mysql-server community-mysql
    fi
    
    # Запуск и включение MySQL
    $SERVICE_MANAGER start mysql || $SERVICE_MANAGER start mysqld
    $SERVICE_MANAGER enable mysql || $SERVICE_MANAGER enable mysqld
    
    log_success "MySQL успешно установлен"
}

install_mariadb() {
    log_info "Установка MariaDB..."
    
    if [[ "$OS_TYPE" == "debian" ]]; then
        # Добавление репозитория MariaDB, если указана версия
        if [[ -n "$DB_VERSION" ]]; then
            # Добавляем ключи для репозитория MariaDB
            apt-key adv --fetch-keys 'https://mariadb.org/mariadb_release_signing_key.asc'
            
            # Добавляем репозиторий вручную
            if [[ -f /etc/lsb-release ]]; then
                # Ubuntu
                . /etc/lsb-release
                echo "deb [arch=amd64] https://mirror.mva-n.net/mariadb/repo/${DB_VERSION}/ubuntu ${DISTRIB_CODENAME} main" > /etc/apt/sources.list.d/mariadb.list
            else
                # Debian
                . /etc/os-release
                echo "deb [arch=amd64] https://mirror.mva-n.net/mariadb/repo/${DB_VERSION}/debian ${VERSION_CODENAME} main" > /etc/apt/sources.list.d/mariadb.list
            fi
            
            # Обновляем индекс пакетов
            apt update
        fi
        
        # Установка MariaDB сервера
        apt install -y mariadb-server
        
    elif [[ "$OS_TYPE" == "rhel" ]]; then
        # Добавление репозитория MariaDB, если указана версия
        if [[ -n "$DB_VERSION" ]]; then
            # Создаем конфигурацию репозитория вручную
            cat > /etc/yum.repos.d/MariaDB.repo << EOF
[mariadb]
name = MariaDB
baseurl = https://mirror.mva-n.net/mariadb/yum/${DB_VERSION}/rhel\$releasever-amd64
gpgkey=https://mirror.mva-n.net/mariadb/yum/RPM-GPG-KEY-MariaDB
gpgcheck=1
EOF
        fi
        
        # Установка MariaDB сервера
        yum install -y MariaDB-server MariaDB-client || yum install -y mariadb-server mariadb
    fi
    
    # Запуск и включение MariaDB
    $SERVICE_MANAGER start mariadb || $SERVICE_MANAGER start mysql
    $SERVICE_MANAGER enable mariadb || $SERVICE_MANAGER enable mysql
    
    log_success "MariaDB успешно установлен"
}

# Настройка Nginx в качестве прокси для Apache
configure_nginx_apache_proxy() {
    log_info "Настройка Nginx в качестве прокси для Apache..."
    
    # Проверка, установлены ли Nginx и Apache
    if ! command -v nginx &> /dev/null; then
        log_error "Nginx не установлен. Невозможно настроить прокси."
        return 1
    fi
    
    if ! command -v apache2 &> /dev/null && ! command -v httpd &> /dev/null; then
        log_error "Apache не установлен. Невозможно настроить прокси."
        return 1
    fi
    
    # Настройка Apache для прослушивания на локальном порту 8080
    if [[ "$OS_TYPE" == "debian" ]]; then
        # Изменение порта в Apache
        sed -i 's/Listen 80/Listen 127.0.0.1:8080/g' /etc/apache2/ports.conf
        
        # Перезапуск Apache
        $SERVICE_MANAGER restart apache2
    elif [[ "$OS_TYPE" == "rhel" ]]; then
        # Изменение порта в Apache
        sed -i 's/Listen 80/Listen 127.0.0.1:8080/g' /etc/httpd/conf/httpd.conf
        
        # Перезапуск Apache
        $SERVICE_MANAGER restart httpd
    fi
    
    # Настройка Nginx для проксирования запросов в Apache
    if [[ "$OS_TYPE" == "debian" ]]; then
        cat > /etc/nginx/conf.d/proxy.conf << EOF
# Настройки проксирования для Apache
proxy_connect_timeout 60s;
proxy_send_timeout 60s;
proxy_read_timeout 60s;
proxy_buffering on;
proxy_buffer_size 8k;
proxy_buffers 8 8k;
EOF
    elif [[ "$OS_TYPE" == "rhel" ]]; then
        cat > /etc/nginx/conf.d/proxy.conf << EOF
# Настройки проксирования для Apache
proxy_connect_timeout 60s;
proxy_send_timeout 60s;
proxy_read_timeout 60s;
proxy_buffering on;
proxy_buffer_size 8k;
proxy_buffers 8 8k;
EOF
    fi
    
    # Перезапуск Nginx
    $SERVICE_MANAGER restart nginx
    
    log_success "Nginx настроен в качестве прокси для Apache"
}

configure_database() {
    log_info "Настройка базы данных..."
    
    local db_cmd
    if [[ "$DATABASE" == "mysql" ]]; then
        db_cmd="mysql"
    else
        db_cmd="mariadb"
    fi
    
    # Безопасная установка
    if [[ "$DATABASE" == "mysql" ]]; then
        # Для MySQL
        mysql_secure_installation <<EOF

y
$DB_PASS
$DB_PASS
y
y
y
y
EOF
    else
        # Для MariaDB
        mysql_secure_installation <<EOF

y
$DB_PASS
$DB_PASS
y
y
y
y
EOF
    fi
    
    # Создание базы данных и пользователя, если запрошено
    if [[ "$CREATE_DB" == true ]]; then
        log_info "Создание базы данных $DB_NAME и пользователя $DB_USER..."
        
        $db_cmd -u root -p"$DB_PASS" <<EOF
CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF
        
        log_success "База данных и пользователь успешно созданы"
    fi
}

configure_nginx() {
    log_info "Настройка Nginx для ${DOMAIN}..."
    
    # Резервное копирование конфигурации по умолчанию
    if [[ -f /etc/nginx/sites-available/default ]]; then
        cp /etc/nginx/sites-available/default /etc/nginx/sites-available/default.bak
    fi
    
    # Создание конфигурации сайта
    if [[ "$WEB_SERVER" == "nginx" ]]; then
        # Стандартная конфигурация Nginx с PHP-FPM
        cat > /etc/nginx/sites-available/$DOMAIN.conf << EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};
    root ${SITE_DIR};
    
    index index.php index.html index.htm;
    
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    
    # Конфигурация PHP-FPM
    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/var/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        
        # Оптимизация
        fastcgi_buffer_size 16k;
        fastcgi_buffers 16 16k;
    }
    
    # Заголовки безопасности
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'; frame-ancestors 'self';" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), interest-cohort=()" always;
    
    # Запрет доступа к скрытым файлам
    location ~ /\.(?!well-known) {
        deny all;
    }
    
    # Включение сжатия gzip
    gzip on;
    gzip_vary on;
    gzip_min_length 1000;
    gzip_proxied any;
    gzip_types text/plain text/css text/xml application/json application/javascript application/rss+xml application/atom+xml image/svg+xml;
    
    # Настройки кеширования
    location ~* \.(jpg|jpeg|png|gif|ico|css|js)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }
    
    # Настройки логирования
    access_log /var/log/nginx/${DOMAIN}_access.log;
    error_log /var/log/nginx/${DOMAIN}_error.log;
}
EOF
    elif [[ "$WEB_SERVER" == "nginx_apache_proxy" ]]; then
        # Конфигурация Nginx как прокси для Apache
        cat > /etc/nginx/sites-available/$DOMAIN.conf << EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};
    
    access_log /var/log/nginx/${DOMAIN}_access.log;
    error_log /var/log/nginx/${DOMAIN}_error.log;
    
    # Статические файлы обслуживаются Nginx для повышения производительности
    location ~* \.(jpg|jpeg|gif|png|css|js|ico|xml)$ {
        root ${SITE_DIR};
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }
    
    # Запрет доступа к скрытым файлам
    location ~ /\.(?!well-known) {
        deny all;
    }
    
    # Все остальные запросы проксируются в Apache
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # Настройки проксирования
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        
        # Буферизация для повышения производительности
        proxy_buffering on;
        proxy_buffer_size 16k;
        proxy_buffers 16 16k;
    }
    
    # Заголовки безопасности
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'; frame-ancestors 'self';" always;
    
    # Включение сжатия gzip
    gzip on;
    gzip_vary on;
    gzip_min_length 1000;
    gzip_proxied any;
    gzip_types text/plain text/css text/xml application/json application/javascript application/rss+xml application/atom+xml image/svg+xml;
}
EOF
    fi
    
    # Создание символической ссылки для активации сайта
    if [[ -d /etc/nginx/sites-enabled ]]; then
        ln -sf /etc/nginx/sites-available/$DOMAIN.conf /etc/nginx/sites-enabled/
        
        # Удаление сайта по умолчанию, если он существует
        if [[ -f /etc/nginx/sites-enabled/default ]]; then
            rm -f /etc/nginx/sites-enabled/default
        fi
    elif [[ -d /etc/nginx/conf.d ]]; then
        # Для систем без sites-enabled (например, CentOS)
        ln -sf /etc/nginx/sites-available/$DOMAIN.conf /etc/nginx/conf.d/$DOMAIN.conf
    fi
    
    # Создание директории сайта, если она не существует
    mkdir -p ${SITE_DIR}
    
    # Создание простого тестового файла
    cat > ${SITE_DIR}/index.php << EOF
<?php
    echo '<h1>Добро пожаловать на ${DOMAIN}!</h1>';
    echo '<p>Версия PHP: ' . phpversion() . '</p>';
    echo '<h2>Установленные модули PHP:</h2>';
    echo '<pre>';
    print_r(get_loaded_extensions());
    echo '</pre>';
?>
EOF
    
    # Установка правильных прав доступа
    chown -R www-data:www-data ${SITE_DIR} || chown -R nginx:nginx ${SITE_DIR}
    
    # Проверка конфигурации Nginx
    nginx -t
    
    # Перезагрузка Nginx
    $SERVICE_MANAGER reload nginx
    
    log_success "Nginx успешно настроен для ${DOMAIN}"
}

configure_apache() {
    log_info "Настройка Apache для ${DOMAIN}..."
    
    # Создание конфигурации сайта
    if [[ "$OS_TYPE" == "debian" ]]; then
        conf_file="/etc/apache2/sites-available/$DOMAIN.conf"
        
        if [[ "$WEB_SERVER" == "apache" ]]; then
            # Стандартная конфигурация Apache
            cat > $conf_file << EOF
<VirtualHost *:80>
    ServerName ${DOMAIN}
    ServerAlias www.${DOMAIN}
    DocumentRoot ${SITE_DIR}
    
    <Directory ${SITE_DIR}>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
EOF

            if [[ "$PHP_HANDLER" == "fpm" ]]; then
                # Конфигурация для PHP-FPM
                cat >> $conf_file << EOF
    
    # PHP-FPM Configuration
    <FilesMatch \.php$>
        SetHandler "proxy:unix:/var/run/php/php${PHP_VERSION}-fpm.sock|fcgi://localhost"
    </FilesMatch>
EOF
            fi

            cat >> $conf_file << EOF
    
    # Заголовки безопасности
    Header set X-Frame-Options "SAMEORIGIN"
    Header set X-XSS-Protection "1; mode=block"
    Header set X-Content-Type-Options "nosniff"
    Header set Referrer-Policy "no-referrer-when-downgrade"
    Header set Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'; frame-ancestors 'self';"
    
    # Включение сжатия gzip
    <IfModule mod_deflate.c>
        AddOutputFilterByType DEFLATE text/html text/plain text/xml text/css application/javascript application/json
    </IfModule>
    
    # Настройки кеширования
    <IfModule mod_expires.c>
        ExpiresActive On
        ExpiresByType image/jpg "access plus 1 month"
        ExpiresByType image/jpeg "access plus 1 month"
        ExpiresByType image/gif "access plus 1 month"
        ExpiresByType image/png "access plus 1 month"
        ExpiresByType text/css "access plus 1 week"
        ExpiresByType application/javascript "access plus 1 week"
    </IfModule>
    
    # Настройки логирования
    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}_error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}_access.log combined
</VirtualHost>
EOF
        elif [[ "$WEB_SERVER" == "nginx_apache_proxy" ]]; then
            # Конфигурация Apache за Nginx прокси
            cat > $conf_file << EOF
<VirtualHost 127.0.0.1:8080>
    ServerName ${DOMAIN}
    ServerAlias www.${DOMAIN}
    DocumentRoot ${SITE_DIR}
    
    <Directory ${SITE_DIR}>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
EOF

            if [[ "$PHP_HANDLER" == "fpm" ]]; then
                # Конфигурация для PHP-FPM
                cat >> $conf_file << EOF
    
    # PHP-FPM Configuration
    <FilesMatch \.php$>
        SetHandler "proxy:unix:/var/run/php/php${PHP_VERSION}-fpm.sock|fcgi://localhost"
    </FilesMatch>
EOF
            fi

            cat >> $conf_file << EOF
    
    # Настройки для прокси
    UseCanonicalName Off
    
    # Настройки логирования
    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}_error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}_access.log combined
    
    # Запись заголовков X-Forwarded в логи
    LogFormat "%{X-Forwarded-For}i %l %u %t \"%r\" %>s %b \"%{Referer}i\" \"%{User-agent}i\"" proxy
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}_proxy.log proxy
</VirtualHost>
EOF
        fi
        
        # Включение необходимых модулей
        a2enmod rewrite headers expires deflate
        if [[ "$PHP_HANDLER" == "fpm" ]]; then
            a2enmod proxy_fcgi
        fi
        
        # Включение сайта и отключение сайта по умолчанию
        a2ensite $DOMAIN.conf
        a2dissite 000-default.conf
        
    elif [[ "$OS_TYPE" == "rhel" ]]; then
        if [[ "$WEB_SERVER" == "apache" ]]; then
            conf_file="/etc/httpd/conf.d/$DOMAIN.conf"
            
            cat > $conf_file << EOF
<VirtualHost *:80>
    ServerName ${DOMAIN}
    ServerAlias www.${DOMAIN}
    DocumentRoot ${SITE_DIR}
    
    <Directory ${SITE_DIR}>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
EOF

            if [[ "$PHP_HANDLER" == "fpm" ]]; then
                # Конфигурация для PHP-FPM
                cat >> $conf_file << EOF
    
    # PHP-FPM Configuration
    <FilesMatch \.php$>
        SetHandler "proxy:fcgi://127.0.0.1:9000"
    </FilesMatch>
EOF
            fi

            cat >> $conf_file << EOF
    
    # Заголовки безопасности
    Header set X-Frame-Options "SAMEORIGIN"
    Header set X-XSS-Protection "1; mode=block"
    Header set X-Content-Type-Options "nosniff"
    Header set Referrer-Policy "no-referrer-when-downgrade"
    Header set Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'; frame-ancestors 'self';"
    
    # Включение сжатия gzip
    <IfModule mod_deflate.c>
        AddOutputFilterByType DEFLATE text/html text/plain text/xml text/css application/javascript application/json
    </IfModule>
    
    # Настройки кеширования
    <IfModule mod_expires.c>
        ExpiresActive On
        ExpiresByType image/jpg "access plus 1 month"
        ExpiresByType image/jpeg "access plus 1 month"
        ExpiresByType image/gif "access plus 1 month"
        ExpiresByType image/png "access plus 1 month"
        ExpiresByType text/css "access plus 1 week"
        ExpiresByType application/javascript "access plus 1 week"
    </IfModule>
    
    # Настройки логирования
    ErrorLog /var/log/httpd/${DOMAIN}_error.log
    CustomLog /var/log/httpd/${DOMAIN}_access.log combined
</VirtualHost>
EOF
        elif [[ "$WEB_SERVER" == "nginx_apache_proxy" ]]; then
            conf_file="/etc/httpd/conf.d/$DOMAIN.conf"
            
            cat > $conf_file << EOF
<VirtualHost 127.0.0.1:8080>
    ServerName ${DOMAIN}
    ServerAlias www.${DOMAIN}
    DocumentRoot ${SITE_DIR}
    
    <Directory ${SITE_DIR}>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
EOF

            if [[ "$PHP_HANDLER" == "fpm" ]]; then
                # Конфигурация для PHP-FPM
                cat >> $conf_file << EOF
    
    # PHP-FPM Configuration
    <FilesMatch \.php$>
        SetHandler "proxy:fcgi://127.0.0.1:9000"
    </FilesMatch>
EOF
            fi

            cat >> $conf_file << EOF
    
    # Настройки для прокси
    UseCanonicalName Off
    
    # Настройки логирования
    ErrorLog /var/log/httpd/${DOMAIN}_error.log
    CustomLog /var/log/httpd/${DOMAIN}_access.log combined
    
    # Запись заголовков X-Forwarded в логи
    LogFormat "%{X-Forwarded-For}i %l %u %t \"%r\" %>s %b \"%{Referer}i\" \"%{User-agent}i\"" proxy
    CustomLog /var/log/httpd/${DOMAIN}_proxy.log proxy
</VirtualHost>
EOF
        fi
        
        # Включение необходимых модулей
        for mod in rewrite headers expires deflate proxy_fcgi; do
            if ! grep -q "LoadModule ${mod}_module" /etc/httpd/conf.modules.d/*.conf; then
                echo "LoadModule ${mod}_module modules/mod_${mod}.so" >> /etc/httpd/conf.modules.d/00-base.conf
            fi
        done
    fi
    
    # Создание директории сайта, если она не существует
    mkdir -p ${SITE_DIR}
    
    # Создание простого тестового файла
    cat > ${SITE_DIR}/index.php << EOF
<?php
    echo '<h1>Добро пожаловать на ${DOMAIN}!</h1>';
    echo '<p>Версия PHP: ' . phpversion() . '</p>';
    echo '<h2>Установленные модули PHP:</h2>';
    echo '<pre>';
    print_r(get_loaded_extensions());
    echo '</pre>';
?>
EOF
    
    # Установка правильных прав доступа
    if [[ "$OS_TYPE" == "debian" ]]; then
        chown -R www-data:www-data ${SITE_DIR}
    elif [[ "$OS_TYPE" == "rhel" ]]; then
        chown -R apache:apache ${SITE_DIR}
    fi
    
    # Перезапуск Apache
    if [[ "$OS_TYPE" == "debian" ]]; then
        $SERVICE_MANAGER restart apache2
    elif [[ "$OS_TYPE" == "rhel" ]]; then
        $SERVICE_MANAGER restart httpd
    fi
    
    log_success "Apache успешно настроен для ${DOMAIN}"
}

configure_php() {
    log_info "Оптимизация конфигурации PHP..."
    
    local php_ini
    if [[ "$OS_TYPE" == "debian" ]]; then
        if [[ "$PHP_HANDLER" == "fpm" ]]; then
            php_ini="/etc/php/${PHP_VERSION}/fpm/php.ini"
        elif [[ "$PHP_HANDLER" == "fcgi" ]]; then
            php_ini="/etc/php/${PHP_VERSION}/cgi/php.ini"
        else
            php_ini="/etc/php/${PHP_VERSION}/apache2/php.ini"
        fi
    elif [[ "$OS_TYPE" == "rhel" ]]; then
        php_ini="/etc/php.ini"
    fi
    
    # Резервное копирование оригинального php.ini
    cp $php_ini ${php_ini}.bak
    
    # Обновление настроек PHP для лучшей производительности
    sed -i 's/memory_limit = .*/memory_limit = 256M/' $php_ini
    sed -i 's/upload_max_filesize = .*/upload_max_filesize = 64M/' $php_ini
    sed -i 's/post_max_size = .*/post_max_size = 64M/' $php_ini
    sed -i 's/max_execution_time = .*/max_execution_time = 300/' $php_ini
    sed -i 's/max_input_time = .*/max_input_time = 300/' $php_ini
    sed -i 's/;opcache.enable=.*/opcache.enable=1/' $php_ini
    sed -i 's/;opcache.memory_consumption=.*/opcache.memory_consumption=128/' $php_ini
    sed -i 's/;opcache.interned_strings_buffer=.*/opcache.interned_strings_buffer=8/' $php_ini
    sed -i 's/;opcache.max_accelerated_files=.*/opcache.max_accelerated_files=10000/' $php_ini
    sed -i 's/;opcache.revalidate_freq=.*/opcache.revalidate_freq=60/' $php_ini
    sed -i 's/;opcache.fast_shutdown=.*/opcache.fast_shutdown=1/' $php_ini
    
    # Настройка PHP-FPM для лучшей производительности (если используется)
    if [[ "$PHP_HANDLER" == "fpm" ]]; then
        local fpm_conf
        if [[ "$OS_TYPE" == "debian" ]]; then
            fpm_conf="/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"
        elif [[ "$OS_TYPE" == "rhel" ]]; then
            fpm_conf="/etc/php-fpm.d/www.conf"
        fi
        
        # Резервное копирование оригинальной конфигурации
        cp $fpm_conf ${fpm_conf}.bak
        
        # Оптимизация PHP-FPM
        sed -i 's/^pm = .*/pm = dynamic/' $fpm_conf
        sed -i 's/^pm.max_children = .*/pm.max_children = 50/' $fpm_conf
        sed -i 's/^pm.start_servers = .*/pm.start_servers = 5/' $fpm_conf
        sed -i 's/^pm.min_spare_servers = .*/pm.min_spare_servers = 5/' $fpm_conf
        sed -i 's/^pm.max_spare_servers = .*/pm.max_spare_servers = 35/' $fpm_conf
        sed -i 's/^;pm.max_requests = .*/pm.max_requests = 500/' $fpm_conf
        
        # Перезапуск PHP-FPM
        if [[ "$OS_TYPE" == "debian" ]]; then
            $SERVICE_MANAGER restart php${PHP_VERSION}-fpm
        elif [[ "$OS_TYPE" == "rhel" ]]; then
            $SERVICE_MANAGER restart php-fpm
        fi
    elif [[ "$PHP_HANDLER" == "mod_php" ]]; then
        # Перезапуск Apache для применения изменений в php.ini
        if [[ "$OS_TYPE" == "debian" ]]; then
            $SERVICE_MANAGER restart apache2
        elif [[ "$OS_TYPE" == "rhel" ]]; then
            $SERVICE_MANAGER restart httpd
        fi
    fi
    
    log_success "PHP успешно оптимизирован"
}

configure_mysql_performance() {
    log_info "Оптимизация производительности MySQL/MariaDB..."
    
    local my_cnf
    if [[ "$DATABASE" == "mysql" ]]; then
        if [[ "$OS_TYPE" == "debian" ]]; then
            my_cnf="/etc/mysql/mysql.conf.d/mysqld.cnf"
        elif [[ "$OS_TYPE" == "rhel" ]]; then
            my_cnf="/etc/my.cnf"
        fi
    else
        if [[ "$OS_TYPE" == "debian" ]]; then
            my_cnf="/etc/mysql/mariadb.conf.d/50-server.cnf"
        elif [[ "$OS_TYPE" == "rhel" ]]; then
            my_cnf="/etc/my.cnf.d/server.cnf"
        fi
    fi
    
    # Резервное копирование оригинальной конфигурации
    cp $my_cnf ${my_cnf}.bak
    
    # Получение объема системной памяти
    local mem_total=$(free -m | grep Mem | awk '{print $2}')
    local innodb_buffer_pool_size=$(($mem_total/2))
    
    # Добавление настроек оптимизации
    cat >> $my_cnf << EOF

# Оптимизации производительности
innodb_buffer_pool_size = ${innodb_buffer_pool_size}M
innodb_log_file_size = 64M
innodb_flush_method = O_DIRECT
innodb_flush_log_at_trx_commit = 2
query_cache_type = 1
query_cache_size = 64M
query_cache_limit = 2M
max_connections = 500
EOF
    
    # Перезапуск службы базы данных
    if [[ "$DATABASE" == "mysql" ]]; then
        $SERVICE_MANAGER restart mysql || $SERVICE_MANAGER restart mysqld
    else
        $SERVICE_MANAGER restart mariadb || $SERVICE_MANAGER restart mysql
    fi
    
    log_success "Производительность базы данных оптимизирована"
}

#=====================================================================
# Функции для управления панелями
#=====================================================================

prompt_main_selection() {
    echo -e "${CYAN}=== Выбор типа установки ===${NC}"
    echo "1) Установить LEMP/LAMP стек"
    echo "2) Установить панель управления сервером"
    read -p "Выберите тип установки [1-2] (по умолчанию: 1): " choice
    
    case $choice in
        2)
            OPERATION="install_panel"
            log_info "Выбрано: Установка панели управления"
            ;;
        *)
            OPERATION="install_stack"
            log_info "Выбрано: Установка LEMP/LAMP стека"
            ;;
    esac
}

prompt_panel_selection() {
    echo -e "${CYAN}=== Выбор панели управления ===${NC}"
    echo "1) ISPManager"
    echo "2) Hestia Control Panel"
    echo "3) FastPanel"
    echo "4) aaPanel"
    read -p "Выберите панель управления [1-4] (по умолчанию: 1): " choice
    
    case $choice in
        2)
            PANEL_TYPE="hestia"
            log_info "Выбрана панель: Hestia Control Panel"
            ;;
        3)
            PANEL_TYPE="fastpanel"
            log_info "Выбрана панель: FastPanel"
            ;;
        4)
            PANEL_TYPE="aapanel"
            log_info "Выбрана панель: aaPanel"
            ;;
        *)
            PANEL_TYPE="ispmanager"
            log_info "Выбрана панель: ISPManager"
            ;;
    esac
}

install_panel() {
    log_info "Установка панели управления ${PANEL_TYPE}..."
    
    case $PANEL_TYPE in
        "ispmanager")
            install_ispmanager
            ;;
        "hestia")
            install_hestia
            ;;
        "fastpanel")
            install_fastpanel
            ;;
        "aapanel")
            install_aapanel
            ;;
    esac
    
    log_success "Панель управления ${PANEL_TYPE} успешно установлена"
}

install_ispmanager() {
    log_info "Установка ISPManager..."
    
    # Обновление системы
    update_system
    
    # Установка зависимостей
    install_dependencies
    
    # Удаление старых версий файла установщика, если они существуют
    rm -f install.sh install.sh.* 2>/dev/null || true
    
    # Скачивание установщика ISPManager
    if ! wget -O install.sh https://download.ispmanager.com/install.sh; then
        log_error "Не удалось скачать установщик ISPManager. Проверьте соединение с интернетом."
        return 1
    fi
    
    # Проверка, что файл успешно загружен и имеет минимальный размер
    if [ ! -s install.sh ] || [ $(stat -c%s install.sh) -lt 1000 ]; then
        log_error "Скачанный файл установщика ISPManager слишком мал или пуст."
        rm -f install.sh
        return 1
    fi
    
    # Установка прав на выполнение
    chmod +x install.sh
    
    # Запрос лицензионного ключа
    read -p "Введите лицензионный ключ для ISPManager (оставьте пустым для триальной версии): " license_key
    
    # Запуск установки в интерактивном режиме
    log_info "Запуск установщика ISPManager в интерактивном режиме..."
    
    if [[ -n "$license_key" ]]; then
        # Запуск с ключом
        ./install.sh --key "$license_key"
    else
        # Запуск без ключа (триальная версия)
        ./install.sh
    fi
    
    # Проверка результата установки
    if [ -d "/usr/local/mgr5" ] || grep -q "Your newly installed ispmanager panel" "$INSTALL_LOG"; then
        log_success "ISPManager успешно установлен"
        
        # Вывод информации о доступе
        echo -e "${GREEN}=================================================${NC}"
        echo -e "${GREEN}ISPManager успешно установлен!${NC}"
        echo -e "${GREEN}=================================================${NC}"
        echo "Доступ к панели управления: https://$(hostname -f):1500/"
        echo "Логин: admin"
        echo "Пароль: admin (если не было указано иное в процессе установки)"
        echo "Рекомендуется изменить пароль после первого входа!"
        echo -e "${GREEN}=================================================${NC}"
        
        # Очистка
        rm -f install.sh
        
        return 0
    else
        log_error "Установка ISPManager не удалась. Файлы установки не обнаружены."
        rm -f install.sh
        return 1
    fi
}


install_hestia() {
    log_info "Установка Hestia Control Panel..."
    
    # Обновление системы
    update_system
    
    # Установка зависимостей
    install_dependencies
    
    # Скачивание и запуск установщика Hestia
    wget https://raw.githubusercontent.com/hestiacp/hestiacp/release/install/hst-install.sh
    chmod +x hst-install.sh
    
    # Запрос параметров установки
    read -p "Введите email администратора: " admin_email
    if [[ -z "$admin_email" ]]; then
        admin_email="admin@$(hostname -f)"
    fi
    
    # Запуск установки в автоматическом режиме
    ./hst-install.sh --email "$admin_email" --password $(openssl rand -base64 8) --multiphp yes
    
    # Очистка
    rm -f hst-install.sh
    
    log_success "Hestia Control Panel успешно установлен"
    
    # Вывод информации о доступе
    echo -e "${GREEN}=================================================${NC}"
    echo -e "${GREEN}Hestia Control Panel успешно установлен!${NC}"
    echo -e "${GREEN}=================================================${NC}"
    echo "Доступ к панели управления: https://$(hostname -f):8083/"
    echo "Логин: admin"
    echo "Пароль: Был сгенерирован во время установки, проверьте вывод выше."
    echo -e "${GREEN}=================================================${NC}"
}

install_fastpanel() {
    log_info "Установка FastPanel..."
    
    # Проверка наличия MySQL/MariaDB
    if check_installed_database || check_installed_webserver || check_installed_php; then
        log_warning "На сервере обнаружены установленные компоненты. FastPanel требует чистую установку ОС."
        
        # Предлагаем удалить все компоненты
        if prompt_yes_no "Хотите автоматически удалить все компоненты перед установкой FastPanel? (рекомендуется)" "y"; then
            log_info "Удаление всех компонентов перед установкой FastPanel..."
            
            # Временно отключаем строгий режим для предотвращения аварийного завершения
            set +e
            
            # Принудительное удаление проблемного пакета exim4
            if [[ "$OS_TYPE" == "debian" ]]; then
                log_info "Удаление пакета exim4..."
                dpkg --purge --force-all exim4-daemon-light exim4-config exim4-base exim4 2>/dev/null || true
            fi
            
            # Останавливаем сервисы с таймаутом
            log_info "Останавливаем сервисы..."
            for svc in mysql mariadb nginx apache2 httpd php*-fpm php-fpm; do
                log_info "Останавливаем $svc..."
                timeout 10 $SERVICE_MANAGER stop $svc 2>/dev/null || true
            done
            
            # Удаление компонентов в зависимости от типа ОС
            if [[ "$OS_TYPE" == "debian" ]]; then
                # Удаление репозиториев
                log_info "Удаление репозиториев..."
                find /etc/apt/sources.list.d/ -name "mariadb*" -o -name "mysql*" -o -name "nginx*" -o -name "php*" -delete 2>/dev/null || true
                
                # Установка неинтерактивного режима
                export DEBIAN_FRONTEND=noninteractive
                
                # Принудительное удаление пакетов
                log_info "Удаление пакетов базы данных..."
                timeout 120 apt-get purge -y --force-yes mysql* mariadb* 2>/dev/null || true
                
                log_info "Удаление веб-серверов..."
                timeout 120 apt-get purge -y --force-yes nginx* apache2* 2>/dev/null || true
                
                log_info "Удаление PHP..."
                timeout 120 apt-get purge -y --force-yes php* 2>/dev/null || true
                
                log_info "Удаление других компонентов..."
                timeout 120 apt-get purge -y --force-yes exim4* 2>/dev/null || true
                
                # Очистка системы
                log_info "Очистка системы..."
                timeout 60 apt-get autoremove -y --force-yes 2>/dev/null || true
                timeout 30 apt-get clean 2>/dev/null || true
                
                # Исправление возможных проблем с dpkg
                log_info "Исправление проблем с пакетной системой..."
                timeout 60 dpkg --configure -a 2>/dev/null || true
                timeout 60 apt-get -f install -y 2>/dev/null || true
                
                # Удаление конфигурационных директорий и логов
                log_info "Удаление конфигурационных директорий..."
                find /etc/mysql /var/lib/mysql /etc/mariadb /var/lib/mariadb /etc/nginx /etc/apache2 /etc/php* /var/log/mysql* /var/log/mariadb* /var/log/nginx* /var/log/apache2* /var/log/php* -maxdepth 0 -exec rm -rf {} \; 2>/dev/null || true
                
            elif [[ "$OS_TYPE" == "rhel" ]]; then
                # Аналогичная логика для RHEL-систем
                log_info "Удаление репозиториев..."
                find /etc/yum.repos.d/ -name "mariadb*" -o -name "mysql*" -o -name "nginx*" -delete 2>/dev/null || true
                
                # Удаление пакетов
                log_info "Удаление компонентов..."
                timeout 120 yum remove -y mysql* mariadb* nginx* httpd* php* 2>/dev/null || true
                timeout 60 yum autoremove -y 2>/dev/null || true
                timeout 30 yum clean all 2>/dev/null || true
                
                # Удаление конфигурационных директорий и логов
                log_info "Удаление конфигурационных директорий..."
                find /etc/my.cnf* /var/lib/mysql /etc/nginx /etc/httpd /etc/php* /var/log/mysql* /var/log/mariadb* /var/log/nginx* /var/log/httpd* /var/log/php* -maxdepth 0 -exec rm -rf {} \; 2>/dev/null || true
            fi
            
            # Возвращаем строгий режим
            set -e
            
            log_success "Компоненты, мешающие установке FastPanel, успешно удалены"
        else
            log_warning "Установка FastPanel на систему с предустановленными компонентами может не сработать"
            if ! prompt_yes_no "Всё равно продолжить установку?" "n"; then
                log_error "Установка FastPanel отменена пользователем"
                return 1
            fi
        fi
    fi
    
    # Обновление системы
    update_system
    
    # Установка зависимостей
    install_dependencies
    
    # Скачивание и запуск установщика FastPanel
    wget http://repo.fastpanel.direct/install_fastpanel.sh
    chmod +x install_fastpanel.sh
    
    # Запуск установки
    ./install_fastpanel.sh
    INSTALLER_EXIT_CODE=$?
    
    # Проверка успешности установки
    INSTALL_SUCCESS=false
    if [[ $INSTALLER_EXIT_CODE -eq 0 ]] || [ -d "/usr/local/fastpanel" ] || [ -d "/usr/local/fastpanel2" ] || 
       [ -d "/usr/local/fastpanel2-nginx" ] || [ -f "/usr/bin/fpctl" ] || 
       grep -q "FASTPANEL successfully installed" "${LOG_FILE}"; then
        INSTALL_SUCCESS=true
    fi
    
    # Дополнительная проверка, если не нашли путь установки
    if [[ "$INSTALL_SUCCESS" == false ]]; then
        log_info "Поиск установленных компонентов FastPanel..."
        FOUND_FILES=$(find /usr/local -name "*fastpanel*" -type d 2>/dev/null | wc -l)
        if [[ $FOUND_FILES -gt 0 ]]; then
            log_info "Обнаружены файлы FastPanel в нестандартных путях"
            INSTALL_SUCCESS=true
        fi
    fi
    
    # Очистка
    rm -f install_fastpanel.sh
    
    if $INSTALL_SUCCESS; then
        log_success "FastPanel успешно установлен"
        
        # Вывод информации о доступе
        echo -e "${GREEN}=================================================${NC}"
        echo -e "${GREEN}FastPanel успешно установлен!${NC}"
        echo -e "${GREEN}=================================================${NC}"
        echo "Доступ к панели управления: https://$(hostname -f):8888/"
        echo "Логин и пароль были указаны во время установки."
        echo "Проверьте вывод установщика для получения данных для входа."
        echo -e "${GREEN}=================================================${NC}"
        return 0
    else
        log_error "Установка FastPanel не удалась. Проверьте лог для получения дополнительной информации."
        echo -e "${RED}=================================================${NC}"
        echo -e "${RED}Установка FastPanel не удалась!${NC}"
        echo -e "${RED}=================================================${NC}"
        echo "Возможные причины:"
        echo "1. Не все конфликтующие компоненты были удалены"
        echo "2. Проблемы с сетевым подключением к репозиторию FastPanel"
        echo "3. Несовместимость с текущей версией операционной системы"
        echo ""
        echo "Рекомендация: Для установки FastPanel лучше использовать чистую"
        echo "установку операционной системы без предустановленных компонентов."
        echo -e "${RED}=================================================${NC}"
        return 1
    fi
}

install_aapanel() {
    log_info "Установка aaPanel..."
    
    # Обновление системы
    update_system
    
    # Установка зависимостей
    install_dependencies
    
    # Скачивание и запуск установщика aaPanel
    if [[ "$OS_TYPE" == "debian" ]]; then
        wget -O install.sh http://www.aapanel.com/script/install-ubuntu_6.0_en.sh
    elif [[ "$OS_TYPE" == "rhel" ]]; then
        wget -O install.sh http://www.aapanel.com/script/install_6.0_en.sh
    fi
    
    chmod +x install.sh
    
    # Запуск установки
    ./install.sh
    
    # Очистка
    rm -f install.sh
    
    log_success "aaPanel успешно установлен"
    
    # Вывод информации о доступе
    echo -e "${GREEN}=================================================${NC}"
    echo -e "${GREEN}aaPanel успешно установлен!${NC}"
    echo -e "${GREEN}=================================================${NC}"
    echo "Доступ к панели управления: http://$(hostname -f):8888/"
    echo "Логин и пароль были указаны во время установки."
    echo -e "${GREEN}=================================================${NC}"
}


uninstall_panel() {
    log_info "Удаление установленной панели управления: ${PANEL_TYPE}..."
    
    # Предварительный запрос на удаление всех компонентов
    if prompt_yes_no "Рекомендуется удалить все компоненты стека (веб-серверы, базы данных, PHP) для установки новой панели. Выполнить полную очистку?" "y"; then
        FULL_CLEANUP=true
    else
        FULL_CLEANUP=false
        log_warning "Выбрано удаление только панели управления без компонентов стека. Могут возникнуть конфликты при установке новой панели."
    fi
    
    # Удаление панели в зависимости от типа
    case $PANEL_TYPE in
        "ispmanager")
            log_info "Удаление ISPManager..."
            
            # Проверка наличия скрипта деинсталляции
            if [ -f "/usr/local/ispmgr/sbin/uninstall.sh" ]; then
                if prompt_yes_no "Запустить официальный скрипт удаления ISPManager?" "y"; then
                    /usr/local/ispmgr/sbin/uninstall.sh
                else
                    # Ручное удаление компонентов ISPManager
                    service ispmgr stop 2>/dev/null || systemctl stop ispmgr 2>/dev/null
                    
                    # Удаление пакетов
                    if [[ "$OS_TYPE" == "debian" ]]; then
                        apt purge -y ispmgr* 2>/dev/null
                    elif [[ "$OS_TYPE" == "rhel" ]]; then
                        yum remove -y ispmgr* 2>/dev/null
                    fi
                    
                    # Удаление директорий
                    rm -rf /usr/local/ispmgr 2>/dev/null
                    rm -rf /usr/local/mgr5 2>/dev/null
                    rm -rf /opt/ispmgr 2>/dev/null
                fi
            else
                log_warning "Не найден официальный скрипт удаления ISPManager. Выполняем ручное удаление..."
                
                # Останавливаем службы
                service ispmgr stop 2>/dev/null || systemctl stop ispmgr 2>/dev/null
                
                # Удаление пакетов
                if [[ "$OS_TYPE" == "debian" ]]; then
                    apt purge -y ispmgr* 2>/dev/null
                elif [[ "$OS_TYPE" == "rhel" ]]; then
                    yum remove -y ispmgr* 2>/dev/null
                fi
                
                # Удаление директорий
                rm -rf /usr/local/ispmgr 2>/dev/null
                rm -rf /usr/local/mgr5 2>/dev/null
                rm -rf /opt/ispmgr 2>/dev/null
            fi
            ;;
            
        "hestia")
            log_info "Удаление Hestia Control Panel..."
            
            # Попытка удаления с помощью встроенных утилит
            if [ -f "/usr/local/hestia/bin/v-delete-user-package" ]; then
                if prompt_yes_no "Удалить Hestia Control Panel с помощью встроенных утилит?" "y"; then
                    # Останавливаем сервисы Hestia
                    systemctl stop hestia
                    
                    # Удаляем все пакеты, связанные с Hestia
                    apt purge -y hestia*
                    apt autoremove -y
                    
                    # Удаляем директории Hestia
                    rm -rf /usr/local/hestia
                    rm -rf /etc/hestiacp
                    
                    log_success "Hestia Control Panel удалена с помощью встроенных утилит"
                else
                    log_info "Выполняем ручное удаление Hestia..."
                    
                    # Ручное удаление компонентов
                    systemctl stop hestia nginx apache2 php*-fpm mysql
                    
                    # Удаление пакетов
                    apt purge -y hestia* nginx apache2 php* mysql* mariadb*
                    apt autoremove -y
                    
                    # Удаление директорий
                    rm -rf /usr/local/hestia
                    rm -rf /etc/hestiacp
                fi
            else
                log_warning "Встроенные утилиты Hestia не найдены. Выполняем ручное удаление..."
                
                # Останавливаем сервисы
                systemctl stop hestia 2>/dev/null
                
                # Удаляем пакеты
                if [[ "$OS_TYPE" == "debian" ]]; then
                    apt purge -y hestia* 2>/dev/null
                    apt autoremove -y
                elif [[ "$OS_TYPE" == "rhel" ]]; then
                    yum remove -y hestia* 2>/dev/null
                    yum autoremove -y
                fi
                
                # Удаляем директории
                rm -rf /usr/local/hestia 2>/dev/null
                rm -rf /etc/hestiacp 2>/dev/null
            fi
            ;;
            
        "fastpanel")
            log_info "Удаление FastPanel..."
            
            # Проверка наличия утилиты управления fpctl
            if [ -f "/usr/bin/fpctl" ]; then
                if prompt_yes_no "Запустить официальный процесс удаления FastPanel?" "y"; then
                    log_info "Запуск официальной утилиты удаления..."
                    /usr/bin/fpctl cleanup
                    
                    # Дополнительная очистка после удаления
                    rm -rf /usr/local/fastpanel* 2>/dev/null
                    rm -f /usr/bin/fpctl 2>/dev/null
                else
                    perform_manual_fastpanel_cleanup
                fi
            else
                log_warning "Не найден официальный инструмент удаления FastPanel. Выполняем ручное удаление..."
                perform_manual_fastpanel_cleanup
            fi
            ;;

            
        "aapanel")
            log_info "Удаление aaPanel..."
            
            # Проверка наличия скрипта удаления
            if [ -f "/etc/init.d/bt" ]; then
                if prompt_yes_no "Запустить официальный скрипт удаления aaPanel?" "y"; then
                    /etc/init.d/bt stop
                    /etc/init.d/bt delete
                else
                    # Ручное удаление компонентов
                    log_info "Выполняем ручное удаление aaPanel..."
                    
                    # Останавливаем службы
                    /etc/init.d/bt stop 2>/dev/null
                    
                    # Удаление директорий
                    rm -rf /www/server/panel 2>/dev/null
                    rm -rf /www/server/phpinfo 2>/dev/null
                    rm -f /etc/init.d/bt 2>/dev/null
                    
                    # Удаление пользователя
                    userdel -r www 2>/dev/null
                    
                    # Удаление cron заданий
                    crontab -l | grep -v "/www/server/panel" | crontab -
                fi
            else
                log_warning "Не найден официальный скрипт удаления aaPanel. Выполняем ручное удаление..."
                
                # Удаление директорий
                rm -rf /www/server/panel 2>/dev/null
                rm -rf /www/server/phpinfo 2>/dev/null
                rm -f /etc/init.d/bt 2>/dev/null
                
                # Удаление пользователя
                userdel -r www 2>/dev/null
                
                # Удаление cron заданий
                crontab -l | grep -v "/www/server/panel" | crontab -
            fi
            ;;
            
        *)
            log_error "Неизвестный тип панели управления или панель не обнаружена"
            return 1
            ;;
    esac
    
    # Выполняем полную очистку компонентов стека, если выбрано
    # В блоке полной очистки компонентов стека внутри uninstall_panel()
if [[ "$FULL_CLEANUP" == true ]]; then
    log_info "Выполнение полной очистки компонентов стека..."
    
    # Останавливаем все сервисы
    log_info "Останавливаем все сервисы..."
    $SERVICE_MANAGER stop nginx apache2 httpd php*-fpm php-fpm mysql mariadb exim4 dovecot proftpd 2>/dev/null || true
    
    # Удаление репозиториев
    log_info "Удаление репозиториев..."
    if [[ "$OS_TYPE" == "debian" ]]; then
        # Удаление внешних репозиториев
        rm -f /etc/apt/sources.list.d/*.list 2>/dev/null || true
        
        # Восстановление стандартных репозиториев, если они были изменены
        if [[ -f /etc/apt/sources.list.bak ]]; then
            mv /etc/apt/sources.list.bak /etc/apt/sources.list
        fi
        
        # Обновление индекса пакетов
        apt update
    elif [[ "$OS_TYPE" == "rhel" ]]; then
        # Удаление репозиториев
        rm -f /etc/yum.repos.d/nginx* /etc/yum.repos.d/mysql* /etc/yum.repos.d/mariadb* /etc/yum.repos.d/remi* /etc/yum.repos.d/epel* 2>/dev/null || true
        
        # Очистка кэша yum
        yum clean all
    fi
    
    # Удаление всех компонентов в зависимости от типа ОС
    log_info "Удаление всех компонентов веб-стека..."
        if [[ "$OS_TYPE" == "debian" ]]; then
            # Сначала исправляем любые проблемы с пакетами
            apt -f install -y || true
            
            # Принудительное удаление проблемных пакетов
            dpkg --force-all --purge exim4 exim4-base exim4-config exim4-daemon-light exim4-daemon-heavy 2>/dev/null || true
            
            # Удаление компонентов веб-сервера
            for pkg in nginx nginx-common nginx-full nginx-light nginx-extras apache2 apache2-bin apache2-data apache2-utils libapache2-mod-* lighttpd; do
                apt purge -y $pkg 2>/dev/null || dpkg --force-all --purge $pkg 2>/dev/null || true
            done
            
            # Удаление PHP
            for pkg in php* libapache2-mod-php*; do
                apt purge -y $pkg 2>/dev/null || dpkg --force-all --purge $pkg 2>/dev/null || true
            done
            
            # Удаление баз данных
            for pkg in mysql* mariadb*; do
                apt purge -y $pkg 2>/dev/null || dpkg --force-all --purge $pkg 2>/dev/null || true
            done
            
            # Удаление FTP и почтовых сервисов
            for pkg in proftpd* dovecot* postfix*; do
                apt purge -y $pkg 2>/dev/null || dpkg --force-all --purge $pkg 2>/dev/null || true
            done
            
            # Очистка зависимостей
            apt --fix-broken install -y || true
            apt autoremove -y --purge || true
            apt clean || true
            
            # Исправление оставшихся проблем
            dpkg --configure -a || true
            
        elif [[ "$OS_TYPE" == "rhel" ]]; then
            # Удаление веб-серверов
            yum remove -y nginx* httpd* lighttpd* 2>/dev/null || true
            
            # Удаление PHP
            yum remove -y php* mod_php* 2>/dev/null || true
            
            # Удаление баз данных
            yum remove -y mysql* mariadb* 2>/dev/null || true
            
            # Удаление FTP и почтовых сервисов
            yum remove -y proftpd* dovecot* postfix* 2>/dev/null || true
            
            # Очистка зависимостей
            yum autoremove -y || true
            yum clean all || true
        fi
        
        # Удаление конфигурационных директорий и файлов
        log_info "Удаление конфигурационных директорий и файлов..."
        
        # Веб-серверы
        rm -rf /etc/nginx /etc/apache2 /etc/httpd /etc/lighttpd 2>/dev/null || true
        rm -rf /var/www/* /usr/share/nginx /usr/share/apache2 /var/lib/nginx 2>/dev/null || true
        
        # PHP
        rm -rf /etc/php* /var/lib/php* 2>/dev/null || true
        
        # Базы данных
        rm -rf /etc/mysql /var/lib/mysql /etc/my.cnf* /etc/mariadb /var/lib/mariadb 2>/dev/null || true
        
        # Почтовые сервисы
        rm -rf /etc/exim4 /etc/dovecot /etc/postfix 2>/dev/null || true
        
        # FTP
        rm -rf /etc/proftpd* 2>/dev/null || true
        
        # Удаление логов
        log_info "Удаление логов..."
        rm -rf /var/log/nginx* /var/log/apache2* /var/log/httpd* /var/log/php* /var/log/mysql* /var/log/mariadb* /var/log/exim* /var/log/dovecot* /var/log/proftpd* 2>/dev/null || true
        
        # Удаление пользователей и групп (осторожно, только связанные с веб-сервисами)
        log_info "Удаление системных пользователей..."
        userdel -r www-data 2>/dev/null || true
        userdel -r nginx 2>/dev/null || true
        userdel -r apache 2>/dev/null || true
        userdel -r mysql 2>/dev/null || true
        userdel -r dovecot 2>/dev/null || true
        userdel -r postfix 2>/dev/null || true
        userdel -r proftpd 2>/dev/null || true
        
        # Перезагрузка systemd для применения изменений
        log_info "Перезагрузка systemd для применения изменений..."
        $SERVICE_MANAGER daemon-reload || true
        
        log_success "Полная очистка компонентов стека завершена"
    fi
    
    log_success "Панель управления ${PANEL_TYPE} успешно удалена"
    
    # Сбрасываем переменную после удаления
    PANEL_TYPE=""
    PANEL_INSTALLED=false
    
    return 0
}

perform_manual_fastpanel_cleanup() {
    log_info "Выполняем ручное удаление FastPanel..."
    
    # Список служб, которые могут быть связаны с FastPanel
    local services=("fpconfd" "fpapid" "fastpanel" "fastpanel-nginx" "fastpanel-mysql" "fastpanel-apache" "fastpanel-php")
    
    # Останавливаем службы
    for service in "${services[@]}"; do
        log_info "Останавливаем службу $service..."
        $SERVICE_MANAGER stop $service 2>/dev/null || true
    done
    
    # Удаление директорий
    log_info "Удаление директорий FastPanel..."
    rm -rf /usr/local/fastpanel* 2>/dev/null || true
    rm -rf /opt/fastpanel* 2>/dev/null || true
    rm -rf /etc/fastpanel* 2>/dev/null || true
    rm -f /usr/bin/fpctl 2>/dev/null || true
    
    # Удаление системных служб
    log_info "Удаление системных служб..."
    for service in "${services[@]}"; do
        rm -f /etc/systemd/system/$service.service 2>/dev/null || true
        rm -f /usr/lib/systemd/system/$service.service 2>/dev/null || true
    done
    
    # Перезагрузка systemd для применения изменений
    log_info "Перезагрузка systemd..."
    $SERVICE_MANAGER daemon-reload || true
    
    log_info "Ручное удаление FastPanel завершено"
}

#=====================================================================
# Функции безопасности
#=====================================================================

setup_firewall() {
    log_info "Настройка файервола..."
    
    if [[ "$OS_TYPE" == "debian" ]]; then
        # Установка UFW, если еще не установлен
        apt install -y ufw
        
        # Установка политик по умолчанию
        ufw default deny incoming
        ufw default allow outgoing
        
        # Разрешение SSH (порт 22)
        ufw allow ssh
        
        # Разрешение HTTP и HTTPS
        ufw allow 80/tcp
        ufw allow 443/tcp
        
        # Включение UFW в неинтерактивном режиме
        echo "y" | ufw enable
        
    elif [[ "$OS_TYPE" == "rhel" ]]; then
        # Установка и настройка firewalld
        yum install -y firewalld
        $SERVICE_MANAGER start firewalld
        $SERVICE_MANAGER enable firewalld
        
        # Разрешение SSH, HTTP и HTTPS
        firewall-cmd --permanent --add-service=ssh
        firewall-cmd --permanent --add-service=http
        firewall-cmd --permanent --add-service=https
        
        # Применение изменений
        firewall-cmd --reload
    fi
    
    log_success "Файервол успешно настроен"
}

setup_fail2ban() {
    log_info "Настройка Fail2Ban..."
    
    if [[ "$OS_TYPE" == "debian" ]]; then
        apt install -y fail2ban
    elif [[ "$OS_TYPE" == "rhel" ]]; then
        yum install -y fail2ban
    fi
    
    # Создание конфигурации для Fail2Ban
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true

[nginx-http-auth]
enabled = true

[apache-auth]
enabled = true

[php-url-fopen]
enabled = true
EOF
    
    # Перезапуск Fail2Ban
    $SERVICE_MANAGER start fail2ban
    $SERVICE_MANAGER enable fail2ban
    
    log_success "Fail2Ban успешно настроен"
}

setup_ssl() {
    log_info "Настройка SSL с Certbot..."
    
    # Проверка, что домен не является localhost
    if [[ "$DOMAIN" == "localhost" ]]; then
        log_warning "SSL не может быть настроен для localhost"
        return 1
    fi
    
    # Установка Certbot
    if [[ "$OS_TYPE" == "debian" ]]; then
        apt install -y certbot
        
        if [[ "$WEB_SERVER" == "nginx" || "$WEB_SERVER" == "nginx_apache_proxy" ]]; then
            apt install -y python3-certbot-nginx
            certbot --nginx -d ${DOMAIN} -d www.${DOMAIN} --non-interactive --agree-tos --email admin@${DOMAIN}
        elif [[ "$WEB_SERVER" == "apache" ]]; then
            apt install -y python3-certbot-apache
            certbot --apache -d ${DOMAIN} -d www.${DOMAIN} --non-interactive --agree-tos --email admin@${DOMAIN}
        fi
    elif [[ "$OS_TYPE" == "rhel" ]]; then
        yum install -y certbot
        
        if [[ "$WEB_SERVER" == "nginx" || "$WEB_SERVER" == "nginx_apache_proxy" ]]; then
            yum install -y python3-certbot-nginx
            certbot --nginx -d ${DOMAIN} -d www.${DOMAIN} --non-interactive --agree-tos --email admin@${DOMAIN}
        elif [[ "$WEB_SERVER" == "apache" ]]; then
            yum install -y python3-certbot-apache
            certbot --apache -d ${DOMAIN} -d www.${DOMAIN} --non-interactive --agree-tos --email admin@${DOMAIN}
        fi
    fi
    
    # Добавление автоматического обновления сертификатов
    echo "0 3 * * * root certbot renew --quiet" > /etc/cron.d/certbot-renew
    
    log_success "SSL успешно настроен для ${DOMAIN}"
}

setup_swap() {
    log_info "Настройка файла подкачки (swap) размером ${SWAP_SIZE}..."
    
    # Проверка, существует ли уже swap
    if free | grep -q 'Swap' && [[ $(free | grep 'Swap' | awk '{print $2}') -gt 0 ]]; then
        log_warning "Swap уже сконфигурирован. Пропускаем этот шаг."
        return
    fi
    
    # Создание swap файла
    fallocate -l ${SWAP_SIZE} /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    
    # Добавление swap в fstab для автоматического монтирования при загрузке
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    
    # Настройка параметров swap
    echo "vm.swappiness=10" >> /etc/sysctl.conf
    echo "vm.vfs_cache_pressure=50" >> /etc/sysctl.conf
    sysctl -p
    
    log_success "Swap успешно настроен"
}

disable_directory_listing() {
    log_info "Отключение листинга директорий..."
    
    if [[ "$WEB_SERVER" == "nginx" || "$WEB_SERVER" == "nginx_apache_proxy" ]]; then
        # Для Nginx
        find /etc/nginx -type f -name "*.conf" -exec sed -i 's/autoindex on/autoindex off/g' {} \;
        $SERVICE_MANAGER reload nginx
    fi
    
    if [[ "$WEB_SERVER" == "apache" || "$WEB_SERVER" == "nginx_apache_proxy" ]]; then
        # Для Apache
        if [[ "$OS_TYPE" == "debian" ]]; then
            find /etc/apache2 -type f -name "*.conf" -exec sed -i 's/Options Indexes/Options/g' {} \;
            $SERVICE_MANAGER reload apache2
        elif [[ "$OS_TYPE" == "rhel" ]]; then
            find /etc/httpd -type f -name "*.conf" -exec sed -i 's/Options Indexes/Options/g' {} \;
            $SERVICE_MANAGER reload httpd
        fi
    fi
    
    log_success "Листинг директорий успешно отключен"
}

enhance_security() {
    log_info "Настройка дополнительных мер безопасности..."
    
    # 1. Настройка защиты от брутфорс-атак с помощью fail2ban
    setup_fail2ban
    
    # 2. Усиление безопасности SSH (если существует)
    if [[ -f /etc/ssh/sshd_config ]]; then
        log_info "Настройка безопасности SSH..."
        
        # Создание резервной копии
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
        
        # Отключение аутентификации по паролю, если есть ключи
        if [[ -d /root/.ssh ]] || compgen -G "/home/*/.ssh" > /dev/null; then
            if prompt_yes_no "Обнаружены SSH-ключи. Отключить аутентификацию по паролю (повышает безопасность, но доступ будет только по ключу)?" "n"; then
                sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config
                sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config
                log_info "Аутентификация по паролю для SSH отключена"
            fi
        fi
        
        # Перезапуск SSH для применения изменений
        $SERVICE_MANAGER restart sshd
        
        log_success "Безопасность SSH настроена"
    fi
    
    # 3. Настройка файловых прав для повышения безопасности
    log_info "Настройка файловых прав..."
    
    # Исправление прав доступа к важным файлам конфигурации
    if [[ "$WEB_SERVER" == "nginx" || "$WEB_SERVER" == "nginx_apache_proxy" ]]; then
        find /etc/nginx -type f -name "*.conf" -exec chmod 640 {} \;
    fi
    
    if [[ "$WEB_SERVER" == "apache" || "$WEB_SERVER" == "nginx_apache_proxy" ]]; then
        if [[ "$OS_TYPE" == "debian" ]]; then
            find /etc/apache2 -type f -name "*.conf" -exec chmod 640 {} \;
        elif [[ "$OS_TYPE" == "rhel" ]]; then
            find /etc/httpd -type f -name "*.conf" -exec chmod 640 {} \;
        fi
    fi
    
    # Защита конфигурации PHP
    if [[ "$OS_TYPE" == "debian" ]]; then
        find /etc/php -type f -name "*.ini" -exec chmod 640 {} \;
    elif [[ "$OS_TYPE" == "rhel" ]]; then
        chmod 640 /etc/php.ini
        find /etc/php.d -type f -name "*.ini" -exec chmod 640 {} \; 2>/dev/null || true
    fi
    
    # 4. Защита от XSS и других веб-атак
    if [[ "$WEB_SERVER" == "nginx" || "$WEB_SERVER" == "nginx_apache_proxy" ]]; then
        log_info "Настройка дополнительных заголовков безопасности для Nginx..."
        
        # Создание файла с дополнительными заголовками безопасности
        cat > /etc/nginx/conf.d/security-headers.conf << EOF
# Дополнительные заголовки безопасности
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "no-referrer-when-downgrade" always;
add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'; frame-ancestors 'self';" always;
add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), interest-cohort=()" always;
EOF

        # Перезагрузка Nginx для применения изменений
        $SERVICE_MANAGER reload nginx
    fi
    
    if [[ "$WEB_SERVER" == "apache" || "$WEB_SERVER" == "nginx_apache_proxy" ]]; then
        log_info "Настройка дополнительных заголовков безопасности для Apache..."
        
        # Создание файла с дополнительными заголовками безопасности
        if [[ "$OS_TYPE" == "debian" ]]; then
            headers_file="/etc/apache2/conf-available/security-headers.conf"
            
            cat > $headers_file << EOF
<IfModule mod_headers.c>
    Header set X-Frame-Options "SAMEORIGIN"
    Header set X-XSS-Protection "1; mode=block"
    Header set X-Content-Type-Options "nosniff"
    Header set Referrer-Policy "no-referrer-when-downgrade"
    Header set Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'; frame-ancestors 'self';"
    Header set Permissions-Policy "camera=(), microphone=(), geolocation=(), interest-cohort=()"
</IfModule>
EOF
            
            # Включение конфигурации
            a2enconf security-headers
            
        elif [[ "$OS_TYPE" == "rhel" ]]; then
            headers_file="/etc/httpd/conf.d/security-headers.conf"
            
            cat > $headers_file << EOF
<IfModule mod_headers.c>
    Header set X-Frame-Options "SAMEORIGIN"
    Header set X-XSS-Protection "1; mode=block"
    Header set X-Content-Type-Options "nosniff"
    Header set Referrer-Policy "no-referrer-when-downgrade"
    Header set Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'; frame-ancestors 'self';"
    Header set Permissions-Policy "camera=(), microphone=(), geolocation=(), interest-cohort=()"
</IfModule>
EOF
        fi
        
        # Перезапуск Apache для применения изменений
        if [[ "$OS_TYPE" == "debian" ]]; then
            $SERVICE_MANAGER restart apache2
        elif [[ "$OS_TYPE" == "rhel" ]]; then
            $SERVICE_MANAGER restart httpd
        fi
    fi
    
    # 5. Защита базы данных
    log_info "Настройка дополнительной защиты базы данных..."
    
    # Настройка разрешений на прослушивание только локальных соединений
    if [[ "$DATABASE" == "mysql" ]]; then
        local my_cnf
        if [[ "$OS_TYPE" == "debian" ]]; then
            my_cnf="/etc/mysql/mysql.conf.d/mysqld.cnf"
        elif [[ "$OS_TYPE" == "rhel" ]]; then
            my_cnf="/etc/my.cnf"
        fi
        
        # Проверяем, существует ли параметр bind-address
        if grep -q "bind-address" $my_cnf; then
            sed -i 's/^bind-address.*/bind-address = 127.0.0.1/' $my_cnf
        else
            echo "bind-address = 127.0.0.1" >> $my_cnf
        fi
        
        # Перезапуск MySQL
        $SERVICE_MANAGER restart mysql || $SERVICE_MANAGER restart mysqld
        
    elif [[ "$DATABASE" == "mariadb" ]]; then
        local my_cnf
        if [[ "$OS_TYPE" == "debian" ]]; then
            my_cnf="/etc/mysql/mariadb.conf.d/50-server.cnf"
        elif [[ "$OS_TYPE" == "rhel" ]]; then
            my_cnf="/etc/my.cnf.d/server.cnf"
        fi
        
        # Проверяем, существует ли параметр bind-address
        if grep -q "bind-address" $my_cnf; then
            sed -i 's/^bind-address.*/bind-address = 127.0.0.1/' $my_cnf
        else
            echo "bind-address = 127.0.0.1" >> $my_cnf
        fi
        
        # Перезапуск MariaDB
        $SERVICE_MANAGER restart mariadb || $SERVICE_MANAGER restart mysql
    fi
    
    # 6. Настройка защиты от DDoS-атак для Nginx
    if [[ "$WEB_SERVER" == "nginx" || "$WEB_SERVER" == "nginx_apache_proxy" ]]; then
        setup_nginx_dos_protection
    fi
    
    log_success "Дополнительные меры безопасности настроены"
}

# Дополнительная настройка защиты от DDoS для Nginx
setup_nginx_dos_protection() {

    if [[ -f /etc/nginx/conf.d/rate-limiting.conf ]]; then
        log_info "Защита от DoS уже настроена. Пропускаем этот шаг."
        return
    fi

    log_info "Настройка защиты от DoS-атак для Nginx..."
    
    # Создание файла конфигурации ограничений на уровне http
    cat > /etc/nginx/conf.d/rate-limiting.conf << EOF
# Ограничение количества запросов
limit_req_zone \$binary_remote_addr zone=one:10m rate=1r/s;
limit_req_zone \$binary_remote_addr zone=two:10m rate=10r/s;

# Ограничение количества соединений
limit_conn_zone \$binary_remote_addr zone=addr:10m;

# Защита от медленных запросов (Slowloris) - на уровне http
client_body_timeout 10s;
client_header_timeout 10s;
keepalive_timeout 65s;
send_timeout 10s;

# Настройки по умолчанию для всех серверов
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    
    # Ограничение размера тела запроса
    client_max_body_size 10m;
    
    # Ограничение количества соединений с одного IP
    limit_conn addr 15;
    
    # Возвращаем 444 для неизвестных виртуальных хостов
    return 444;
}
EOF
    
    # Отдельный файл для включения в блоки location
    cat > /etc/nginx/snippets/rate-limiting.conf << EOF
# Ограничение количества запросов к PHP файлам
location ~ \.php$ {
    limit_req zone=one burst=5 nodelay;
    limit_req_status 429;
    try_files \$uri =404;
    # ... другие настройки PHP ...
}

# Ограничение количества запросов к динамичным ресурсам
location ~ \.(php|asp|aspx|jsp|cgi)$ {
    limit_req zone=one burst=5 nodelay;
    limit_req_status 429;
}

# Ограничение количества запросов к статичным ресурсам
location ~* \.(css|js|jpg|jpeg|png|gif|ico|svg)$ {
    limit_req zone=two burst=20 nodelay;
    limit_req_status 429;
    expires 30d;
    add_header Cache-Control "public, no-transform";
}

# Ограничение количества соединений с одного IP
limit_conn addr 20;
limit_conn_status 429;
EOF
    
    # Создаем файл с настройками для включения в server блоки
    cat > /etc/nginx/conf.d/server-rate-limiting.conf << EOF
# Включите эти настройки в server блоки
# Защита от медленных запросов (Slowloris) - на уровне server
client_body_timeout 10s;
client_header_timeout 10s;
keepalive_timeout 65s;
send_timeout 10s;
EOF
    
    # Переделываем логику включения сниппета - только для блоков server
    for config in /etc/nginx/sites-available/*.conf; do
        if [[ -f "$config" ]]; then
            if ! grep -q "include snippets/server-rate-limiting.conf;" "$config"; then
                sed -i '/server {/a \    # Включение защиты от DDoS на уровне сервера\n    include snippets/server-rate-limiting.conf;' "$config"
            fi
        fi
    done


    
    # Перезагрузка Nginx для применения изменений
    nginx -t && $SERVICE_MANAGER reload nginx
    
    log_success "Защита от DoS-атак для Nginx настроена"
}

#=====================================================================
# Функции очистки
#=====================================================================

cleanup_system() {
    log_info "Очистка системы..."

    if [[ "$OS_TYPE" == "debian" ]]; then
        apt clean
        apt autoremove -y
    elif [[ "$OS_TYPE" == "rhel" ]]; then
        yum clean all
        yum autoremove -y
    fi
    
    log_success "Система успешно очищена"
}

uninstall_stack() {
    log_info "Удаление установленных компонентов..."
    
    if [[ "$OS_TYPE" == "debian" ]]; then
        # Удаление веб-сервера
        if [[ "$WEB_SERVER" == "nginx" || "$WEB_SERVER" == "nginx_apache_proxy" ]]; then
            apt purge -y nginx nginx-common
            rm -rf /etc/nginx
        fi
        
        if [[ "$WEB_SERVER" == "apache" || "$WEB_SERVER" == "nginx_apache_proxy" ]]; then
            apt purge -y apache2 apache2-utils
            rm -rf /etc/apache2
        fi
        
        # Удаление PHP
        apt purge -y php* php*-fpm php*-common
        rm -rf /etc/php
        
        # Удаление базы данных
        if [[ "$DATABASE" == "mysql" ]]; then
            apt purge -y mysql-server mysql-client
            rm -rf /etc/mysql /var/lib/mysql
        else
            apt purge -y mariadb-server mariadb-client
            rm -rf /etc/mysql /var/lib/mysql
        fi
        
    elif [[ "$OS_TYPE" == "rhel" ]]; then
        # Удаление веб-сервера
        if [[ "$WEB_SERVER" == "nginx" || "$WEB_SERVER" == "nginx_apache_proxy" ]]; then
            yum remove -y nginx
            rm -rf /etc/nginx
        fi
        
        if [[ "$WEB_SERVER" == "apache" || "$WEB_SERVER" == "nginx_apache_proxy" ]]; then
            yum remove -y httpd
            rm -rf /etc/httpd
        fi
        
        # Удаление PHP
        yum remove -y php* php-fpm
        rm -rf /etc/php.d /etc/php-fpm.d
        
        # Удаление базы данных
        if [[ "$DATABASE" == "mysql" ]]; then
            yum remove -y mysql mysql-server
            rm -rf /var/lib/mysql
        else
            yum remove -y mariadb mariadb-server
            rm -rf /var/lib/mysql
        fi
    fi
    
    # Удаление swap-файла, если он был создан скриптом
    if [[ -f /swapfile ]]; then
        swapoff /swapfile
        rm -f /swapfile
        sed -i '/swapfile/d' /etc/fstab
    fi
    
    # Удаление логов
    rm -f /var/log/lemp_automate.log
    
    log_success "Все компоненты успешно удалены"
}


#=====================================================================
# Интерактивные функции
#=====================================================================

prompt_operation() {
    # Проверяем, установлен ли уже стек
    if detect_installed_software; then
        echo -e "${CYAN}=== Выбор операции ===${NC}"
        echo "1) Добавить новый сайт"
        echo "2) Установить новый LEMP/LAMP стек (удалит существующий)"
        read -p "Выберите операцию [1-2] (по умолчанию: 1): " choice
        
        case $choice in
            2)
                if prompt_yes_no "Это действие удалит существующий стек! Вы уверены?" "n"; then
                    OPERATION="install"
                    log_info "Выбрано: Установка нового стека"
                else
                    OPERATION="add_site"
                    log_info "Выбрано: Добавление нового сайта"
                fi
                ;;
            *)
                OPERATION="add_site"
                log_info "Выбрано: Добавление нового сайта"
                ;;
        esac
    else
        OPERATION="install"
        log_info "Стек не установлен. Будет выполнена установка."
    fi
}

prompt_web_server() {
    echo -e "${CYAN}=== Выбор веб-сервера ===${NC}"
    echo "1) Nginx (рекомендуется)"
    echo "2) Apache"
    echo "3) Nginx + Apache (Nginx в качестве прокси)"
    read -p "Выберите веб-сервер [1-3] (по умолчанию: 1): " choice
    
    case $choice in
        2)
            WEB_SERVER="apache"
            ;;
        3)
            WEB_SERVER="nginx_apache_proxy"
            ;;
        *)
            WEB_SERVER="nginx"
            ;;
    esac
    
    log_info "Выбран веб-сервер: ${WEB_SERVER}"
    
    # Выбор обработчика PHP, если выбран Apache
    if [[ "$WEB_SERVER" == "apache" ]]; then
        echo -e "${CYAN}=== Выбор обработчика PHP ===${NC}"
        echo "1) PHP-FPM (рекомендуется)"
        echo "2) mod_php (Apache модуль)"
        read -p "Выберите обработчик PHP [1-2] (по умолчанию: 1): " choice
        
        case $choice in
            2)
                PHP_HANDLER="mod_php"
                ;;
            *)
                PHP_HANDLER="fpm"
                ;;
        esac
        
        log_info "Выбран обработчик PHP: ${PHP_HANDLER}"
    else
        # Для Nginx всегда используем PHP-FPM
        PHP_HANDLER="fpm"
    fi
}

prompt_php_version() {
    echo -e "${CYAN}=== Выбор версии PHP ===${NC}"
    echo "1) PHP 7.4"
    echo "2) PHP 8.0"
    echo "3) PHP 8.1"
    echo "4) PHP 8.2 (рекомендуется)"
    read -p "Выберите версию PHP [1-4] (по умолчанию: 4): " choice
    
    case $choice in
        1)
            PHP_VERSION="7.4"
            ;;
        2)
            PHP_VERSION="8.0"
            ;;
        3)
            PHP_VERSION="8.1"
            ;;
        *)
            PHP_VERSION="8.2"
            ;;
    esac
    
    log_info "Выбрана версия PHP: ${PHP_VERSION}"
}

prompt_database() {
    echo -e "${CYAN}=== Выбор СУБД ===${NC}"
    echo "1) MariaDB (рекомендуется)"
    echo "2) MySQL"
    read -p "Выберите СУБД [1-2] (по умолчанию: 1): " choice
    
    case $choice in
        2)
            DATABASE="mysql"
            ;;
        *)
            DATABASE="mariadb"
            ;;
    esac
    
    log_info "Выбрана СУБД: ${DATABASE}"
    
    # Запрос версии СУБД
    echo -e "${CYAN}=== Версия СУБД ===${NC}"
    echo "Укажите конкретную версию ${DATABASE} (например: 10.6 для MariaDB или 8.0 для MySQL)"
    echo "Оставьте пустым для использования версии из репозитория по умолчанию"
    read -p "Версия ${DATABASE}: " DB_VERSION
    
    if [[ -n "$DB_VERSION" ]]; then
        log_info "Выбрана версия ${DATABASE}: ${DB_VERSION}"
    else
        log_info "Будет использована версия ${DATABASE} из репозитория по умолчанию"
    fi
}

prompt_domain() {
    echo -e "${CYAN}=== Настройка домена ===${NC}"
    read -p "Введите доменное имя (например, example.com): " DOMAIN
    
    if [[ -z "$DOMAIN" ]]; then
        DOMAIN="localhost"
        log_info "Доменное имя не указано, будет использован localhost"
    else
        log_info "Указано доменное имя: ${DOMAIN}"
    fi
    
    # Запрос директории сайта
    read -p "Введите путь к директории сайта (по умолчанию: /var/www/${DOMAIN}): " SITE_DIR
    
    if [[ -z "$SITE_DIR" ]]; then
        SITE_DIR="/var/www/${DOMAIN}"
    fi
    
    log_info "Директория сайта: ${SITE_DIR}"
}

prompt_db_credentials() {
    echo -e "${CYAN}=== Настройка базы данных ===${NC}"
    
    # Запрос на создание базы данных
    if prompt_yes_no "Создать базу данных и пользователя?" "y"; then
        CREATE_DB=true
        
        # Имя базы данных
        read -p "Введите имя базы данных (по умолчанию: ${DOMAIN//./_}): " DB_NAME
        if [[ -z "$DB_NAME" ]]; then
            DB_NAME="${DOMAIN//./_}"
        fi
        
        # Имя пользователя базы данных
        read -p "Введите имя пользователя базы данных (по умолчанию: ${DB_NAME}): " DB_USER
        if [[ -z "$DB_USER" ]]; then
            DB_USER="${DB_NAME}"
        fi
        
        # Пароль пользователя базы данных
        read -p "Введите пароль пользователя базы данных (нажмите Enter для генерации): " DB_PASS
        if [[ -z "$DB_PASS" ]]; then
            DB_PASS=$(openssl rand -base64 12)
            echo "Сгенерирован пароль: ${DB_PASS}"
        fi
        
        log_info "Будут созданы: БД ${DB_NAME}, пользователь ${DB_USER}"
    else
        CREATE_DB=false
        
        # Всё равно нужен пароль root для безопасной установки MySQL/MariaDB
        read -p "Введите пароль для root пользователя базы данных (нажмите Enter для генерации): " DB_PASS
        if [[ -z "$DB_PASS" ]]; then
            DB_PASS=$(openssl rand -base64 12)
            echo "Сгенерирован пароль: ${DB_PASS}"
        fi
        
        log_info "База данных и пользователь не будут созданы"
    fi
}

prompt_ssl() {
    echo -e "${CYAN}=== Настройка SSL ===${NC}"
    
    if [[ "$DOMAIN" != "localhost" ]]; then
        if prompt_yes_no "Настроить SSL с Let's Encrypt для ${DOMAIN}?" "y"; then
            ENABLE_SSL=true
            log_info "SSL будет настроен для ${DOMAIN}"
        else
            ENABLE_SSL=false
            log_info "SSL не будет настроен"
        fi
    else
        log_info "SSL нельзя настроить для localhost, пропускаем..."
        ENABLE_SSL=false
    fi
}

prompt_swap() {
    echo -e "${CYAN}=== Настройка файла подкачки (swap) ===${NC}"
    
    # Получение информации о памяти
    local mem_total=$(free -m | grep Mem | awk '{print $2}')
    
    if [[ $mem_total -lt 2048 ]]; then
        echo "У вас всего ${mem_total}MB оперативной памяти."
        if prompt_yes_no "Настроить файл подкачки (swap)?" "y"; then
            ENABLE_SWAP=true
            
            read -p "Введите размер swap-файла (по умолчанию: 2G): " swap_input
            if [[ -n "$swap_input" ]]; then
                SWAP_SIZE="$swap_input"
            fi
            
            log_info "Будет создан swap-файл размером ${SWAP_SIZE}"
        else
            ENABLE_SWAP=false
            log_info "Swap-файл не будет создан"
        fi
    else
        log_info "У вас достаточно оперативной памяти (${mem_total}MB). Swap-файл не требуется."
        ENABLE_SWAP=false
    fi
}

#=====================================================================
# Основная функция
#=====================================================================

display_banner() {
    echo -e "${GREEN}"
    echo "  _____                             __  __                                       "
    echo " / ____|                           |  \/  |                                      "
    echo "| (___   ___ _ ____   _____ _ __  | \  / | __ _ _ __   __ _  __ _  ___ _ __     "
    echo " \___ \ / _ \ '__\ \ / / _ \ '__| | |\/| |/ _\` | '_ \ / _\` |/ _\` |/ _ \ '__|    "
    echo " ____) |  __/ |   \ V /  __/ |    | |  | | (_| | | | | (_| | (_| |  __/ |       "
    echo "|_____/ \___|_|    \_/ \___|_|    |_|  |_|\__,_|_| |_|\__,_|\__, |\___|_|       "
    echo "                                                              __/ |              "
    echo "                                                             |___/               "
    echo -e "${NC}"
    echo "  ---------------------------------------------------------------------------------"
    echo "                Инструмент управления сервером"
    echo "                Установка LEMP/LAMP стека и панелей управления"
    echo "                Версия: 2.3.4"
    echo "                Разработка Pavlovich Vladislav - pavlovich.live"
    echo "                По вопросам функционирования и поддержки: TG @femid00"  
    echo "  ---------------------------------------------------------------------------------"
    echo ""
}

display_summary() {
    echo -e "${CYAN}=== Сводка настроек ===${NC}"
    
    if [[ "$OPERATION" == "add_site" ]]; then
        echo "Операция:          Добавление сайта"
    else
        echo "Операция:          Установка стека"
        echo "Веб-сервер:        ${WEB_SERVER}"
        echo "Версия PHP:        ${PHP_VERSION}"
        echo "СУБД:              ${DATABASE} ${DB_VERSION}"
    fi
    
    echo "Домен:             ${DOMAIN}"
    echo "Директория сайта:  ${SITE_DIR}"
    
    if [[ "$CREATE_DB" == true ]]; then
        echo "База данных:       ${DB_NAME}"
        echo "Пользователь БД:   ${DB_USER}"
        echo "Пароль БД:         ${DB_PASS}"
    fi
    
    if [[ "$OPERATION" == "install" ]]; then
        echo "Настроить SSL:     $(if [[ "$ENABLE_SSL" == true ]]; then echo "Да"; else echo "Нет"; fi)"
        echo "Настроить swap:    $(if [[ "$ENABLE_SWAP" == true ]]; then echo "Да (${SWAP_SIZE})"; else echo "Нет"; fi)"
    else
        if [[ "$ENABLE_SSL" == true ]]; then
            echo "Настроить SSL:     Да"
        fi
    fi
    echo ""
    
    if prompt_yes_no "Продолжить с этими настройками?" "y"; then
        return 0
    else
        log_error "Установка отменена пользователем"
        exit 1
    fi
}

install_stack() {
    log_info "Установка LEMP/LAMP стека..."
    
    # Обновление системы
    update_system
    
    # Установка зависимостей
    install_dependencies
    
    # Порядок установки зависит от выбранного стека
    if [[ "$WEB_SERVER" == "nginx_apache_proxy" ]]; then
        # Для режима прокси сначала устанавливаем Apache с настройкой порта 8080
        install_apache
        
        # Затем устанавливаем Nginx
        install_nginx
        
        # Настраиваем проксирование
        configure_nginx_apache_proxy
    else
        # Обычный порядок для стандартных стеков
        if [[ "$WEB_SERVER" == "nginx" ]]; then
            install_nginx
        elif [[ "$WEB_SERVER" == "apache" ]]; then
            install_apache
        fi
    fi
    
    # Установка PHP
    install_php
    
    # Установка базы данных
    if [[ "$DATABASE" == "mysql" ]]; then
        install_mysql
    else
        install_mariadb
    fi
    
    # Настройка базы данных
    configure_database
    
    # Добавление сайта
    add_site
    
    # Оптимизация PHP
    configure_php
    
    # Оптимизация базы данных
    configure_mysql_performance
    
    # Настройка файервола
    setup_firewall
    
    # Настройка Fail2Ban
    setup_fail2ban
    
    # Отключение листинга директорий
    disable_directory_listing
    
    # Настройка SSL, если запрошено
    if [[ "$ENABLE_SSL" == true ]]; then
        setup_ssl
    fi
    
    # Настройка swap, если запрошено
    if [[ "$ENABLE_SWAP" == true ]]; then
        setup_swap
    fi
    
    # Дополнительные меры безопасности
    enhance_security
    
    # Очистка системы
    cleanup_system
    
    log_success "=================================================="
    log_success "      Установка LEMP/LAMP стека завершена!        "
    log_success "=================================================="
}

add_site() {
    log_info "Добавление нового сайта: ${DOMAIN}..."
    
    # Настройка веб-сервера для сайта
    if [[ "$WEB_SERVER" == "nginx" || "$WEB_SERVER" == "nginx_apache_proxy" ]]; then
        configure_nginx
    fi
    
    if [[ "$WEB_SERVER" == "apache" || "$WEB_SERVER" == "nginx_apache_proxy" ]]; then
        configure_apache
    fi
    
    # Создание базы данных и пользователя, если запрошено
    if [[ "$CREATE_DB" == true ]]; then
        configure_database
    fi
    
    # Настройка SSL, если запрошено
    if [[ "$ENABLE_SSL" == true ]]; then
        setup_ssl
    fi
    
    log_success "Сайт ${DOMAIN} успешно добавлен"
}

main() {
    # Проверка прав root
    check_root
    
    # Создание лог-файла
    touch "${LOG_FILE}"
    
    # Отображение баннера
    display_banner
    
    # Определение ОС
    detect_os
    
    # Определяем статус установленных компонентов
    STACK_INSTALLED=false
    PANEL_INSTALLED=false
    
    if detect_installed_software; then
        STACK_INSTALLED=true
    fi
    
    if detect_installed_panel; then
        PANEL_INSTALLED=true
    fi
    
    # Определяем режим работы на основе установленных компонентов
    if $STACK_INSTALLED && $PANEL_INSTALLED; then
        # Установлены и стек, и панель
        echo -e "${CYAN}=== Выбор операции ===${NC}"
        echo "Обнаружены установленный стек и панель управления: ${PANEL_TYPE}"
        echo "1) Добавить новый сайт"
        echo "2) Установить новый LEMP/LAMP стек (удалит существующий)"
        echo "3) Установить новую панель управления (удалит существующую)"
        read -p "Выберите операцию [1-3] (по умолчанию: 1): " choice
        
        case $choice in
            2)
                if prompt_yes_no "Это действие удалит существующий стек! Вы уверены?" "n"; then
                    OPERATION="install_stack"
                    log_info "Выбрано: Установка нового стека"
                else
                    OPERATION="add_site"
                    log_info "Выбрано: Добавление нового сайта"
                fi
                ;;
            3)
                if prompt_yes_no "Это действие удалит существующую панель ${PANEL_TYPE}! Вы уверены?" "n"; then
                    uninstall_panel
                    OPERATION="install_panel"
                    log_info "Выбрано: Установка новой панели управления"
                    prompt_panel_selection
                else
                    OPERATION="add_site"
                    log_info "Выбрано: Добавление нового сайта"
                fi
                ;;
            *)
                OPERATION="add_site"
                log_info "Выбрано: Добавление нового сайта"
                ;;
        esac
        
    elif $STACK_INSTALLED; then
        # Установлен только стек
        echo -e "${CYAN}=== Выбор операции ===${NC}"
        echo "1) Добавить новый сайт"
        echo "2) Установить новый LEMP/LAMP стек (удалит существующий)"
        echo "3) Установить панель управления сервером"
        read -p "Выберите операцию [1-3] (по умолчанию: 1): " choice
        
        case $choice in
            2)
                if prompt_yes_no "Это действие удалит существующий стек! Вы уверены?" "n"; then
                    OPERATION="install_stack"
                    log_info "Выбрано: Установка нового стека"
                else
                    OPERATION="add_site"
                    log_info "Выбрано: Добавление нового сайта"
                fi
                ;;
            3)
                OPERATION="install_panel"
                log_info "Выбрано: Установка панели управления"
                prompt_panel_selection
                ;;
            *)
                OPERATION="add_site"
                log_info "Выбрано: Добавление нового сайта"
                ;;
        esac
        
    elif $PANEL_INSTALLED; then
        # Установлена только панель
        echo -e "${CYAN}=== Выбор операции ===${NC}"
        echo "Обнаружена установленная панель управления: ${PANEL_TYPE}"
        echo "1) Установить LEMP/LAMP стек (возможны конфликты с панелью)"
        echo "2) Установить новую панель управления (удалит существующую)"
        read -p "Выберите операцию [1-2] (по умолчанию: 1): " choice
        
        case $choice in
            2)
                if prompt_yes_no "Это действие удалит существующую панель ${PANEL_TYPE}! Вы уверены?" "n"; then
                    uninstall_panel
                    OPERATION="install_panel"
                    log_info "Выбрано: Установка новой панели управления"
                    prompt_panel_selection
                else
                    OPERATION="install_stack"
                    log_info "Выбрано: Установка стека (возможны конфликты с панелью)"
                fi
                ;;
            *)
                if prompt_yes_no "Установка стека может конфликтовать с панелью ${PANEL_TYPE}. Продолжить?" "n"; then
                    OPERATION="install_stack"
                    log_info "Выбрано: Установка стека"
                else
                    log_error "Установка отменена пользователем"
                    exit 1
                fi
                ;;
        esac
        
    else
        # Ничего не установлено
        prompt_main_selection
    fi
    
    # Если выбрана установка панели - запросить её тип
    if [[ "$OPERATION" == "install_panel" && -z "$PANEL_TYPE" ]]; then
        prompt_panel_selection
    fi

    # Ветвление логики в зависимости от выбранной операции
    if [[ "$OPERATION" == "add_site" ]]; then
        # Запрос только необходимых параметров для добавления сайта
        prompt_domain
        prompt_db_credentials
        prompt_ssl
        
        # Отображение и подтверждение настроек
        display_summary
        
        # Добавление сайта
        add_site
        
    elif [[ "$OPERATION" == "install_panel" ]]; then
        # Отображение информации о выбранной панели
        echo -e "${CYAN}=== Сводка настроек ===${NC}"
        echo "Операция:          Установка панели управления"
        echo "Панель:            ${PANEL_TYPE}"
        echo ""
        
        if prompt_yes_no "Продолжить с этими настройками?" "y"; then
            # Установка панели управления
            install_panel
        else
            log_error "Установка отменена пользователем"
            exit 1
        fi
        
    else
        # Запрос параметров для полной установки стека
        prompt_web_server
        prompt_php_version
        prompt_database
        prompt_domain
        prompt_db_credentials
        prompt_ssl
        prompt_swap
        
        # Отображение и подтверждение настроек
        display_summary
        
        # Установка стека
        install_stack
    fi
    
    echo -e "${GREEN}Операция завершена!${NC}"
    
    if [[ "$OPERATION" == "install_stack" ]]; then
        echo "Веб-сервер:        ${WEB_SERVER}"
        echo "Версия PHP:        ${PHP_VERSION}"
        echo "СУБД:              ${DATABASE} ${DB_VERSION}"
        echo "Домен:             ${DOMAIN}"
        echo "Директория сайта:  ${SITE_DIR}"
        
        if [[ "$CREATE_DB" == true ]]; then
            echo -e "${YELLOW}Информация о базе данных:${NC}"
            echo "База данных:       ${DB_NAME}"
            echo "Пользователь БД:   ${DB_USER}"
            echo "Пароль БД:         ${DB_PASS}"
            echo -e "${YELLOW}ВАЖНО: Сохраните эти данные в безопасном месте!${NC}"
        fi
        
        echo ""
        echo "Вы можете просмотреть лог операции: ${LOG_FILE}"
        echo ""
        
        if [[ "$DOMAIN" != "localhost" ]]; then
            echo "Ваш сайт доступен по адресу: http://${DOMAIN}"
            if [[ "$ENABLE_SSL" == true ]]; then
                echo "Защищенный доступ: https://${DOMAIN}"
            fi
        else
            echo "Ваш сайт доступен по адресу: http://localhost"
        fi
    elif [[ "$OPERATION" == "add_site" ]]; then
        echo "Домен:             ${DOMAIN}"
        echo "Директория сайта:  ${SITE_DIR}"
        
        if [[ "$CREATE_DB" == true ]]; then
            echo -e "${YELLOW}Информация о базе данных:${NC}"
            echo "База данных:       ${DB_NAME}"
            echo "Пользователь БД:   ${DB_USER}"
            echo "Пароль БД:         ${DB_PASS}"
            echo -e "${YELLOW}ВАЖНО: Сохраните эти данные в безопасном месте!${NC}"
        fi
        
        echo ""
        echo "Вы можете просмотреть лог операции: ${LOG_FILE}"
        echo ""
        
        if [[ "$DOMAIN" != "localhost" ]]; then
            echo "Ваш сайт доступен по адресу: http://${DOMAIN}"
            if [[ "$ENABLE_SSL" == true ]]; then
                echo "Защищенный доступ: https://${DOMAIN}"
            fi
        else
            echo "Ваш сайт доступен по адресу: http://localhost"
        fi
    elif [[ "$OPERATION" == "install_panel" ]]; then
        echo "Панель управления: ${PANEL_TYPE}"
        echo ""
        echo "Вы можете просмотреть лог операции: ${LOG_FILE}"
    fi
    
    echo ""
    echo -e "${GREEN}Спасибо за использование LEMP/LAMP Stack!${NC}"
}


#=====================================================================
# Дополнительная функция для удаления всего стека
#=====================================================================

show_help() {
    echo "Использование: $0 [ОПЦИИ]"
    echo ""
    echo "Без параметров: Запуск в интерактивном режиме"
    echo ""
    echo "Опции:"
    echo "  --uninstall    Удаление всех установленных компонентов LEMP/LAMP стека"
    echo "  --stack        Только установка LEMP/LAMP стека (без меню выбора панелей)"
    echo "  --panel TYPE   Установка указанной панели управления (ispmanager, hestia, fastpanel, aapanel)"
    echo "  --help         Показать эту справку"
    echo ""
}

# Обновленная обработка параметров командной строки
if [[ $# -gt 0 ]]; then
    case "$1" in
        --uninstall)
            check_root
            detect_os
            if prompt_yes_no "Вы уверены, что хотите удалить все компоненты LEMP/LAMP стека?" "n"; then
                uninstall_stack
            else
                echo "Удаление отменено."
            fi
            exit 0
            ;;
        --stack)
            OPERATION="install_stack"
            ;;
        --panel)
            OPERATION="install_panel"
            if [[ -n "$2" && ("$2" == "ispmanager" || "$2" == "hestia" || "$2" == "fastpanel" || "$2" == "aapanel") ]]; then
                PANEL_TYPE="$2"
            else
                echo "Укажите тип панели: ispmanager, hestia, fastpanel или aapanel"
                echo "Например: $0 --panel hestia"
                exit 1
            fi
            ;;
        --help)
            show_help
            exit 0
            ;;
        *)
            echo "Неизвестный параметр: $1"
            show_help
            exit 1
            ;;
    esac
fi

# Запуск основной функции
main