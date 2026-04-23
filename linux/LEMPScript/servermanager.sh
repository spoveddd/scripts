#!/usr/bin/env bash
#=====================================================================
# Server Manager — LEMP/LAMP provisioning tool
#=====================================================================
# Автор:      Павлович Владислав — pavlovich.blog
# Поддержка:  TG @sysadminctl
# Версия:     3.1.2
#
# Ключевые возможности v3.1:
#   * First-run wizard + главное меню (multi-level submenus)
#     - Wizard (5 шагов) при первом запуске: update → swap → firewall
#       → выбор стек/панель → установка
#     - Главное меню при последующих: Сайты / PHP / БД / Система / Обслуживание
#   * Multi-PHP: одновременная установка PHP 7.4 / 8.0 / 8.1 / 8.2 /
#     8.3 / 8.4 / 8.5 с одной "нативной" (default) версией
#   * Per-site PHP version и выбор backend-handler'а:
#       - php-fpm          (Nginx → PHP-FPM, самый быстрый)
#       - apache-mod-php   (Nginx → Apache + mod_php, .htaccess ok)
#       - apache-php-fpm   (Nginx → Apache → PHP-FPM, .htaccess + любая версия)
#   * Per-site state в /etc/servermanager/sites/<domain>.conf
#   * Panel installers: запуск официальных installer'ов без модификаций
#   * Идемпотентные операции (managed-блоки, проверки, без дублей)
#   * SSH-port detection перед настройкой firewall
#   * SELinux: автоматический fcontext/restorecon на RHEL
#   * Credentials в защищённый файл, не в stdout
#   * Non-interactive режим через env-vars для CI/CD
#
# Поддерживаемые ОС:
#   * Ubuntu 20.04 / 22.04 / 24.04
#   * Debian 11 / 12
#   * Rocky / AlmaLinux 8 / 9
#=====================================================================

# Строгий режим выполнения.
# НЕ используем -E: ERR trap при -E наследуется в функции и command substitution,
# и срабатывает на легитимные возвраты ≠0 (напр. `grep` без совпадения в state_get).
# Это каскадно ломает функции, которые штатно возвращают "ключ не найден" / "нет".
# `-e` + top-level trap ERR достаточен: падение любой функции, вызванной без
# защиты (|| true, if ..., &&/||), всё равно срабатывает на верхнем уровне.
set -euo pipefail

# Версия
SM_VERSION="3.4.0"
SM_STATE_FORMAT="1"
SM_SITE_FORMAT="1"

#=====================================================================
# Цвета (tty-aware)
#=====================================================================
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'
    CYAN=$'\033[0;36m'
    BOLD=$'\033[1m'
    NC=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''
fi

#=====================================================================
# Пути и переменные
#=====================================================================
SM_DIR="/etc/servermanager"
SM_SITES_DIR="${SM_DIR}/sites"
SM_STATE_FILE="${SM_DIR}/state.conf"
SM_CRED_DIR="/root/.servermanager"
LOG_FILE="/var/log/servermanager.log"

# Поддерживаемые версии PHP
SUPPORTED_PHP_VERSIONS=("7.4" "8.0" "8.1" "8.2" "8.3" "8.4" "8.5")

# Маркер managed-блоков
SM_MARK_BEGIN="# >>> servermanager managed block >>>"
SM_MARK_END="# <<< servermanager managed block <<<"

# Runtime переменные (заполняются в ходе работы)
OS_TYPE=""          # debian | rhel
OS_ID=""            # ubuntu | debian | rocky | almalinux
OS_VERSION=""       # 22.04 | 12 | 9
OS_CODENAME=""      # jammy | bookworm | ""
PKG_MGR=""          # apt | dnf | yum
SVC_MGR="systemctl"

# Параметры операции (заполняются в prompts)
OPERATION=""
WEB_SERVER=""           # nginx | apache | nginx_apache
DATABASE=""             # mariadb | mysql
DB_VERSION=""
PHP_DEFAULT=""          # версия PHP по умолчанию
PHP_TO_INSTALL=()       # массив версий PHP для установки
DOMAIN=""
SITE_DIR=""
SITE_PHP_VERSION=""
SITE_BACKEND=""         # php-fpm | apache-mod-php | apache-php-fpm
ENABLE_SSL=false
SSL_EMAIL=""
SITE_WWW_ALIAS=true
ENABLE_SWAP=false
SWAP_SIZE="2G"
CREATE_DB=false
DB_NAME=""
DB_USER=""
DB_PASS=""
DB_ROOT_PASS=""

#=====================================================================
# Logging
#=====================================================================
# Регулярка для strip ANSI-escape (цвета и форматирование) при записи в лог-файл.
_SM_ANSI_STRIP_SED='s/\x1b\[[0-9;]*[A-Za-z]//g'

log() {
    local ts msg clean
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    msg="${ts} $*"
    # В консоль — с цветами (если tty), в лог-файл — без ANSI.
    printf '%b\n' "$msg" >&2
    clean=$(printf '%b' "$msg" | sed -E "$_SM_ANSI_STRIP_SED")
    printf '%s\n' "$clean" >> "${LOG_FILE}"
}
log_info()    { log "${BLUE}[INFO]${NC}    $*"; }
log_ok()      { log "${GREEN}[OK]${NC}      $*"; }
log_warn()    { log "${YELLOW}[WARN]${NC}    $*"; }
log_error()   { log "${RED}[ERROR]${NC}   $*"; }
log_section() {
    # Пустая строка-разделитель без timestamp
    echo >> "${LOG_FILE}"
    echo >&2
    log "${BOLD}${CYAN}=== $* ===${NC}"
}

# Обработчик ошибок: при падении показываем хвост лога
_error_trap() {
    local rc=$?
    local line=$1
    echo >&2
    log_error "==================================================="
    log_error "Скрипт прерван (exit=${rc}) на строке ${line}"
    if [[ -f "$LOG_FILE" ]]; then
        log_error "Последние 30 строк лога:"
        echo >&2
        tail -n 30 "$LOG_FILE" | sed 's/^/    /' >&2
        echo >&2
    fi
    log_error "Полный лог: ${LOG_FILE}"
    log_error "==================================================="
    exit "$rc"
}
trap '_error_trap $LINENO' ERR

#=====================================================================
# Package manager helpers: подавляем шумный вывод apt/yum, ошибки
# и stdout уходят в LOG_FILE. Команды ведут себя неинтерактивно.
#=====================================================================

# Обновить индексы пакетов
pkg_update() {
    if [[ "$OS_TYPE" == "debian" ]]; then
        if [[ "${SM_SHOW_PKG_PROGRESS:-0}" == "1" && -t 1 ]]; then
            local rc=0
            DEBIAN_FRONTEND=noninteractive apt-get update 2>&1 | tee -a "$LOG_FILE" || rc=${PIPESTATUS[0]}
            return "$rc"
        fi
        DEBIAN_FRONTEND=noninteractive apt-get update >>"$LOG_FILE" 2>&1
    else
        if [[ "${SM_SHOW_PKG_PROGRESS:-0}" == "1" && -t 1 ]]; then
            $PKG_MGR check-update 2>&1 | tee -a "$LOG_FILE" || true
            return 0
        fi
        $PKG_MGR check-update >>"$LOG_FILE" 2>&1 || true
    fi
}

# Установить пакеты (без шумного вывода, не зависает на prompts)
pkg_install() {
    if [[ "$OS_TYPE" == "debian" ]]; then
        if [[ "${SM_SHOW_PKG_PROGRESS:-0}" == "1" && -t 1 ]]; then
            local rc=0
            DEBIAN_FRONTEND=noninteractive apt-get install -y --show-progress \
                -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold" \
                "$@" 2>&1 | tee -a "$LOG_FILE" || rc=${PIPESTATUS[0]}
            return "$rc"
        fi
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
            "$@" >>"$LOG_FILE" 2>&1
    else
        if [[ "${SM_SHOW_PKG_PROGRESS:-0}" == "1" && -t 1 ]]; then
            local rc=0
            $PKG_MGR install -y "$@" 2>&1 | tee -a "$LOG_FILE" || rc=${PIPESTATUS[0]}
            return "$rc"
        fi
        $PKG_MGR install -y "$@" >>"$LOG_FILE" 2>&1
    fi
}

# Удалить пакеты (точные имена)
pkg_purge() {
    if [[ "$OS_TYPE" == "debian" ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y "$@" >>"$LOG_FILE" 2>&1
    else
        $PKG_MGR remove -y "$@" >>"$LOG_FILE" 2>&1
    fi
}

# Удалить пакеты по glob-шаблонам. Принимает паттерны вида "php7.4*", "mariadb-*".
# apt-get / dnf НЕ раскрывают shell glob в кавычках — раскрываем сами через
# dpkg-query / rpm, передаём в purge явный список имён.
pkg_purge_glob() {
    local -a patterns=("$@") matches=() pkg
    (( ${#patterns[@]} == 0 )) && return 0

    if [[ "$OS_TYPE" == "debian" ]]; then
        # dpkg-query поддерживает shell-style globbing при --show
        local pat
        for pat in "${patterns[@]}"; do
            while IFS= read -r pkg; do
                [[ -n "$pkg" ]] && matches+=("$pkg")
            done < <(dpkg-query -W -f='${Package}\n' "$pat" 2>/dev/null || true)
        done
    else
        # RHEL: rpm -qa принимает glob
        local pat
        for pat in "${patterns[@]}"; do
            while IFS= read -r pkg; do
                [[ -n "$pkg" ]] && matches+=("$pkg")
            done < <(rpm -qa --qf '%{NAME}\n' "$pat" 2>/dev/null || true)
        done
    fi

    (( ${#matches[@]} == 0 )) && { log_info "pkg_purge_glob: ничего не найдено для: ${patterns[*]}"; return 0; }

    # Дедуп
    local -A seen=()
    local -a uniq=()
    for pkg in "${matches[@]}"; do
        [[ -z "${seen[$pkg]:-}" ]] && { seen[$pkg]=1; uniq+=("$pkg"); }
    done

    log_info "pkg_purge_glob: удаляю ${#uniq[@]} пакетов: ${uniq[*]}"
    pkg_purge "${uniq[@]}"
}

# Автоудаление и очистка кэша
pkg_cleanup() {
    if [[ "$OS_TYPE" == "debian" ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >>"$LOG_FILE" 2>&1 || true
        apt-get clean >>"$LOG_FILE" 2>&1 || true
    else
        $PKG_MGR autoremove -y >>"$LOG_FILE" 2>&1 || true
        $PKG_MGR clean all >>"$LOG_FILE" 2>&1 || true
    fi
}

cleanup_pkgs() { pkg_cleanup; }

# Полное обновление системы
pkg_upgrade_all() {
    if [[ "$OS_TYPE" == "debian" ]]; then
        if [[ "${SM_SHOW_PKG_PROGRESS:-0}" == "1" && -t 1 ]]; then
            local rc=0
            DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --show-progress \
                -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold" \
                2>&1 | tee -a "$LOG_FILE" || rc=${PIPESTATUS[0]}
            return "$rc"
        fi
        DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
            >>"$LOG_FILE" 2>&1
    else
        if [[ "${SM_SHOW_PKG_PROGRESS:-0}" == "1" && -t 1 ]]; then
            local rc=0
            $PKG_MGR upgrade -y 2>&1 | tee -a "$LOG_FILE" || rc=${PIPESTATUS[0]}
            return "$rc"
        fi
        $PKG_MGR upgrade -y >>"$LOG_FILE" 2>&1
    fi
}

#=====================================================================
# Служебные helpers
#=====================================================================

# Бэкап конфигурационных файлов
backup_config() {
    local file="$1"
    local backup_dir="${SM_DIR}/backups"
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    
    [[ -f "$file" ]] || return 0
    
    mkdir -p "$backup_dir"
    local backup_file="${backup_dir}/$(basename "$file").${timestamp}.backup"
    
    cp "$file" "$backup_file" >>"$LOG_FILE" 2>&1 || {
        log_warn "Не удалось создать бэкап файла $file"
        return 1
    }
    
    log_info "Создан бэкап: $backup_file"
    
    # Удаляем старые бэкапы (оставляем последние 10)
    find "$backup_dir" -name "$(basename "$file")*.backup" -type f | \
        sort -r | tail -n +11 | xargs -r rm -f
    
    return 0
}

# Восстановление из бэкапа
restore_config() {
    local file="$1"
    local backup_dir="${SM_DIR}/backups"
    
    local latest_backup
    latest_backup=$(find "$backup_dir" -name "$(basename "$file")*.backup" -type f | \
        sort -r | head -n1)
    
    [[ -n "$latest_backup" ]] || {
        log_error "Бэкап для $file не найден"
        return 1
    }
    
    log_info "Восстанавливаю $file из бэкапа $latest_backup"
    cp "$latest_backup" "$file" >>"$LOG_FILE" 2>&1 || {
        log_error "Не удалось восстановить $file"
        return 1
    }
    
    return 0
}

# Проверка целостности конфигурации после изменений
validate_config_integrity() {
    local domain="$1"
    local nginx_conf="/etc/nginx/sites-enabled/${domain}.conf"
    local php_version
    local backend
    
    # Проверяем Nginx конфиг
    if ! nginx -t >>"$LOG_FILE" 2>&1; then
        log_error "Nginx конфигурация невалидна"
        return 1
    fi
    
    # Получаем актуальную версию PHP и бэкенд сайта
    if load_site_config "$domain" 2>/dev/null; then
        php_version="$PHP_VERSION"
        backend="$BACKEND"
    else
        log_error "Не удалось загрузить конфигурацию сайта $domain"
        return 1
    fi
    
    # Проверяем PHP-FPM сокет только для PHP-FPM бэкендов
    if [[ "$backend" == "php-fpm" || "$backend" == "apache-php-fpm" ]]; then
        if ! validate_php_fpm_socket "$php_version" "$domain"; then
            log_error "PHP-FPM сокет недоступен для $domain (PHP $php_version)"
            return 1
        fi
    fi
    
    # Проверяем права доступа к директории сайта
    local doc_root="$DOCUMENT_ROOT"
    [[ -d "$doc_root" ]] && [[ -r "$doc_root" ]] || {
        log_error "Директория сайта $doc_root недоступна"
        return 1
    }
    
    return 0
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Запустите скрипт с правами root (sudo).${NC}" >&2
        exit 1
    fi
}

#=====================================================================
# Concurrency guard + graceful interrupt handling
#=====================================================================

SM_LOCK_FILE="${SM_LOCK_FILE:-/var/run/servermanager.lock}"
SM_LOCK_FD=""           # FD, на котором держим блокировку
SM_INTERRUPTED=0        # Поднимается trap'ом при Ctrl+C
declare -a SM_ROLLBACK_ACTIONS=()  # Стек команд для отката

# Регистрирует команду отката. Выполняется в обратном порядке при сбое / прерывании.
# Использование:
#   register_rollback "rm -rf /var/www/${domain}"
#   register_rollback "drop_database ${DB_NAME}"
register_rollback() {
    SM_ROLLBACK_ACTIONS+=("$1")
}

# Сбрасывает очередь отката (вызывать после успешного завершения защищённой операции).
clear_rollback() {
    SM_ROLLBACK_ACTIONS=()
}

# Выполняет зарегистрированные rollback-действия в обратном порядке.
run_rollback() {
    local reason="${1:-неизвестная причина}"
    if (( ${#SM_ROLLBACK_ACTIONS[@]} == 0 )); then
        return 0
    fi
    log_warn "Откат частично выполненных изменений (${reason})..."
    local i action
    for (( i=${#SM_ROLLBACK_ACTIONS[@]}-1; i>=0; i-- )); do
        action="${SM_ROLLBACK_ACTIONS[$i]}"
        log_info "  rollback: ${action}"
        eval "$action" >>"$LOG_FILE" 2>&1 || log_warn "    (шаг отката вернул ошибку — см. лог)"
    done
    clear_rollback
}

# Захватывает эксклюзивную блокировку на время работы скрипта.
# Если лок уже удерживается — ждёт до 10 секунд, затем падает с понятным сообщением.
acquire_lock() {
    if ! command_exists flock; then
        log_warn "flock недоступен — concurrency guard отключён (установите util-linux)"
        return 0
    fi
    local lock_dir
    lock_dir="$(dirname "$SM_LOCK_FILE")"
    mkdir -p "$lock_dir" 2>/dev/null || true
    # Открываем FD 200 на lockfile (динамическое eval для указания FD)
    exec 200>"$SM_LOCK_FILE" || {
        log_warn "Не удалось открыть lockfile ${SM_LOCK_FILE} — guard отключён"
        return 0
    }
    SM_LOCK_FD=200
    if ! flock -w 10 200; then
        log_error "Другой экземпляр servermanager уже работает (lock: ${SM_LOCK_FILE})"
        log_error "Если вы уверены, что это ошибка — удалите lockfile вручную."
        exit 1
    fi
    # Записываем PID внутрь (для диагностики: lsof / cat)
    echo "$$" >&200 2>/dev/null || true
}

# Unified cleanup: trap ERR / EXIT / INT / TERM.
sm_cleanup_on_interrupt() {
    SM_INTERRUPTED=1
    echo >&2
    log_warn "Получен сигнал прерывания — останавливаюсь и откатываю изменения..."
    run_rollback "прерывание (Ctrl+C / TERM)"
    # Лок снимется автоматически при exit через закрытие FD.
    exit 130
}

sm_cleanup_on_exit() {
    local rc=$?
    # Откат выполняется ТОЛЬКО если были незачищенные действия (значит защищённая операция не завершилась).
    if (( ${#SM_ROLLBACK_ACTIONS[@]} > 0 )) && (( rc != 0 )) && (( SM_INTERRUPTED == 0 )); then
        run_rollback "ошибка выполнения (exit=${rc})"
    fi
    # flock освобождается автоматически при закрытии FD (bash сам закрывает).
}

# Регистрируем сигналы. ERR trap уже есть выше, здесь добавляем INT/TERM/EXIT.
trap 'sm_cleanup_on_interrupt' INT TERM
trap 'sm_cleanup_on_exit' EXIT

#=====================================================================
# Система безопасности и изоляции сайтов
#=====================================================================

# Настройка безопасности для нового сайта
setup_site_security() {
    local domain="$1" doc_root="$2"
    local site_user="www_${domain//./_}"
    
    log_info "Настраиваю безопасность для сайта ${domain}..."
    echo "  • Создание пользователя сайта: $site_user"
    
    # Создаем отдельного пользователя для сайта (опционально, для изоляции)
    if ! id "$site_user" >/dev/null 2>&1; then
        if useradd -r -s /usr/sbin/nologin -d "$doc_root" "$site_user" 2>/dev/null; then
            echo "    ✓ Пользователь $site_user создан"
        else
            echo "    ! Предупреждение: Не удалось создать пользователя $site_user"
            log_warn "Не удалось создать пользователя $site_user"
        fi
    else
        echo "    ✓ Пользователь $site_user уже существует"
    fi
    
    echo "  • Настройка прав доступа к директориям"
    # Устанавливаем правильные права доступа
    if chown -R www-data:www-data "$doc_root" 2>/dev/null; then
        echo "    ✓ Владелец директорий: www-data:www-data"
    elif chown -R nginx:nginx "$doc_root" 2>/dev/null; then
        echo "    ✓ Владелец директорий: nginx:nginx"
    fi
    
    if find "$doc_root" -type d -exec chmod 755 {} \; 2>/dev/null; then
        echo "    ✓ Права директорий: 755"
    fi
    if find "$doc_root" -type f -exec chmod 644 {} \; 2>/dev/null; then
        echo "    ✓ Права файлов: 644"
    fi
    
    echo "  • Создание файлов безопасности"
    
    # Создаем .htaccess с базовой защитой
    if cat > "${doc_root}/.htaccess" <<'EOF'
# Server Manager Security Configuration
# Базовая защита сайта

# Запрет доступа к конфигурационным файлам
<FilesMatch "\.(conf|config|ini|log|sh|sql)$">
    Require all denied
</FilesMatch>

# Запрет доступа к .git и .svn
<DirectoryMatch "\/(git|svn|bzr)">
    Require all denied
</DirectoryMatch>

# Защита от XSS
<IfModule mod_headers.c>
    Header always set X-Content-Type-Options nosniff
    Header always set X-Frame-Options SAMEORIGIN
    Header always set X-XSS-Protection "1; mode=block"
</IfModule>

# Скрытие версии PHP
<IfModule php_module>
    php_flag expose_php off
</IfModule>
EOF
    then
        echo "    ✓ Файл .htaccess создан с защитными правилами"
    fi

    # Создаем robots.txt
    if cat > "${doc_root}/robots.txt" <<'EOF'
User-agent: *
Disallow: /admin/
Disallow: /wp-admin/
Disallow: /wp-includes/
Disallow: /wp-content/plugins/
Disallow: /wp-content/themes/
Disallow: /config/
Disallow: /.git/
Disallow: /.svn/
Disallow: /*.log$
Disallow: /*.conf$

Allow: /wp-content/uploads/
Allow: /wp-admin/admin-ajax.php

Sitemap: https://%DOMAIN%/sitemap.xml
EOF
    then
        # Заменяем плейсхолдер домена
        sed -i "s/%DOMAIN%/$domain/g" "${doc_root}/robots.txt"
        echo "    ✓ Файл robots.txt создан"
    fi
    
    echo
    log_ok "Безопасность для сайта ${domain} настроена"
    echo "  • Защищенные файлы: .htaccess, robots.txt"
    echo "  • Ограниченный доступ к конфигурационным файлам"
    echo "  • Защита от XSS атак"
    echo "  • Скрытие версии PHP"
}

# Мониторинг ресурсов сайта
check_site_resources() {
    local domain="$1"
    local access_log="/var/log/nginx/${domain}.access.log"
    local error_log="/var/log/nginx/${domain}.error.log"
    
    echo -e "${CYAN}Статистика сайта: ${domain}${NC}"
    
    # Анализ access log за последние 24 часа.
    # Парсим поле [time_local] в combined-формате nginx: `IP - - [DD/Mon/YYYY:HH:MM:SS +ZZZZ] "..."`
    # через gawk mktime — надёжнее, чем -mtime, который проверяет mtime файла целиком.
    if [[ -f "$access_log" ]]; then
        # AWK считает hits / unique IPs / traffic за последние 86400 секунд.
        local stats
        stats=$(awk -v now="$(date +%s)" '
            BEGIN{FS=" "; MONTHS="Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec"; split(MONTHS, m, " "); for(i=1;i<=12;i++) mi[m[i]]=i}
            {
                # Ищем [DD/Mon/YYYY:HH:MM:SS +ZZZZ] — берём 4-е поле (может содержать "[")
                if ($4 !~ /^\[/) next
                ts=$4; sub(/^\[/, "", ts)
                # ts = DD/Mon/YYYY:HH:MM:SS
                split(ts, p, "[/:]")
                if (length(p) < 6) next
                mon=mi[p[2]]; if (mon=="") next
                t=mktime(p[3]" "mon" "p[1]" "p[4]" "p[5]" "p[6])
                if (t <= 0) next
                if (now - t > 86400) next
                hits++
                ips[$1]=1
                # $10 — body_bytes_sent в combined-формате. Может быть "-"
                if ($10 ~ /^[0-9]+$/) bytes += $10
            }
            END{
                uniq=0; for(ip in ips) uniq++
                printf "%d|%d|%.2f", hits+0, uniq+0, (bytes/1024/1024)
            }
        ' "$access_log" 2>/dev/null || echo "0|0|0.00")

        local hits_today unique_ips bandwidth_mb
        hits_today="$(echo "$stats" | cut -d'|' -f1)"
        unique_ips="$(echo "$stats" | cut -d'|' -f2)"
        bandwidth_mb="$(echo "$stats" | cut -d'|' -f3)"

        printf "  📈 Запросов за 24ч: ${BOLD}%s${NC}\n" "$hits_today"
        printf "  👥 Уникальных IP: ${BOLD}%s${NC}\n" "$unique_ips"
        printf "  📊 Трафик за 24ч: ${BOLD}%s MB${NC}\n" "$bandwidth_mb"
    fi

    # Проверка ошибок за 24 часа.
    # nginx error_log формат: `YYYY/MM/DD HH:MM:SS [level] ...` — парсим первые два поля.
    if [[ -f "$error_log" ]]; then
        local errors_today
        errors_today=$(awk -v now="$(date +%s)" '
            {
                if ($1 !~ /^[0-9]{4}\// || $2 !~ /^[0-9]{2}:/) next
                split($1, d, "/"); split($2, t, ":")
                ts=mktime(d[1]" "d[2]+0" "d[3]+0" "t[1]+0" "t[2]+0" "t[3]+0)
                if (ts <= 0) next
                if (now - ts <= 86400) cnt++
            }
            END{print cnt+0}
        ' "$error_log" 2>/dev/null || echo "0")
        if (( errors_today > 0 )); then
            printf "  ⚠️  Ошибок за 24ч: ${RED}%s${NC}\n" "$errors_today"
            echo -e "${YELLOW}Последние ошибки:${NC}"
            tail -n 5 "$error_log" 2>/dev/null | sed 's/^/    /' || true
        else
            printf "  ✅ Ошибок за 24ч: ${GREEN}0${NC}\n"
        fi
    fi
    echo
}

# Проверка SSL сертификатов.
# Сканирует оба пути: /etc/letsencrypt/live (certbot) и /etc/ssl/acme (acme.sh).
check_ssl_certificates() {
    echo -e "${CYAN}Статус SSL сертификатов:${NC}"

    local total_certs=0
    local expired_certs=0
    local expiring_soon=0
    local -a cert_files=()

    # acme.sh: /etc/ssl/acme/<domain>.fullchain.cer
    if [[ -d "${SM_ACME_SSL_DIR:-/etc/ssl/acme}" ]]; then
        local f
        for f in "${SM_ACME_SSL_DIR:-/etc/ssl/acme}"/*.fullchain.cer; do
            [[ -f "$f" ]] && cert_files+=("$f")
        done
    fi

    # certbot (legacy): /etc/letsencrypt/live/<domain>/fullchain.pem
    if [[ -d "/etc/letsencrypt/live" ]]; then
        while IFS= read -r -d '' cert_dir; do
            local cf="${cert_dir}/fullchain.pem"
            [[ -f "$cf" ]] && cert_files+=("$cf")
        done < <(find "/etc/letsencrypt/live" -maxdepth 1 -mindepth 1 -type d ! -name "letsencrypt" -print0 2>/dev/null)
    fi

    if (( ${#cert_files[@]} == 0 )); then
        echo "  [X] Нет SSL-сертификатов (ни в acme.sh, ни в certbot/legacy)"
        echo "  Выпустить: sudo $0 --issue-ssl <domain>"
        return 0
    fi

    local cert_file domain expiry_date expiry_timestamp current_timestamp days_until_expiry
    for cert_file in "${cert_files[@]}"; do
        # Извлекаем имя домена из пути.
        if [[ "$cert_file" == */fullchain.pem ]]; then
            # certbot: /etc/letsencrypt/live/example.com/fullchain.pem
            domain="$(basename "$(dirname "$cert_file")")"
        else
            # acme.sh: /etc/ssl/acme/example.com.fullchain.cer
            domain="$(basename "$cert_file" .fullchain.cer)"
        fi

        total_certs=$((total_certs + 1))

        expiry_date="$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)"
        if [[ -z "$expiry_date" ]]; then
            printf "  [?] %s - не удалось прочитать срок действия\n" "$domain"
            continue
        fi
        expiry_timestamp="$(date -d "$expiry_date" +%s 2>/dev/null || echo "0")"
        current_timestamp="$(date +%s)"
        days_until_expiry=$(( (expiry_timestamp - current_timestamp) / 86400 ))

        if (( days_until_expiry < 0 )); then
            expired_certs=$((expired_certs + 1))
            printf "  [X] %s - истёк (%d дней назад)\n" "$domain" $((-days_until_expiry))
        elif (( days_until_expiry < 30 )); then
            expiring_soon=$((expiring_soon + 1))
            printf "  [!] %s - истекает через %d дней\n" "$domain" "$days_until_expiry"
        else
            printf "  [OK] %s - действителен %d дней\n" "$domain" "$days_until_expiry"
        fi
    done

    echo
    printf "  Всего сертификатов: ${BOLD}%d${NC}\n" "$total_certs"
    printf "  Истекшие: ${RED}%d${NC}\n" "$expired_certs"
    printf "  Истекают скоро: ${YELLOW}%d${NC}\n" "$expiring_soon"

    if (( expired_certs > 0 )); then
        echo
        echo "  ${YELLOW}ВНИМАНИЕ: Есть истекшие сертификаты!${NC}"
        echo "  Обновите: sudo $0 --issue-ssl <domain>"
    elif (( expiring_soon > 0 )); then
        echo
        echo "  ${YELLOW}ВНИМАНИЕ: Есть сертификаты, истекающие скоро.${NC}"
        echo "  acme.sh обновляет их автоматически через cron (см. 'crontab -l')."
    fi
    echo
}

#=====================================================================
# Система бэкапов (v3.3.0+): per-site архивы + системные конфиги
#
# Принципы:
# - БД через mysqldump --single-transaction (консистентный снимок InnoDB).
# - Файлы через tar.gz с exclude-паттернами для кэшей.
# - Хранение: /var/backups/servermanager/sites/<domain>/ и .../system/
# - Retention по умолчанию — 7 последних на сайт (SM_BACKUP_KEEP).
# - НЕ бэкапим /var/lib/mysql raw (раньше ломалось на живой БД).
# - НЕ бэкапим /root/.acme.sh (легче перевыпустить сертификаты).
#=====================================================================

SM_BACKUP_DIR="${SM_BACKUP_DIR:-/var/backups/servermanager}"
SM_BACKUP_KEEP="${SM_BACKUP_KEEP:-7}"

# Exclude-паттерны для tar (бесполезный шум, восстанавливается автоматически).
_SM_BACKUP_EXCLUDES=(
    --exclude='node_modules'
    --exclude='vendor/composer/tmp-*'
    --exclude='wp-content/cache'
    --exclude='wp-content/uploads/cache'
    --exclude='wp-content/upgrade'
    --exclude='*.log'
    --exclude='*.tmp'
    --exclude='.git'
    --exclude='.svn'
    --exclude='.cache'
    --exclude='__pycache__'
)

_backup_timestamp() { date '+%Y%m%d_%H%M%S'; }

# Человекочитаемый размер файла.
_human_size() {
    local bytes="${1:-0}"
    if command_exists numfmt; then
        numfmt --to=iec-i --suffix=B --format='%.1f' "$bytes" 2>/dev/null && return
    fi
    if (( bytes > 1073741824 )); then printf "%.1fG" "$(awk "BEGIN{print $bytes/1073741824}")"
    elif (( bytes > 1048576 )); then printf "%.1fM" "$(awk "BEGIN{print $bytes/1048576}")"
    elif (( bytes > 1024 )); then printf "%.1fK" "$(awk "BEGIN{print $bytes/1024}")"
    else printf "%dB" "$bytes"
    fi
}

# Ротация: оставить только SM_BACKUP_KEEP последних бэкапов в указанной директории.
_backup_rotate() {
    local dir="$1" pattern="$2"
    [[ -d "$dir" ]] || return 0
    local keep="${SM_BACKUP_KEEP:-7}"
    (( keep < 1 )) && keep=1

    # Сортируем по времени модификации (новые сверху), удаляем всё после keep-го.
    local -a old=()
    while IFS= read -r -d '' f; do
        old+=("$f")
    done < <(find "$dir" -maxdepth 1 -type f -name "$pattern" -printf '%T@\t%p\0' 2>/dev/null \
             | sort -z -rn -t$'\t' -k1 \
             | awk -v RS='\0' -v ORS='\0' -v n="$keep" 'NR>n{sub(/^[^\t]+\t/,""); print}')
    if (( ${#old[@]} > 0 )); then
        local o
        for o in "${old[@]}"; do
            rm -f "$o" "${o%.tar.gz}.meta" 2>/dev/null || true
            log_info "Ротация: удалён старый бэкап $(basename "$o")"
        done
    fi
}

# Дамп БД сайта через mysqldump. Читает креды из /root/.servermanager/db-<domain>.txt.
# Возвращает 0 и печатает путь к .sql.gz в stdout; 1 при ошибке.
_dump_site_db() {
    local domain="$1" out_dir="$2"
    local cred_file="${SM_CRED_DIR}/db-${domain}.txt"
    [[ -f "$cred_file" ]] || return 1

    local db_name db_user db_pass db_host
    db_name="$(kv_get_file "$cred_file" "DB_NAME")"
    db_user="$(kv_get_file "$cred_file" "DB_USER")"
    db_pass="$(kv_get_file "$cred_file" "DB_PASS")"
    db_host="$(kv_get_file "$cred_file" "DB_HOST")"
    [[ -z "$db_name" || -z "$db_user" ]] && return 1
    [[ -z "$db_host" ]] && db_host="127.0.0.1"

    local sql_file="${out_dir}/db.sql.gz"
    # --single-transaction: консистентный snapshot без блокировок на InnoDB
    # --quick: не держать всё в памяти (для больших таблиц)
    # --routines --triggers --events: включаем SP, триггеры
    # --set-gtid-purged=OFF: совместимость с MariaDB (безопасно ломается на MySQL без GTID)
    if MYSQL_PWD="$db_pass" mysqldump \
            --host="$db_host" --user="$db_user" \
            --single-transaction --quick --routines --triggers \
            --set-gtid-purged=OFF \
            --default-character-set=utf8mb4 \
            "$db_name" 2>>"$LOG_FILE" | gzip -c > "$sql_file"; then
        # Если вывод пустой (mysqldump упал после открытия pipe), считаем неудачей.
        if [[ ! -s "$sql_file" ]] || [[ "$(stat -c%s "$sql_file" 2>/dev/null || echo 0)" -lt 100 ]]; then
            rm -f "$sql_file"
            return 1
        fi
        echo "$sql_file"
        return 0
    fi
    rm -f "$sql_file"
    return 1
}

# Бэкап одного сайта. Создаёт: /var/backups/servermanager/sites/<domain>/<domain>_<ts>.tar.gz
create_site_backup() {
    local domain="$1"
    if [[ -z "$domain" ]]; then
        log_error "create_site_backup: нужен domain"
        return 1
    fi
    if ! load_site_config "$domain"; then
        log_error "Сайт ${domain} не найден"
        return 1
    fi

    local ts; ts="$(_backup_timestamp)"
    local dest_dir="${SM_BACKUP_DIR}/sites/${domain}"
    local workdir
    workdir="$(mktemp -d)"
    trap "rm -rf '$workdir'" RETURN

    mkdir -p "$dest_dir"
    chmod 700 "$dest_dir"
    chmod 700 "${SM_BACKUP_DIR}" 2>/dev/null || true

    local payload="${workdir}/${domain}_${ts}"
    mkdir -p "$payload"

    log_info "Бэкап сайта ${domain} → ${dest_dir}/${domain}_${ts}.tar.gz"

    # 1. Метаданные и конфиги
    cp -f "${SM_SITES_DIR}/${domain}.conf" "${payload}/site.conf" 2>/dev/null || true
    cp -f "/etc/nginx/sites-available/${domain}.conf" "${payload}/nginx.conf" 2>/dev/null || true
    if [[ "$OS_TYPE" == "debian" ]]; then
        cp -f "/etc/apache2/sites-available/${domain}.conf" "${payload}/apache.conf" 2>/dev/null || true
    else
        cp -f "/etc/httpd/conf.d/${domain}.conf" "${payload}/apache.conf" 2>/dev/null || true
    fi

    # FPM pool конфиг (если есть)
    local pool_file=""
    if [[ "$OS_TYPE" == "debian" ]]; then
        pool_file="/etc/php/${PHP_VERSION}/fpm/pool.d/${domain}.conf"
    else
        local scl="php${PHP_VERSION//./}"
        pool_file="/etc/opt/remi/${scl}/php-fpm.d/${domain}.conf"
    fi
    [[ -f "$pool_file" ]] && cp -f "$pool_file" "${payload}/fpm-pool.conf" || true

    # 2. Дамп БД
    local db_ok=false
    if [[ -n "${DB_NAME:-}" ]]; then
        echo "  • Дамп БД ${DB_NAME}..."
        if _dump_site_db "$domain" "$payload" >/dev/null; then
            db_ok=true
            local sz
            sz="$(stat -c%s "${payload}/db.sql.gz" 2>/dev/null || echo 0)"
            echo "    ✓ db.sql.gz ($(_human_size "$sz"))"
        else
            log_warn "mysqldump для ${DB_NAME} не удался — см. ${LOG_FILE}"
            echo "    ✗ БД пропущена"
        fi
    else
        echo "  • БД не настроена для сайта — пропускаю"
    fi

    # 3. Файлы сайта
    if [[ -d "$DOCUMENT_ROOT" ]]; then
        echo "  • Архивация ${DOCUMENT_ROOT}..."
        local files_tar="${payload}/files.tar"
        # tar с exclude; -C чтобы не тащить полный путь.
        # 2>> в лог, 1>/dev/null чтобы не засорять консоль.
        if tar -cf "$files_tar" "${_SM_BACKUP_EXCLUDES[@]}" \
                -C "$(dirname "$DOCUMENT_ROOT")" "$(basename "$DOCUMENT_ROOT")" \
                2>>"$LOG_FILE"; then
            local fsz
            fsz="$(stat -c%s "$files_tar" 2>/dev/null || echo 0)"
            echo "    ✓ files.tar ($(_human_size "$fsz"))"
        else
            log_warn "Архивация файлов сайта завершилась с предупреждением — см. ${LOG_FILE}"
        fi
    else
        log_warn "DOCUMENT_ROOT ${DOCUMENT_ROOT} не существует — архив без файлов"
    fi

    # 4. meta.json (плоский KV, без реальных JSON-зависимостей).
    cat > "${payload}/meta.txt" <<EOF
format_version=1
created_at=$(date -Iseconds)
sm_version=${SM_VERSION}
domain=${domain}
document_root=${DOCUMENT_ROOT:-}
php_version=${PHP_VERSION:-}
backend=${BACKEND:-}
ssl=${SSL:-false}
db_name=${DB_NAME:-}
db_user=${DB_USER:-}
db_included=$db_ok
www_alias=${WWW_ALIAS:-true}
EOF

    # 5. Упаковка всего payload в один tar.gz
    local final="${dest_dir}/${domain}_${ts}.tar.gz"
    if ! tar -czf "$final" -C "$workdir" "${domain}_${ts}" 2>>"$LOG_FILE"; then
        log_error "Не удалось упаковать финальный архив ${final}"
        return 1
    fi
    chmod 600 "$final"

    # 6. meta-файл рядом с архивом (для быстрого list без распаковки)
    local final_size
    final_size="$(stat -c%s "$final" 2>/dev/null || echo 0)"
    cat > "${dest_dir}/${domain}_${ts}.meta" <<EOF
domain=${domain}
timestamp=${ts}
created_at=$(date -Iseconds)
db_included=$db_ok
size_bytes=$final_size
sm_version=${SM_VERSION}
EOF
    chmod 600 "${dest_dir}/${domain}_${ts}.meta"

    log_ok "Бэкап готов: ${final} ($(_human_size "$final_size"))"

    _backup_rotate "$dest_dir" "${domain}_*.tar.gz"
    return 0
}

# Бэкап всех сайтов по очереди. Возвращает 0 если все успешны, 1 если хоть один упал.
backup_all_sites() {
    if ! compgen -G "${SM_SITES_DIR}/*.conf" > /dev/null; then
        log_warn "Сайтов не найдено в ${SM_SITES_DIR}"
        return 0
    fi
    local total=0 failed=0 f domain
    for f in "${SM_SITES_DIR}"/*.conf; do
        domain="$(kv_get_file "$f" "DOMAIN")"
        [[ -z "$domain" ]] && continue
        total=$((total + 1))
        if ! create_site_backup "$domain"; then
            failed=$((failed + 1))
            log_error "Бэкап сайта ${domain} не удался"
        fi
    done
    log_info "Бэкап всех сайтов: всего=${total}, успешно=$((total - failed)), ошибок=${failed}"
    (( failed == 0 ))
}

# Бэкап только системных конфигов (без сайтов). Полезно перед миграцией/отладкой.
# НЕ архивирует /var/lib/mysql raw — вместо этого делает mysqldump --all-databases.
create_system_backup() {
    local ts; ts="$(_backup_timestamp)"
    local dest_dir="${SM_BACKUP_DIR}/system"
    mkdir -p "$dest_dir"
    chmod 700 "$dest_dir"

    local workdir; workdir="$(mktemp -d)"
    trap "rm -rf '$workdir'" RETURN

    local payload="${workdir}/system_${ts}"
    mkdir -p "$payload"

    log_info "Системный бэкап → ${dest_dir}/system_${ts}.tar.gz"

    # 1. Конфиги (копируем целиком, без live-БД).
    local d
    for d in /etc/nginx /etc/apache2 /etc/httpd /etc/php /etc/mysql /etc/servermanager; do
        if [[ -d "$d" ]]; then
            mkdir -p "${payload}${d%/*}"
            cp -a "$d" "${payload}${d%/*}/" 2>>"$LOG_FILE" || log_warn "Не удалось скопировать $d"
        fi
    done

    # 2. Дамп всех БД (один .sql.gz)
    local root_pass=""
    if [[ -f "${SM_CRED_DIR}/db-root.txt" ]]; then
        root_pass="$(kv_get_file "${SM_CRED_DIR}/db-root.txt" "DB_ROOT_PASS")"
    fi
    if [[ -n "$root_pass" ]] && command_exists mysqldump; then
        echo "  • Дамп всех БД..."
        if MYSQL_PWD="$root_pass" mysqldump -u root \
                --all-databases --single-transaction --quick --routines --triggers --events \
                --set-gtid-purged=OFF 2>>"$LOG_FILE" \
                | gzip -c > "${payload}/all_databases.sql.gz"; then
            if [[ -s "${payload}/all_databases.sql.gz" ]]; then
                echo "    ✓ all_databases.sql.gz"
            else
                rm -f "${payload}/all_databases.sql.gz"
                log_warn "Дамп БД пустой — пропущен"
            fi
        else
            rm -f "${payload}/all_databases.sql.gz"
            log_warn "mysqldump --all-databases не удался"
        fi
    else
        log_info "Root-пароль БД не найден — пропускаю дамп"
    fi

    # 3. SSL (только acme.sh конфиг, сертификаты проще перевыпустить)
    if [[ -d /etc/ssl/acme ]]; then
        mkdir -p "${payload}/etc/ssl"
        cp -a /etc/ssl/acme "${payload}/etc/ssl/" 2>/dev/null || true
    fi

    # 4. meta
    cat > "${payload}/meta.txt" <<EOF
format_version=1
type=system
created_at=$(date -Iseconds)
sm_version=${SM_VERSION}
EOF

    local final="${dest_dir}/system_${ts}.tar.gz"
    if ! tar -czf "$final" -C "$workdir" "system_${ts}" 2>>"$LOG_FILE"; then
        log_error "Не удалось упаковать системный архив"
        return 1
    fi
    chmod 600 "$final"

    local sz; sz="$(stat -c%s "$final" 2>/dev/null || echo 0)"
    log_ok "Системный бэкап готов: ${final} ($(_human_size "$sz"))"
    _backup_rotate "$dest_dir" "system_*.tar.gz"
    return 0
}

# Список бэкапов: либо по конкретному сайту, либо всех сайтов + system.
list_backups() {
    local filter="${1:-}"
    echo -e "${CYAN}Бэкапы (${SM_BACKUP_DIR}):${NC}"

    if [[ ! -d "${SM_BACKUP_DIR}" ]]; then
        echo "  (директория не существует — бэкапов нет)"
        return 0
    fi

    local found=0
    local site_dir
    if [[ -n "$filter" ]]; then
        # Конкретный сайт
        site_dir="${SM_BACKUP_DIR}/sites/${filter}"
        if [[ ! -d "$site_dir" ]]; then
            echo "  (для сайта ${filter} бэкапов нет)"
            return 0
        fi
        echo -e "  ${BOLD}${filter}:${NC}"
        _list_dir "$site_dir" "${filter}_*.tar.gz" && found=1
    else
        # Все сайты + system
        if [[ -d "${SM_BACKUP_DIR}/sites" ]]; then
            local sd
            for sd in "${SM_BACKUP_DIR}/sites"/*/; do
                [[ -d "$sd" ]] || continue
                local dn; dn="$(basename "$sd")"
                echo -e "  ${BOLD}${dn}:${NC}"
                _list_dir "$sd" "${dn}_*.tar.gz" && found=1
            done
        fi
        if [[ -d "${SM_BACKUP_DIR}/system" ]]; then
            echo -e "  ${BOLD}system (configs + all DBs):${NC}"
            _list_dir "${SM_BACKUP_DIR}/system" "system_*.tar.gz" && found=1
        fi
    fi

    if (( found == 0 )); then
        echo "  (бэкапов не найдено)"
    fi
}

# Внутренний хелпер: печать таблицы по одной директории.
_list_dir() {
    local dir="$1" pattern="$2"
    [[ -d "$dir" ]] || return 1
    local any=0 f sz mtime
    while IFS= read -r -d '' f; do
        any=1
        sz="$(stat -c%s "$f" 2>/dev/null || echo 0)"
        mtime="$(stat -c%y "$f" 2>/dev/null | cut -d. -f1)"
        printf "    - %s  (%s, %s)\n" "$(basename "$f")" "$(_human_size "$sz")" "$mtime"
    done < <(find "$dir" -maxdepth 1 -type f -name "$pattern" -print0 2>/dev/null | sort -z -r)
    (( any == 1 ))
}

# Восстановление сайта из архива. Аргумент — путь к .tar.gz или краткое имя.
restore_site_backup() {
    local arg="$1"
    if [[ -z "$arg" ]]; then
        log_error "restore_site_backup: нужен путь к архиву"
        return 1
    fi

    local archive=""
    if [[ -f "$arg" ]]; then
        archive="$arg"
    elif [[ -f "${SM_BACKUP_DIR}/sites/${arg}" ]]; then
        archive="${SM_BACKUP_DIR}/sites/${arg}"
    else
        # Попробовать найти по префиксу домена
        local cand
        cand="$(find "${SM_BACKUP_DIR}/sites" -maxdepth 2 -type f -name "*${arg}*" 2>/dev/null | sort -r | head -n1)"
        [[ -n "$cand" ]] && archive="$cand"
    fi

    if [[ ! -f "$archive" ]]; then
        log_error "Архив не найден: $arg"
        return 1
    fi

    log_info "Восстановление из ${archive}"

    local workdir; workdir="$(mktemp -d)"
    trap "rm -rf '$workdir'" RETURN

    if ! tar -xzf "$archive" -C "$workdir" 2>>"$LOG_FILE"; then
        log_error "Не удалось распаковать архив"
        return 1
    fi

    # Payload — единственная директория внутри архива
    local payload
    payload="$(find "$workdir" -maxdepth 1 -mindepth 1 -type d | head -n1)"
    if [[ -z "$payload" || ! -f "${payload}/meta.txt" ]]; then
        log_error "Архив повреждён или не наш формат (нет meta.txt)"
        return 1
    fi

    local domain doc_root db_name db_included
    domain="$(kv_get_file "${payload}/meta.txt" "domain")"
    doc_root="$(kv_get_file "${payload}/meta.txt" "document_root")"
    db_name="$(kv_get_file "${payload}/meta.txt" "db_name")"
    db_included="$(kv_get_file "${payload}/meta.txt" "db_included")"

    if [[ -z "$domain" ]]; then
        log_error "В meta.txt нет поля domain — не могу восстановить"
        return 1
    fi

    log_warn "ВНИМАНИЕ: восстановление перезапишет:"
    log_warn "  - файлы в ${doc_root}"
    [[ "$db_included" == "true" && -n "$db_name" ]] && log_warn "  - БД ${db_name} (будет полностью заменена)"
    if ! prompt_yes_no "Продолжить восстановление сайта ${domain}?" "n"; then
        log_info "Восстановление отменено"
        return 0
    fi

    # 1. Файлы: распаковываем files.tar поверх текущих
    if [[ -f "${payload}/files.tar" && -n "$doc_root" ]]; then
        echo "  • Восстанавливаю файлы в ${doc_root}..."
        local parent; parent="$(dirname "$doc_root")"
        mkdir -p "$parent"
        # Удаляем текущие файлы сайта (по запросу)
        if prompt_yes_no "Сначала очистить ${doc_root} перед распаковкой?" "y"; then
            # Только если путь безопасный (не /, не /var/www целиком)
            if [[ "$doc_root" == /var/www/* && "$doc_root" != "/var/www" ]]; then
                rm -rf "${doc_root:?}"/* "${doc_root:?}"/.[!.]* 2>/dev/null || true
            else
                log_warn "Пропускаю очистку небезопасного пути"
            fi
        fi
        if tar -xf "${payload}/files.tar" -C "$parent" 2>>"$LOG_FILE"; then
            echo "    ✓ файлы восстановлены"
        else
            log_error "Распаковка files.tar завершилась с ошибкой"
        fi
        # Владелец
        if [[ "$OS_TYPE" == "debian" ]]; then
            chown -R www-data:www-data "$doc_root" 2>/dev/null || true
        else
            chown -R apache:apache "$doc_root" 2>/dev/null || true
        fi
    fi

    # 2. БД: восстанавливаем только если креды есть в системе
    if [[ "$db_included" == "true" && -f "${payload}/db.sql.gz" && -n "$db_name" ]]; then
        local cred_file="${SM_CRED_DIR}/db-${domain}.txt"
        if [[ -f "$cred_file" ]]; then
            local db_user db_pass db_host
            db_user="$(kv_get_file "$cred_file" "DB_USER")"
            db_pass="$(kv_get_file "$cred_file" "DB_PASS")"
            db_host="$(kv_get_file "$cred_file" "DB_HOST")"
            [[ -z "$db_host" ]] && db_host="127.0.0.1"
            echo "  • Восстановление БД ${db_name}..."
            if gunzip -c "${payload}/db.sql.gz" \
                | MYSQL_PWD="$db_pass" mysql --host="$db_host" --user="$db_user" "$db_name" 2>>"$LOG_FILE"; then
                echo "    ✓ БД восстановлена"
            else
                log_error "Ошибка импорта БД — см. ${LOG_FILE}"
            fi
        else
            log_warn "Учётки БД для ${domain} не найдены (${cred_file}) — БД пропущена"
            log_warn "Создайте сайт через add-site, затем запустите restore-site снова"
        fi
    fi

    # 3. Конфиги (опционально)
    if prompt_yes_no "Восстановить nginx/apache конфиги из архива (перезаписать текущие)?" "n"; then
        [[ -f "${payload}/nginx.conf" ]] && cp -f "${payload}/nginx.conf" "/etc/nginx/sites-available/${domain}.conf" || true
        if [[ "$OS_TYPE" == "debian" ]]; then
            [[ -f "${payload}/apache.conf" ]] && cp -f "${payload}/apache.conf" "/etc/apache2/sites-available/${domain}.conf" || true
        else
            [[ -f "${payload}/apache.conf" ]] && cp -f "${payload}/apache.conf" "/etc/httpd/conf.d/${domain}.conf" || true
        fi
        [[ -f "${payload}/site.conf" ]] && cp -f "${payload}/site.conf" "${SM_SITES_DIR}/${domain}.conf" || true
        if nginx -t >/dev/null 2>&1; then
            $SVC_MGR reload nginx >/dev/null 2>&1 || true
        else
            log_warn "nginx -t не прошёл с восстановленным конфигом — проверьте вручную"
        fi
    fi

    log_ok "Восстановление сайта ${domain} завершено"
    return 0
}

# Установка cron на ежедневный бэкап всех сайтов в 03:00.
backup_setup_cron() {
    local script_path
    script_path="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    local cron_line="0 3 * * * ${script_path} backup-all >> /var/log/servermanager-backup.log 2>&1"

    local current
    current="$(crontab -l 2>/dev/null || true)"
    if echo "$current" | grep -qF "${script_path} backup-all"; then
        log_info "Cron уже настроен:"
        echo "$current" | grep -F "${script_path} backup-all"
        return 0
    fi

    { echo "$current"; echo "$cron_line"; } | grep -v '^$' | crontab -
    log_ok "Cron установлен: ежедневный бэкап в 03:00"
    log_info "Лог автобэкапов: /var/log/servermanager-backup.log"
}

backup_remove_cron() {
    local script_path
    script_path="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    local current
    current="$(crontab -l 2>/dev/null || true)"
    if ! echo "$current" | grep -qF "${script_path} backup-all"; then
        log_info "Cron не настроен — нечего удалять"
        return 0
    fi
    echo "$current" | grep -vF "${script_path} backup-all" | crontab -
    log_ok "Cron для автобэкапа удалён"
}

#=====================================================================
# Система мониторинга производительности
#=====================================================================
monitor_server_performance() {
    echo -e "${CYAN}📈 Мониторинг производительности сервера:${NC}"
    
    # CPU
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | sed 's/%us,//' || echo "N/A")
    printf "  💻 CPU: ${YELLOW}%s%%${NC}\n" "$cpu_usage"
    
    # Память
    local mem_info=$(free | awk 'NR==2{printf "%.1f%%", $3*100/$2}')
    printf "  💾 RAM: ${YELLOW}%s${NC}\n" "$mem_info"
    
    # Диск
    local disk_usage=$(df / | awk 'NR==2 {print $5}')
    printf "  💿 Диск: ${YELLOW}%s${NC}\n" "$disk_usage"
    
    # Load Average
    local load_avg=$(uptime | awk -F'load average:' '{print $2}' | sed 's/^ *//')
    printf "  📊 Load: ${YELLOW}%s${NC}\n" "$load_avg"
    
    # Активные соединения
    local connections=$(ss -t | wc -l 2>/dev/null || echo "N/A")
    printf "  🔗 Соединений: ${YELLOW}%s${NC}\n" "$connections"
    
    echo
}

init_dirs() {
    mkdir -p "${SM_DIR}" "${SM_SITES_DIR}" "${SM_CRED_DIR}"
    chmod 700 "${SM_CRED_DIR}"
    touch "${LOG_FILE}"
    chmod 640 "${LOG_FILE}" || true
}

command_exists() { command -v "$1" &>/dev/null; }

#=====================================================================
# Safe parsing helpers (avoid "source" on writable files)
#=====================================================================

# Reads KEY=VALUE lines from a file without evaluating code.
# - strips surrounding single/double quotes
# - returns empty if key not found
kv_get_file() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 0
    awk -v k="$key" -F= '
        $0 ~ "^[[:space:]]*"k"[[:space:]]*=" {
            sub("^[[:space:]]*"k"[[:space:]]*=[[:space:]]*", "", $0)
            gsub("\r","",$0)
            # strip surrounding quotes
            if ($0 ~ /^".*"$/) { sub(/^"/,"",$0); sub(/"$/,"",$0) }
            else if ($0 ~ /^\x27.*\x27$/) { sub(/^\x27/,"",$0); sub(/\x27$/,"",$0) }
            print $0
        }
    ' "$file" | tail -n1
}

# Load site config safely into globals:
# DOMAIN DOCUMENT_ROOT PHP_VERSION BACKEND SSL DB_NAME DB_USER WWW_ALIAS CREATED_AT SITE_FORMAT
load_site_config() {
    local domain="$1"
    local f="${SM_SITES_DIR}/${domain}.conf"
    [[ -f "$f" ]] || return 1
    DOMAIN="$(kv_get_file "$f" "DOMAIN")"
    DOCUMENT_ROOT="$(kv_get_file "$f" "DOCUMENT_ROOT")"
    PHP_VERSION="$(kv_get_file "$f" "PHP_VERSION")"
    BACKEND="$(kv_get_file "$f" "BACKEND")"
    SSL="$(kv_get_file "$f" "SSL")"
    DB_NAME="$(kv_get_file "$f" "DB_NAME")"
    DB_USER="$(kv_get_file "$f" "DB_USER")"
    WWW_ALIAS="$(kv_get_file "$f" "WWW_ALIAS")"
    CREATED_AT="$(kv_get_file "$f" "CREATED_AT")"
    SITE_FORMAT="$(kv_get_file "$f" "SITE_FORMAT")"
    return 0
}

bool_is_true() {
    [[ "${1:-false}" == "true" ]] || [[ "${1:-false}" == "1" ]] || [[ "${1:-false}" == "y" ]] || [[ "${1:-false}" == "yes" ]]
}

site_server_names() {
    # site_server_names domain www_alias -> prints "domain www.domain" or "domain"
    local d="$1" www="${2:-true}"
    if bool_is_true "$www" && [[ "$d" != "localhost" ]] && [[ "$d" != www.* ]]; then
        printf "%s www.%s" "$d" "$d"
    else
        printf "%s" "$d"
    fi
}

apache_server_alias_line() {
    local d="$1" www="${2:-true}"
    if bool_is_true "$www" && [[ "$d" != "localhost" ]] && [[ "$d" != www.* ]]; then
        printf "    ServerAlias www.%s" "$d"
    else
        printf ""
    fi
}

ensure_php_installed_for_site() {
    local v="$1"
    if ! state_list_php | tr ' ' '\n' | grep -qxF "$v"; then
        log_error "PHP ${v} не установлен. Установите его в меню PHP (или через CLI install-php ${v})"
        return 1
    fi
    return 0
}

ensure_apache_mod_php() {
    # Ensure Apache + mod_php package for default PHP (Debian/Ubuntu).
    local default_php
    default_php="$(state_get default_php_version)"
    if [[ -z "$default_php" ]]; then
        log_error "Не задан default PHP. Сначала установите PHP и выберите default."
        return 1
    fi
    if [[ "$OS_TYPE" == "debian" ]]; then
        # Package name: libapache2-mod-phpX.Y
        local pkg="libapache2-mod-php${default_php}"
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            log_info "Устанавливаю ${pkg} для apache-mod-php..."
            pkg_install "$pkg" || { log_error "Не удалось установить ${pkg}"; return 1; }
        fi
    fi
    return 0
}

nginx_apply_site_conf() {
    # nginx_apply_site_conf domain tmp_conf final_conf
    local domain="$1" tmp_conf="$2" final_conf="$3"
    local enabled="/etc/nginx/sites-enabled/${domain}.conf"
    local prev_target=""
    if [[ -L "$enabled" ]]; then
        prev_target="$(readlink -f "$enabled" 2>/dev/null || true)"
    elif [[ -e "$enabled" ]]; then
        prev_target="__file__"
    fi

    ln -sf "$tmp_conf" "$enabled"
    rm -f /etc/nginx/sites-enabled/default
    if nginx -t >>"$LOG_FILE" 2>&1; then
        mv -f "$tmp_conf" "$final_conf"
        ln -sf "$final_conf" "$enabled"
        $SVC_MGR reload nginx >>"$LOG_FILE" 2>&1 || true
        return 0
    fi

    # rollback
    log_error "nginx -t не прошёл — откатываю изменения для ${domain}. Подробности в ${LOG_FILE}"
    if [[ "$prev_target" == "__file__" ]]; then
        rm -f "$enabled"
    elif [[ -n "$prev_target" ]]; then
        ln -sf "$prev_target" "$enabled"
    else
        rm -f "$enabled"
    fi
    rm -f "$tmp_conf" || true
    return 1
}

apache_configtest() {
    if [[ "$OS_TYPE" == "debian" ]]; then
        apache2ctl -t >>"$LOG_FILE" 2>&1
    else
        httpd -t >>"$LOG_FILE" 2>&1
    fi
}

apache_apply_site_conf() {
    # apache_apply_site_conf domain tmp_conf final_conf backend
    local domain="$1" tmp_conf="$2" final_conf="$3" backend="$4"
    local prev_exists=false
    [[ -f "$final_conf" ]] && prev_exists=true

    mv -f "$tmp_conf" "$final_conf"
    if [[ "$OS_TYPE" == "debian" ]]; then
        a2enmod remoteip >/dev/null 2>&1 || true
        a2ensite "${domain}.conf" >/dev/null 2>&1 || true
        if [[ "$backend" == "apache-mod-php" ]]; then
            local default_php
            default_php=$(state_get default_php_version)
            a2dismod mpm_event mpm_worker 2>/dev/null || true
            a2enmod mpm_prefork 2>/dev/null || true
            a2enmod "php${default_php}" 2>/dev/null || true
        else
            a2dismod mpm_prefork 2>/dev/null || true
            a2enmod mpm_event 2>/dev/null || true
            local v
            for v in "${SUPPORTED_PHP_VERSIONS[@]}"; do
                a2dismod "php${v}" 2>/dev/null || true
            done
        fi
    fi

    if apache_configtest; then
        [[ "$OS_TYPE" == "debian" ]] && $SVC_MGR reload apache2 >>"$LOG_FILE" 2>&1 || true
        [[ "$OS_TYPE" == "rhel"   ]] && $SVC_MGR reload httpd   >>"$LOG_FILE" 2>&1 || true
        return 0
    fi

    log_error "Apache configtest не прошёл — откатываю изменения для ${domain}. Подробности в ${LOG_FILE}"
    rm -f "$final_conf" || true
    if $prev_exists; then
        log_warn "Предыдущая конфигурация ${final_conf} была перезаписана. Восстановите из бэкапа/лога при необходимости."
    fi
    return 1
}

# Validate DB identifiers (simple + safe for SQL and filesystem)
validate_db_ident() {
    local s="$1"
    [[ "$s" =~ ^[a-z0-9_]{1,32}$ ]]
}

# Validate DB password (keep it simple to avoid SQL quoting issues)
validate_db_pass() {
    local s="$1"
    [[ "$s" =~ ^[A-Za-z0-9]{8,64}$ ]]
}

# Safe docroot check before destructive actions
assert_safe_docroot_for_delete() {
    local p="$1"
    [[ -n "$p" ]] || return 1
    command_exists realpath || { log_warn "realpath не найден — не могу безопасно проверить путь"; return 1; }
    local rp
    rp="$(realpath -m "$p" 2>/dev/null || true)"
    [[ -n "$rp" ]] || return 1
    # Only allow inside /var/www and not the directory itself
    [[ "$rp" == /var/www/* ]] || return 1
    [[ "$rp" != "/var/www" && "$rp" != "/var/www/" && "$rp" != "/" && "$rp" != "/var" ]] || return 1
    return 0
}

# Non-interactive режим: если SM_NON_INTERACTIVE=1, все промпты
# принимают значения из окружения или используют defaults.
is_non_interactive() {
    [[ "${SM_NON_INTERACTIVE:-0}" == "1" ]] || [[ ! -t 0 ]]
}

prompt() {
    # prompt "Вопрос" "значение_по_умолчанию" VAR_NAME
    local q="$1" def="${2:-}" var_name="$3" ans
    # В non-interactive режиме: берём из уже установленной VAR или из default
    if is_non_interactive; then
        # Если переменная уже установлена извне (env var) — используем её значение
        ans="${!var_name:-$def}"
        printf -v "$var_name" '%s' "$ans"
        return 0
    fi
    if [[ -n "$def" ]]; then
        read -r -p "$q [$def]: " ans || true
        ans="${ans:-$def}"
    else
        read -r -p "$q: " ans || true
    fi
    printf -v "$var_name" '%s' "$ans"
}

prompt_yes_no() {
    # prompt_yes_no "Текст" "y|n"  -> return 0/1
    local q="$1" def="${2:-n}" ans hint
    if is_non_interactive; then
        [[ "$def" == "y" ]]
        return
    fi
    [[ "$def" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
    read -r -p "$q $hint: " ans || true
    ans="${ans:-$def}"
    [[ "${ans,,}" =~ ^(y|yes|д|да)$ ]]
}

prompt_choice() {
    # prompt_choice VAR_NAME "Заголовок" "default_index" "label1" "label2" ...
    local var_name="$1" title="$2" default_idx="$3"
    shift 3
    local -a options=("$@")
    local i=1 choice

    if is_non_interactive; then
        choice="${!var_name:-$default_idx}"
        printf -v "$var_name" '%s' "$choice"
        return 0
    fi

    echo -e "${CYAN}${title}${NC}"
    for opt in "${options[@]}"; do
        printf "  %d) %s\n" "$i" "$opt"
        ((i++))
    done
    read -r -p "Выбор [1-${#options[@]}] (по умолчанию: ${default_idx}): " choice
    choice="${choice:-$default_idx}"
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#options[@]} )); then
        choice="$default_idx"
    fi
    printf -v "$var_name" '%s' "$choice"
}

# Валидация доменного имени
validate_domain() {
    local d="$1"
    # RFC 1035 + IDNA (упрощённо): буквы/цифры/дефисы, длина ≤253, labels ≤63
    if [[ "$d" == "localhost" ]]; then
        return 0
    fi
    if (( ${#d} > 253 )); then
        return 1
    fi
    # Проверка: минимум одна точка, только допустимые символы
    if ! [[ "$d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        return 1
    fi
    return 0
}

# Проверка: свободен ли порт?
port_in_use() {
    local port="$1"
    if command_exists ss; then
        ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"
    elif command_exists netstat; then
        netstat -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"
    else
        return 1
    fi
}

# Показать, кто занимает порт
who_uses_port() {
    local port="$1"
    if command_exists ss; then
        ss -tlnpH 2>/dev/null | awk -v p=":$port" '$4 ~ p {print $6}' | head -1
    else
        echo "неизвестный процесс"
    fi
}

# Генератор паролей (без спецсимволов, чтобы не ломать конфиги)
gen_password() {
    local len="${1:-16}"
    tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$len" || true
}

# Замена блока между маркерами (идемпотентно)
update_managed_block() {
    local file="$1" content="$2"
    if [[ ! -f "$file" ]]; then
        {
            echo "$SM_MARK_BEGIN"
            echo "$content"
            echo "$SM_MARK_END"
        } > "$file"
        return
    fi
    if grep -qF "$SM_MARK_BEGIN" "$file"; then
        # Удаляем старый блок и вставляем новый
        sed -i "/${SM_MARK_BEGIN}/,/${SM_MARK_END}/d" "$file"
    fi
    {
        echo ""
        echo "$SM_MARK_BEGIN"
        echo "$content"
        echo "$SM_MARK_END"
    } >> "$file"
}

# Убрать managed-блок из файла
remove_managed_block() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    if grep -qF "$SM_MARK_BEGIN" "$file"; then
        sed -i "/${SM_MARK_BEGIN}/,/${SM_MARK_END}/d" "$file"
    fi
}

#=====================================================================
# State (плоский key=value файл, достаточно для наших нужд)
#=====================================================================
state_get() {
    local key="$1"
    [[ -f "$SM_STATE_FILE" ]] || return 0
    # awk вместо grep|tail|cut — чтобы всегда возвращать 0 (ключ не найден — не ошибка),
    # и чтобы точное совпадение ключа (grep -E ломался на ключах с .  / +).
    awk -F= -v k="$key" '$1==k{v=$0; sub(/^[^=]*=/,"",v); last=v} END{if(last!="") print last}' "$SM_STATE_FILE"
    return 0
}

state_set() {
    local key="$1" value="$2"
    init_dirs
    touch "$SM_STATE_FILE"
    # Avoid sed-escaping pitfalls: rewrite file via tmp
    local tmp
    tmp="$(mktemp)"
    if grep -qE "^${key}=" "$SM_STATE_FILE"; then
        awk -v k="$key" -v v="$value" -F= '
            BEGIN{updated=0}
            $1==k {print k"="v; updated=1; next}
            {print}
            END{ if(!updated) print k"="v }
        ' "$SM_STATE_FILE" > "$tmp"
    else
        cat "$SM_STATE_FILE" > "$tmp"
        printf "%s=%s\n" "$key" "$value" >> "$tmp"
    fi
    mv -f "$tmp" "$SM_STATE_FILE"
}

state_list_php() {
    state_get "installed_php_versions" | tr ',' ' '
}

state_add_php() {
    local ver="$1"
    local cur
    cur="$(state_get installed_php_versions)"
    if [[ -z "$cur" ]]; then
        state_set "installed_php_versions" "$ver"
    elif ! echo "$cur" | tr ',' '\n' | grep -qxF "$ver"; then
        state_set "installed_php_versions" "${cur},${ver}"
    fi
}

state_remove_php() {
    local ver="$1" cur new
    cur="$(state_get installed_php_versions)"
    [[ -z "$cur" ]] && return 0
    new=$(echo "$cur" | tr ',' '\n' | grep -vxF "$ver" | paste -sd',' -)
    state_set "installed_php_versions" "$new"
}

#=====================================================================
# OS detection
#=====================================================================
detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Невозможно определить ОС: нет /etc/os-release"
        exit 1
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID:-}"
    OS_VERSION="${VERSION_ID:-}"
    OS_CODENAME="${VERSION_CODENAME:-}"

    case "$OS_ID" in
        ubuntu|debian)
            OS_TYPE="debian"
            PKG_MGR="apt"
            if [[ "$OS_ID" == "debian" && -z "$OS_CODENAME" ]]; then
                # Debian sometimes omits; попробуем lsb_release
                OS_CODENAME=$(lsb_release -sc 2>/dev/null || echo "")
            fi
            ;;
        rocky|almalinux|rhel|centos)
            OS_TYPE="rhel"
            if command_exists dnf; then
                PKG_MGR="dnf"
            else
                PKG_MGR="yum"
            fi
            ;;
        *)
            log_error "Неподдерживаемая ОС: ${OS_ID} ${OS_VERSION}"
            log_error "Поддерживаются: Ubuntu, Debian, Rocky, AlmaLinux, RHEL"
            exit 1
            ;;
    esac

    log_ok "Определена ОС: ${PRETTY_NAME:-$OS_ID $OS_VERSION} (тип: $OS_TYPE, pkg: $PKG_MGR)"
}

#=====================================================================
# Определение SSH-порта (чтобы не отрезать себя от сервера при UFW)
#=====================================================================
detect_ssh_port() {
    local port=""
    # 1) Active sshd config
    if [[ -f /etc/ssh/sshd_config ]]; then
        port=$(awk 'BEGIN{IGNORECASE=1} /^[[:space:]]*Port[[:space:]]+/ {print $2; exit}' /etc/ssh/sshd_config)
    fi
    # 2) sshd_config.d/
    if [[ -z "$port" && -d /etc/ssh/sshd_config.d ]]; then
        port=$(awk 'BEGIN{IGNORECASE=1} /^[[:space:]]*Port[[:space:]]+/ {print $2; exit}' /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true)
    fi
    # 3) Живые listener'ы
    if [[ -z "$port" ]] && command_exists ss; then
        port=$(ss -tlnp 2>/dev/null | awk '/sshd/ {split($4,a,":"); print a[length(a)]; exit}')
    fi
    echo "${port:-22}"
}

#=====================================================================
# Detection установленного ПО
#=====================================================================

detect_installed_webserver() {
    local n_ok=false a_ok=false
    command_exists nginx    && n_ok=true
    command_exists apache2  && a_ok=true
    command_exists httpd    && a_ok=true

    if $n_ok && $a_ok; then
        # оба — определяем, настроен ли proxy
        if grep -rqs "proxy_pass http://127.0.0.1:8080" /etc/nginx/ 2>/dev/null; then
            WEB_SERVER="nginx_apache"
        else
            WEB_SERVER="nginx"
        fi
    elif $n_ok; then
        WEB_SERVER="nginx"
    elif $a_ok; then
        WEB_SERVER="apache"
    else
        WEB_SERVER=""
        return 1
    fi
    return 0
}

# Найти все установленные версии PHP из SUPPORTED_PHP_VERSIONS
detect_installed_php_versions() {
    local -a found=()
    local v
    for v in "${SUPPORTED_PHP_VERSIONS[@]}"; do
        if [[ "$OS_TYPE" == "debian" ]]; then
            if command_exists "php${v}" || [[ -d "/etc/php/${v}" ]]; then
                found+=("$v")
            fi
        else
            # Remi SCL pattern: php74, php80, ..., php85
            local scl="php${v//./}"
            if [[ -d "/etc/opt/remi/${scl}" ]] || command_exists "$scl"; then
                found+=("$v")
            fi
        fi
    done
    # Также проверяем системный php (базовый пакет без суффикса)
    if [[ ${#found[@]} -eq 0 ]] && command_exists php; then
        local sysver
        sysver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "")
        [[ -n "$sysver" ]] && found+=("$sysver")
    fi
    printf '%s\n' "${found[@]}"
}

detect_installed_database() {
    if command_exists mariadb; then
        DATABASE="mariadb"
        DB_VERSION=$(mariadb --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 | cut -d. -f1,2)
        return 0
    fi
    if command_exists mysql; then
        if mysql --version 2>/dev/null | grep -qi mariadb; then
            DATABASE="mariadb"
        else
            DATABASE="mysql"
        fi
        DB_VERSION=$(mysql --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 | cut -d. -f1,2)
        return 0
    fi
    DATABASE=""
    DB_VERSION=""
    return 1
}

detect_installed_panel() {
    if [[ -d /usr/local/mgr5 || -d /usr/local/ispmgr ]]; then
        echo "ispmanager"; return 0
    fi
    if [[ -d /usr/local/hestia || -d /etc/hestiacp ]]; then
        echo "hestia"; return 0
    fi
    if [[ -d /usr/local/fastpanel2 || -f /usr/bin/fpctl ]]; then
        echo "fastpanel"; return 0
    fi
    if [[ -d /www/server/panel || -f /etc/init.d/bt ]]; then
        echo "aapanel"; return 0
    fi
    return 1
}

#=====================================================================
# Pre-flight checks
#=====================================================================
preflight_checks() {
    log_section "Предварительные проверки"

    # RAM
    local mem_mb
    mem_mb=$(free -m | awk '/^Mem:/ {print $2}')
    if (( mem_mb < 512 )); then
        log_warn "Мало оперативной памяти (${mem_mb}MB). Рекомендуется минимум 1GB."
    fi

    # Диск
    local free_gb
    free_gb=$(df -BG / | awk 'NR==2 {gsub("G",""); print $4}')
    if (( free_gb < 3 )); then
        log_warn "Мало свободного места на /: ${free_gb}G. Рекомендуется минимум 5G."
    fi

    # Интернет
    if ! curl -fsS --max-time 5 https://1.1.1.1 >/dev/null 2>&1; then
        log_warn "Нет доступа к интернету — установка может не пройти."
    fi

    # systemd
    if ! command_exists systemctl; then
        log_error "systemctl не найден. Скрипт работает только с systemd."
        exit 1
    fi

    log_ok "Предварительные проверки пройдены"
}

#=====================================================================
# Репозитории: Debian/Ubuntu (deb.sury.org для PHP) и RHEL (Remi)
#=====================================================================

setup_sury_repo() {
    # Современный способ: signed-by keyring, не apt-key (deprecated в Ubuntu 22+)
    [[ "$OS_TYPE" == "debian" ]] || return 0
    local keyring="/etc/apt/keyrings/deb.sury.org-php.gpg"
    local list="/etc/apt/sources.list.d/sury-php.list"

    if [[ -f "$keyring" && -f "$list" ]]; then
        log_info "Репозиторий Sury/PHP уже настроен"
        return 0
    fi

    log_info "Настраиваю репозиторий deb.sury.org для PHP..."
    mkdir -p /etc/apt/keyrings
    pkg_install curl ca-certificates gnupg lsb-release
    curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o "$keyring"
    chmod 644 "$keyring"

    local codename="${OS_CODENAME:-$(lsb_release -sc)}"
    # Для Debian URL — packages.sury.org/php/; для Ubuntu — тот же, он поддерживает оба
    echo "deb [signed-by=${keyring}] https://packages.sury.org/php/ ${codename} main" > "$list"
    pkg_update
    log_ok "Репозиторий Sury/PHP подключён"
}

setup_remi_repo() {
    [[ "$OS_TYPE" == "rhel" ]] || return 0
    local rhel_ver
    rhel_ver=$(rpm -E %rhel)
    if rpm -q "remi-release" >/dev/null 2>&1 || rpm -q "remi-release-${rhel_ver}" >/dev/null 2>&1; then
        log_info "Репозиторий Remi уже подключён"
    else
        log_info "Подключаю репозиторий Remi для RHEL${rhel_ver}..."
        pkg_install "https://rpms.remirepo.net/enterprise/remi-release-${rhel_ver}.rpm"
    fi
    # EPEL нужен для некоторых зависимостей
    if ! rpm -q epel-release >/dev/null 2>&1; then
        pkg_install epel-release
    fi
    # На RHEL 8/9 есть dnf-modules для PHP; мы идём через remi-SCL пакеты (php74, php80, ...)
    # Никаких module reset/enable делать не нужно — SCL-пакеты ставятся параллельно системному.
    log_ok "Репозиторий Remi подключён"
}

setup_nginx_repo() {
    # Nginx из дистрибутивных репозиториев обычно ОК.
    # На Debian 11/12, Ubuntu 22/24 nginx есть нативно. Ничего не делаем.
    :
}

setup_mariadb_repo() {
    # Используем только ОФИЦИАЛЬНЫЕ репозитории mariadb.org
    [[ -z "$DB_VERSION" ]] && return 0

    if [[ "$OS_TYPE" == "debian" ]]; then
        local list="/etc/apt/sources.list.d/mariadb.list"
        local keyring="/etc/apt/keyrings/mariadb-keyring.pgp"
        if [[ -f "$list" && -f "$keyring" ]]; then
            return 0
        fi
        mkdir -p /etc/apt/keyrings
        log_info "Настраиваю официальный репозиторий MariaDB ${DB_VERSION}..."
        pkg_install curl ca-certificates
        curl -fsSL https://mariadb.org/mariadb_release_signing_key.pgp -o "$keyring"
        chmod 644 "$keyring"
        local codename="${OS_CODENAME:-$(lsb_release -sc)}"
        echo "deb [signed-by=${keyring}] https://mirror.mariadb.org/repo/${DB_VERSION}/${OS_ID} ${codename} main" > "$list"
        pkg_update
    else
        local rhel_ver
        rhel_ver=$(rpm -E %rhel)
        cat > /etc/yum.repos.d/MariaDB.repo <<EOF
[mariadb]
name = MariaDB-${DB_VERSION}
baseurl = https://mirror.mariadb.org/yum/${DB_VERSION}/rhel/${rhel_ver}/\$basearch
module_hotfixes = 1
gpgkey = https://mirror.mariadb.org/yum/RPM-GPG-KEY-MariaDB
gpgcheck = 1
EOF
    fi
    log_ok "Репозиторий MariaDB ${DB_VERSION} подключён"
}

#=====================================================================
# Установка системных зависимостей
#=====================================================================

install_base_deps() {
    log_section "Установка базовых зависимостей"
    log_info "Обновление индексов пакетов..."
    pkg_update
    log_info "Установка базовых пакетов..."
    if [[ "$OS_TYPE" == "debian" ]]; then
        pkg_install curl wget ca-certificates gnupg lsb-release \
            software-properties-common apt-transport-https \
            openssl iproute2 net-tools
    else
        pkg_install curl wget ca-certificates gnupg2 \
            openssl iproute net-tools
    fi
    log_ok "Базовые зависимости установлены"
}

#=====================================================================
# Установка Nginx
#=====================================================================
install_nginx() {
    if command_exists nginx; then
        log_info "Nginx уже установлен"
    else
        log_section "Установка Nginx"
        log_info "Устанавливаю пакет nginx..."
        pkg_install nginx
    fi

    # Директории для site-configs (унифицируем под Debian-like структуру)
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/snippets

    # В nginx.conf должен быть include sites-enabled — на Debian есть, на RHEL добавим
    if [[ "$OS_TYPE" == "rhel" ]] && ! grep -q "sites-enabled" /etc/nginx/nginx.conf; then
        # Вставляем include перед закрывающей скобкой http-блока
        sed -i '/^http {/a\    include /etc/nginx/sites-enabled/*.conf;' /etc/nginx/nginx.conf
    fi

    $SVC_MGR enable --now nginx >/dev/null 2>&1 || true
    log_ok "Nginx установлен и запущен"
}

#=====================================================================
# Установка Apache (всегда бэкенд на 127.0.0.1:8080)
#=====================================================================
install_apache() {
    # Проверка: не занят ли :8080 чем-то чужим?
    if port_in_use 8080 && ! (command_exists apache2 || command_exists httpd); then
        local who
        who=$(who_uses_port 8080)
        log_error "Порт 8080 занят (${who}). Apache-бэкенд не может стартовать."
        log_error "Освободите порт и перезапустите установку."
        exit 1
    fi

    local svc
    if [[ "$OS_TYPE" == "debian" ]]; then
        svc="apache2"
        if ! command_exists apache2; then
            log_section "Установка Apache"
            # Останавливаем, чтобы не конфликтовать с Nginx на :80 сразу после установки
            $SVC_MGR stop nginx 2>/dev/null || true
            log_info "Устанавливаю apache2..."
            pkg_install apache2
            # Настраиваем порт 8080 ДО запуска
            configure_apache_backend
            $SVC_MGR restart "$svc"
            $SVC_MGR start nginx 2>/dev/null || true
        else
            configure_apache_backend
        fi
        # Включаем нужные модули
        a2enmod rewrite headers expires deflate proxy_fcgi setenvif >/dev/null 2>&1 || true
        a2dismod mpm_prefork mpm_worker 2>/dev/null || true
        a2enmod mpm_event 2>/dev/null || true
    else
        svc="httpd"
        if ! command_exists httpd; then
            log_section "Установка Apache (httpd)"
            $SVC_MGR stop nginx 2>/dev/null || true
            log_info "Устанавливаю httpd..."
            pkg_install httpd mod_ssl
            configure_apache_backend
            $SVC_MGR restart "$svc"
            $SVC_MGR start nginx 2>/dev/null || true
        else
            configure_apache_backend
        fi
    fi

    $SVC_MGR enable --now "$svc" >/dev/null 2>&1 || true
    log_ok "Apache установлен, слушает 127.0.0.1:8080"
}

# Apache должен слушать только localhost:8080 (бэкенд за Nginx)
configure_apache_backend() {
    if [[ "$OS_TYPE" == "debian" ]]; then
        local ports="/etc/apache2/ports.conf"
        cat > "$ports" <<'EOF'
# Управляется servermanager: Apache работает как бэкенд для Nginx
Listen 127.0.0.1:8080
<IfModule ssl_module>
    Listen 127.0.0.1:8443
</IfModule>
EOF
        # Отключаем дефолтный 000-default
        rm -f /etc/apache2/sites-enabled/000-default.conf
    else
        local httpd_conf="/etc/httpd/conf/httpd.conf"
        # Все Listen → 127.0.0.1:8080 через managed-блок
        sed -i -E 's/^[[:space:]]*Listen[[:space:]]+[0-9:\.]+.*$/# &/' "$httpd_conf"
        update_managed_block "$httpd_conf" "Listen 127.0.0.1:8080"
        # Отключаем welcome.conf
        if [[ -f /etc/httpd/conf.d/welcome.conf ]]; then
            sed -i 's/^/# /' /etc/httpd/conf.d/welcome.conf
        fi
    fi
}

#=====================================================================
# Установка PHP (одна версия за вызов; может вызываться несколько раз)
#=====================================================================

# install_php_version <version>
install_php_version() {
    local v="$1"
    log_section "Установка PHP ${v}"

    if [[ "$OS_TYPE" == "debian" ]]; then
        setup_sury_repo

        # Обязательные пакеты (должны быть во всех версиях PHP от Sury)
        local mandatory=(
            "php${v}-fpm" "php${v}-cli" "php${v}-common"
            "php${v}-mysql" "php${v}-xml" "php${v}-curl"
            "php${v}-gd" "php${v}-mbstring" "php${v}-zip"
            "php${v}-intl" "php${v}-bcmath"
            "php${v}-soap" "php${v}-readline"
        )

        # Опциональные пакеты — могут отсутствовать для некоторых версий:
        #  - opcache: c PHP 8.4+ встроен в основной пакет php8.X,
        #    отдельного php8.4-opcache / php8.5-opcache НЕТ
        #  - imap: удалён из ядра в PHP 8.4 (вынесен в PECL)
        local optional=()
        case "$v" in
            7.4|8.0|8.1|8.2|8.3)
                optional+=("php${v}-opcache" "php${v}-imap")
                ;;
            # 8.4, 8.5 — opcache в основном пакете, imap недоступен
        esac

        log_info "Устанавливаю обязательные пакеты PHP ${v}..."
        pkg_install "${mandatory[@]}"

        # Опциональные — ставим по одному, игнорируем ошибки
        local pkg
        for pkg in "${optional[@]}"; do
            if pkg_install "$pkg" 2>/dev/null; then
                log_info "  + ${pkg}"
            else
                log_warn "  — ${pkg} не найден в репозитории (ок для новых PHP)"
            fi
        done

        # Проверка: OPcache должен быть доступен (в 8.4+ он в основном пакете)
        if ! "php${v}" -d opcache.enable_cli=1 -m 2>/dev/null | grep -qi "Zend OPcache"; then
            log_warn "OPcache не обнаружен в PHP ${v} — производительность будет ниже"
        fi

        $SVC_MGR enable --now "php${v}-fpm" >/dev/null 2>&1 || true

    else
        # RHEL: remi SCL пакеты (php74, php80, ..., php85)
        setup_remi_repo
        local scl="php${v//./}"

        local mandatory=(
            "${scl}" "${scl}-php-fpm" "${scl}-php-cli" "${scl}-php-common"
            "${scl}-php-mysqlnd" "${scl}-php-xml" "${scl}-php-mbstring"
            "${scl}-php-gd" "${scl}-php-intl"
            "${scl}-php-soap" "${scl}-php-bcmath" "${scl}-php-pecl-zip"
        )
        local optional=("${scl}-php-opcache")

        log_info "Устанавливаю обязательные пакеты PHP ${v}..."
        pkg_install "${mandatory[@]}"

        local pkg
        for pkg in "${optional[@]}"; do
            if pkg_install "$pkg" 2>/dev/null; then
                log_info "  + ${pkg}"
            else
                log_warn "  — ${pkg} не найден (возможно встроен в ядро)"
            fi
        done

        $SVC_MGR enable --now "${scl}-php-fpm" >/dev/null 2>&1 || true
    fi

    optimize_php_version "$v"
    state_add_php "$v"
    log_ok "PHP ${v} установлен"
}

# Удаление версии PHP
uninstall_php_version() {
    local v="$1"
    log_section "Удаление PHP ${v}"

    # Проверяем: есть ли сайты, использующие эту версию
    local in_use=()
    local f
    if compgen -G "${SM_SITES_DIR}/*.conf" > /dev/null; then
        for f in "${SM_SITES_DIR}"/*.conf; do
            local pv d
            pv="$(kv_get_file "$f" "PHP_VERSION")"
            d="$(kv_get_file "$f" "DOMAIN")"
            if [[ -n "$pv" && "$pv" == "$v" ]]; then
                in_use+=("$d")
            fi
        done
    fi
    if (( ${#in_use[@]} > 0 )); then
        log_error "PHP ${v} используется сайтами: ${in_use[*]}"
        log_error "Смените им версию перед удалением."
        return 1
    fi

    if [[ "$OS_TYPE" == "debian" ]]; then
        $SVC_MGR disable --now "php${v}-fpm" >/dev/null 2>&1 || true
        pkg_purge_glob "php${v}*" || true
        pkg_cleanup
    else
        local scl="php${v//./}"
        $SVC_MGR disable --now "${scl}-php-fpm" >/dev/null 2>&1 || true
        pkg_purge_glob "${scl}*" "${scl}-*" || true
    fi

    state_remove_php "$v"

    # Если удалили default — выбираем новый default (самую новую из оставшихся)
    local cur_default
    cur_default=$(state_get default_php_version)
    if [[ "$cur_default" == "$v" ]]; then
        local remaining
        remaining=$(state_list_php | tr ' ' '\n' | sort -V | tail -n1)
        if [[ -n "$remaining" ]]; then
            state_set default_php_version "$remaining"
            log_info "Новый default PHP: ${remaining}"
        else
            state_set default_php_version ""
        fi
    fi
    log_ok "PHP ${v} удалён"
}

# Оптимизация php.ini + pool.conf для конкретной версии
optimize_php_version() {
    local v="$1"
    local php_ini fpm_conf

    if [[ "$OS_TYPE" == "debian" ]]; then
        php_ini="/etc/php/${v}/fpm/php.ini"
        fpm_conf="/etc/php/${v}/fpm/pool.d/www.conf"
    else
        local scl="php${v//./}"
        php_ini="/etc/opt/remi/${scl}/php.ini"
        fpm_conf="/etc/opt/remi/${scl}/php-fpm.d/www.conf"
    fi

    [[ -f "$php_ini" ]] || { log_warn "Нет php.ini для $v: $php_ini"; return; }

    # Бэкап один раз
    [[ -f "${php_ini}.sm-backup" ]] || cp "$php_ini" "${php_ini}.sm-backup"

    # Используем managed-блок — он переопределит значения
    local ram_mb mem_limit
    ram_mb=$(free -m | awk '/^Mem:/ {print $2}')
    if (( ram_mb < 1024 )); then
        mem_limit="128M"
    elif (( ram_mb < 2048 )); then
        mem_limit="256M"
    else
        mem_limit="512M"
    fi

    update_managed_block "$php_ini" "$(cat <<EOF
memory_limit = ${mem_limit}
upload_max_filesize = 64M
post_max_size = 64M
max_execution_time = 300
max_input_time = 300
max_input_vars = 3000
date.timezone = UTC
expose_php = Off
; OPcache
opcache.enable = 1
opcache.enable_cli = 0
opcache.memory_consumption = 128
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.revalidate_freq = 60
opcache.validate_timestamps = 1
opcache.fast_shutdown = 1
EOF
)"

    # Pool: master www.conf оставляем для кейса "нет per-site пулов"
    if [[ -f "$fpm_conf" ]]; then
        [[ -f "${fpm_conf}.sm-backup" ]] || cp "$fpm_conf" "${fpm_conf}.sm-backup"
        sed -i 's/^pm = .*/pm = dynamic/' "$fpm_conf" 2>/dev/null || true
        sed -i 's/^pm.max_children = .*/pm.max_children = 25/' "$fpm_conf" 2>/dev/null || true
        sed -i 's/^pm.start_servers = .*/pm.start_servers = 4/' "$fpm_conf" 2>/dev/null || true
        sed -i 's/^pm.min_spare_servers = .*/pm.min_spare_servers = 2/' "$fpm_conf" 2>/dev/null || true
        sed -i 's/^pm.max_spare_servers = .*/pm.max_spare_servers = 8/' "$fpm_conf" 2>/dev/null || true
        sed -i 's/^;pm.max_requests = .*/pm.max_requests = 500/' "$fpm_conf" 2>/dev/null || true
    fi

    restart_php_fpm "$v"
}

restart_php_fpm() {
    local v="$1" svc
    if [[ "$OS_TYPE" == "debian" ]]; then
        svc="php${v}-fpm"
    else
        svc="php${v//./}-php-fpm"
    fi
    $SVC_MGR restart "$svc" >/dev/null 2>&1 || log_warn "Не удалось перезапустить $svc"
}

# Вернуть путь к PHP-FPM socket (Debian) или TCP-endpoint (RHEL)
php_fpm_endpoint() {
    local v="$1" domain="${2:-}"
    if [[ "$OS_TYPE" == "debian" ]]; then
        if [[ -n "$domain" && -S "/run/php/php${v}-fpm-${domain}.sock" ]]; then
            echo "unix:/run/php/php${v}-fpm-${domain}.sock"
        else
            echo "unix:/run/php/php${v}-fpm.sock"
        fi
    else
        # В Remi-пакетах php-fpm обычно слушает на уникальном порту: 9000 для базового,
        # или unix-сокет /var/opt/remi/phpXY/run/php-fpm/www.sock.
        local scl="php${v//./}"
        if [[ -S "/var/opt/remi/${scl}/run/php-fpm/${domain}.sock" ]]; then
            echo "unix:/var/opt/remi/${scl}/run/php-fpm/${domain}.sock"
        elif [[ -S "/var/opt/remi/${scl}/run/php-fpm/www.sock" ]]; then
            echo "unix:/var/opt/remi/${scl}/run/php-fpm/www.sock"
        else
            # Fallback — определим порт из конфига
            echo "127.0.0.1:9000"
        fi
    fi
}

# Создать per-site PHP-FPM пул (для multi-PHP)
create_site_fpm_pool() {
    local v="$1" domain="$2"
    local pool_file sock_path user group

    if [[ "$OS_TYPE" == "debian" ]]; then
        pool_file="/etc/php/${v}/fpm/pool.d/${domain}.conf"
        sock_path="/run/php/php${v}-fpm-${domain}.sock"
        user="www-data"
        group="www-data"
    else
        local scl="php${v//./}"
        pool_file="/etc/opt/remi/${scl}/php-fpm.d/${domain}.conf"
        sock_path="/var/opt/remi/${scl}/run/php-fpm/${domain}.sock"
        user="apache"
        group="apache"
    fi

    cat > "$pool_file" <<EOF
; servermanager per-site pool for ${domain} on PHP ${v}
[${domain}]
user = ${user}
group = ${group}
listen = ${sock_path}
listen.owner = ${user}
listen.group = ${group}
listen.mode = 0660

pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 4
pm.max_requests = 500

php_admin_value[error_log] = /var/log/php${v}-fpm-${domain}.log
php_admin_flag[log_errors] = on
php_admin_value[memory_limit] = 256M
EOF
    restart_php_fpm "$v"
    echo "unix:${sock_path}"
}

remove_site_fpm_pool() {
    local v="$1" domain="$2" pool_file
    if [[ "$OS_TYPE" == "debian" ]]; then
        pool_file="/etc/php/${v}/fpm/pool.d/${domain}.conf"
    else
        pool_file="/etc/opt/remi/php${v//./}/php-fpm.d/${domain}.conf"
    fi
    [[ -f "$pool_file" ]] && rm -f "$pool_file"
    restart_php_fpm "$v" 2>/dev/null || true
}

#=====================================================================
# Установка MariaDB / MySQL
#=====================================================================
install_mariadb() {
    if command_exists mariadb || command_exists mysql; then
        log_info "Сервер БД уже установлен"
        return 0
    fi
    log_section "Установка MariaDB"
    setup_mariadb_repo

    log_info "Устанавливаю MariaDB (может занять минуту)..."
    if [[ "$OS_TYPE" == "debian" ]]; then
        pkg_install mariadb-server mariadb-client
    else
        pkg_install MariaDB-server MariaDB-client 2>/dev/null \
          || pkg_install mariadb-server mariadb
    fi

    $SVC_MGR enable --now mariadb >/dev/null 2>&1 || $SVC_MGR enable --now mysql >/dev/null 2>&1 || true

    secure_database_install
    state_set "database" "mariadb"
    [[ -n "$DB_VERSION" ]] && state_set "database_version" "$DB_VERSION"
    log_ok "MariaDB установлена и базово защищена"
}

install_mysql() {
    if command_exists mariadb || command_exists mysql; then
        log_info "Сервер БД уже установлен"
        return 0
    fi
    log_section "Установка MySQL"

    log_info "Устанавливаю MySQL (может занять минуту)..."
    if [[ "$OS_TYPE" == "debian" ]]; then
        pkg_install mysql-server
    else
        pkg_install mysql-server
    fi

    $SVC_MGR enable --now mysql >/dev/null 2>&1 || $SVC_MGR enable --now mysqld >/dev/null 2>&1 || true

    secure_database_install
    state_set "database" "mysql"
    [[ -n "$DB_VERSION" ]] && state_set "database_version" "$DB_VERSION"
    log_ok "MySQL установлен и базово защищён"
}

# Замена mysql_secure_installation через прямой SQL (надёжнее heredoc)
secure_database_install() {
    log_info "Применяю базовые меры безопасности к БД..."
    [[ -z "${DB_ROOT_PASS:-}" ]] && DB_ROOT_PASS=$(gen_password 20)

    # Пытаемся разными способами подключиться (на свежей установке root обычно unix_socket)
    local mysql_cmd=""
    if mysql --protocol=socket -u root -e "SELECT 1" &>/dev/null; then
        mysql_cmd="mysql --protocol=socket -u root"
    elif mariadb -u root -e "SELECT 1" &>/dev/null; then
        mysql_cmd="mariadb -u root"
    elif MYSQL_PWD="${DB_ROOT_PASS}" mysql -u root -e "SELECT 1" &>/dev/null; then
        # Avoid exposing password in process list
        mysql_cmd="MYSQL_PWD=${DB_ROOT_PASS} mysql -u root"
    else
        log_warn "Не удалось подключиться к БД от root — безопасность придётся настраивать вручную"
        return 0
    fi

    # Унифицированная очистка + установка пароля
    # Используется ALTER USER вместо UPDATE mysql.user (работает и в MySQL 8 и в MariaDB 10.4+)
    $mysql_cmd <<EOF || true
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
FLUSH PRIVILEGES;
EOF

    # Сохраняем пароль в защищённый файл
    init_dirs
    local cred_file="${SM_CRED_DIR}/db-root.txt"
    cat > "$cred_file" <<EOF
# servermanager — учётные данные root для БД
# $(date -Iseconds)
DB_ROOT_USER=root
DB_ROOT_PASS=${DB_ROOT_PASS}
EOF
    chmod 600 "$cred_file"
    log_ok "Пароль root для БД сохранён в ${cred_file}"

    # Записываем /root/.my.cnf для passwordless доступа через mysql/mariadb CLI
    cat > "/root/.my.cnf" <<EOF
[client]
user=root
password=${DB_ROOT_PASS}
EOF
    chmod 600 "/root/.my.cnf"
    log_ok "Записан /root/.my.cnf — теперь 'mysql' работает без ввода пароля"
}

optimize_database() {
    log_section "Оптимизация БД"
    local my_cnf
    if [[ "$OS_TYPE" == "debian" ]]; then
        if [[ -f /etc/mysql/mariadb.conf.d/50-server.cnf ]]; then
            my_cnf="/etc/mysql/mariadb.conf.d/50-server.cnf"
        else
            my_cnf="/etc/mysql/mysql.conf.d/mysqld.cnf"
        fi
    else
        if [[ -f /etc/my.cnf.d/server.cnf ]]; then
            my_cnf="/etc/my.cnf.d/server.cnf"
        else
            my_cnf="/etc/my.cnf"
        fi
    fi

    local mem_mb innodb_mb
    mem_mb=$(free -m | awk '/^Mem:/ {print $2}')
    # 40% от RAM, но не менее 128MB и не более 2GB (скрипт обычно запускают на VPS)
    innodb_mb=$(( mem_mb * 40 / 100 ))
    (( innodb_mb < 128 )) && innodb_mb=128
    (( innodb_mb > 2048 )) && innodb_mb=2048

    # ВАЖНО: query_cache удалён из MySQL 8 и deprecated в MariaDB — НЕ включаем.
    update_managed_block "$my_cnf" "$(cat <<EOF
[mysqld]
# servermanager managed tuning
innodb_buffer_pool_size = ${innodb_mb}M
innodb_log_file_size = 64M
innodb_flush_method = O_DIRECT
innodb_flush_log_at_trx_commit = 2
max_connections = 200
table_open_cache = 2000
tmp_table_size = 64M
max_heap_table_size = 64M
# bind только на loopback — DB-сервер не должен торчать наружу
bind-address = 127.0.0.1
# Жёсткий skip-name-resolve — ускоряет login
skip-name-resolve = 1
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
EOF
)"

    $SVC_MGR restart mariadb 2>/dev/null || $SVC_MGR restart mysql 2>/dev/null || $SVC_MGR restart mysqld 2>/dev/null || true
    log_ok "Оптимизация БД применена (InnoDB buffer pool = ${innodb_mb}M)"
}

mysql_root_defaults_file() {
    # Prints path to a temp defaults-extra-file (caller must rm -f).
    # Returns non-zero if root password is missing.
    local root_pass="$1"
    [[ -n "$root_pass" ]] || return 1
    local tmp
    tmp="$(mktemp)"
    chmod 600 "$tmp"
    cat > "$tmp" <<EOF
[client]
user=root
password=${root_pass}
EOF
    echo "$tmp"
}

# Создать БД и пользователя для сайта
create_site_database() {
    local db_name="$1" db_user="$2" db_pass="$3"
    if ! validate_db_ident "$db_name"; then
        log_error "Некорректное имя БД: '$db_name' (разрешено: [a-z0-9_], длина 1..32)"
        return 1
    fi
    if ! validate_db_ident "$db_user"; then
        log_error "Некорректный пользователь БД: '$db_user' (разрешено: [a-z0-9_], длина 1..32)"
        return 1
    fi
    if ! validate_db_pass "$db_pass"; then
        log_error "Некорректный пароль БД (разрешено: A-Za-z0-9, длина 8..64). Оставьте пустым для генерации."
        return 1
    fi
    local root_pass
    root_pass=$(grep -E '^DB_ROOT_PASS=' "${SM_CRED_DIR}/db-root.txt" 2>/dev/null | cut -d= -f2)

    local defaults=""
    if [[ -n "$root_pass" ]]; then
        defaults="$(mysql_root_defaults_file "$root_pass")" || true
    fi
    local mysql_cmd="mysql -u root"
    [[ -n "$defaults" ]] && mysql_cmd="mysql --defaults-extra-file=${defaults}"

    $mysql_cmd <<EOF
CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
ALTER USER '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';
FLUSH PRIVILEGES;
EOF
    [[ -n "$defaults" ]] && rm -f "$defaults" || true
    log_ok "БД ${db_name} и пользователь ${db_user} созданы/обновлены"
}

drop_site_database() {
    local db_name="$1" db_user="$2"
    local root_pass
    root_pass=$(grep -E '^DB_ROOT_PASS=' "${SM_CRED_DIR}/db-root.txt" 2>/dev/null | cut -d= -f2)
    local defaults=""
    if [[ -n "$root_pass" ]]; then
        defaults="$(mysql_root_defaults_file "$root_pass")" || true
    fi
    local mysql_cmd="mysql -u root"
    [[ -n "$defaults" ]] && mysql_cmd="mysql --defaults-extra-file=${defaults}"

    if [[ -n "$db_user" ]]; then
        $mysql_cmd <<EOF || true
DROP DATABASE IF EXISTS \`${db_name}\`;
DROP USER IF EXISTS '${db_user}'@'localhost';
FLUSH PRIVILEGES;
EOF
    else
        $mysql_cmd <<EOF || true
DROP DATABASE IF EXISTS \`${db_name}\`;
FLUSH PRIVILEGES;
EOF
    fi
    [[ -n "$defaults" ]] && rm -f "$defaults" || true
}


#=====================================================================
# Per-site configuration
#=====================================================================

# Сохранить метаданные сайта
save_site_config() {
    local domain="$1" doc_root="$2" php_ver="$3" backend="$4" ssl="$5" db_name="${6:-}" db_user="${7:-}" www_alias="${8:-true}"
    local f="${SM_SITES_DIR}/${domain}.conf"
    init_dirs
    cat > "$f" <<EOF
# servermanager site config
SITE_FORMAT="${SM_SITE_FORMAT}"
DOMAIN="${domain}"
DOCUMENT_ROOT="${doc_root}"
PHP_VERSION="${php_ver}"
BACKEND="${backend}"
SSL="${ssl}"
DB_NAME="${db_name}"
DB_USER="${db_user}"
WWW_ALIAS="${www_alias}"
CREATED_AT="$(date -Iseconds)"
EOF
    chmod 640 "$f"
}

list_sites() {
    if ! compgen -G "${SM_SITES_DIR}/*.conf" > /dev/null; then
        echo "(нет сайтов)"
        return
    fi
    printf "  %-4s %-30s %-8s %-18s %-5s %s\n" "#" "DOMAIN" "PHP" "BACKEND" "SSL" "DOCROOT"
    printf "  %-4s %-30s %-8s %-18s %-5s %s\n" "--" "------" "---" "-------" "---" "-------"
    local f i=1
    for f in "${SM_SITES_DIR}"/*.conf; do
        local d pv be ssl dr
        d="$(kv_get_file "$f" "DOMAIN")"
        pv="$(kv_get_file "$f" "PHP_VERSION")"
        be="$(kv_get_file "$f" "BACKEND")"
        ssl="$(kv_get_file "$f" "SSL")"
        dr="$(kv_get_file "$f" "DOCUMENT_ROOT")"
        printf "  %-4s %-30s %-8s %-18s %-5s %s\n" "${i})" "${d}" "${pv}" "${be}" "${ssl}" "${dr}"
        ((i++))
    done
}

# pick_site VARNAME — shows numbered list, reads a number, sets VARNAME to the domain.
# Returns 1 if no sites or invalid selection.
pick_site() {
    local _var="$1"
    if ! compgen -G "${SM_SITES_DIR}/*.conf" > /dev/null; then
        echo "(нет сайтов)"
        return 1
    fi

    local -a _domains=()
    local f
    for f in "${SM_SITES_DIR}"/*.conf; do
        _domains+=("$(kv_get_file "$f" "DOMAIN")")
    done

    list_sites
    echo
    local _num
    read -r -p "Номер сайта: " _num
    if ! [[ "$_num" =~ ^[0-9]+$ ]] || (( _num < 1 || _num > ${#_domains[@]} )); then
        log_error "Неверный номер: $_num"
        return 1
    fi
    printf -v "$_var" '%s' "${_domains[$(( _num - 1 ))]}"
}

#=====================================================================
# Default/Catch-all конфигурация
#=====================================================================

# Создание default конфигурации для catch-all scenarios
setup_default_config() {
    local default_conf="/etc/nginx/sites-available/default"
    local default_ssl="/etc/nginx/sites-available/default-ssl"
    local enabled_dir="/etc/nginx/sites-enabled"
    
    log_info "Настраиваю default конфигурацию для catch-all scenarios..."
    
    # Бэкап существующих default конфигов
    backup_config "$default_conf" 2>/dev/null || true
    backup_config "$default_ssl" 2>/dev/null || true
    
    # Создаем безопасную default конфигурацию
    cat > "$default_conf" <<'EOF'
# servermanager managed — default catch-all configuration
# This configuration handles requests to server IP and unknown domains

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    
    # Security headers
    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header Permissions-Policy "interest-cohort=()" always;
    
    # Default page
    location / {
        return 200 '<!DOCTYPE html><html><head><title>Server Manager</title><style>body { font-family: Arial, sans-serif; text-align: center; margin-top: 100px; background: #f5f5f5; } .container { background: white; padding: 40px; border-radius: 10px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); max-width: 600px; margin: 0 auto; } h1 { color: #2c3e50; } p { color: #7f8c8d; line-height: 1.6; } .stats { background: #ecf0f1; padding: 20px; border-radius: 5px; margin: 20px 0; text-align: left; } .stat-item { margin: 10px 0; } .footer { margin-top: 30px; font-size: 12px; color: #95a5a6; }</style></head><body><div class="container"><h1>🚀 Server Manager</h1><p>Этот сервер управляется через Server Manager v3.1.2</p><div class="stats"><div class="stat-item"><strong>📊 Статус сервера:</strong> Активен</div><div class="stat-item"><strong>🌐 Веб-сервер:</strong> Nginx</div><div class="stat-item"><strong>⚡ PHP:</strong> Мульти-версионная поддержка</div><div class="stat-item"><strong>🗄️ База данных:</strong> MySQL/MariaDB</div></div><p><em>Для добавления сайтов используйте команду: sudo ./servermanager.sh</em></p><div class="footer">Server Manager — LEMP/LAMP provisioning tool<br>Автор: Павлович Владислав — pavlovich.blog</div></div></body></html>';
        types { text/html; }
    }
    
    # Health check endpoint
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
    
    # Запрет доступа к скрытым файлам
    location ~ /\. { deny all; }
    
    # Логи для default конфигурации
    access_log /var/log/nginx/default.access.log;
    error_log  /var/log/nginx/default.error.log;
}

# SSL default configuration (placeholder)
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    
    # Self-signed certificate для IP доступа
    ssl_certificate /etc/ssl/certs/ssl-cert-snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    
    # Безопасный редирект на HTTP для неизвестных доменов
    return 301 http://$host$request_uri;
}
EOF

    # Активируем default конфигурацию
    ln -sf "$default_conf" "${enabled_dir}/default" 2>/dev/null || true
    
    # Удаляем стандартные default конфиги если они есть
    rm -f "${enabled_dir}/default" 2>/dev/null || true
    
    # Перезагружаем Nginx
    nginx -t >>"$LOG_FILE" 2>&1 && $SVC_MGR reload nginx >>"$LOG_FILE" 2>&1 || {
        log_error "Не удалось применить default конфигурацию"
        return 1
    }
    
    log_ok "Default конфигурация установлена"
    return 0
}

# Проверка и восстановление default конфигурации
ensure_default_config() {
    local default_conf="/etc/nginx/sites-enabled/default"
    
    if [[ ! -f "$default_conf" ]] || ! grep -q "servermanager managed.*default" "$default_conf"; then
        log_info "Default конфигурация отсутствует или повреждена, восстанавливаю..."
        setup_default_config
    fi
}

#=====================================================================
# Улучшенный UX/UI компоненты
#=====================================================================

# Прогресс-бар для длительных операций
show_progress() {
    local current="$1" total="$2" width="$3" desc="$4"
    local percent=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))
    
    printf "\r${CYAN}%s${NC} [" "$desc"
    printf "%*s" "$filled" "" | tr ' ' '█'
    printf "%*s" "$empty" "" | tr ' ' '░'
    printf "] %d%%" "$percent"
    
    if (( current == total )); then
        echo " ${GREEN}✓${NC}"
    fi
}

# Анимированный спиннер для ожидания
show_spinner() {
    local pid="$1" desc="$2"
    local chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    local i=0
    
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i + 1) % 10 ))
        printf "\r${CYAN}%s${NC} %s" "${chars:$i:1}" "$desc"
        sleep 0.1
    done
    printf "\r${GREEN}✓${NC} %s\n" "$desc"
}

# Улучшенный banner с системной информацией (совместимая версия)
show_enhanced_banner() {
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    (( cols > 120 )) && cols=120

    local line
    line=$(printf '%*s' "$cols" '' | tr ' ' '=')

    local title="Server Manager v${SM_VERSION}"
    local subtitle="LEMP/LAMP Stack Management System"
    local author="Автор: Павлович Владислав — pavlovich.blog"
    local support="Поддержка: TG @sysadminctl"

    # Собираем системную информацию
    local uptime_info=$(uptime -p 2>/dev/null | sed 's/up //' || echo "N/A")
    local mem_info=$(free -h | awk '/^Mem:/ {printf "%s/%s", $3, $2}')
    local disk_info=$(df -h / | awk 'NR==2 {printf "%s/%s", $3, $2}')
    local load_avg=$(uptime | awk -F'load average:' '{print $2}' | sed 's/^ *//')

    echo
    echo -e "${GREEN}${BOLD}${line}${NC}"
    printf "%*s${BOLD}%s${NC}\n" $(( (cols - ${#title}) / 2 )) "" "$title"
    printf "%*s${CYAN}%s${NC}\n" $(( (cols - ${#subtitle}) / 2 )) "" "$subtitle"
    echo -e "${GREEN}${BOLD}${line}${NC}"
    
    # Системная информация в табличном виде
    echo -e "${BOLD}Системная информация:${NC}"
    printf "  Uptime: ${YELLOW}%s${NC}\n" "$uptime_info"
    printf "  Memory: ${YELLOW}%s${NC}\n" "$mem_info"
    printf "  Disk:   ${YELLOW}%s${NC}\n" "$disk_info"
    printf "  Load:   ${YELLOW}%s${NC}\n" "$load_avg"
    echo
    
    printf "%*s%s\n" $(( (cols - ${#author}) / 2 )) "" "$author"
    printf "%*s${CYAN}%s${NC}\n" $(( (cols - ${#support}) / 2 )) "" "$support"
    echo
}

# Улучшенное отображение состояния сервера (совместимая версия)
show_enhanced_state_summary() {
    echo -e "${BOLD}Состояние сервера:${NC}"
    
    # Веб-сервер
    local web_server=$(state_get webserver)
    local web_status="[X] Не установлен"
    if command_exists nginx; then
        web_status="[OK] Активен"
    elif command_exists apache2 || command_exists httpd; then
        web_status="[OK] Apache"
    fi
    printf "  Web:      ${BOLD}%s${NC} %s\n" "${web_server:-'N/A'}" "$web_status"
    
    # PHP
    local php_versions=$(state_list_php)
    local php_default=$(state_get default_php_version)
    local php_status="[X] Не установлен"
    if [[ -n "$php_versions" ]]; then
        php_status="[OK] ${php_versions} (default: ${php_default})"
    fi
    printf "  PHP:      %s\n" "$php_status"
    
    # База данных
    local db=$(state_get database)
    local db_version=$(state_get database_version)
    local db_status="[X] Не установлена"
    if command_exists mysql || command_exists mariadb; then
        db_status="[OK] ${db} ${db_version}"
    fi
    printf "  БД:       %s\n" "$db_status"
    
    # Сайты
    local site_count=0
    if compgen -G "${SM_SITES_DIR}/*.conf" > /dev/null; then
        site_count=$(ls -1 "${SM_SITES_DIR}"/*.conf 2>/dev/null | wc -l)
    fi
    printf "  Сайтов:   ${BOLD}%d${NC}\n" "$site_count"
    
    # SSL сертификаты (acme.sh + legacy certbot)
    local ssl_count=0
    if [[ -d "${SM_ACME_SSL_DIR:-/etc/ssl/acme}" ]]; then
        ssl_count=$(find "${SM_ACME_SSL_DIR:-/etc/ssl/acme}" -maxdepth 1 -type f -name "*.fullchain.cer" 2>/dev/null | wc -l)
    fi
    if [[ -d "/etc/letsencrypt/live" ]]; then
        ssl_count=$(( ssl_count + $(find /etc/letsencrypt/live -maxdepth 1 -mindepth 1 -type d ! -name "letsencrypt" 2>/dev/null | wc -l) ))
    fi
    printf "  SSL:      ${BOLD}%d${NC} сертификатов\n" "$ssl_count"
    
    echo
}

#=====================================================================
# Шаблоны Nginx и Apache для сайта
#=====================================================================

# (DEPRECATED) change_php_version_in_config / change_apache_php_version удалены в v3.2.0:
# они патчили nginx-конфиг через sed, но sed-паттерны не учитывали per-site FPM-сокет
# (/run/php/php${v}-fpm-${domain}.sock vs /run/php/php${v}-fpm.sock), из-за чего замена
# не срабатывала и сайт переставал отвечать после смены PHP-версии.
# change_site_php теперь перерендеривает конфиг через render_nginx_site / render_apache_site.

# Аргументы: domain, doc_root, php_ver, backend
render_nginx_site() {
    local domain="$1" doc_root="$2" php_ver="$3" backend="$4" www_alias="${5:-true}" ssl_config="${6:-}"
    local conf="/etc/nginx/sites-available/${domain}.conf"
    local tmp_conf="/etc/nginx/sites-available/.servermanager.${domain}.$$.conf"
    local php_endpoint
    local names
    names="$(site_server_names "$domain" "$www_alias")"

    case "$backend" in
        php-fpm)
            php_endpoint=$(create_site_fpm_pool "$php_ver" "$domain")
            # Nginx напрямую работает с PHP-FPM
            cat > "$tmp_conf" <<EOF
# servermanager managed — ${domain}
server {
    listen 80;
    listen [::]:80;
    server_name ${names};
    root ${doc_root};
    index index.php index.html;

    access_log /var/log/nginx/${domain}.access.log;
    error_log  /var/log/nginx/${domain}.error.log;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "interest-cohort=()" always;

    # Статика
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff2?|ttf|webp)\$ {
        expires 30d;
        access_log off;
        add_header Cache-Control "public, no-transform";
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass ${php_endpoint};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 16 16k;
    }

    # Запрет доступа к скрытым файлам и .ht*
    location ~ /\.(?!well-known) { deny all; }

    gzip on;
    gzip_vary on;
    gzip_min_length 1000;
    gzip_types text/plain text/css application/json application/javascript application/xml image/svg+xml;
}
EOF

# Добавляем SSL конфигурацию если она была сохранена
if [[ -n "$ssl_config" ]]; then
    if [[ "$backend" == "php-fpm" ]]; then
        # SSL для PHP-FPM
        cat >> "$tmp_conf" <<SSL_EOF

# SSL configuration (preserved from Certbot)
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${names};
    root ${doc_root};
    index index.php index.html;

    access_log /var/log/nginx/${domain}.access.log;
    error_log  /var/log/nginx/${domain}.error.log;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "interest-cohort=()" always;

    # Статика
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff2?|ttf|webp)\$ {
        expires 30d;
        access_log off;
        add_header Cache-Control "public, no-transform";
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass ${php_endpoint};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 16 16k;
    }

    # Запрет доступа к скрытым файлам и .ht*
    location ~ /\.(?!well-known) { deny all; }

    gzip on;
    gzip_vary on;
    gzip_min_length 1000;
    gzip_types text/plain text/css application/json application/javascript application/xml image/svg+xml;

$ssl_config
}
SSL_EOF
    else
        # SSL для Apache бэкендов
        cat >> "$tmp_conf" <<SSL_EOF

# SSL configuration (preserved from Certbot)
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${names};
    root ${doc_root};
    index index.php index.html;

    access_log /var/log/nginx/${domain}.access.log;
    error_log  /var/log/nginx/${domain}.error.log;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "interest-cohort=()" always;

    # Статика обслуживается Nginx напрямую
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff2?|ttf|webp)\$ {
        expires 30d;
        access_log off;
        try_files \$uri @apache;
    }

    location ~ /\.(?!well-known) { deny all; }

    # Всё остальное → Apache
    location / {
        try_files \$uri @apache;
    }

    location @apache {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        proxy_buffering on;
        proxy_buffers 16 16k;
    }

    gzip on;
    gzip_vary on;
    gzip_min_length 1000;
    gzip_types text/plain text/css application/json application/javascript application/xml image/svg+xml;

$ssl_config
}
SSL_EOF
    fi
fi
            ;;
        apache-mod-php|apache-php-fpm)
            # Nginx проксирует динамику в Apache на 127.0.0.1:8080; статика отдаётся Nginx
            if [[ -n "$ssl_config" ]]; then
                # Создаем конфигурацию с SSL для Apache
                cat > "$tmp_conf" <<EOF
# servermanager managed — ${domain}
server {
    listen 80;
    listen [::]:80;
    server_name ${names};
    root ${doc_root};
    index index.php index.html;

    access_log /var/log/nginx/${domain}.access.log;
    error_log  /var/log/nginx/${domain}.error.log;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Статика обслуживается Nginx напрямую
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff2?|ttf|webp)\$ {
        expires 30d;
        access_log off;
        try_files \$uri @apache;
    }

    location ~ /\.(?!well-known) { deny all; }

    # Всё остальное → Apache
    location / {
        try_files \$uri @apache;
    }

    location @apache {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        proxy_buffering on;
        proxy_buffers 16 16k;
    }

    gzip on;
    gzip_vary on;
    gzip_min_length 1000;
    gzip_types text/plain text/css application/json application/javascript application/xml image/svg+xml;
}

# SSL configuration (preserved from Certbot)
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${names};
    root ${doc_root};
    index index.php index.html;

    access_log /var/log/nginx/${domain}.access.log;
    error_log  /var/log/nginx/${domain}.error.log;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "interest-cohort=()" always;

    # Статика обслуживается Nginx напрямую
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff2?|ttf|webp)\$ {
        expires 30d;
        access_log off;
        try_files \$uri @apache;
    }

    location ~ /\.(?!well-known) { deny all; }

    # Всё остальное → Apache
    location / {
        try_files \$uri @apache;
    }

    location @apache {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        proxy_buffering on;
        proxy_buffers 16 16k;
    }

    gzip on;
    gzip_vary on;
    gzip_min_length 1000;
    gzip_types text/plain text/css application/json application/javascript application/xml image/svg+xml;

$ssl_config
}

$ssl_config
EOF
            else
                # Создаем конфигурацию без SSL для Apache
                cat > "$tmp_conf" <<EOF
# servermanager managed — ${domain}
server {
    listen 80;
    listen [::]:80;
    server_name ${names};
    root ${doc_root};
    index index.php index.html;

    access_log /var/log/nginx/${domain}.access.log;
    error_log  /var/log/nginx/${domain}.error.log;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Статика обслуживается Nginx напрямую
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff2?|ttf|webp)\$ {
        expires 30d;
        access_log off;
        try_files \$uri @apache;
    }

    location ~ /\.(?!well-known) { deny all; }

    # Всё остальное → Apache
    location / {
        try_files \$uri @apache;
    }

    location @apache {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        proxy_buffering on;
        proxy_buffers 16 16k;
    }

    gzip on;
    gzip_vary on;
    gzip_min_length 1000;
    gzip_types text/plain text/css application/json application/javascript application/xml image/svg+xml;
}
EOF
            fi
            ;;
        *)
            log_error "Неизвестный backend: $backend"
            return 1
            ;;
    esac

    nginx_apply_site_conf "$domain" "$tmp_conf" "$conf"
}

render_apache_site() {
    local domain="$1" doc_root="$2" php_ver="$3" backend="$4" www_alias="${5:-true}"
    local conf handler_block php_endpoint
    local tmp_conf
    tmp_conf="$(mktemp)"

    if [[ "$OS_TYPE" == "debian" ]]; then
        conf="/etc/apache2/sites-available/${domain}.conf"
    else
        conf="/etc/httpd/conf.d/${domain}.conf"
    fi

    case "$backend" in
        apache-mod-php)
            # mod_php работает только для default PHP (одна версия mod_php в Apache)
            handler_block=""  # Apache сам обработает через mod_php<ver>
            ;;
        apache-php-fpm)
            php_endpoint=$(create_site_fpm_pool "$php_ver" "$domain")
            # В SetHandler proxy_fcgi принимает префикс "unix:" или "fcgi://host:port"
            local proxy_target
            if [[ "$php_endpoint" == unix:* ]]; then
                proxy_target="unix:${php_endpoint#unix:}|fcgi://localhost"
            else
                proxy_target="fcgi://${php_endpoint}"
            fi
            handler_block=$(cat <<EOF
    <FilesMatch \.php\$>
        SetHandler "proxy:${proxy_target}"
    </FilesMatch>
EOF
)
            ;;
        *)
            return 0
            ;;
    esac

    local alias_line
    alias_line="$(apache_server_alias_line "$domain" "$www_alias")"
    cat > "$tmp_conf" <<EOF
# servermanager managed — ${domain}
<VirtualHost 127.0.0.1:8080>
    ServerName ${domain}
${alias_line}
    DocumentRoot ${doc_root}

    <Directory ${doc_root}>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

${handler_block}

    # Получаем реальный IP от Nginx
    SetEnvIf X-Forwarded-Proto "https" HTTPS=on
    RemoteIPHeader X-Forwarded-For

    ErrorLog /var/log/$([ "$OS_TYPE" = "debian" ] && echo apache2 || echo httpd)/${domain}.error.log
    CustomLog /var/log/$([ "$OS_TYPE" = "debian" ] && echo apache2 || echo httpd)/${domain}.access.log combined
</VirtualHost>
EOF

    apache_apply_site_conf "$domain" "$tmp_conf" "$conf" "$backend"
}

#=====================================================================
# SELinux (для RHEL/Rocky/AlmaLinux)
# Без этого nginx/httpd не сможет читать /var/www/<domain> и подключаться
# к сокетам PHP-FPM — результат обычно 403.
#=====================================================================
selinux_enabled() {
    [[ "$OS_TYPE" == "rhel" ]] || return 1
    command_exists getenforce || return 1
    [[ "$(getenforce 2>/dev/null)" != "Disabled" ]]
}

selinux_ensure_tools() {
    # policycoreutils-python-utils даёт semanage/restorecon/chcon
    if ! command_exists semanage; then
        pkg_install policycoreutils-python-utils 2>/dev/null \
          || pkg_install policycoreutils-python 2>/dev/null \
          || log_warn "Не удалось установить policycoreutils-python-utils"
    fi
}

selinux_fix_site() {
    local doc_root="$1"
    selinux_enabled || return 0
    selinux_ensure_tools

    # Разрешить HTTPD читать контент сайта
    if command_exists semanage; then
        semanage fcontext -a -t httpd_sys_content_t "${doc_root}(/.*)?" 2>/dev/null \
          || semanage fcontext -m -t httpd_sys_content_t "${doc_root}(/.*)?" 2>/dev/null || true
        # Для writable директорий (uploads, cache) пользователь может вручную
        # применить: semanage fcontext -a -t httpd_sys_rw_content_t "<path>(/.*)?"
    fi
    command_exists restorecon && restorecon -R "${doc_root}" >/dev/null 2>&1 || true

    # Разрешить HTTPD делать сетевые соединения и подключаться к FPM-сокетам
    command_exists setsebool && setsebool -P httpd_can_network_connect on 2>/dev/null || true
}

#=====================================================================
# Добавление / удаление сайта
#=====================================================================

add_site() {
    # Валидация
    if ! validate_domain "$DOMAIN"; then
        log_error "Некорректное доменное имя: '${DOMAIN}'"
        log_error "Ожидается формат: example.com, sub.example.com, localhost"
        return 1
    fi

    # Не добавляем дубликат
    if [[ -f "${SM_SITES_DIR}/${DOMAIN}.conf" ]]; then
        log_error "Сайт ${DOMAIN} уже существует. Используйте 'change-php'/'remove-site' или другой домен."
        return 1
    fi

    log_section "Добавление сайта: ${DOMAIN}"

    # Чистим очередь отката перед началом защищённой операции.
    clear_rollback

    # Проверки готовности
    ensure_php_installed_for_site "$SITE_PHP_VERSION" || return 1
    if [[ "$SITE_BACKEND" == "apache-mod-php" ]]; then
        # mod_php работает только для default PHP
        local default_php
        default_php="$(state_get default_php_version)"
        if [[ -z "$default_php" || "$SITE_PHP_VERSION" != "$default_php" ]]; then
            log_error "apache-mod-php поддерживает только default PHP (${default_php:-не задан})"
            return 1
        fi
    fi

    # Создаём директорию сайта. Откат удалит её обратно, но ТОЛЬКО если она в /var/www/
    # и не существовала до нас (assert_safe_docroot_for_delete страхует).
    local _dir_existed_before=false
    [[ -d "$SITE_DIR" ]] && _dir_existed_before=true
    mkdir -p "$SITE_DIR"
    if ! $_dir_existed_before; then
        register_rollback "if assert_safe_docroot_for_delete '${SITE_DIR}' 2>/dev/null; then rm -rf '${SITE_DIR}'; fi"
    fi
    register_rollback "rm -f '${SM_SITES_DIR}/${DOMAIN}.conf'"
    register_rollback "rm -f '/etc/nginx/sites-enabled/${DOMAIN}.conf' '/etc/nginx/sites-available/${DOMAIN}.conf'"
    if [[ "$OS_TYPE" == "debian" ]]; then
        register_rollback "a2dissite '${DOMAIN}.conf' >/dev/null 2>&1 || true; rm -f '/etc/apache2/sites-available/${DOMAIN}.conf'"
    else
        register_rollback "rm -f '/etc/httpd/conf.d/${DOMAIN}.conf'"
    fi
    register_rollback "remove_site_fpm_pool '${SITE_PHP_VERSION}' '${DOMAIN}'"

    # Владелец
    local web_user
    if [[ "$OS_TYPE" == "debian" ]]; then web_user="www-data"; else web_user="apache"; fi

    # Тестовая index.php
    if [[ ! -f "${SITE_DIR}/index.php" && ! -f "${SITE_DIR}/index.html" ]]; then
        cat > "${SITE_DIR}/index.php" <<'PHPEOF'
<?php
declare(strict_types=1);

$host = htmlspecialchars($_SERVER['HTTP_HOST'] ?? 'localhost', ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
$php  = htmlspecialchars(PHP_VERSION, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
$sapi = htmlspecialchars((string)php_sapi_name(), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
$sw   = htmlspecialchars($_SERVER['SERVER_SOFTWARE'] ?? 'n/a', ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');

header('Content-Type: text/html; charset=UTF-8');
?>
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title><?= $host ?> — стартовая страница</title>
  <style>
    :root { color-scheme: light dark; }
    body { font-family: system-ui, -apple-system, Segoe UI, Roboto, Ubuntu, Cantarell, Noto Sans, Arial, sans-serif; margin: 0; padding: 32px; }
    .card { max-width: 760px; margin: 0 auto; padding: 24px; border-radius: 14px; border: 1px solid rgba(127,127,127,.25); background: rgba(127,127,127,.06); }
    h1 { margin: 0 0 10px; font-size: 22px; }
    p { margin: 8px 0; line-height: 1.5; }
    code { padding: 2px 6px; border-radius: 6px; background: rgba(127,127,127,.15); }
    .muted { opacity: .75; }
    .grid { display: grid; grid-template-columns: 1fr; gap: 8px; margin-top: 14px; }
    @media (min-width: 640px) { .grid { grid-template-columns: 1fr 1fr; } }
  </style>
</head>
<body>
  <div class="card">
    <h1>Это начальная страница сайта <code><?= $host ?></code></h1>
    <p class="muted">Сервер управляется скриптом <code>servermanager.sh</code>.</p>
    <div class="grid">
      <p><strong>PHP</strong>: <code><?= $php ?></code></p>
      <p><strong>SAPI</strong>: <code><?= $sapi ?></code></p>
      <p><strong>Server</strong>: <code><?= $sw ?></code></p>
    </div>
  </div>
</body>
</html>
PHPEOF
    fi
    chown -R "${web_user}:${web_user}" "$SITE_DIR"

    # SELinux contexts (no-op на Debian/Ubuntu)
    selinux_fix_site "$SITE_DIR"

    # Сохраняем метаданные СРАЗУ — до рендеринга конфигов.
    # Так сайт всегда отображается в списке, даже если рендер упадёт.
    # SSL=false на этом этапе; обновляем до true только после успешного acme.sh.
    save_site_config "$DOMAIN" "$SITE_DIR" "$SITE_PHP_VERSION" "$SITE_BACKEND" "false" "${DB_NAME:-}" "${DB_USER:-}" "$SITE_WWW_ALIAS"

    # Render configs
    render_nginx_site "$DOMAIN" "$SITE_DIR" "$SITE_PHP_VERSION" "$SITE_BACKEND" "$SITE_WWW_ALIAS"
    if [[ "$SITE_BACKEND" != "php-fpm" ]]; then
        # При выборе apache-* backend: Apache обязателен
        if ! command_exists apache2 && ! command_exists httpd; then
            install_apache
        fi
        [[ "$SITE_BACKEND" == "apache-mod-php" ]] && ensure_apache_mod_php || true
        render_apache_site "$DOMAIN" "$SITE_DIR" "$SITE_PHP_VERSION" "$SITE_BACKEND" "$SITE_WWW_ALIAS"
    fi

    # БД
    if [[ "$CREATE_DB" == true ]]; then
        create_site_database "$DB_NAME" "$DB_USER" "$DB_PASS"
        # Регистрируем откат БД + кред-файла. Откат безопасный: dropUser/dropDatabase идемпотентны.
        register_rollback "drop_site_database '${DB_NAME}' '${DB_USER}' 2>/dev/null || true"
        register_rollback "rm -f '${SM_CRED_DIR}/db-${DOMAIN}.txt'"
        # Сохраняем креды в защищённый файл
        local cred_file="${SM_CRED_DIR}/db-${DOMAIN}.txt"
        cat > "$cred_file" <<EOF
# servermanager — учётные данные БД для ${DOMAIN}
DB_HOST=127.0.0.1
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
EOF
        chmod 600 "$cred_file"
        log_ok "Учётные данные БД сохранены в ${cred_file}"
    fi

    # SSL: обновляем статус в конфиге только после успеха acme.sh.
    # SSL-выпуск НЕ считается критической операцией — rate-limit / DNS-ошибка не должна
    # откатывать уже созданный сайт. Поэтому сбрасываем rollback ДО попытки SSL.
    clear_rollback

    if [[ "$ENABLE_SSL" == true ]]; then
        if setup_ssl_for_site "$DOMAIN"; then
            save_site_config "$DOMAIN" "$SITE_DIR" "$SITE_PHP_VERSION" "$SITE_BACKEND" "true" "${DB_NAME:-}" "${DB_USER:-}" "$SITE_WWW_ALIAS"
        else
            log_warn "SSL не был настроен — в конфиге сайта SSL=false. Запустите снова через меню: Сайты → Выпустить SSL."
        fi
    fi

    log_ok "Сайт ${DOMAIN} добавлен"
    return 0
}

remove_site() {
    local domain="$1"
    log_section "Удаление сайта: ${domain}"
    if ! load_site_config "$domain"; then
        log_error "Сайт ${domain} не найден в ${SM_SITES_DIR}"
        return 1
    fi
    local php_ver="${PHP_VERSION}"
    local backend="${BACKEND}"
    local doc_root="${DOCUMENT_ROOT}"
    local db_name="${DB_NAME}"
    local db_user="${DB_USER}"

    # Конфиги Nginx
    rm -f "/etc/nginx/sites-enabled/${domain}.conf" "/etc/nginx/sites-available/${domain}.conf"
    # Apache
    if [[ "$OS_TYPE" == "debian" ]]; then
        a2dissite "${domain}.conf" >/dev/null 2>&1 || true
        rm -f "/etc/apache2/sites-available/${domain}.conf"
    else
        rm -f "/etc/httpd/conf.d/${domain}.conf"
    fi
    # FPM pool
    remove_site_fpm_pool "$php_ver" "$domain"

    # БД (с подтверждением отдельно)
    if [[ -n "$db_name" ]]; then
        if prompt_yes_no "Удалить также БД '${db_name}' и пользователя '${db_user}'?" "n"; then
            drop_site_database "$db_name" "$db_user"
        fi
    fi

    # Директория сайта (с подтверждением)
    if [[ -d "$doc_root" ]]; then
        if prompt_yes_no "Удалить директорию ${doc_root} со всем содержимым?" "n"; then
            if assert_safe_docroot_for_delete "$doc_root"; then
                rm -rf "$doc_root"
            else
                log_error "Отказываюсь удалять небезопасный путь: '${doc_root}'"
                log_error "Разрешено удалять только внутри /var/www/* (и не /var/www целиком)"
                return 1
            fi
        fi
    fi

    rm -f "${SM_SITES_DIR}/${domain}.conf"
    rm -f "${SM_CRED_DIR}/db-${domain}.txt"

    # Reload webservers (не используем &&/|| — они сложно сочетаются с set -e).
    if nginx -t >/dev/null 2>&1; then
        $SVC_MGR reload nginx >/dev/null 2>&1 || log_warn "nginx reload не удался"
    else
        log_warn "nginx -t не прошёл после удаления сайта — проверьте /etc/nginx"
    fi
    if [[ "$OS_TYPE" == "debian" ]]; then
        $SVC_MGR reload apache2 >/dev/null 2>&1 || true
    else
        $SVC_MGR reload httpd >/dev/null 2>&1 || true
    fi

    log_ok "Сайт ${domain} удалён"
}

# Переключение PHP-версии сайта.
#
# Подход: НЕ патчим конфиг через sed (это было источником багов с путями сокетов
# вида /run/php/php${v}-fpm-${domain}.sock vs /run/php/php${v}-fpm.sock).
# Вместо этого ПЕРЕРЕНДЕРИВАЕМ nginx/apache-конфиги через render_*_site()
# с новой версией PHP. Это атомарно и гарантирует консистентность.
change_site_php() {
    local domain="$1" new_ver="$2"

    if ! load_site_config "$domain"; then
        log_error "Сайт ${domain} не найден"
        return 1
    fi

    if ! state_list_php | tr ' ' '\n' | grep -qxF "$new_ver"; then
        log_error "PHP ${new_ver} не установлен. Сначала добавьте версию."
        return 1
    fi

    # apache-mod-php работает только для default PHP (одна версия mod_php в Apache).
    local default_php
    default_php=$(state_get default_php_version)
    if [[ "$BACKEND" == "apache-mod-php" && "$new_ver" != "$default_php" ]]; then
        log_warn "apache-mod-php поддерживает только default PHP (${default_php})."
        if prompt_yes_no "Переключить backend на apache-php-fpm (чтобы использовать PHP ${new_ver})?" "y"; then
            BACKEND="apache-php-fpm"
        else
            return 1
        fi
    fi

    local old_ver="$PHP_VERSION"
    if [[ "$old_ver" == "$new_ver" ]]; then
        log_info "Сайт ${domain} уже использует PHP ${new_ver} — изменений не требуется"
        return 0
    fi

    local nginx_conf="/etc/nginx/sites-available/${domain}.conf"
    local apache_conf=""
    if [[ "$OS_TYPE" == "debian" ]]; then
        apache_conf="/etc/apache2/sites-available/${domain}.conf"
    else
        apache_conf="/etc/httpd/conf.d/${domain}.conf"
    fi

    log_info "Начинаю переключение сайта ${domain}: PHP ${old_ver} → ${new_ver} (backend: ${BACKEND})"

    # Бэкапим существующие конфиги (для rollback).
    backup_config "$nginx_conf" || log_warn "Не удалось создать бэкап nginx-конфига"
    if [[ "$BACKEND" == "apache-mod-php" || "$BACKEND" == "apache-php-fpm" ]]; then
        [[ -f "$apache_conf" ]] && backup_config "$apache_conf" || true
    fi

    # Сохраняем ссылку на текущий SSL-конфиг (если SSL включён) — чтобы
    # после re-render не потерять сертификаты.
    local preserved_ssl=""
    if bool_is_true "${SSL:-false}"; then
        preserved_ssl="$(extract_ssl_config "$domain" 2>/dev/null || true)"
    fi

    local rollback_needed=false
    _change_php_rollback() {
        log_warn "Откат change_site_php для ${domain}..."
        # Восстанавливаем конфиги.
        restore_config "$nginx_conf" 2>/dev/null || true
        if [[ "$BACKEND" == "apache-mod-php" || "$BACKEND" == "apache-php-fpm" ]]; then
            [[ -f "$apache_conf" ]] && restore_config "$apache_conf" 2>/dev/null || true
        fi
        # Удаляем новый FPM-пул, восстанавливаем старый (если были).
        if [[ "$BACKEND" == "php-fpm" || "$BACKEND" == "apache-php-fpm" ]]; then
            remove_site_fpm_pool "$new_ver" "$domain" >/dev/null 2>&1 || true
            create_site_fpm_pool "$old_ver" "$domain" >/dev/null 2>&1 || true
        fi
        # Пробуем reload nginx с восстановленным конфигом.
        nginx -t >/dev/null 2>&1 && $SVC_MGR reload nginx >/dev/null 2>&1 || true
        if [[ "$BACKEND" == "apache-mod-php" || "$BACKEND" == "apache-php-fpm" ]]; then
            if [[ "$OS_TYPE" == "debian" ]]; then
                $SVC_MGR reload apache2 >/dev/null 2>&1 || true
            else
                $SVC_MGR reload httpd >/dev/null 2>&1 || true
            fi
        fi
    }

    # Рендерим новый nginx-конфиг с новой версией PHP (render_nginx_site сам
    # создаст per-site FPM-пул через create_site_fpm_pool).
    if bool_is_true "${SSL:-false}" && [[ -n "$preserved_ssl" ]]; then
        # SSL был включён — используем update_site_config_with_ssl (он умеет SSL-блок).
        # Для этого нужно обновить PHP_VERSION в загруженной конфиге, иначе update_site_config_with_ssl
        # возьмёт старую версию.
        PHP_VERSION="$new_ver"
        if ! update_site_config_with_ssl "$domain" "$SM_ACME_SSL_DIR"; then
            rollback_needed=true
            log_error "Не удалось перерендерить SSL-конфиг для PHP ${new_ver}"
        fi
    else
        if ! render_nginx_site "$domain" "$DOCUMENT_ROOT" "$new_ver" "$BACKEND" "${WWW_ALIAS:-true}" ""; then
            rollback_needed=true
            log_error "Не удалось перерендерить nginx-конфиг для PHP ${new_ver}"
        fi
    fi

    # Apache-конфиг (если используется Apache-backend).
    if ! $rollback_needed && [[ "$BACKEND" == "apache-mod-php" || "$BACKEND" == "apache-php-fpm" ]]; then
        if ! render_apache_site "$domain" "$DOCUMENT_ROOT" "$new_ver" "$BACKEND" "${WWW_ALIAS:-true}"; then
            rollback_needed=true
            log_error "Не удалось перерендерить apache-конфиг для PHP ${new_ver}"
        fi
    fi

    if $rollback_needed; then
        _change_php_rollback
        return 1
    fi

    # Ждём, пока поднимется FPM-сокет новой версии (только для FPM-backend'ов).
    if [[ "$BACKEND" == "php-fpm" || "$BACKEND" == "apache-php-fpm" ]]; then
        local retries=0
        local max_retries=5
        while (( retries < max_retries )); do
            if validate_php_fpm_socket "$new_ver" "$domain"; then
                break
            fi
            sleep 1
            ((retries++))
        done
        if ! validate_php_fpm_socket "$new_ver" "$domain"; then
            log_error "PHP-FPM сокет для ${new_ver} не появился — откатываю"
            _change_php_rollback
            return 1
        fi
    fi

    # Удаляем старый FPM-пул (он больше не используется этим сайтом).
    # Другие сайты на этой же версии продолжают работать через свои per-site пулы.
    if [[ "$old_ver" != "$new_ver" ]]; then
        remove_site_fpm_pool "$old_ver" "$domain" >/dev/null 2>&1 || true
    fi

    # Сохраняем состояние.
    save_site_config "$DOMAIN" "$DOCUMENT_ROOT" "$new_ver" "$BACKEND" "${SSL:-false}" "${DB_NAME:-}" "${DB_USER:-}" "${WWW_ALIAS:-true}"

    log_ok "Сайт ${domain} переключён на PHP ${new_ver} (backend: ${BACKEND})"
    if bool_is_true "${SSL:-false}"; then
        log_info "Проверьте: https://${domain}"
    else
        log_info "Проверьте: http://${domain}"
    fi
    return 0
}


#=====================================================================
# SSL Helper Functions
#=====================================================================

# Извлечь SSL конфигурацию из существующего файла
extract_ssl_config() {
    local domain="$1"
    local conf_file="/etc/nginx/sites-enabled/${domain}.conf"
    
    [[ -f "$conf_file" ]] || return 0
    
    # Извлекаем только SSL сертификаты и настройки, не включая listen директивы
    awk '
    BEGIN { server_count=0; ssl_config=""; second_server=""; has_ssl=false; }
    
    # Считаем server блоки
    /^server\s*{/ { 
        server_count++
        if (server_count == 1) {
            current_block = "first"
        } else if (server_count == 2) {
            current_block = "second"
        }
    }
    
    # В первом server блоке ищем SSL сертификаты (но не listen)
    current_block == "first" && (/ssl_certificate/ || /ssl_certificate_key/ || /include.*letsencrypt/ || /ssl_dhparam/) {
        has_ssl = true
        ssl_config = ssl_config $0 "\n"
    }
    
    # Собираем второй server блок полностью
    current_block == "second" {
        second_server = second_server $0 "\n"
    }
    
    END {
        # Выводим только если есть SSL сертификаты
        if (has_ssl && ssl_config != "") {
            printf "# SSL configuration (preserved from Certbot)\n"
            printf "%s", ssl_config
        }
        
        # Выводим второй server блок если он есть
        if (second_server != "") {
            printf "\n# HTTP redirect server block (preserved from Certbot)\n"
            printf "%s", second_server
        }
    }
    ' "$conf_file"
}

# Валидация PHP-FPM сокета
validate_php_fpm_socket() {
    local php_ver="$1" domain="$2"
    local socket_path="/run/php/php${php_ver}-fpm-${domain}.sock"
    
    [[ -S "$socket_path" ]] && [[ -r "$socket_path" ]]
}

# Перезапуск PHP-FPM сервиса
restart_php_fpm() {
    local php_ver="$1"
    local service_name="php${php_ver}-fpm"
    
    if [[ "$OS_TYPE" == "debian" ]]; then
        $SVC_MGR restart "$service_name" >>"$LOG_FILE" 2>&1
    else
        # RHEL: php74-php-fpm, php80-php-fpm, etc.
        local scl_name="php${php_ver//./}"
        $SVC_MGR restart "${scl_name}-php-fpm" >>"$LOG_FILE" 2>&1
    fi
}

#=====================================================================
# SSL (Let's Encrypt) через acme.sh в режиме --webroot
# Принцип: acme.sh кладёт токен в ${DOCROOT}/.well-known/acme-challenge/,
# Nginx отдаёт его по HTTP — без остановки веб-сервера и без :80 bind conflict.
#=====================================================================

SM_ACME_HOME="${SM_ACME_HOME:-/root/.acme.sh}"
SM_ACME_SSL_DIR="${SM_ACME_SSL_DIR:-/etc/ssl/acme}"

# Установка acme.sh если отсутствует (идемпотентная)
install_acme_sh() {
    local acme_cmd="${SM_ACME_HOME}/acme.sh"

    if [[ -x "$acme_cmd" ]]; then
        return 0
    fi

    log_info "Устанавливаю acme.sh..."

    # Зависимости: socat нужен для TLS-ALPN, curl — для HTTP-01, cron — для автообновления.
    if [[ "$OS_TYPE" == "debian" ]]; then
        pkg_install curl socat cron >/dev/null 2>&1 || true
    else
        pkg_install curl socat cronie >/dev/null 2>&1 || true
        $SVC_MGR enable --now crond >/dev/null 2>&1 || true
    fi

    # Email берём из SSL_EMAIL если задан, иначе admin@<hostname>.
    local email="${SSL_EMAIL:-admin@$(hostname -f 2>/dev/null || hostname)}"

    # get.acme.sh ставит в $HOME/.acme.sh, добавляет cron и alias.
    if ! curl -fsSL https://get.acme.sh | sh -s "email=${email}" >>"$LOG_FILE" 2>&1; then
        log_error "Не удалось установить acme.sh — см. ${LOG_FILE}"
        return 1
    fi

    # Идемпотентный PATH в .bashrc (только если ещё не прописан).
    local rc="$HOME/.bashrc"
    local path_line='export PATH="$HOME/.acme.sh:$PATH"'
    if [[ -f "$rc" ]] && ! grep -qxF "$path_line" "$rc"; then
        echo "$path_line" >> "$rc"
    fi
    export PATH="${SM_ACME_HOME}:$PATH"

    # Используем Let's Encrypt как default CA (acme.sh с 3.0 использует ZeroSSL по умолчанию).
    "$acme_cmd" --set-default-ca --server letsencrypt >>"$LOG_FILE" 2>&1 || true

    log_ok "acme.sh установлен в ${SM_ACME_HOME}"
}

# Перерендеривает nginx-конфиг сайта с включённым SSL (cert от acme.sh).
# HTTP-блок отдаёт .well-known/acme-challenge/ из docroot (нужно для renewal),
# остальные запросы редиректит на HTTPS.
update_site_config_with_ssl() {
    local domain="$1" ssl_dir="$2"
    local conf_file="/etc/nginx/sites-available/${domain}.conf"
    local tmp_conf="/etc/nginx/sites-available/.servermanager.ssl.${domain}.$$.conf"

    if ! load_site_config "$domain"; then
        log_error "Не удалось загрузить конфигурацию сайта $domain"
        return 1
    fi

    local names
    names="$(site_server_names "$domain" "${WWW_ALIAS:-true}")"

    local php_endpoint=""
    if [[ "$BACKEND" == "php-fpm" || "$BACKEND" == "apache-php-fpm" ]]; then
        php_endpoint="unix:/run/php/php${PHP_VERSION}-fpm-${domain}.sock"
        # На RHEL путь сокета другой — учитываем.
        if [[ "$OS_TYPE" == "rhel" ]]; then
            local scl="php${PHP_VERSION//./}"
            php_endpoint="unix:/var/opt/remi/${scl}/run/php-fpm/${domain}.sock"
        fi
    fi

    # Общий HTTP-блок: challenge → docroot, остальное → 301 HTTPS.
    {
        cat <<EOF
# servermanager managed — ${domain}
server {
    listen 80;
    listen [::]:80;
    server_name ${names};

    # ACME http-01 challenge (acme.sh --webroot)
    location ^~ /.well-known/acme-challenge/ {
        root ${DOCUMENT_ROOT};
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

EOF

        # HTTPS блок зависит от backend'а.
        case "$BACKEND" in
            php-fpm)
                cat <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${names};
    root ${DOCUMENT_ROOT};
    index index.php index.html;

    access_log /var/log/nginx/${domain}.access.log;
    error_log  /var/log/nginx/${domain}.error.log;

    ssl_certificate ${ssl_dir}/${domain}.fullchain.cer;
    ssl_certificate_key ${ssl_dir}/${domain}.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "interest-cohort=()" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff2?|ttf|webp)\$ {
        expires 30d;
        access_log off;
        add_header Cache-Control "public, no-transform";
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass ${php_endpoint};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTPS on;
        include fastcgi_params;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 16 16k;
    }

    location ~ /\.(?!well-known) { deny all; }

    gzip on;
    gzip_vary on;
    gzip_min_length 1000;
    gzip_types text/plain text/css application/json application/javascript application/xml image/svg+xml;
}
EOF
                ;;
            apache-mod-php|apache-php-fpm)
                cat <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${names};
    root ${DOCUMENT_ROOT};
    index index.php index.html;

    access_log /var/log/nginx/${domain}.access.log;
    error_log  /var/log/nginx/${domain}.error.log;

    ssl_certificate ${ssl_dir}/${domain}.fullchain.cer;
    ssl_certificate_key ${ssl_dir}/${domain}.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff2?|ttf|webp)\$ {
        expires 30d;
        access_log off;
        try_files \$uri @apache;
    }

    location ~ /\.(?!well-known) { deny all; }

    location / {
        try_files \$uri @apache;
    }

    location @apache {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        proxy_buffering on;
        proxy_buffers 16 16k;
    }

    gzip on;
    gzip_vary on;
    gzip_min_length 1000;
    gzip_types text/plain text/css application/json application/javascript application/xml image/svg+xml;
}
EOF
                ;;
        esac
    } > "$tmp_conf"

    if nginx_apply_site_conf "$domain" "$tmp_conf" "$conf_file"; then
        SSL="true"
        save_site_config "$DOMAIN" "$DOCUMENT_ROOT" "$PHP_VERSION" "$BACKEND" "$SSL" "${DB_NAME:-}" "${DB_USER:-}" "${WWW_ALIAS:-true}"
        log_ok "SSL конфигурация обновлена для ${domain}"
        return 0
    else
        log_error "Не удалось применить SSL конфигурацию для ${domain}"
        return 1
    fi
}

# Настройка cron для автообновления через acme.sh.
# acme.sh --install-cronjob добавляет корневой cron, который вызывает --cron ежедневно.
setup_acme_cron() {
    local acme_cmd="${SM_ACME_HOME}/acme.sh"
    [[ -x "$acme_cmd" ]] || return 0
    if "$acme_cmd" --install-cronjob >>"$LOG_FILE" 2>&1; then
        log_info "acme.sh cron установлен для автообновления сертификатов"
    else
        log_warn "Не удалось установить cron для acme.sh — проверьте вручную"
    fi
}

#=====================================================================
# Основной путь получения SSL сертификата — acme.sh --webroot.
# Не требует остановки nginx, не занимает :80/:443.
#=====================================================================
setup_ssl_for_site() {
    local domain="$1"
    local www_alias="${WWW_ALIAS:-true}"

    if ! load_site_config "$domain" 2>/dev/null; then
        log_error "Сайт ${domain} не найден"
        return 1
    fi
    [[ -n "${WWW_ALIAS:-}" ]] && www_alias="${WWW_ALIAS}"

    if [[ "$domain" == "localhost" || "$domain" == *".local" ]]; then
        log_warn "SSL нельзя настроить для ${domain}"
        return 0
    fi

    # Проверка: домен резолвится? Для DNS-01 это не требуется (acme.sh ставит TXT-запись через API).
    if [[ "${SM_ACME_MODE:-webroot}" != "dns" ]]; then
        if ! getent hosts "$domain" >/dev/null 2>&1; then
            log_warn "Домен ${domain} не резолвится — SSL не будет настроен."
            log_warn "Варианты:"
            log_warn "  • настроить DNS и повторить: $0 issue-ssl ${domain}"
            log_warn "  • использовать DNS-01: SM_ACME_MODE=dns SM_ACME_DNS_PROVIDER=dns_cf $0 issue-ssl ${domain}"
            return 0
        fi
    fi

    install_acme_sh || return 1

    # Пред-проверка webroot делается только для webroot-режима — DNS-01/standalone не используют файлы.
    if [[ "${SM_ACME_MODE:-webroot}" == "webroot" ]]; then
        # Готовим docroot для challenge'ов.
        if [[ -z "${DOCUMENT_ROOT:-}" || ! -d "$DOCUMENT_ROOT" ]]; then
            log_error "DOCUMENT_ROOT не найден для ${domain}: ${DOCUMENT_ROOT:-<empty>}"
            return 1
        fi
        install -d -m 0755 "${DOCUMENT_ROOT}/.well-known/acme-challenge"
        # Владелец — веб-сервер (чтобы acme.sh мог писать, будучи запущен от root — ок, но на всякий случай).
        if [[ "$OS_TYPE" == "debian" ]]; then
            chown -R www-data:www-data "${DOCUMENT_ROOT}/.well-known" 2>/dev/null || true
        else
            chown -R apache:apache "${DOCUMENT_ROOT}/.well-known" 2>/dev/null || true
        fi

        # Проверяем, что nginx действительно отдаёт challenge-файлы (иначе acme.sh упадёт).
        local probe_token="_sm_probe_$$_$(date +%s)"
        local probe_file="${DOCUMENT_ROOT}/.well-known/acme-challenge/${probe_token}"
        echo "$probe_token" > "$probe_file"
        local probe_url="http://${domain}/.well-known/acme-challenge/${probe_token}"
        local probe_rc=0
        local probe_body
        probe_body="$(curl -fsS --max-time 10 "$probe_url" 2>/dev/null)" || probe_rc=$?
        rm -f "$probe_file"
        if (( probe_rc != 0 )) || [[ "$probe_body" != "$probe_token" ]]; then
            log_warn "HTTP-01 pre-flight не прошёл: ${probe_url} не отдаёт ожидаемый ответ."
            log_warn "Проверьте, что домен указывает на этот сервер и порт 80 открыт."
            log_warn "Если сайт за Cloudflare proxy — используйте DNS-01: SM_ACME_MODE=dns SM_ACME_DNS_PROVIDER=dns_cf $0 issue-ssl ${domain}"
            log_warn "Продолжаю попытку выпуска (acme.sh может сработать через другой путь)."
        fi
    fi

    local acme_cmd="${SM_ACME_HOME}/acme.sh"
    [[ -z "${SSL_EMAIL:-}" ]] && SSL_EMAIL="admin@${domain}"

    # Выбор сервера: staging (для тестов, лимиты 30000/час, сертификаты невалидны в браузере)
    # или production Let's Encrypt. Управляется SM_ACME_STAGING=1.
    local acme_server="letsencrypt"
    if [[ "${SM_ACME_STAGING:-0}" == "1" || "${SM_ACME_STAGING:-0}" == "true" ]]; then
        acme_server="letsencrypt_test"
        log_warn "SM_ACME_STAGING=1 — использую staging LE (сертификат НЕ будет доверенным в браузере, только для тестов)"
    fi

    # Режим валидации: webroot (default), standalone (acme.sh поднимает :80 сам),
    # dns (DNS-01 через API провайдера — самый надёжный, нужны SM_ACME_DNS_PROVIDER + креды).
    local acme_mode="${SM_ACME_MODE:-webroot}"
    case "$acme_mode" in
        webroot|standalone|dns) : ;;
        *) log_warn "Неизвестный SM_ACME_MODE='${acme_mode}', откатываюсь на webroot"; acme_mode="webroot" ;;
    esac

    log_info "Получаю сертификат для ${domain} через acme.sh --${acme_mode} (CA: ${acme_server})..."

    # Сборка аргументов в зависимости от режима.
    local -a issue_args=(--issue -d "$domain")
    case "$acme_mode" in
        webroot)
            issue_args+=(-w "$DOCUMENT_ROOT")
            ;;
        standalone)
            # acme.sh сам поднимет :80 — нужен установленный socat.
            # Если nginx/apache держит :80, acme.sh упадёт. Делаем явную остановку.
            issue_args+=(--standalone --httpport 80)
            if [[ "${SM_ACME_STOP_WEB:-0}" == "1" ]]; then
                log_warn "SM_ACME_STOP_WEB=1 — временно останавливаю веб-сервер для standalone validation"
                $SVC_MGR stop nginx >/dev/null 2>&1 || true
                $SVC_MGR stop apache2 >/dev/null 2>&1 || true
                $SVC_MGR stop httpd >/dev/null 2>&1 || true
                # Гарантируем рестарт после завершения issue — через trap.
                # shellcheck disable=SC2064
                trap "$SVC_MGR start nginx >/dev/null 2>&1 || true; \
                      $SVC_MGR start apache2 >/dev/null 2>&1 || true; \
                      $SVC_MGR start httpd >/dev/null 2>&1 || true; \
                      trap - RETURN" RETURN
            fi
            ;;
        dns)
            # DNS-01: нужен SM_ACME_DNS_PROVIDER (напр. dns_cf для Cloudflare) + его переменные
            # (CF_Token / CF_Account_ID и т.п.) уже экспортированы в окружении.
            local dns_provider="${SM_ACME_DNS_PROVIDER:-}"
            if [[ -z "$dns_provider" ]]; then
                log_error "SM_ACME_MODE=dns требует SM_ACME_DNS_PROVIDER (напр. dns_cf для Cloudflare)"
                log_error "Документация: https://github.com/acmesh-official/acme.sh/wiki/dnsapi"
                return 1
            fi
            issue_args+=(--dns "$dns_provider")
            ;;
    esac

    if bool_is_true "$www_alias" && [[ "$domain" != www.* ]]; then
        # Для DNS-01 www-поддомен можно выпускать независимо от резолва.
        # Для webroot/standalone — только если резолвится.
        if [[ "$acme_mode" == "dns" ]] || getent hosts "www.${domain}" >/dev/null 2>&1; then
            issue_args+=(-d "www.${domain}")
        else
            log_warn "www.${domain} не резолвится — выпускаю сертификат только на ${domain}"
        fi
    fi
    issue_args+=(--server "$acme_server" --keylength ec-256)

    local acme_rc=0
    "$acme_cmd" "${issue_args[@]}" >>"$LOG_FILE" 2>&1 || acme_rc=$?

    if (( acme_rc != 0 )); then
        log_error "acme.sh --issue завершился с ошибкой (exit=${acme_rc}). Подробности: ${LOG_FILE}"
        # Распознаём типичные ошибки и подсказываем, что делать.
        local tail_log
        tail_log="$(tail -n 80 "$LOG_FILE" 2>/dev/null)"
        if echo "$tail_log" | grep -q 'rateLimited\|too many certificates'; then
            log_warn "Hit Let's Encrypt rate limit. Варианты:"
            log_warn "  1) Подождать (лимит снимается через 7 дней с последнего выпуска)"
            log_warn "  2) Staging для тестов: SM_ACME_STAGING=1 $0 issue-ssl ${domain}"
            log_warn "  3) Доки: https://letsencrypt.org/docs/rate-limits/"
        elif echo "$tail_log" | grep -q 'urn:ietf:params:acme:error:unauthorized\|Invalid response from'; then
            log_warn "HTTP-01 validation не прошёл. Возможные причины и альтернативы:"
            log_warn "  • домен ${domain} не указывает на IP этого сервера (проверьте A-запись)"
            log_warn "  • порт 80 закрыт firewall'ом или провайдером (проверьте: curl -I http://${domain}/)"
            log_warn "  • сайт за Cloudflare proxy (оранжевое облако) — LE не может достучаться"
            log_warn "  → Альтернативы:"
            log_warn "     а) standalone (acme.sh сам поднимет :80, временно остановив nginx):"
            log_warn "        SM_ACME_MODE=standalone SM_ACME_STOP_WEB=1 $0 issue-ssl ${domain}"
            log_warn "     б) DNS-01 (через API провайдера, работает за Cloudflare):"
            log_warn "        export CF_Token=...; export CF_Account_ID=..."
            log_warn "        SM_ACME_MODE=dns SM_ACME_DNS_PROVIDER=dns_cf $0 issue-ssl ${domain}"
            log_warn "        Список провайдеров: https://github.com/acmesh-official/acme.sh/wiki/dnsapi"
        elif echo "$tail_log" | grep -q 'EAB\|externalAccountRequired'; then
            log_warn "CA требует EAB (External Account Binding)."
            log_warn "Если используете ZeroSSL/BuyPass — добавьте --eab-kid / --eab-hmac-key в acme.sh."
        elif echo "$tail_log" | grep -q 'DNS problem\|NXDOMAIN\|SERVFAIL'; then
            log_warn "DNS-01 validation не прошёл — провайдер не успел опубликовать TXT-запись."
            log_warn "Повторите через минуту или проверьте креды SM_ACME_DNS_PROVIDER."
        fi
        return 1
    fi

    log_ok "SSL-сертификат получен для ${domain}"

    mkdir -p "$SM_ACME_SSL_DIR"
    chmod 0755 "$SM_ACME_SSL_DIR"

    # Устанавливаем cert в стабильный путь и прописываем reload nginx при обновлении.
    if ! "$acme_cmd" --install-cert -d "$domain" --ecc \
        --cert-file "${SM_ACME_SSL_DIR}/${domain}.cer" \
        --key-file "${SM_ACME_SSL_DIR}/${domain}.key" \
        --fullchain-file "${SM_ACME_SSL_DIR}/${domain}.fullchain.cer" \
        --reloadcmd "systemctl reload nginx" >>"$LOG_FILE" 2>&1; then
        log_error "Не удалось установить сертификат в ${SM_ACME_SSL_DIR}"
        return 1
    fi

    chmod 0600 "${SM_ACME_SSL_DIR}/${domain}.key" 2>/dev/null || true

    # Обновляем конфиг сайта — переключаем на HTTPS.
    update_site_config_with_ssl "$domain" "$SM_ACME_SSL_DIR" || return 1

    setup_acme_cron
    return 0
}

#=====================================================================
# Firewall + Fail2ban
#=====================================================================
setup_firewall() {
    log_section "Настройка firewall"
    local ssh_port
    ssh_port=$(detect_ssh_port)
    log_info "Определён SSH-порт: ${ssh_port}"

    if [[ "$OS_TYPE" == "debian" ]]; then
        pkg_install ufw

        # Фикс для VPS без полноценной поддержки IPv6 в ядре (OpenVZ, некоторые
        # дешёвые VPS): ip6tables-restore падает на ufw6-user-input target.
        # Проверяем, работает ли ip6tables вообще.
        local ufw_ipv6="yes"
        if ! [[ -f /proc/net/if_inet6 ]] || ! ip6tables -L -n >/dev/null 2>&1; then
            log_warn "IPv6 в ядре недоступен или неполноценен — отключаю IPv6 в UFW"
            ufw_ipv6="no"
        fi
        if [[ -f /etc/default/ufw ]]; then
            sed -i "s/^IPV6=.*/IPV6=${ufw_ipv6}/" /etc/default/ufw
            grep -qE '^IPV6=' /etc/default/ufw || echo "IPV6=${ufw_ipv6}" >> /etc/default/ufw
        fi

        ufw --force reset >/dev/null 2>&1 || true
        ufw default deny incoming >/dev/null
        ufw default allow outgoing >/dev/null
        ufw allow "${ssh_port}/tcp" >/dev/null
        ufw allow 80/tcp >/dev/null
        ufw allow 443/tcp >/dev/null

        # Активируем с обработкой ошибок — НЕ ронять установку при проблемах с UFW
        local ufw_err
        ufw_err="$(mktemp)"
        if echo "y" | ufw enable 2>"$ufw_err" >/dev/null; then
            log_ok "UFW активирован (SSH:${ssh_port}, HTTP, HTTPS)"
            rm -f "$ufw_err" || true
        else
            log_warn "UFW не запустился. Подробности: ${ufw_err}"
            log_warn "Частая причина на VPS — отсутствие IPv6 модулей ядра."
            log_warn "Попробуйте вручную: sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw && ufw --force enable"
            log_warn "Сервер продолжит работу БЕЗ firewall. Настройте его вручную позже."
            return 0
        fi
    else
        pkg_install firewalld
        $SVC_MGR enable --now firewalld
        firewall-cmd --permanent --add-port="${ssh_port}/tcp" >/dev/null
        firewall-cmd --permanent --add-service=http >/dev/null
        firewall-cmd --permanent --add-service=https >/dev/null
        firewall-cmd --reload >/dev/null

        # SELinux: зарегистрировать нестандартный SSH-порт
        if [[ "$ssh_port" != "22" ]] && selinux_enabled; then
            selinux_ensure_tools
            semanage port -a -t ssh_port_t -p tcp "$ssh_port" 2>/dev/null \
              || semanage port -m -t ssh_port_t -p tcp "$ssh_port" 2>/dev/null || true
        fi
        # Разрешить httpd/nginx подключаться к FPM (актуально при apache-php-fpm через TCP)
        if selinux_enabled && command_exists setsebool; then
            setsebool -P httpd_can_network_connect on 2>/dev/null || true
        fi
        log_ok "firewalld активирован (SSH:${ssh_port}, HTTP, HTTPS)"
    fi
}

setup_fail2ban() {
    log_section "Настройка Fail2ban"
    if ! command_exists fail2ban-server; then
        pkg_install fail2ban || { log_warn "Не удалось установить fail2ban — пропускаю"; return 0; }
    fi
    local ssh_port
    ssh_port=$(detect_ssh_port)

    mkdir -p /etc/fail2ban/jail.d

    # Определяем пути к логам nginx для текущей ОС.
    # Debian/Ubuntu: /var/log/nginx/error.log (filters читают отсюда по дефолту)
    # RHEL/Rocky/Alma: то же /var/log/nginx/error.log, но fail2ban-server в systemd-backend
    # читает journal. Для filter-based jail'ов нужен явный logpath.
    local nginx_error_log="/var/log/nginx/error.log"
    local nginx_access_log="/var/log/nginx/access.log"

    # Проверяем, что filter-файлы для nginx-http-auth / nginx-botsearch существуют.
    # На некоторых системах (минимальный RHEL-образ) фильтры могут отсутствовать —
    # тогда включение jail'а приведёт к ошибке при рестарте fail2ban.
    local nginx_http_auth_enabled="false"
    local nginx_botsearch_enabled="false"
    if [[ -f /etc/fail2ban/filter.d/nginx-http-auth.conf ]] && [[ -f "$nginx_error_log" || "$(dirname "$nginx_error_log")" == "/var/log/nginx" ]]; then
        nginx_http_auth_enabled="true"
    else
        log_info "nginx-http-auth filter/log не найден — jail отключён"
    fi
    if [[ -f /etc/fail2ban/filter.d/nginx-botsearch.conf ]]; then
        nginx_botsearch_enabled="true"
    else
        log_info "nginx-botsearch filter не найден — jail отключён"
    fi

    # Backend: на RHEL 8/9 по умолчанию systemd (journal), на Debian — auto.
    # Для nginx jail'ов нужен polling backend (читает файлы напрямую).
    local default_backend="auto"
    if [[ "$OS_TYPE" == "rhel" ]]; then
        default_backend="systemd"
    fi

    {
        cat <<EOF
# servermanager managed
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = ${default_backend}

[sshd]
enabled  = true
port     = ${ssh_port}
EOF

        if [[ "$nginx_http_auth_enabled" == "true" ]]; then
            cat <<EOF

[nginx-http-auth]
enabled  = true
filter   = nginx-http-auth
backend  = polling
logpath  = ${nginx_error_log}
EOF
        fi

        if [[ "$nginx_botsearch_enabled" == "true" ]]; then
            cat <<EOF

[nginx-botsearch]
enabled  = true
filter   = nginx-botsearch
backend  = polling
logpath  = ${nginx_access_log}
EOF
        fi
    } > /etc/fail2ban/jail.d/servermanager.conf

    $SVC_MGR enable --now fail2ban >/dev/null 2>&1 || true
    # restart с проверкой: если конфиг кривой, даём понятное сообщение.
    if ! $SVC_MGR restart fail2ban >/dev/null 2>&1; then
        log_warn "fail2ban не смог рестартовать с нашим конфигом — проверяю jail'ы..."
        log_warn "Лог fail2ban: $($SVC_MGR status fail2ban --no-pager 2>&1 | tail -n 5 || echo 'недоступен')"
        return 1
    fi

    log_ok "Fail2ban активирован (sshd$([[ "$nginx_http_auth_enabled" == "true" ]] && echo ", nginx-http-auth")$([[ "$nginx_botsearch_enabled" == "true" ]] && echo ", nginx-botsearch"))"
}

#=====================================================================
# Swap
#=====================================================================
setup_swap() {
    log_section "Настройка swap"

    # Уже есть активный swap?
    if [[ $(swapon --show | wc -l) -gt 0 ]]; then
        log_info "Swap уже активен, пропускаю"
        return
    fi

    if [[ -f /swapfile ]]; then
        log_warn "/swapfile уже существует, но неактивен — попробую включить"
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1 || true
        swapon /swapfile || { log_error "Не удалось включить swap"; return 1; }
    else
        log_info "Создаю swap-файл размером ${SWAP_SIZE}..."
        if ! fallocate -l "${SWAP_SIZE}" /swapfile 2>/dev/null; then
            # fallocate не работает на некоторых FS (ZFS) и OpenVZ
            local size_mb
            size_mb=$(numfmt --from=iec "${SWAP_SIZE}" 2>/dev/null)
            size_mb=$(( size_mb / 1024 / 1024 ))
            dd if=/dev/zero of=/swapfile bs=1M count="${size_mb}" status=none
        fi
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null
        swapon /swapfile
    fi

    # fstab — идемпотентно
    if ! grep -qE '^/swapfile\s' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    # sysctl tuning
    update_managed_block /etc/sysctl.d/99-servermanager.conf "$(cat <<EOF
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF
)"
    sysctl -p /etc/sysctl.d/99-servermanager.conf >/dev/null
    log_ok "Swap (${SWAP_SIZE}) настроен"
}

#=====================================================================
# Меню: управление сайтами
#=====================================================================

menu_sites() {
    while true; do
        echo
        echo -e "${CYAN}=== Управление сайтами ===${NC}"
        echo "  1) Список сайтов"
        echo "  2) Добавить сайт"
        echo "  3) Удалить сайт"
        echo "  4) Изменить версию PHP у сайта"
        echo "  5) Изменить backend у сайта"
        echo "  6) Выпустить SSL для сайта"
        echo "  0) Назад"
        local c
        read -r -p "Выбор: " c
        case "$c" in
            1) list_sites ;;
            2) prompt_site_params; add_site ;;
            3)
                list_sites
                local d
                prompt "Домен для удаления" "" d
                [[ -n "$d" ]] && remove_site "$d"
                ;;
            4)
                list_sites
                local d v
                prompt "Домен" "" d
                [[ -z "$d" ]] && continue
                echo "Установленные PHP: $(state_list_php)"
                prompt "Новая версия PHP" "" v
                [[ -n "$v" ]] && change_site_php "$d" "$v"
                ;;
            5)
                list_sites
                local d
                prompt "Домен" "" d
                [[ -z "$d" ]] && continue
                load_site_config "$d" || { log_error "Сайт не найден"; continue; }
                local choice
                prompt_choice choice "Выберите новый backend:" "1" \
                    "php-fpm (Nginx → PHP-FPM, fastest)" \
                    "apache-mod-php (Nginx → Apache+mod_php, только default PHP)" \
                    "apache-php-fpm (Nginx → Apache → PHP-FPM, .htaccess + любая версия)"
                case "$choice" in
                    1) BACKEND="php-fpm" ;;
                    2) BACKEND="apache-mod-php" ;;
                    3) BACKEND="apache-php-fpm" ;;
                esac
                # Удаляем старый per-site pool и пересобираем конфиги
                remove_site_fpm_pool "$PHP_VERSION" "$DOMAIN"
                # Apache нужен для не-php-fpm backends
                if [[ "$BACKEND" != "php-fpm" ]] && ! command_exists apache2 && ! command_exists httpd; then
                    install_apache
                fi
                render_nginx_site "$DOMAIN" "$DOCUMENT_ROOT" "$PHP_VERSION" "$BACKEND" "${WWW_ALIAS:-true}"
                if [[ "$BACKEND" != "php-fpm" ]]; then
                    [[ "$BACKEND" == "apache-mod-php" ]] && ensure_apache_mod_php || true
                    render_apache_site "$DOMAIN" "$DOCUMENT_ROOT" "$PHP_VERSION" "$BACKEND" "${WWW_ALIAS:-true}"
                fi
                save_site_config "$DOMAIN" "$DOCUMENT_ROOT" "$PHP_VERSION" "$BACKEND" "$SSL" "$DB_NAME" "$DB_USER" "${WWW_ALIAS:-true}"
                log_ok "Backend изменён на ${BACKEND}"
                ;;
            6)
                list_sites
                local d
                prompt "Домен" "" d
                [[ -n "$d" ]] && setup_ssl_for_site "$d"
                ;;
            0|q|Q) return ;;
        esac
    done
}

#=====================================================================
# Меню: управление PHP
#=====================================================================
menu_php() {
    while true; do
        echo
        echo -e "${CYAN}=== Управление PHP ===${NC}"
        echo "  Установленные: $(state_list_php)"
        echo "  По умолчанию:  $(state_get default_php_version)"
        echo
        echo "  1) Установить дополнительную версию PHP"
        echo "  2) Удалить версию PHP"
        echo "  3) Сменить версию по умолчанию"
        echo "  0) Назад"
        local c
        read -r -p "Выбор: " c
        case "$c" in
            1)
                echo "Поддерживаемые версии: ${SUPPORTED_PHP_VERSIONS[*]}"
                local v
                prompt "Версия для установки" "8.5" v
                if ! printf '%s\n' "${SUPPORTED_PHP_VERSIONS[@]}" | grep -qxF "$v"; then
                    log_error "Неподдерживаемая версия: $v"
                    continue
                fi
                install_php_version "$v"
                # Если ещё не назначен default — это первая установленная
                [[ -z "$(state_get default_php_version)" ]] && state_set default_php_version "$v"
                ;;
            2)
                echo "Установлены: $(state_list_php)"
                local v
                prompt "Версия для удаления" "" v
                [[ -n "$v" ]] && uninstall_php_version "$v"
                ;;
            3)
                echo "Установлены: $(state_list_php)"
                local v
                prompt "Новая default-версия" "" v
                if state_list_php | tr ' ' '\n' | grep -qxF "$v"; then
                    state_set default_php_version "$v"
                    log_ok "Default PHP установлен: $v"
                else
                    log_error "Версия $v не установлена"
                fi
                ;;
            0|q|Q) return ;;
        esac
    done
}

#=====================================================================
# Prompts для первичной установки и добавления сайта
#=====================================================================


#=====================================================================
# СЕКЦИЯ v3.1: First-run wizard + main_menu (multi-level)
#=====================================================================

#---------------------------------------------------------------------
# Операции с сайтом (prompt_site_params) — используется wizard'ом и меню
#---------------------------------------------------------------------
prompt_site_params() {
    echo
    echo -e "${CYAN}=== Параметры сайта ===${NC}"

    if is_non_interactive; then
        DOMAIN="${DOMAIN:-}"
        [[ -z "$DOMAIN" ]] && { log_error "DOMAIN обязателен в non-interactive режиме"; return 1; }
        validate_domain "$DOMAIN" || { log_error "Некорректное доменное имя: $DOMAIN"; return 1; }
        SITE_DIR="${SITE_DIR:-/var/www/${DOMAIN}}"
        SITE_PHP_VERSION="${SITE_PHP_VERSION:-$(state_get default_php_version)}"
        SITE_BACKEND="${SITE_BACKEND:-php-fpm}"
        SITE_WWW_ALIAS="${SITE_WWW_ALIAS:-true}"
        CREATE_DB="${CREATE_DB:-false}"
        [[ "$CREATE_DB" == "true" ]] || CREATE_DB=false
        if [[ "$CREATE_DB" == true ]]; then
            local safe; safe=$(echo "$DOMAIN" | tr '.-' '_' | tr '[:upper:]' '[:lower:]')
            DB_NAME="${DB_NAME:-$safe}"
            DB_USER="${DB_USER:-$DB_NAME}"
            DB_PASS="${DB_PASS:-$(gen_password 20)}"
            if ! validate_db_ident "$DB_NAME" || ! validate_db_ident "$DB_USER"; then
                log_error "DB_NAME/DB_USER должны быть в формате [a-z0-9_], 1..32 (non-interactive)"
                return 1
            fi
            if ! validate_db_pass "$DB_PASS"; then
                log_warn "DB_PASS содержит небезопасные символы/длину — генерирую безопасный пароль"
                DB_PASS="$(gen_password 20)"
            fi
        fi
        ENABLE_SSL="${ENABLE_SSL:-false}"
        [[ "$ENABLE_SSL" == "true" ]] || ENABLE_SSL=false
        SSL_EMAIL="${SSL_EMAIL:-admin@${DOMAIN}}"
        return 0
    fi

    # Interactive
    while true; do
        prompt "Доменное имя (например, example.com)" "" DOMAIN
        if [[ -z "$DOMAIN" ]]; then
            log_error "Домен обязателен"; continue
        fi
        if ! validate_domain "$DOMAIN"; then
            log_error "Некорректное доменное имя: '${DOMAIN}'"; continue
        fi
        break
    done
    prompt "Директория сайта" "/var/www/${DOMAIN}" SITE_DIR

    # www alias — спрашиваем сразу после имени и директории, логично вместе с доменом
    if [[ "$DOMAIN" == "localhost" || "$DOMAIN" == www.* ]]; then
        SITE_WWW_ALIAS=false
    else
        if prompt_yes_no "Добавить алиас www.${DOMAIN}?" "y"; then
            SITE_WWW_ALIAS=true
        else
            SITE_WWW_ALIAS=false
        fi
    fi

    local available_php default_php
    available_php=$(state_list_php)
    [[ -z "$available_php" ]] && available_php="${PHP_TO_INSTALL[*]:-}"
    default_php=$(state_get default_php_version)
    [[ -z "$default_php" ]] && default_php="${PHP_DEFAULT:-8.5}"

    echo "Доступные PHP: ${available_php}"
    prompt "Версия PHP для сайта" "${default_php}" SITE_PHP_VERSION

    # Определяем текущий стек для отображения релевантных backend-опций
    local cur_ws
    cur_ws="$(state_get webserver)"
    local apache_installed=false
    { command_exists apache2 || command_exists httpd; } && apache_installed=true || true

    local c
    if [[ "$cur_ws" == "nginx" ]] && ! $apache_installed; then
        # Nginx-only: Apache не установлен — только php-fpm
        SITE_BACKEND="php-fpm"
        echo -e "${CYAN}Backend: php-fpm${NC} (автовыбор — стек Nginx-only, Apache не установлен)"
    else
        prompt_choice c "Backend (обработчик PHP):" "1" \
            "php-fpm (Nginx → PHP-FPM, быстрее всего, без .htaccess)" \
            "apache-mod-php (.htaccess; только default PHP ${default_php})" \
            "apache-php-fpm (.htaccess + любая версия PHP)"
        case "$c" in
            1) SITE_BACKEND="php-fpm" ;;
            2) SITE_BACKEND="apache-mod-php" ;;
            3) SITE_BACKEND="apache-php-fpm" ;;
        esac
    fi

    # apache-mod-php работает только для default PHP
    if [[ "$SITE_BACKEND" == "apache-mod-php" && "$SITE_PHP_VERSION" != "$default_php" ]]; then
        log_warn "apache-mod-php поддерживает только default PHP (${default_php})"
        if prompt_yes_no "Переключить backend на apache-php-fpm?" "y"; then
            SITE_BACKEND="apache-php-fpm"
        else
            SITE_PHP_VERSION="$default_php"
        fi
    fi

    if prompt_yes_no "Создать БД и пользователя для сайта?" "y"; then
        CREATE_DB=true
        local safe; safe=$(echo "$DOMAIN" | tr '.-' '_' | tr '[:upper:]' '[:lower:]')
        prompt "Имя БД" "${safe}" DB_NAME
        prompt "Пользователь БД" "${DB_NAME}" DB_USER
        prompt "Пароль БД (пусто = сгенерировать)" "" DB_PASS
        [[ -z "$DB_PASS" ]] && DB_PASS=$(gen_password 20)
        if ! validate_db_ident "$DB_NAME"; then
            log_error "Имя БД должно быть [a-z0-9_], длина 1..32"
            return 1
        fi
        if ! validate_db_ident "$DB_USER"; then
            log_error "Пользователь БД должен быть [a-z0-9_], длина 1..32"
            return 1
        fi
        if ! validate_db_pass "$DB_PASS"; then
            log_warn "Пароль БД должен быть A-Za-z0-9, длина 8..64 — генерирую безопасный пароль"
            DB_PASS="$(gen_password 20)"
        fi
    else
        CREATE_DB=false
    fi

    if [[ "$DOMAIN" != "localhost" ]]; then
        if prompt_yes_no "Получить SSL (Let's Encrypt)?" "y"; then
            ENABLE_SSL=true
            prompt "Email для Let's Encrypt" "admin@${DOMAIN}" SSL_EMAIL
        else
            ENABLE_SSL=false
        fi
    else
        ENABLE_SSL=false
    fi
}

#---------------------------------------------------------------------
# FIRST-RUN WIZARD (все шаги обязательны)
#---------------------------------------------------------------------
wizard_step_update_system() {
    log_section "Шаг 1/5: Обновление системы"
    local c
    prompt_choice c "Как обновить систему?" "1" \
        "Обновить индексы пакетов (быстро, рекомендуется)" \
        "Обновить только необходимые пакеты (средне)" \
        "Полное обновление системы (долго)" \
        "Пропустить"
    case "$c" in
        1)
            log_info "Обновление индексов пакетов..."
            pkg_update
            log_ok "Индексы обновлены"
            ;;
        2)
            log_info "Обновление базовых пакетов..."
            pkg_update
            if [[ "$OS_TYPE" == "debian" ]]; then
                DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade \
                    -o Dpkg::Options::="--force-confdef" \
                    -o Dpkg::Options::="--force-confold" \
                    curl wget ca-certificates gnupg lsb-release >>"$LOG_FILE" 2>&1
            else
                $PKG_MGR update -y curl wget ca-certificates gnupg2 >>"$LOG_FILE" 2>&1
            fi
            log_ok "Базовые пакеты обновлены"
            ;;
        3)
            log_info "Полное обновление системы (это может занять несколько минут)..."
            log_info "Прогресс пишется в ${LOG_FILE}"
            pkg_update
            pkg_upgrade_all
            log_ok "Система полностью обновлена"
            ;;
        4) log_info "Обновление пропущено" ;;
    esac
}

wizard_step_swap() {
    log_section "Шаг 2/5: Swap-файл"
    local mem_mb
    mem_mb=$(free -m | awk '/^Mem:/ {print $2}')
    echo "Оперативная память: ${mem_mb} MB"
    if prompt_yes_no "Настроить swap-файл?" "y"; then
        ENABLE_SWAP=true
        prompt "Размер swap" "2G" SWAP_SIZE
        setup_swap
    else
        ENABLE_SWAP=false
        log_info "Swap пропущен"
    fi
}

wizard_step_security() {
    log_section "Шаг 3/5: Firewall и Fail2Ban"
    if prompt_yes_no "Настроить firewall (UFW/firewalld) и Fail2Ban?" "y"; then
        setup_firewall
        setup_fail2ban
    else
        log_warn "Firewall НЕ настроен — сервер уязвим для сетевых атак"
    fi
}

wizard_step_choose_path() {
    log_section "Шаг 4/5: Тип установки"
    local c
    prompt_choice c "Что ставить?" "1" \
        "LEMP/LAMP стек (Nginx + PHP + MariaDB/MySQL)" \
        "Панель управления (ISPManager / HestiaCP / FastPanel / aaPanel)"
    case "$c" in
        1) WIZARD_PATH="stack" ;;
        2) WIZARD_PATH="panel" ;;
    esac
}

wizard_step_install_stack() {
    log_section "Шаг 5/5: Установка стека"
    install_base_deps

    # Параметры веб-сервера
    local c
    prompt_choice c "Выбор backend-стека:" "1" \
        "Только Nginx (все сайты через PHP-FPM, быстрее всего)" \
        "Nginx + Apache (для сайтов с .htaccess)"
    case "$c" in
        1) WEB_SERVER="nginx" ;;
        2) WEB_SERVER="nginx_apache" ;;
    esac

    # PHP
    echo
    echo "Поддерживаемые версии PHP: ${SUPPORTED_PHP_VERSIONS[*]}"
    echo "Рекомендуется: 8.3 8.5 (LTS + актуальная)"

    # Цикл переспроса до валидного ввода
    local phpline v sv ok all_ok
    while true; do
        prompt "Версии PHP для установки (через пробел)" "8.3 8.5" phpline
        PHP_TO_INSTALL=()
        local _item
        for _item in $phpline; do
            _item=$(printf '%s' "$_item" | tr -d $'\r\xc2\xa0' | xargs)
            [[ -n "$_item" ]] && PHP_TO_INSTALL+=("$_item")
        done

        if (( ${#PHP_TO_INSTALL[@]} == 0 )); then
            log_error "Не указано ни одной версии. Попробуйте ещё раз."
            continue
        fi

        all_ok=true
        for v in "${PHP_TO_INSTALL[@]}"; do
            ok=false
            for sv in "${SUPPORTED_PHP_VERSIONS[@]}"; do
                [[ "$v" == "$sv" ]] && { ok=true; break; }
            done
            if ! $ok; then
                log_error "Неподдерживаемая версия: '$v'"
                log_error "Hex: $(printf '%s' "$v" | od -An -c -tx1 | head -1)"
                log_error "Поддерживаются только: ${SUPPORTED_PHP_VERSIONS[*]}"
                all_ok=false
                break
            fi
        done
        $all_ok && break
    done

    PHP_DEFAULT=$(printf '%s\n' "${PHP_TO_INSTALL[@]}" | sort -V | tail -n1)
    prompt "Default PHP" "${PHP_DEFAULT}" PHP_DEFAULT

    # БД
    prompt_choice c "СУБД:" "1" "MariaDB (рекомендуется)" "MySQL"
    case "$c" in
        1) DATABASE="mariadb"; prompt "Версия MariaDB (пусто = из дистрибутива)" "" DB_VERSION ;;
        2) DATABASE="mysql"; DB_VERSION="" ;;
    esac

    # Установка
    install_nginx
    [[ "$WEB_SERVER" == "nginx_apache" ]] && install_apache

    local failed_versions=()
    # Временно отключаем set -e, чтобы падение одной версии не прерывало цикл
    set +e
    for v in "${PHP_TO_INSTALL[@]}"; do
        if install_php_version "$v"; then
            :  # OK
        else
            log_error "Установка PHP ${v} не удалась"
            failed_versions+=("$v")
        fi
    done
    set -e

    if (( ${#failed_versions[@]} > 0 )); then
        log_warn "Не удалось установить версии: ${failed_versions[*]}"
        log_warn "Успешно установлены: $(state_list_php)"
        # Если провалилась default версия — переключаемся на последнюю успешную
        if [[ " ${failed_versions[*]} " =~ \ ${PHP_DEFAULT}\  ]]; then
            local newest
            newest=$(state_list_php | tr ' ' '\n' | sort -V | tail -n1)
            if [[ -n "$newest" ]]; then
                log_warn "PHP_DEFAULT=${PHP_DEFAULT} не установлен — переключаюсь на ${newest}"
                PHP_DEFAULT="$newest"
            fi
        fi
    fi

    if [[ -z "$(state_list_php)" ]]; then
        log_error "Не удалось установить ни одной версии PHP — прерываю установку"
        exit 1
    fi

    state_set default_php_version "$PHP_DEFAULT"
    state_set webserver "$WEB_SERVER"

    if [[ "$DATABASE" == "mariadb" ]]; then
        install_mariadb
    else
        install_mysql
    fi
    optimize_database

    # Помечаем установку как завершённую ДО первого сайта: чтобы повторный запуск
    # не показывал "foreign" в случае падения/выхода на этапе добавления сайта.
    state_set "wizard_completed" "$(date -Iseconds)"

    cleanup_pkgs

    # ─── Экран успешной установки ────────────────────────────────────
    clear_or_newlines
    echo -e "${GREEN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║          УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!                ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "${BOLD}  Что установлено:${NC}"
    echo "    Web-сервер : $(state_get webserver)"
    echo "    PHP        : $(state_list_php)  (default: $(state_get default_php_version))"
    echo "    БД         : $(state_get database) $(state_get database_version)"
    echo
    echo -e "${BOLD}  Важные файлы:${NC}"
    echo "    Лог работы скрипта  : ${LOG_FILE}"
    echo "    Состояние стека     : ${SM_STATE_FILE}"
    echo "    Метаданные сайтов   : ${SM_SITES_DIR}/"
    echo "    Пароль root БД      : ${SM_CRED_DIR}/db-root.txt  ${RED}(chmod 600)${NC}"
    echo
    echo -e "${BOLD}  Быстрые команды (при следующих запусках):${NC}"
    local _sn; _sn="$(basename "$0" 2>/dev/null || echo "servermanager.sh")"
    echo "    ./${_sn}                     — главное меню"
    echo "    ./${_sn} status              — статус сервисов и сайтов"
    echo "    ./${_sn} add-site            — добавить сайт"
    echo "    ./${_sn} list-sites          — список сайтов"
    echo "    ./${_sn} install-php <ver>   — установить ещё версию PHP"
    echo
    echo -e "${BOLD}  Checklist после установки:${NC}"
    echo "    [ ] Настройте DNS доменов (A/AAAA → IP этого сервера)"
    echo "    [ ] Проверьте, что SSH-порт открыт: ufw status / firewall-cmd --list-all"
    echo "    [ ] Проверьте автообновление SSL: crontab -l | grep acme.sh"
    echo "    [ ] Настройте бэкапы (файлы сайтов + дамп БД)"
    echo
    echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════════${NC}"

    # Предлагаем создать первый сайт прямо сейчас, без повторного запуска скрипта
    echo
    echo -e "${CYAN}${BOLD}Хотите создать первый сайт прямо сейчас?${NC}"
    echo "  Если да — нажмите Enter или введите 'y'."
    echo "  Если нет — введите 'n' для перехода в главное меню."
    echo
    if prompt_yes_no "Создать первый сайт?" "y"; then
        prompt_site_params
        add_site
    else
        log_info "Сайт можно добавить позже: Главное меню → Сайты → Добавить сайт"
    fi

    # Показываем next-steps только если не добавили сайт (чтобы не дублировать)
    show_post_install_next_steps
    main_menu
}

wizard_step_install_panel() {
    log_section "Шаг 5/5: Установка панели управления"
    echo
    echo -e "${YELLOW}ВНИМАНИЕ:${NC} Панели управления требуют ЧИСТОЙ ОС."
    echo "Если на сервере уже есть Nginx/Apache/PHP/MySQL — будут конфликты."
    echo
    if ! prompt_yes_no "ОС чистая и вы понимаете риски?" "n"; then
        log_info "Установка панели отменена. Вернитесь к мастеру позже."
        exit 0
    fi

    local c
    prompt_choice c "Выбор панели:" "2" \
        "ISPManager (коммерческая, пробный период)" \
        "HestiaCP (open source, рекомендуется)" \
        "FastPanel (freemium)" \
        "aaPanel (open source, китайская)"
    case "$c" in
        1) install_panel_ispmanager ;;
        2) install_panel_hestia ;;
        3) install_panel_fastpanel ;;
        4) install_panel_aapanel ;;
    esac
}

first_run_wizard() {
    clear_or_newlines
    banner

    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    (( cols > 100 )) && cols=100
    local line
    line=$(printf '%*s' "$cols" '' | tr ' ' '-')
    local wiz_title="Мастер первоначальной настройки"
    local wiz_pad=$(( (cols - ${#wiz_title}) / 2 ))
    (( wiz_pad < 0 )) && wiz_pad=0

    echo -e "${CYAN}${BOLD}${line}${NC}"
    printf "${CYAN}${BOLD}%${wiz_pad}s%s${NC}\n" "" "$wiz_title"
    echo -e "${CYAN}${BOLD}${line}${NC}"
    echo "Это первый запуск на этой системе. Пройдём все шаги последовательно."
    echo

    WIZARD_PATH=""
    wizard_step_update_system
    wizard_step_swap
    wizard_step_security
    wizard_step_choose_path

    if [[ "$WIZARD_PATH" == "stack" ]]; then
        wizard_step_install_stack
    else
        wizard_step_install_panel
    fi
}

#---------------------------------------------------------------------
# Post-install: what next?
#---------------------------------------------------------------------
show_post_install_next_steps() {
    if ! is_non_interactive; then
        echo
        read -r -p "Нажмите Enter для перехода в главное меню..." _
    fi
}

#=====================================================================
# Полное удаление стека (ДЕСТРУКТИВНО)
#=====================================================================
uninstall_stack() {
    clear_or_newlines
    echo -e "${RED}${BOLD}=== УДАЛЕНИЕ ВСЕГО СТЕКА ===${NC}"
    echo
    echo "Будут удалены:"
    echo "  • Nginx, Apache2/httpd"
    echo "  • Все версии PHP (php*-fpm, php*-cli, ...)"
    echo "  • MariaDB / MySQL"
    echo "  • Fail2ban"
    echo "  • Конфиги в /etc/nginx /etc/apache2 /etc/httpd /etc/php"
    echo "  • Метаданные servermanager в ${SM_DIR}"
    echo
    echo -e "${RED}Файлы сайтов в /var/www/ НЕ удаляются (удалите вручную при необходимости).${NC}"
    echo -e "${RED}Базы данных НЕ удаляются — сделайте dump перед удалением.${NC}"
    echo
    if ! prompt_yes_no "Вы ТОЧНО хотите удалить весь стек? Это необратимо." "n"; then
        log_info "Отменено."
        return 0
    fi
    if ! prompt_yes_no "Последнее подтверждение: удалить всё?" "n"; then
        log_info "Отменено."
        return 0
    fi

    log_section "Удаление стека"

    # Nginx
    if command_exists nginx; then
        $SVC_MGR disable --now nginx 2>/dev/null || true
        pkg_purge nginx nginx-common nginx-full nginx-extras 2>/dev/null || true
    fi

    # Apache
    if command_exists apache2; then
        $SVC_MGR disable --now apache2 2>/dev/null || true
        pkg_purge apache2 apache2-utils apache2-bin 2>/dev/null || true
    fi
    if command_exists httpd; then
        $SVC_MGR disable --now httpd 2>/dev/null || true
        pkg_purge httpd httpd-tools mod_ssl 2>/dev/null || true
    fi

    # PHP
    local v
    for v in "${SUPPORTED_PHP_VERSIONS[@]}"; do
        if [[ "$OS_TYPE" == "debian" ]]; then
            pkg_purge_glob "php${v}*" || true
        else
            pkg_purge_glob "php${v//./}*" "php${v//./}-*" || true
        fi
    done

    # MariaDB / MySQL
    if $SVC_MGR is-active mariadb &>/dev/null; then
        $SVC_MGR disable --now mariadb 2>/dev/null || true
        pkg_purge mariadb-server mariadb-client "MariaDB-server" "MariaDB-client" 2>/dev/null || true
    fi
    if $SVC_MGR is-active mysql &>/dev/null || $SVC_MGR is-active mysqld &>/dev/null; then
        $SVC_MGR disable --now mysql mysqld 2>/dev/null || true
        pkg_purge mysql-server mysql-client 2>/dev/null || true
    fi

    # Fail2ban
    if command_exists fail2ban-server; then
        $SVC_MGR disable --now fail2ban 2>/dev/null || true
        pkg_purge fail2ban 2>/dev/null || true
    fi

    # Certbot (legacy, v3.1.x и ниже). Начиная с v3.2.0 используется acme.sh.
    if command_exists certbot; then
        pkg_purge certbot python3-certbot-nginx >/dev/null 2>&1 || true
    fi

    # acme.sh: НЕ удаляем сам бинарник/аккаунт (он может быть нужен для других сайтов
    # на этом же хосте после переустановки). Но cron-задачи от acme.sh чистим —
    # они бесполезны без acme.sh и просто мусорят.
    if prompt_yes_no "Удалить acme.sh целиком (/root/.acme.sh/, cron-задачу acme.sh, сертификаты в /etc/ssl/acme/)?" "n"; then
        # uninstall-cronjob + удаление файлов
        [[ -x "${SM_ACME_HOME:-/root/.acme.sh}/acme.sh" ]] && \
            "${SM_ACME_HOME:-/root/.acme.sh}/acme.sh" --uninstall-cronjob >/dev/null 2>&1 || true
        rm -rf "${SM_ACME_HOME:-/root/.acme.sh}" "${SM_ACME_SSL_DIR:-/etc/ssl/acme}" 2>/dev/null || true
        log_ok "acme.sh удалён"
    fi

    # Очистка cron-задач, оставленных servermanager'ом и acme.sh.
    # Даже если acme.sh оставили — наш backup-cron и устаревшие записи чистим.
    uninstall_cron_jobs

    pkg_cleanup

    # Метаданные SM
    rm -rf "${SM_DIR}" || true

    # Lockfile на всякий случай — чтобы после uninstall не висел.
    rm -f "${SM_LOCK_FILE:-/var/run/servermanager.lock}" 2>/dev/null || true

    log_ok "Стек удалён. Файлы сайтов /var/www/ и БД сохранены."
    log_ok "Учётные данные БД были в ${SM_CRED_DIR}/ — они также удалены вместе с SM_DIR."
}

# Чистит cron-задачи servermanager (backup-all, и опционально acme.sh).
# Вызывается как из uninstall_stack, так и как CLI-команда.
uninstall_cron_jobs() {
    local current
    current="$(crontab -l 2>/dev/null || true)"
    if [[ -z "$current" ]]; then
        log_info "crontab root пуст — нечего чистить"
        return 0
    fi
    local filtered
    # Выбрасываем строки:
    # - содержащие путь к servermanager (наш backup-cron),
    # - относящиеся к acme.sh,
    # - явные старые маркеры "# servermanager managed" (на будущее).
    filtered="$(echo "$current" | grep -vE 'servermanager(\.sh)?|\.acme\.sh|# servermanager managed' || true)"
    if [[ "$filtered" == "$current" ]]; then
        log_info "Записей servermanager/acme.sh в crontab не найдено"
        return 0
    fi
    if [[ -z "$filtered" ]]; then
        crontab -r 2>/dev/null || true
    else
        echo "$filtered" | crontab -
    fi
    log_ok "Cron-задачи servermanager/acme.sh удалены"
}

#=====================================================================
# PANEL INSTALLERS (официальные, без модификаций)
#=====================================================================

panel_preflight() {
    # Проверка: чистая ли ОС? Если что-то есть — warn + подтверждение
    local has_issues=false
    if command_exists nginx; then log_warn "Установлен Nginx"; has_issues=true; fi
    if command_exists apache2 || command_exists httpd; then log_warn "Установлен Apache"; has_issues=true; fi
    if command_exists php; then log_warn "Установлен PHP"; has_issues=true; fi
    if command_exists mysql || command_exists mariadb; then log_warn "Установлена БД"; has_issues=true; fi

    if $has_issues; then
        log_warn "На сервере есть компоненты, которые могут конфликтовать с панелью"
        prompt_yes_no "Всё равно продолжить?" "n" || exit 0
    fi
}

# Общая логика запуска официальных installer'ов панелей.
# Проверяет exit code и возвращает 1 при ошибке — вызывающий код сам решает, что делать.
# Использует директорию с нормальным размером вместо /tmp (который может быть tmpfs).
_run_panel_installer() {
    local panel_name="$1" url="$2"
    local cache_dir="/var/cache/servermanager"
    mkdir -p "$cache_dir"
    local tmp
    tmp="$(mktemp "${cache_dir}/${panel_name}-installer.XXXXXX.sh")"

    log_info "Скачиваю официальный installer ${panel_name}..."
    if ! wget -q -O "$tmp" "$url"; then
        log_error "Не удалось скачать installer ${panel_name} (${url})"
        rm -f "$tmp"
        return 1
    fi
    if [[ ! -s "$tmp" ]]; then
        log_error "Скачанный installer ${panel_name} пуст"
        rm -f "$tmp"
        return 1
    fi
    chmod +x "$tmp"

    log_info "Запускаю официальный installer ${panel_name}. Отвечайте на его вопросы."
    echo "---"
    local rc=0
    # Installer — интерактивный, stdin/stdout/stderr пробрасываем напрямую.
    bash "$tmp" || rc=$?
    rm -f "$tmp"

    if (( rc != 0 )); then
        log_error "Installer ${panel_name} завершился с ошибкой (exit=${rc})"
        return 1
    fi
    return 0
}

install_panel_hestia() {
    panel_preflight
    if _run_panel_installer "hestia" \
        "https://raw.githubusercontent.com/hestiacp/hestiacp/release/install/hst-install.sh"; then
        state_set "panel" "hestia"
        echo
        log_ok "HestiaCP: https://$(hostname -f):8083/"
    else
        return 1
    fi
}

install_panel_fastpanel() {
    panel_preflight
    if _run_panel_installer "fastpanel" \
        "http://repo.fastpanel.direct/install_fastpanel.sh"; then
        state_set "panel" "fastpanel"
        echo
        log_ok "FastPanel: https://$(hostname -f):8888/ (данные входа см. в выводе installer'а)"
    else
        return 1
    fi
}

install_panel_aapanel() {
    panel_preflight
    local url
    if [[ "$OS_TYPE" == "debian" ]]; then
        url="http://www.aapanel.com/script/install-ubuntu_7.0_en.sh"
    else
        url="http://www.aapanel.com/script/install_7.0_en.sh"
    fi
    if _run_panel_installer "aapanel" "$url"; then
        state_set "panel" "aapanel"
        echo
        log_ok "aaPanel: данные входа см. в выводе installer'а"
    else
        return 1
    fi
}

install_panel_ispmanager() {
    panel_preflight
    if _run_panel_installer "ispmanager" \
        "https://download.ispmanager.com/install.sh"; then
        state_set "panel" "ispmanager"
        echo
        log_ok "ISPManager: https://$(hostname -f):1500/"
    else
        return 1
    fi
}

#=====================================================================
# MAIN MENU (multi-level)
#=====================================================================

banner() {
    # Используем улучшенный banner с системной информацией
    show_enhanced_banner
}

press_any_key() {
    if ! is_non_interactive; then
        echo
        read -r -p "Нажмите Enter для продолжения..." _
    fi
}

show_state_summary() {
    # Используем улучшенное отображение состояния
    show_enhanced_state_summary
}

#---------------------------------------------------------------------
# Submenu: Мониторинг и аналитика
#---------------------------------------------------------------------
submenu_monitoring() {
    while true; do
        clear_or_newlines
        banner
        echo -e "${CYAN}${BOLD}=== Мониторинг и аналитика ===${NC}"
        echo "  1) Производительность сервера"
        echo "  2) Статистика сайта"
        echo "  3) Статус SSL сертификатов"
        echo "  4) Общая статистика"
        echo "  0) Назад"
        local c; read -r -p "Выбор: " c
        case "$c" in
            1)
                monitor_server_performance
                press_any_key
                ;;
            2)
                local d
                pick_site d || { press_any_key; continue; }
                check_site_resources "$d"
                press_any_key
                ;;
            3)
                check_ssl_certificates
                press_any_key
                ;;
            4)
                clear_or_newlines
                echo -e "${CYAN}${BOLD}=== Общая статистика сервера ===${NC}"
                monitor_server_performance
                check_ssl_certificates
                press_any_key
                ;;
            0|q|Q) return ;;
        esac
    done
}

#---------------------------------------------------------------------
# Submenu: Безопасность
#---------------------------------------------------------------------
submenu_security() {
    while true; do
        clear_or_newlines
        banner
        echo -e "${CYAN}${BOLD}=== Безопасность ===${NC}"
        echo "  1) Настроить безопасность сайта"
        echo "  2) Настройка firewall"
        echo "  3) Настройка Fail2Ban"
        echo "  4) Проверка безопасности"
        echo "  5) Настройка default конфигурации"
        echo "  0) Назад"
        local c; read -r -p "Выбор: " c
        case "$c" in
            1)
                local d
                pick_site d || { press_any_key; continue; }
                load_site_config "$d" || { log_error "Сайт не найден"; press_any_key; continue; }
                setup_site_security "$d" "$DOCUMENT_ROOT"
                press_any_key
                ;;
            2)
                setup_firewall
                press_any_key
                ;;
            3)
                setup_fail2ban
                press_any_key
                ;;
            4)
                clear_or_newlines
                echo -e "${CYAN}${BOLD}=== 🔍 Проверка безопасности ===${NC}"
                
                # Проверка default конфигурации
                if ensure_default_config; then
                    echo "  ✅ Default конфигурация в порядке"
                else
                    echo "  🔴 Default конфигурация требует внимания"
                fi
                
                # Проверка SSL сертификатов
                check_ssl_certificates
                
                # Проверка прав доступа
                echo -e "${CYAN}🔒 Проверка прав доступа:${NC}"
                if [[ -d "/var/www" ]]; then
                    local www_perms=$(stat -c "%a" /var/www 2>/dev/null || echo "N/A")
                    printf "  📂 /var/www права: ${YELLOW}%s${NC}\n" "$www_perms"
                fi
                
                press_any_key
                ;;
            5)
                setup_default_config
                press_any_key
                ;;
            0|q|Q) return ;;
        esac
    done
}

#---------------------------------------------------------------------
# Submenu: Бэкапы
#---------------------------------------------------------------------
submenu_backups() {
    while true; do
        clear_or_newlines
        banner
        echo -e "${CYAN}${BOLD}=== Бэкапы и восстановление ===${NC}"
        echo "  📂 Хранилище: ${SM_BACKUP_DIR}  (retention: ${SM_BACKUP_KEEP})"
        echo
        echo "  1) Создать бэкап одного сайта"
        echo "  2) Создать бэкап всех сайтов"
        echo "  3) Создать системный бэкап (конфиги + все БД)"
        echo "  4) Список бэкапов"
        echo "  5) Восстановить сайт из бэкапа"
        echo "  6) Настроить автобэкап (cron, ежедневно в 03:00)"
        echo "  7) Отключить автобэкап"
        echo "  0) Назад"
        local c; read -r -p "Выбор: " c
        case "$c" in
            1)
                local domain
                list_sites
                prompt "Домен для бэкапа" "" domain
                if [[ -n "$domain" ]]; then
                    create_site_backup "$domain" || log_error "Ошибка создания бэкапа"
                fi
                press_any_key
                ;;
            2)
                backup_all_sites || log_warn "Часть бэкапов завершилась с ошибкой — см. лог"
                press_any_key
                ;;
            3)
                create_system_backup || log_error "Ошибка создания системного бэкапа"
                press_any_key
                ;;
            4)
                list_backups
                press_any_key
                ;;
            5)
                list_backups
                echo
                local archive
                prompt "Путь к архиву (или имя файла в ${SM_BACKUP_DIR}/sites/)" "" archive
                if [[ -n "$archive" ]]; then
                    restore_site_backup "$archive" || log_error "Ошибка восстановления"
                fi
                press_any_key
                ;;
            6)
                backup_setup_cron
                press_any_key
                ;;
            7)
                backup_remove_cron
                press_any_key
                ;;
            0|q|Q) return ;;
        esac
    done
}

#---------------------------------------------------------------------
# Submenu: Сайты
#---------------------------------------------------------------------
submenu_sites() {
    while true; do
        clear_or_newlines
        echo -e "${CYAN}${BOLD}=== Сайты ===${NC}"
        echo "  1) Добавить сайт"
        echo "  2) Список сайтов"
        echo "  3) Удалить сайт"
        echo "  4) Изменить PHP-версию сайта"
        echo "  5) Изменить backend сайта"
        echo "  6) Выпустить/обновить SSL"
        echo "  0) Назад"
        local c; read -r -p "Выбор: " c
        case "$c" in
            1)
                prompt_site_params && add_site
                press_any_key
                ;;
            2)
                list_sites; press_any_key ;;
            3)
                local d
                pick_site d || { press_any_key; continue; }
                remove_site "$d"
                press_any_key
                ;;
            4)
                local d v
                pick_site d || { press_any_key; continue; }
                echo "Установленные PHP: $(state_list_php)"
                prompt "Новая версия PHP" "" v
                [[ -n "$v" ]] && change_site_php "$d" "$v"
                press_any_key
                ;;
            5)
                local d
                pick_site d || { press_any_key; continue; }
                load_site_config "$d" || { log_error "Сайт не найден"; press_any_key; continue; }
                local bc
                prompt_choice bc "Новый backend:" "1" \
                    "php-fpm" "apache-mod-php" "apache-php-fpm"
                case "$bc" in
                    1) BACKEND="php-fpm" ;;
                    2) BACKEND="apache-mod-php" ;;
                    3) BACKEND="apache-php-fpm" ;;
                esac
                remove_site_fpm_pool "$PHP_VERSION" "$DOMAIN"
                if [[ "$BACKEND" != "php-fpm" ]] && ! command_exists apache2 && ! command_exists httpd; then
                    install_apache
                fi
                render_nginx_site "$DOMAIN" "$DOCUMENT_ROOT" "$PHP_VERSION" "$BACKEND" "${WWW_ALIAS:-true}"
                if [[ "$BACKEND" != "php-fpm" ]]; then
                    [[ "$BACKEND" == "apache-mod-php" ]] && ensure_apache_mod_php || true
                    render_apache_site "$DOMAIN" "$DOCUMENT_ROOT" "$PHP_VERSION" "$BACKEND" "${WWW_ALIAS:-true}"
                fi
                save_site_config "$DOMAIN" "$DOCUMENT_ROOT" "$PHP_VERSION" "$BACKEND" "$SSL" "$DB_NAME" "$DB_USER" "${WWW_ALIAS:-true}"
                log_ok "Backend изменён: ${BACKEND}"
                press_any_key
                ;;
            6)
                local d
                pick_site d || { press_any_key; continue; }
                setup_ssl_for_site "$d"
                press_any_key
                ;;
            0|q|Q) return ;;
        esac
    done
}

#---------------------------------------------------------------------
# Submenu: PHP
#---------------------------------------------------------------------
submenu_php() {
    while true; do
        clear_or_newlines
        echo -e "${CYAN}${BOLD}=== PHP ===${NC}"
        echo "  Установленные: $(state_list_php)"
        echo "  По умолчанию:  $(state_get default_php_version)"
        echo
        echo "  1) Установить доп. версию PHP"
        echo "  2) Удалить версию PHP"
        echo "  3) Сменить версию по умолчанию"
        echo "  4) Показать сайты по версиям PHP"
        echo "  0) Назад"
        local c; read -r -p "Выбор: " c
        case "$c" in
            1)
                echo "Поддерживаемые: ${SUPPORTED_PHP_VERSIONS[*]}"
                local v; prompt "Версия" "8.5" v
                if ! printf '%s\n' "${SUPPORTED_PHP_VERSIONS[@]}" | grep -qxF "$v"; then
                    log_error "Неподдерживаемая версия: $v"; press_any_key; continue
                fi
                install_php_version "$v"
                [[ -z "$(state_get default_php_version)" ]] && state_set default_php_version "$v"
                press_any_key
                ;;
            2)
                echo "Установлены: $(state_list_php)"
                local v; prompt "Версия для удаления" "" v
                [[ -n "$v" ]] && uninstall_php_version "$v"
                press_any_key
                ;;
            3)
                echo "Установлены: $(state_list_php)"
                local v; prompt "Новый default" "" v
                if state_list_php | tr ' ' '\n' | grep -qxF "$v"; then
                    state_set default_php_version "$v"
                    log_ok "Default PHP: $v"
                else
                    log_error "Версия $v не установлена"
                fi
                press_any_key
                ;;
            4)
                echo
                local v
                for v in $(state_list_php); do
                    echo "PHP ${v}:"
                    if compgen -G "${SM_SITES_DIR}/*.conf" > /dev/null; then
                        local f
                        for f in "${SM_SITES_DIR}"/*.conf; do
                            local pv d be
                            pv="$(kv_get_file "$f" "PHP_VERSION")"
                            d="$(kv_get_file "$f" "DOMAIN")"
                            be="$(kv_get_file "$f" "BACKEND")"
                            [[ "$pv" == "$v" ]] && echo "  - $d ($be)"
                        done
                    fi
                done
                press_any_key
                ;;
            0|q|Q) return ;;
        esac
    done
}

#---------------------------------------------------------------------
# Submenu: Базы данных (new)
#---------------------------------------------------------------------
submenu_databases() {
    while true; do
        clear_or_newlines
        echo -e "${CYAN}${BOLD}=== Базы данных ===${NC}"
        echo "  1) Создать БД и пользователя"
        echo "  2) Список баз данных"
        echo "  3) Удалить БД и пользователя"
        echo "  0) Назад"
        local c; read -r -p "Выбор: " c
        case "$c" in
            1) menu_create_orphan_db; press_any_key ;;
            2) list_databases; press_any_key ;;
            3) menu_drop_db; press_any_key ;;
            0|q|Q) return ;;
        esac
    done
}

menu_create_orphan_db() {
    local name user pass
    prompt "Имя БД" "" name
    [[ -z "$name" ]] && { log_error "Имя обязательно"; return; }
    name="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
    if ! validate_db_ident "$name"; then
        log_error "Некорректное имя БД (разрешено: [a-z0-9_], длина 1..32)"
        return
    fi
    prompt "Имя пользователя" "${name}" user
    user="$(echo "$user" | tr '[:upper:]' '[:lower:]')"
    if ! validate_db_ident "$user"; then
        log_error "Некорректное имя пользователя (разрешено: [a-z0-9_], длина 1..32)"
        return
    fi
    prompt "Пароль (пусто = сгенерировать)" "" pass
    [[ -z "$pass" ]] && pass=$(gen_password 20)
    if ! validate_db_pass "$pass"; then
        log_warn "Пароль должен быть A-Za-z0-9, длина 8..64 — генерирую безопасный пароль"
        pass="$(gen_password 20)"
    fi

    create_site_database "$name" "$user" "$pass"

    local cred_file="${SM_CRED_DIR}/db-${name}.txt"
    cat > "$cred_file" <<EOF
# servermanager — orphan БД (не привязана к сайту)
DB_HOST=127.0.0.1
DB_NAME=${name}
DB_USER=${user}
DB_PASS=${pass}
EOF
    chmod 600 "$cred_file"
    log_ok "БД ${name} и пользователь ${user} созданы"
    log_ok "Учётные данные: ${cred_file}"
}

list_databases() {
    echo
    echo -e "${BOLD}Все базы данных на сервере (кроме системных):${NC}"
    local root_pass mysql_cmd
    root_pass=$(grep -E '^DB_ROOT_PASS=' "${SM_CRED_DIR}/db-root.txt" 2>/dev/null | cut -d= -f2)
    mysql_cmd="mysql -u root"
    local defaults=""
    if [[ -n "$root_pass" ]]; then
        defaults="$(mysql_root_defaults_file "$root_pass")" || true
        [[ -n "$defaults" ]] && mysql_cmd="mysql --defaults-extra-file=${defaults}"
    fi

    $mysql_cmd -N -e "SHOW DATABASES" 2>/dev/null | \
        grep -vxE "information_schema|performance_schema|mysql|sys" | \
        while read -r db; do
            local size
            size=$($mysql_cmd -N -e "
                SELECT IFNULL(ROUND(SUM(data_length + index_length)/1024/1024, 2), 0)
                FROM information_schema.tables WHERE table_schema='${db}'" 2>/dev/null)
            printf "  %-30s %8s MB\n" "$db" "$size"
        done
    [[ -n "$defaults" ]] && rm -f "$defaults" || true
}

menu_drop_db() {
    list_databases
    local name; prompt "Имя БД для удаления" "" name
    [[ -z "$name" ]] && return
    local user; prompt "Имя пользователя для удаления (пусто = пропустить)" "${name}" user
    if prompt_yes_no "Точно удалить БД '${name}' и пользователя '${user}'? Данные будут ПОТЕРЯНЫ." "n"; then
        drop_site_database "$name" "$user"
        rm -f "${SM_CRED_DIR}/db-${name}.txt"
        log_ok "БД и пользователь удалены"
    fi
}

#---------------------------------------------------------------------
# Submenu: Система (статус, перезапуск, логи)
#---------------------------------------------------------------------
submenu_system() {
    while true; do
        clear_or_newlines
        echo -e "${CYAN}${BOLD}=== Система ===${NC}"
        echo "  1) Статус сервисов"
        echo "  2) Перезапустить все сервисы"
        echo "  3) Перезапустить отдельный сервис"
        echo "  4) Просмотр логов"
        echo "  0) Назад"
        local c; read -r -p "Выбор: " c
        case "$c" in
            1) show_services_status; press_any_key ;;
            2) restart_all_services; press_any_key ;;
            3) restart_one_service; press_any_key ;;
            4) view_logs_menu ;;
            0|q|Q) return ;;
        esac
    done
}

list_managed_services() {
    # Возвращает список сервисов, которые ставил servermanager
    local -a services=()
    systemctl list-unit-files nginx.service &>/dev/null && services+=("nginx")
    systemctl list-unit-files apache2.service &>/dev/null && services+=("apache2")
    systemctl list-unit-files httpd.service &>/dev/null && services+=("httpd")
    local v
    for v in $(state_list_php); do
        if [[ "$OS_TYPE" == "debian" ]]; then
            services+=("php${v}-fpm")
        else
            services+=("php${v//./}-php-fpm")
        fi
    done
    systemctl list-unit-files mariadb.service &>/dev/null && services+=("mariadb")
    systemctl list-unit-files mysql.service &>/dev/null && services+=("mysql")
    systemctl list-unit-files mysqld.service &>/dev/null && services+=("mysqld")
    systemctl list-unit-files fail2ban.service &>/dev/null && services+=("fail2ban")
    printf '%s\n' "${services[@]}"
}

show_services_status() {
    echo
    printf "%-20s %-10s %-10s %s\n" "СЕРВИС" "СОСТОЯНИЕ" "АВТОЗАПУСК" "UPTIME"
    printf "%-20s %-10s %-10s %s\n" "------" "---------" "----------" "------"
    local svc state enabled uptime
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        state=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
        enabled=$(systemctl is-enabled "$svc" 2>/dev/null || echo "disabled")
        uptime=$(systemctl show -p ActiveEnterTimestamp "$svc" 2>/dev/null | cut -d= -f2 | awk '{print $2, $3}')
        # Цвет по состоянию
        local color="${GREEN}"
        [[ "$state" != "active" ]] && color="${RED}"
        printf "%-20s ${color}%-10s${NC} %-10s %s\n" "$svc" "$state" "$enabled" "${uptime:--}"
    done < <(list_managed_services)
}

restart_all_services() {
    if ! prompt_yes_no "Перезапустить ВСЕ сервисы? Будет кратковременная недоступность сайтов." "n"; then
        return
    fi
    local svc
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        echo -n "Перезапуск $svc... "
        if $SVC_MGR restart "$svc" 2>/dev/null; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAILED${NC}"
        fi
    done < <(list_managed_services)
}

restart_one_service() {
    echo
    echo "Доступные сервисы:"
    list_managed_services | nl -w2 -s') '
    local num idx=1 svc
    read -r -p "Номер: " num
    [[ -z "$num" ]] && return
    while IFS= read -r svc; do
        if [[ "$idx" == "$num" ]]; then
            echo -n "Перезапуск $svc... "
            if $SVC_MGR restart "$svc"; then
                echo -e "${GREEN}OK${NC}"
            else
                echo -e "${RED}FAILED${NC}"
            fi
            return
        fi
        ((idx++))
    done < <(list_managed_services)
}

view_logs_menu() {
    while true; do
        clear_or_newlines
        echo -e "${CYAN}${BOLD}=== Логи ===${NC}"
        echo "  1) Лог servermanager"
        echo "  2) Nginx error log"
        echo "  3) Apache error log"
        echo "  4) PHP-FPM error log (выбор версии)"
        echo "  5) MariaDB/MySQL error log"
        echo "  6) Сайт — access/error"
        echo "  0) Назад"
        local c; read -r -p "Выбор: " c
        case "$c" in
            1) less_safe "$LOG_FILE" ;;
            2) less_safe /var/log/nginx/error.log ;;
            3)
                if [[ "$OS_TYPE" == "debian" ]]; then
                    less_safe /var/log/apache2/error.log
                else
                    less_safe /var/log/httpd/error_log
                fi
                ;;
            4)
                echo "Версии: $(state_list_php)"
                local v; prompt "Версия PHP" "" v
                if [[ "$OS_TYPE" == "debian" ]]; then
                    less_safe "/var/log/php${v}-fpm.log"
                else
                    less_safe "/var/opt/remi/php${v//./}/log/php-fpm/error.log"
                fi
                ;;
            5)
                for f in /var/log/mysql/error.log /var/log/mariadb/mariadb.log /var/log/mysqld.log; do
                    [[ -f "$f" ]] && { less_safe "$f"; return; }
                done
                log_warn "Лог БД не найден"
                ;;
            6)
                list_sites
                local d; prompt "Домен" "" d
                [[ -z "$d" ]] && continue
                local el="/var/log/nginx/${d}.error.log"
                local al="/var/log/nginx/${d}.access.log"
                echo "--- error.log (last 50) ---"
                tail -n 50 "$el" 2>/dev/null || echo "(нет файла)"
                echo "--- access.log (last 20) ---"
                tail -n 20 "$al" 2>/dev/null || echo "(нет файла)"
                press_any_key
                ;;
            0|q|Q) return ;;
        esac
    done
}

less_safe() {
    local f="$1"
    if [[ ! -f "$f" ]]; then
        log_warn "Файл не найден: $f"; press_any_key; return
    fi
    if command_exists less; then
        less "$f"
    else
        tail -n 100 "$f"
        press_any_key
    fi
}

#---------------------------------------------------------------------
# Submenu: Обслуживание
#---------------------------------------------------------------------
submenu_maintenance() {
    while true; do
        clear_or_newlines
        echo -e "${CYAN}${BOLD}=== Обслуживание ===${NC}"
        echo "  1) Очистка кэшей пакетного менеджера"
        echo "  2) Очистка логов servermanager"
        echo "  3) Показать занятое место (сайты, БД, логи)"
        echo "  4) УДАЛИТЬ ВЕСЬ СТЕК"
        echo "  0) Назад"
        local c; read -r -p "Выбор: " c
        case "$c" in
            1) cleanup_pkgs; press_any_key ;;
            2)
                if prompt_yes_no "Очистить ${LOG_FILE}?" "n"; then
                    : > "$LOG_FILE"; log_ok "Лог очищен"
                fi
                press_any_key
                ;;
            3) show_disk_usage; press_any_key ;;
            4) uninstall_stack; exit 0 ;;
            0|q|Q) return ;;
        esac
    done
}

show_disk_usage() {
    echo
    echo -e "${BOLD}Использование диска:${NC}"
    echo "--- Директории сайтов ---"
    if compgen -G "${SM_SITES_DIR}/*.conf" > /dev/null; then
        local f
        for f in "${SM_SITES_DIR}"/*.conf; do
            local d dr sz
            d="$(kv_get_file "$f" "DOMAIN")"
            dr="$(kv_get_file "$f" "DOCUMENT_ROOT")"
            sz=$(du -sh "$dr" 2>/dev/null | awk '{print $1}')
            printf "  %-30s %s\n" "$d" "${sz:-?}"
        done
    fi
    echo
    echo "--- Логи ---"
    du -sh /var/log/nginx /var/log/apache2 /var/log/httpd /var/log/mysql /var/log/mariadb /var/log/servermanager.log 2>/dev/null | awk '{printf "  %s\n", $0}'
    echo
    echo "--- БД ---"
    du -sh /var/lib/mysql 2>/dev/null | awk '{printf "  %s\n", $0}'
}

#---------------------------------------------------------------------
# MAIN MENU (диспетчер)
#---------------------------------------------------------------------
clear_or_newlines() {
    if command_exists clear && [[ -t 1 ]]; then
        clear
    else
        echo
        echo
    fi
}

main_menu() {
    while true; do
        clear_or_newlines
        banner
        show_state_summary

        echo -e "${CYAN}${BOLD}=== Главное меню Server Manager ===${NC}"
        echo "  1) Сайты"
        echo "  2) PHP"
        echo "  3) Базы данных"
        echo "  4) Мониторинг и аналитика"
        echo "  5) Безопасность"
        echo "  6) Бэкапы"
        echo "  7) Система (статус, логи, сервисы)"
        echo "  8) Обслуживание"
        echo "  0) Выход"
        local c; read -r -p "Выбор: " c
        case "$c" in
            1) submenu_sites ;;
            2) submenu_php ;;
            3) submenu_databases ;;
            4) submenu_monitoring ;;
            5) submenu_security ;;
            6) submenu_backups ;;
            7) submenu_system ;;
            8) submenu_maintenance ;;
            0|q|Q) echo "Выход"; exit 0 ;;
        esac
    done
}

#=====================================================================
# detect_state + routing
#=====================================================================

detect_state() {
    # Возвращает через echo: "fresh" | "managed" | "panel" | "foreign"
    # fresh    — ничего не стоит; → first_run_wizard
    # managed  — стек стоит и есть наш state.conf; → main_menu
    # panel    — найдена панель управления; → warn + exit
    # foreign  — стек стоит, но state.conf отсутствует; → import + main_menu

    local panel
    panel=$(detect_installed_panel || true)
    if [[ -n "$panel" ]]; then
        echo "panel:$panel"
        return
    fi

    local has_any=false
    detect_installed_webserver && has_any=true
    local found_php
    found_php=$(detect_installed_php_versions | head -1)
    [[ -n "$found_php" ]] && has_any=true
    detect_installed_database && has_any=true

    if ! $has_any; then
        echo "fresh"
        return
    fi

    # Что-то стоит. Это "наше"?
    # Если state.conf уже существует — считаем managed, даже если wizard_completed пустой
    # (частичный/прерванный wizard тоже должен вести в меню).
    if [[ -f "$SM_STATE_FILE" ]]; then
        echo "managed"
    else
        echo "foreign"
    fi
}

import_foreign_state() {
    log_warn "Обнаружены компоненты, установленные не через servermanager"
    log_info "Импортирую состояние в ${SM_STATE_FILE}..."

    # Web server
    detect_installed_webserver && state_set webserver "$WEB_SERVER"

    # PHP versions
    local v
    while IFS= read -r v; do
        [[ -n "$v" ]] && state_add_php "$v"
    done < <(detect_installed_php_versions)
    local newest
    newest=$(state_list_php | tr ' ' '\n' | sort -V | tail -n1)
    [[ -n "$newest" ]] && state_set default_php_version "$newest"

    # DB
    detect_installed_database
    [[ -n "$DATABASE"    ]] && state_set database "$DATABASE"
    [[ -n "$DB_VERSION"  ]] && state_set database_version "$DB_VERSION"

    state_set "imported_at" "$(date -Iseconds)"
    state_set "wizard_completed" "$(date -Iseconds)"
    log_ok "Состояние импортировано"
    echo "  Web:  $(state_get webserver)"
    echo "  PHP:  $(state_list_php)  (default: $(state_get default_php_version))"
    echo "  DB:   $(state_get database) $(state_get database_version)"
}

panel_detected_notice() {
    local panel="$1"
    clear_or_newlines
    banner
    log_warn "=================================================="
    log_warn "  Обнаружена панель управления: ${panel}"
    log_warn "=================================================="
    echo
    echo "servermanager НЕ управляет серверами, на которых уже стоит"
    echo "панель управления. Панель — полноценная система, и наш скрипт"
    echo "может нарушить её конфигурацию."
    echo
    echo "Рекомендации:"
    echo "  • Используйте панель для управления сайтами и PHP"
    echo "  • Если хотите перейти на servermanager — сначала"
    echo "    удалите панель (согласно её документации) на чистой ОС"
    echo
    exit 0
}

#=====================================================================
# CLI
#=====================================================================

show_help() {
    cat <<EOF
Server Manager v${SM_VERSION}

ИСПОЛЬЗОВАНИЕ:
  $0                        Основной режим: wizard при первом запуске,
                            главное меню в последующие разы
  $0 menu                   Форсировать главное меню (даже при fresh)
  $0 wizard                 Форсировать wizard (даже при installed)
  $0 uninstall              Удалить весь стек
  $0 status                 Показать состояние и выйти
  $0 list-sites             Список сайтов
  $0 add-site               Добавить сайт (интерактивно)
  $0 remove-site <domain>   Удалить сайт
  $0 install-php <ver>      Установить доп. версию PHP
  $0 remove-php  <ver>      Удалить версию PHP
  $0 set-default-php <ver>  Сменить default PHP
  $0 change-site-php <domain> <ver>  Сменить PHP для сайта
  $0 issue-ssl <domain>     Выпустить/обновить SSL (acme.sh)
                            По умолчанию webroot (http-01 через файл).
                            Альтернативы (ENV):
                              SM_ACME_STAGING=1   — staging LE (для тестов, без лимитов)
                              SM_ACME_MODE=standalone SM_ACME_STOP_WEB=1
                                                  — acme.sh сам поднимет :80
                              SM_ACME_MODE=dns SM_ACME_DNS_PROVIDER=dns_cf
                                                  — DNS-01 (для сайтов за CF-proxy)

Диагностика:
  $0 doctor                 Health-check: nginx -t, FPM-сокеты, БД, диск, SSL expiry, DNS
  $0 status                 Статус сервисов и сайтов (быстрый обзор)
  $0 uninstall-cron         Очистить cron-задачи servermanager/acme.sh (без удаления стека)

Бэкапы (хранилище: ${SM_BACKUP_DIR:-/var/backups/servermanager}):
  $0 backup-site <domain>    Бэкап одного сайта (файлы + БД через mysqldump)
  $0 backup-all              Бэкап всех сайтов
  $0 backup-system           Бэкап системных конфигов + всех БД
  $0 backup-list [domain]    Список бэкапов (всех или одного сайта)
  $0 restore-site <archive>  Восстановить сайт из архива
  $0 backup-setup-cron       Включить автобэкап всех сайтов (ежедневно 03:00)
  $0 backup-remove-cron      Отключить автобэкап

  $0 -h | --help            Справка

NON-INTERACTIVE РЕЖИМ:
  Установите SM_NON_INTERACTIVE=1 и передайте параметры через env-vars.

  Wizard (install stack):
    WEB_SERVER=nginx|nginx_apache
    PHP_TO_INSTALL="8.3 8.5"   PHP_DEFAULT=8.5
    DATABASE=mariadb|mysql     DB_VERSION=11.4
    ENABLE_SWAP=true|false     SWAP_SIZE=2G

  Add site:
    DOMAIN=example.com
    SITE_DIR=/var/www/example.com
    SITE_PHP_VERSION=8.5       SITE_BACKEND=php-fpm|apache-mod-php|apache-php-fpm
    CREATE_DB=true|false       DB_NAME=... DB_USER=... DB_PASS=...
    ENABLE_SSL=true|false      SSL_EMAIL=me@example.com

ПРИМЕРЫ:
  # Полная неинтерактивная установка:
  SM_NON_INTERACTIVE=1 \\
    WEB_SERVER=nginx PHP_TO_INSTALL="8.3 8.5" PHP_DEFAULT=8.5 \\
    DATABASE=mariadb \\
    DOMAIN=example.com SITE_PHP_VERSION=8.5 SITE_BACKEND=php-fpm \\
    CREATE_DB=true ENABLE_SSL=true SSL_EMAIL=me@example.com \\
    $0 wizard

  # Мгновенный запуск через curl:
  curl -fsSL https://your-host/servermanager.sh | sudo bash

ФАЙЛЫ:
  Логи:     ${LOG_FILE}
  Состояние: ${SM_DIR}/state.conf
  Сайты:    ${SM_SITES_DIR}/
  Секреты:  ${SM_CRED_DIR}/  (chmod 600)
EOF
}

show_status() {
    banner
    show_state_summary
    echo -e "${CYAN}Сайты:${NC}"
    list_sites
    echo
    if command_exists systemctl; then
        echo -e "${CYAN}Сервисы:${NC}"
        show_services_status
    fi
}

#=====================================================================
# Doctor / health-check
#=====================================================================

# Вспомогательные индикаторы: зелёный/красный/жёлтый.
_dr_ok()   { printf "  ${GREEN}[\xe2\x9c\x93]${NC} %s\n" "$*"; }
_dr_fail() { printf "  ${RED}[\xe2\x9c\x97]${NC} %s\n" "$*"; DOCTOR_FAILS=$((DOCTOR_FAILS+1)); }
_dr_warn() { printf "  ${YELLOW}[!]${NC} %s\n" "$*"; DOCTOR_WARNS=$((DOCTOR_WARNS+1)); }
_dr_info() { printf "  ${CYAN}[i]${NC} %s\n" "$*"; }

# Определить публичный IP сервера. Сначала пытаемся ip route, потом внешний сервис.
_dr_server_ip() {
    local ip=""
    # Primary: через default route
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)"
    if [[ -z "$ip" ]]; then
        # Fallback: ifconfig.me / icanhazip (без падения, если сети нет)
        ip="$(curl -fsS --max-time 3 https://ifconfig.me 2>/dev/null || curl -fsS --max-time 3 https://icanhazip.com 2>/dev/null || true)"
    fi
    echo "$ip"
}

doctor() {
    banner
    echo -e "${CYAN}${BOLD}=== Диагностика сервера (doctor) ===${NC}"
    echo

    DOCTOR_FAILS=0
    DOCTOR_WARNS=0

    # --- Nginx ---
    echo -e "${BOLD}Nginx:${NC}"
    if command_exists nginx; then
        local nginx_version
        nginx_version="$(nginx -v 2>&1 | head -n1 | awk -F': ' '{print $2}')"
        _dr_info "version: ${nginx_version}"
        if nginx -t >/dev/null 2>&1; then
            _dr_ok "nginx -t: конфиг валиден"
        else
            _dr_fail "nginx -t провалился — см. 'nginx -t' для деталей"
        fi
        if $SVC_MGR is-active nginx >/dev/null 2>&1; then
            _dr_ok "nginx service: active"
        else
            _dr_fail "nginx service: не запущен"
        fi
    else
        _dr_info "nginx не установлен — пропускаю"
    fi
    echo

    # --- Apache ---
    echo -e "${BOLD}Apache:${NC}"
    local apache_bin=""
    command_exists apache2 && apache_bin="apache2"
    command_exists httpd   && apache_bin="httpd"
    if [[ -n "$apache_bin" ]]; then
        if $apache_bin -t >/dev/null 2>&1 || apachectl -t >/dev/null 2>&1; then
            _dr_ok "${apache_bin}: конфиг валиден"
        else
            _dr_fail "${apache_bin}: конфиг невалиден"
        fi
        if $SVC_MGR is-active "$apache_bin" >/dev/null 2>&1; then
            _dr_ok "${apache_bin} service: active"
        else
            _dr_warn "${apache_bin} service: не запущен (возможно, намеренно — используется только для PHP)"
        fi
    else
        _dr_info "Apache не установлен — пропускаю"
    fi
    echo

    # --- PHP-FPM ---
    echo -e "${BOLD}PHP-FPM:${NC}"
    local php_versions
    php_versions="$(state_list_php || true)"
    if [[ -z "$php_versions" ]]; then
        _dr_info "PHP не установлены через servermanager"
    else
        local v fpm_svc
        for v in $php_versions; do
            if [[ "$OS_TYPE" == "debian" ]]; then
                fpm_svc="php${v}-fpm"
            else
                fpm_svc="php${v//./}-php-fpm"
            fi
            if $SVC_MGR is-active "$fpm_svc" >/dev/null 2>&1; then
                _dr_ok "${fpm_svc}: active"
            else
                _dr_fail "${fpm_svc}: не запущен"
            fi
        done

        # Per-site FPM-сокеты: сверяемся с конфигами сайтов.
        if [[ -d "$SM_SITES_DIR" ]]; then
            local conf domain php_ver sock
            for conf in "$SM_SITES_DIR"/*.conf; do
                [[ -f "$conf" ]] || continue
                domain="$(basename "$conf" .conf)"
                php_ver="$(kv_get_file "$conf" "PHP_VERSION")"
                [[ -z "$php_ver" ]] && continue
                sock="/run/php/php${php_ver}-fpm-${domain}.sock"
                if [[ -S "$sock" ]]; then
                    _dr_ok "socket ${sock}"
                else
                    _dr_fail "socket отсутствует: ${sock} (сайт ${domain})"
                fi
            done
        fi
    fi
    echo

    # --- Database ---
    echo -e "${BOLD}База данных:${NC}"
    local db_svc=""
    if $SVC_MGR is-active mariadb >/dev/null 2>&1; then
        db_svc="mariadb"
    elif $SVC_MGR is-active mysql >/dev/null 2>&1; then
        db_svc="mysql"
    elif $SVC_MGR is-active mysqld >/dev/null 2>&1; then
        db_svc="mysqld"
    fi
    if [[ -n "$db_svc" ]]; then
        _dr_ok "${db_svc} service: active"
        if mysql -e "SELECT 1" >/dev/null 2>&1; then
            _dr_ok "SQL-подключение работает (через /root/.my.cnf)"
            local db_count
            db_count="$(mysql -Nse "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys');" 2>/dev/null || echo "?")"
            _dr_info "пользовательских БД: ${db_count}"
        else
            _dr_fail "не удаётся подключиться через /root/.my.cnf"
        fi
    else
        _dr_info "БД не запущена (или не установлена через servermanager)"
    fi
    echo

    # --- Диск ---
    echo -e "${BOLD}Дисковое пространство:${NC}"
    local path avail_bytes avail_hr use_pct
    for path in / /var/www /var/backups /var/lib/mysql; do
        [[ -d "$path" ]] || continue
        read -r avail_bytes use_pct < <(df --output=avail,pcent -B1 "$path" 2>/dev/null | tail -n1 | awk '{gsub("%","",$2); print $1, $2}')
        avail_hr="$(_human_size "${avail_bytes:-0}")"
        if (( use_pct >= 90 )); then
            _dr_fail "${path}: ${use_pct}% used (свободно: ${avail_hr})"
        elif (( use_pct >= 80 )); then
            _dr_warn "${path}: ${use_pct}% used (свободно: ${avail_hr})"
        else
            _dr_ok "${path}: ${use_pct}% used (свободно: ${avail_hr})"
        fi
    done
    echo

    # --- SSL expiry ---
    echo -e "${BOLD}SSL-сертификаты:${NC}"
    local cert now_s exp_s days_left cert_dir="${SM_ACME_SSL_DIR:-/etc/ssl/acme}"
    local found_certs=false
    now_s="$(date +%s)"
    if [[ -d "$cert_dir" ]]; then
        for cert in "$cert_dir"/*.fullchain.cer; do
            [[ -f "$cert" ]] || continue
            found_certs=true
            local d
            d="$(basename "$cert" .fullchain.cer)"
            exp_s="$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2 | xargs -I{} date -d {} +%s 2>/dev/null || echo 0)"
            if (( exp_s == 0 )); then
                _dr_fail "${d}: не удалось прочитать срок истечения"
                continue
            fi
            days_left=$(( (exp_s - now_s) / 86400 ))
            if (( days_left < 0 )); then
                _dr_fail "${d}: истёк ${days_left#-} дней назад"
            elif (( days_left < 14 )); then
                _dr_warn "${d}: истекает через ${days_left} дн."
            else
                _dr_ok "${d}: ${days_left} дн. до истечения"
            fi
        done
    fi
    # Legacy certbot
    if [[ -d /etc/letsencrypt/live ]]; then
        local le_dir le_cert d
        while IFS= read -r -d '' le_dir; do
            le_cert="${le_dir}/fullchain.pem"
            [[ -f "$le_cert" ]] || continue
            found_certs=true
            d="$(basename "$le_dir")"
            exp_s="$(openssl x509 -enddate -noout -in "$le_cert" 2>/dev/null | cut -d= -f2 | xargs -I{} date -d {} +%s 2>/dev/null || echo 0)"
            if (( exp_s == 0 )); then
                _dr_fail "${d} (certbot legacy): не удалось прочитать срок"
                continue
            fi
            days_left=$(( (exp_s - now_s) / 86400 ))
            if (( days_left < 0 )); then
                _dr_fail "${d} (certbot legacy): истёк"
            elif (( days_left < 14 )); then
                _dr_warn "${d} (certbot legacy): ${days_left} дн."
            else
                _dr_ok "${d} (certbot legacy): ${days_left} дн."
            fi
        done < <(find /etc/letsencrypt/live -maxdepth 1 -mindepth 1 -type d ! -name "README" -print0 2>/dev/null)
    fi
    $found_certs || _dr_info "SSL-сертификаты не найдены (ни в acme.sh, ни в certbot legacy)"
    echo

    # --- DNS (A-записи доменов → IP сервера) ---
    echo -e "${BOLD}DNS A-записи:${NC}"
    local server_ip
    server_ip="$(_dr_server_ip)"
    if [[ -z "$server_ip" ]]; then
        _dr_warn "не удалось определить IP сервера — пропускаю DNS-проверку"
    elif ! command_exists dig && ! command_exists host && ! command_exists getent; then
        _dr_warn "нет dig/host/getent — пропускаю DNS-проверку (установите dnsutils / bind-utils)"
    else
        _dr_info "IP сервера: ${server_ip}"
        if [[ -d "$SM_SITES_DIR" ]]; then
            local conf domain resolved_ips ok=0
            for conf in "$SM_SITES_DIR"/*.conf; do
                [[ -f "$conf" ]] || continue
                domain="$(basename "$conf" .conf)"
                # localhost / *.local / *.test — пропускаем.
                if [[ "$domain" == "localhost" || "$domain" == *.local || "$domain" == *.test ]]; then
                    _dr_info "${domain}: локальный домен, DNS пропущен"
                    continue
                fi
                resolved_ips=""
                if command_exists dig; then
                    resolved_ips="$(dig +short +time=2 +tries=1 A "$domain" 2>/dev/null | tr '\n' ' ' | xargs)"
                elif command_exists host; then
                    resolved_ips="$(host -W 2 -t A "$domain" 2>/dev/null | awk '/has address/ {print $NF}' | tr '\n' ' ' | xargs)"
                else
                    resolved_ips="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' | xargs)"
                fi
                if [[ -z "$resolved_ips" ]]; then
                    _dr_fail "${domain}: не резолвится (нет A-записи?)"
                elif echo " $resolved_ips " | grep -q " $server_ip "; then
                    _dr_ok "${domain} → ${resolved_ips}"
                else
                    _dr_warn "${domain} → ${resolved_ips} (НЕ совпадает с ${server_ip} — возможно, Cloudflare proxy или другой хостинг)"
                fi
            done
        fi
    fi
    echo

    # --- Cron backup ---
    echo -e "${BOLD}Автобэкап (cron):${NC}"
    if crontab -l 2>/dev/null | grep -q 'servermanager.*backup-all'; then
        _dr_ok "автобэкап включён"
    else
        _dr_info "автобэкап не настроен (включить: $0 backup-setup-cron)"
    fi
    echo

    # --- Итог ---
    echo -e "${BOLD}=== Итог ===${NC}"
    if (( DOCTOR_FAILS == 0 && DOCTOR_WARNS == 0 )); then
        echo -e "  ${GREEN}Всё в порядке.${NC}"
        return 0
    fi
    if (( DOCTOR_FAILS > 0 )); then
        echo -e "  ${RED}Проблем: ${DOCTOR_FAILS}, предупреждений: ${DOCTOR_WARNS}${NC}"
        return 1
    fi
    echo -e "  ${YELLOW}Предупреждений: ${DOCTOR_WARNS}${NC}"
    return 0
}

#=====================================================================
# Non-interactive wizard (для CI/CD)
#=====================================================================
run_wizard_noninteractive() {
    # В non-interactive режиме пропускаем обновление системы, swap и firewall
    # настраиваются по env-vars. Стек всегда устанавливается (не панель).
    install_base_deps

    WEB_SERVER="${WEB_SERVER:-nginx}"
    DATABASE="${DATABASE:-mariadb}"
    DB_VERSION="${DB_VERSION:-}"
    local phpline="${PHP_TO_INSTALL:-8.3 8.5}"
    PHP_TO_INSTALL=()
    local _item
    for _item in $phpline; do
        _item=$(printf '%s' "$_item" | tr -d '\r\xc2\xa0' | xargs)
        [[ -n "$_item" ]] && PHP_TO_INSTALL+=("$_item")
    done
    PHP_DEFAULT="${PHP_DEFAULT:-$(printf '%s\n' "${PHP_TO_INSTALL[@]}" | sort -V | tail -n1)}"

    local v sv ok
    for v in "${PHP_TO_INSTALL[@]}"; do
        ok=false
        for sv in "${SUPPORTED_PHP_VERSIONS[@]}"; do
            [[ "$v" == "$sv" ]] && { ok=true; break; }
        done
        if ! $ok; then
            log_error "Неподдерживаемая версия PHP: '$v'"
            log_error "Поддерживаются: ${SUPPORTED_PHP_VERSIONS[*]}"
            exit 1
        fi
    done

    install_nginx
    [[ "$WEB_SERVER" == "nginx_apache" ]] && install_apache

    local failed_versions=()
    set +e
    for v in "${PHP_TO_INSTALL[@]}"; do
        if ! install_php_version "$v"; then
            failed_versions+=("$v")
        fi
    done
    set -e
    (( ${#failed_versions[@]} > 0 )) && log_warn "Не установились: ${failed_versions[*]}"
    if [[ -z "$(state_list_php)" ]]; then
        log_error "Не установлено ни одной версии PHP"; exit 1
    fi
    # Если PHP_DEFAULT не установился — подменяем на доступный
    if ! state_list_php | tr ' ' '\n' | grep -qxF "$PHP_DEFAULT"; then
        PHP_DEFAULT=$(state_list_php | tr ' ' '\n' | sort -V | tail -n1)
        log_warn "Default PHP переключен на ${PHP_DEFAULT}"
    fi
    state_set default_php_version "$PHP_DEFAULT"
    state_set webserver "$WEB_SERVER"

    if [[ "$DATABASE" == "mariadb" ]]; then install_mariadb; else install_mysql; fi
    optimize_database

    [[ "${ENABLE_SWAP:-false}" == "true" ]] && setup_swap
    [[ "${ENABLE_FIREWALL:-true}" == "true" ]] && { setup_firewall; setup_fail2ban; }

    if [[ -n "${DOMAIN:-}" ]]; then
        prompt_site_params
        add_site
    fi

    state_set "wizard_completed" "$(date -Iseconds)"
    cleanup_pkgs
    log_ok "Non-interactive установка завершена"
    log_ok "  Web: $(state_get webserver) | PHP: $(state_list_php) | DB: $(state_get database) $(state_get database_version)"
    log_ok "  Пароль root БД: ${SM_CRED_DIR}/db-root.txt"
    log_ok "  Лог: ${LOG_FILE}"
}

#=====================================================================
# Entry point
#=====================================================================
main() {
    # Help доступен без root (чтобы можно было быстро глянуть команды).
    case "${1:-}" in
        -h|--help|help) show_help; exit 0 ;;
    esac
    require_root
    init_dirs
    detect_os

    # Concurrency guard: блокировка на всё время работы.
    # Read-only команды (status, list-*, backup-list, doctor) не блокируются —
    # их можно запускать параллельно с основным процессом.
    case "${1:-}" in
        status|list-sites|backup-list|doctor) : ;;  # read-only — пропускаем flock
        *) acquire_lock ;;
    esac

    # State format versioning (forward-compatible migrations)
    [[ -z "$(state_get state_format)" ]] && state_set state_format "$SM_STATE_FORMAT"

    # Парсинг CLI
    local cmd="${1:-auto}"
    case "$cmd" in
        -h|--help|help) show_help; exit 0 ;;
        status)         show_status; exit 0 ;;
        list-sites)     list_sites; exit 0 ;;
        add-site)       prompt_site_params; add_site; exit 0 ;;
        remove-site)
            [[ -z "${2:-}" ]] && { log_error "Укажите домен"; exit 1; }
            remove_site "$2"; exit 0 ;;
        install-php)
            [[ -z "${2:-}" ]] && { log_error "Укажите версию"; exit 1; }
            install_php_version "$2"
            [[ -z "$(state_get default_php_version)" ]] && state_set default_php_version "$2"
            exit 0 ;;
        remove-php)
            [[ -z "${2:-}" ]] && { log_error "Укажите версию"; exit 1; }
            uninstall_php_version "$2"; exit 0 ;;
        set-default-php)
            [[ -z "${2:-}" ]] && { log_error "Укажите версию"; exit 1; }
            if state_list_php | tr ' ' '\n' | grep -qxF "$2"; then
                state_set default_php_version "$2"
                log_ok "Default PHP: $2"
            else
                log_error "Версия $2 не установлена"; exit 1
            fi
            exit 0 ;;
        change-site-php)
            [[ -z "${2:-}" || -z "${3:-}" ]] && { log_error "Использование: $0 change-site-php <domain> <php_version>"; exit 1; }
            change_site_php "$2" "$3"; exit $? ;;
        issue-ssl|--issue-ssl)
            [[ -z "${2:-}" ]] && { log_error "Использование: $0 issue-ssl <domain>"; exit 1; }
            setup_ssl_for_site "$2"; exit $? ;;
        backup-site)
            [[ -z "${2:-}" ]] && { log_error "Использование: $0 backup-site <domain>"; exit 1; }
            create_site_backup "$2"; exit $? ;;
        backup-all)
            backup_all_sites; exit $? ;;
        backup-system)
            create_system_backup; exit $? ;;
        backup-list)
            list_backups "${2:-}"; exit 0 ;;
        restore-site)
            [[ -z "${2:-}" ]] && { log_error "Использование: $0 restore-site <архив.tar.gz | имя>"; exit 1; }
            restore_site_backup "$2"; exit $? ;;
        backup-setup-cron)
            backup_setup_cron; exit $? ;;
        backup-remove-cron)
            backup_remove_cron; exit $? ;;
        doctor|health-check)
            doctor; exit $? ;;
        uninstall-cron)
            uninstall_cron_jobs; exit $? ;;
        uninstall) uninstall_stack; exit 0 ;;
        wizard)
            if is_non_interactive; then
                preflight_checks
                run_wizard_noninteractive
            else
                preflight_checks
                first_run_wizard
            fi
            exit 0 ;;
        menu)          main_menu; exit 0 ;;
        auto|"")       ;;  # → detect_state и роутинг ниже
        *)             log_error "Неизвестная команда: $cmd"; show_help; exit 1 ;;
    esac

    # Non-interactive без явной команды → wizard
    if is_non_interactive; then
        preflight_checks
        run_wizard_noninteractive
        exit 0
    fi

    # Auto-route на основании состояния
    local state
    state=$(detect_state)
    case "$state" in
        fresh)
            preflight_checks
            first_run_wizard
            ;;
        managed)
            main_menu
            ;;
        foreign)
            banner
            echo
            import_foreign_state
            echo
            if prompt_yes_no "Перейти в главное меню?" "y"; then
                main_menu
            fi
            ;;
        panel:*)
            panel_detected_notice "${state#panel:}"
            ;;
    esac
}

main "$@"