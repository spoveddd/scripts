#!/usr/bin/env bash
# =============================================================================
# syscheck.sh v2.0 — fast Linux security pre-flight check
# -----------------------------------------------------------------------------
# Быстрая диагностика состояния системы перед началом работы.
# Цель: выявить наиболее распространённые persistence-механизмы, подозрительные
# изменения и индикаторы компрометации за 5-15 секунд (quick mode) или за
# 30-90 секунд (full mode c SUID-сканом и проверкой целостности пакетов).
#
# ВАЖНО: это инструмент pre-flight проверки, НЕ замена HIDS (Wazuh/OSSEC/Falco),
# baseline-систем (AIDE/tripwire) или внешних сканеров (rkhunter/chkrootkit/Lynis).
# Скомпрометированная система может лгать любому инструменту, работающему на ней.
# =============================================================================

set -uo pipefail
IFS=$'\n\t'
umask 077

# Версия
readonly SYSCHECK_VERSION="2.0"

# =============================================================================
# CLI FLAGS
# =============================================================================
MODE="quick"          # quick | full
OUTPUT_FILE=""
NO_COLOR=0
QUIET=0
SHOW_HELP=0

usage() {
    cat <<'EOF'
syscheck.sh — быстрая проверка безопасности Linux-системы

USAGE:
    syscheck.sh [OPTIONS]

OPTIONS:
    -f, --full            Полный режим (включает SUID-скан и проверку целостности пакетов)
    -o, --output FILE     Сохранить полный вывод в файл (в т.ч. без ANSI-цветов)
    -n, --no-color        Отключить цветной вывод
    -q, --quiet           Только сводка и CRIT/WARN-находки
    -v, --version         Показать версию
    -h, --help            Показать эту справку

EXIT CODES:
     0  Всё в порядке
     1  Обнаружены WARN-находки
     2  Обнаружены CRIT-находки (вероятная компрометация)
     3  Ошибка выполнения самого скрипта

EXAMPLES:
    ./syscheck.sh                     # быстрый режим
    sudo ./syscheck.sh --full         # полный режим от root
    ./syscheck.sh -o /tmp/report.txt  # сохранить в файл
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--full)     MODE="full"; shift ;;
        -o|--output)   OUTPUT_FILE="${2:-}"; shift 2 ;;
        -n|--no-color) NO_COLOR=1; shift ;;
        -q|--quiet)    QUIET=1; shift ;;
        -v|--version)  echo "syscheck.sh v${SYSCHECK_VERSION}"; exit 0 ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "Неизвестный флаг: $1" >&2; usage >&2; exit 3 ;;
    esac
done

# =============================================================================
# COLORS (TTY-aware)
# =============================================================================
if [[ $NO_COLOR -eq 1 ]] || [[ ! -t 1 ]] || [[ -n "$OUTPUT_FILE" ]]; then
    RED=''; YEL=''; GRN=''; BLU=''; BLD=''; DIM=''; NC=''
else
    RED=$'\033[0;31m'
    YEL=$'\033[1;33m'
    GRN=$'\033[0;32m'
    BLU=$'\033[0;36m'
    BLD=$'\033[1m'
    DIM=$'\033[2m'
    NC=$'\033[0m'
fi

# =============================================================================
# STATE
# =============================================================================
CRIT_COUNT=0
WARN_COUNT=0
INFO_COUNT=0
declare -a CRIT_FINDINGS=()
declare -a WARN_FINDINGS=()
START_TIME=$(date +%s)

# Перенаправление вывода в файл, если указано
if [[ -n "$OUTPUT_FILE" ]]; then
    # Пишем и в файл, и в stdout
    exec > >(tee -a "$OUTPUT_FILE") 2>&1
fi

# =============================================================================
# OUTPUT HELPERS
# =============================================================================
print_section() {
    [[ $QUIET -eq 1 ]] && return 0
    printf '\n%s=== %s ===%s\n' "${BLD}${BLU}" "$1" "${NC}"
}

print_subsection() {
    [[ $QUIET -eq 1 ]] && return 0
    printf '  %s%s:%s\n' "${BLD}" "$1" "${NC}"
}

print_info() {
    [[ $QUIET -eq 1 ]] && return 0
    printf '    %s\n' "$1"
}

print_dim() {
    [[ $QUIET -eq 1 ]] && return 0
    printf '    %s%s%s\n' "${DIM}" "$1" "${NC}"
}

# Основной API для регистрации находок
ok()    { [[ $QUIET -eq 1 ]] && return 0; printf '    %s✓ %s%s\n' "${GRN}" "$1" "${NC}"; }
info()  { [[ $QUIET -eq 1 ]] && return 0; printf '    %sℹ %s%s\n' "${BLU}" "$1" "${NC}"; INFO_COUNT=$((INFO_COUNT+1)); }
warn()  { printf '    %s⚠ %s%s\n' "${YEL}" "$1" "${NC}"; WARN_COUNT=$((WARN_COUNT+1)); WARN_FINDINGS+=("$1"); }
crit()  { printf '    %s✗ %s%s\n' "${RED}" "$1" "${NC}"; CRIT_COUNT=$((CRIT_COUNT+1)); CRIT_FINDINGS+=("$1"); }

# Безопасное выполнение с таймаутом (не падает, если команды нет)
safe_run() {
    local tmo="${1:-5}"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout --preserve-status "$tmo" "$@" 2>/dev/null || true
    else
        "$@" 2>/dev/null || true
    fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# Человекочитаемый mtime
file_mtime() {
    stat -c '%y' "$1" 2>/dev/null | cut -d. -f1 || echo "?"
}

# =============================================================================
# ENVIRONMENT DETECTION
# =============================================================================
IS_ROOT=0
[[ $(id -u) -eq 0 ]] && IS_ROOT=1

IS_CONTAINER=0
CONTAINER_TYPE=""
detect_container() {
    if [[ -f /.dockerenv ]]; then
        IS_CONTAINER=1; CONTAINER_TYPE="docker"
    elif [[ -f /run/.containerenv ]]; then
        IS_CONTAINER=1; CONTAINER_TYPE="podman"
    elif grep -qaE '(docker|lxc|kubepods|containerd|podman)' /proc/1/cgroup 2>/dev/null; then
        IS_CONTAINER=1; CONTAINER_TYPE="container"
    elif [[ -r /proc/1/environ ]] && tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep -qE '^container='; then
        IS_CONTAINER=1; CONTAINER_TYPE="lxc"
    fi
}

INIT_SYSTEM="unknown"
detect_init() {
    if [[ -d /run/systemd/system ]]; then
        INIT_SYSTEM="systemd"
    elif [[ -f /sbin/openrc ]] || have openrc; then
        INIT_SYSTEM="openrc"
    elif [[ -f /etc/init.d/rcS ]]; then
        INIT_SYSTEM="sysvinit"
    fi
}

DISTRO_ID="unknown"
DISTRO_NAME="unknown"
detect_distro() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_NAME="${PRETTY_NAME:-$ID}"
    fi
}

PKG_MANAGER=""
detect_pkg_manager() {
    if have dpkg; then PKG_MANAGER="dpkg"
    elif have rpm; then PKG_MANAGER="rpm"
    elif have apk; then PKG_MANAGER="apk"
    elif have pacman; then PKG_MANAGER="pacman"
    fi
}

detect_container
detect_init
detect_distro
detect_pkg_manager

# =============================================================================
# HEADER
# =============================================================================
print_header() {
    printf '%s🔍 syscheck.sh v%s — security pre-flight check%s\n' "${BLD}${GRN}" "${SYSCHECK_VERSION}" "${NC}"
    printf '%sВремя:%s       %s\n' "${BLD}" "${NC}" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf '%sХост:%s        %s\n' "${BLD}" "${NC}" "$(hostname 2>/dev/null || echo '?')"
    printf '%sKernel:%s      %s\n' "${BLD}" "${NC}" "$(uname -sr 2>/dev/null || echo '?')"
    printf '%sДистрибутив:%s %s\n' "${BLD}" "${NC}" "$DISTRO_NAME"
    printf '%sInit:%s        %s\n' "${BLD}" "${NC}" "$INIT_SYSTEM"
    printf '%sPkg mgr:%s     %s\n' "${BLD}" "${NC}" "${PKG_MANAGER:-не найден}"
    printf '%sРежим:%s       %s\n' "${BLD}" "${NC}" "$MODE"
    if [[ $IS_CONTAINER -eq 1 ]]; then
        printf '%sКонтейнер:%s   %syes (%s)%s\n' "${BLD}" "${NC}" "${YEL}" "$CONTAINER_TYPE" "${NC}"
    fi
    if [[ $IS_ROOT -eq 0 ]]; then
        printf '%sПривилегии:%s  %snon-root — часть проверок будет неполной%s\n' \
            "${BLD}" "${NC}" "${YEL}" "${NC}"
    fi
}

# =============================================================================
# CHECK 1: ENVIRONMENT & SANITY
# =============================================================================
check_env_sanity() {
    print_section "ЦЕЛОСТНОСТЬ ОКРУЖЕНИЯ"

    # LD_PRELOAD / LD_AUDIT в нашем окружении (признак внедрения)
    if [[ -n "${LD_PRELOAD:-}" ]]; then
        crit "LD_PRELOAD установлен в текущем окружении: $LD_PRELOAD"
    fi
    if [[ -n "${LD_AUDIT:-}" ]]; then
        crit "LD_AUDIT установлен в текущем окружении: $LD_AUDIT"
    fi
    if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
        warn "LD_LIBRARY_PATH установлен: $LD_LIBRARY_PATH"
    fi

    # /etc/ld.so.preload — один из популярнейших persistence-векторов
    if [[ -f /etc/ld.so.preload ]]; then
        if [[ -s /etc/ld.so.preload ]]; then
            crit "/etc/ld.so.preload НЕПУСТОЙ (возможен LD_PRELOAD rootkit):"
            while IFS= read -r line; do
                [[ -n "$line" ]] && print_info "${RED}${line}${NC}"
            done < /etc/ld.so.preload
        else
            ok "/etc/ld.so.preload пустой"
        fi
    else
        ok "/etc/ld.so.preload отсутствует"
    fi

    # PATH-injection
    case ":$PATH:" in
        *::*|*:.:*)
            warn "PATH содержит пустой элемент или '.' — риск PATH hijacking: $PATH" ;;
    esac
}

# =============================================================================
# CHECK 2: ACTIVE SESSIONS & LOGIN HISTORY
# =============================================================================
check_sessions() {
    print_section "АКТИВНЫЕ СЕССИИ И ВХОДЫ"

    print_subsection "Текущие пользователи (who)"
    local who_out
    who_out=$(who 2>/dev/null || true)
    if [[ -n "$who_out" ]]; then
        while IFS= read -r line; do print_info "$line"; done < <(echo "$who_out")
    else
        print_dim "(нет активных сессий или данные недоступны)"
    fi

    print_subsection "Последние 5 входов (last)"
    safe_run 3 last -aiw -n 5 2>/dev/null | sed '/^$/d;/^wtmp begins/d' | \
        while IFS= read -r line; do print_info "$line"; done || true

    # Неудачные попытки (lastb) — только для root
    if [[ $IS_ROOT -eq 1 ]]; then
        print_subsection "Неудачные попытки входа за сутки (lastb)"
        local fails
        fails=$(safe_run 3 lastb -aiw --since "$(date -d '1 day ago' '+%Y-%m-%d' 2>/dev/null || echo '')" 2>/dev/null | \
                sed '/^$/d;/^btmp begins/d' | wc -l)
        if [[ "$fails" -gt 50 ]]; then
            warn "За сутки $fails неудачных попыток входа — возможен brute-force"
        elif [[ "$fails" -gt 0 ]]; then
            print_dim "$fails неудачных попыток за сутки"
        else
            print_dim "неудачных попыток не зарегистрировано"
        fi
    fi
}

# =============================================================================
# CHECK 3: USERS & PRIVILEGES
# =============================================================================
check_users_privs() {
    print_section "ПОЛЬЗОВАТЕЛИ И ПРИВИЛЕГИИ"

    # UID 0 — не только root
    local uid0_users
    uid0_users=$(awk -F: '$3 == 0 {print $1}' /etc/passwd 2>/dev/null | grep -v '^root$' || true)
    if [[ -n "$uid0_users" ]]; then
        crit "Пользователи с UID 0 помимо root:"
        while IFS= read -r u; do print_info "${RED}${u}${NC}"; done < <(echo "$uid0_users")
    else
        ok "UID 0 только у root"
    fi

    # GID 0 — тоже подозрительно
    local gid0_users
    gid0_users=$(awk -F: '$4 == 0 {print $1}' /etc/passwd 2>/dev/null | grep -v '^root$' || true)
    if [[ -n "$gid0_users" ]]; then
        warn "Пользователи с GID 0 (root group) помимо root: $(echo "$gid0_users" | tr '\n' ' ')"
    fi

    # Пустые пароли
    if [[ $IS_ROOT -eq 1 ]] && [[ -r /etc/shadow ]]; then
        local empty_pw
        empty_pw=$(awk -F: '($2 == "" || $2 == "!!") && $1 !~ /^(nobody|_)/ {print $1}' /etc/shadow 2>/dev/null || true)
        if [[ -n "$empty_pw" ]]; then
            # !! означает locked, не пустой — фильтруем
            empty_pw=$(awk -F: '$2 == "" {print $1}' /etc/shadow 2>/dev/null || true)
            if [[ -n "$empty_pw" ]]; then
                crit "Пользователи с пустым паролем: $(echo "$empty_pw" | tr '\n' ' ')"
            fi
        fi
    fi

    # Свежедобавленные пользователи
    print_subsection "Недавние изменения /etc/passwd и /etc/shadow"
    for f in /etc/passwd /etc/shadow /etc/group /etc/gshadow; do
        [[ -r "$f" ]] || continue
        local mtime_sec now_sec age_days
        mtime_sec=$(stat -c %Y "$f" 2>/dev/null || echo 0)
        now_sec=$(date +%s)
        age_days=$(( (now_sec - mtime_sec) / 86400 ))
        if [[ $age_days -le 7 ]]; then
            warn "$f изменён $age_days дней назад ($(file_mtime "$f"))"
        else
            print_dim "$f — изменён $age_days дней назад"
        fi
    done

    # Sudo-группы (sudo, wheel, admin)
    print_subsection "Sudo-группы"
    for grp in sudo wheel admin; do
        local members
        members=$(getent group "$grp" 2>/dev/null | cut -d: -f4 || true)
        if [[ -n "$members" ]]; then
            print_info "$grp: $members"
        fi
    done

    # sudoers с NOPASSWD
    if [[ $IS_ROOT -eq 1 ]]; then
        local nopasswd
        nopasswd=$(grep -rhE '^\s*[^#].*NOPASSWD' /etc/sudoers /etc/sudoers.d/ 2>/dev/null || true)
        if [[ -n "$nopasswd" ]]; then
            warn "Правила NOPASSWD в sudoers:"
            while IFS= read -r line; do
                print_info "${YEL}${line}${NC}"
            done < <(echo "$nopasswd" | head -10)
        fi
        # Sudoers с недавней модификацией
        for f in /etc/sudoers /etc/sudoers.d/*; do
            [[ -f "$f" ]] || continue
            local mtime_sec now_sec age_days
            mtime_sec=$(stat -c %Y "$f" 2>/dev/null || echo 0)
            now_sec=$(date +%s)
            age_days=$(( (now_sec - mtime_sec) / 86400 ))
            if [[ $age_days -le 30 ]]; then
                warn "$f изменён $age_days дней назад"
            fi
        done
    fi
}

# =============================================================================
# CHECK 4: SSH CONFIGURATION & AUTHORIZED KEYS
# =============================================================================
check_ssh() {
    print_section "SSH КОНФИГУРАЦИЯ И КЛЮЧИ"

    # sshd_config ключевые настройки
    if [[ -r /etc/ssh/sshd_config ]]; then
        print_subsection "Ключевые настройки sshd"
        local settings
        settings=$(grep -hE '^\s*(PermitRootLogin|PasswordAuthentication|PermitEmptyPasswords|AuthorizedKeysCommand|AuthorizedKeysFile|Port|Match|ForceCommand)\b' \
                   /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | sort -u || true)
        if [[ -n "$settings" ]]; then
            while IFS= read -r line; do
                case "$line" in
                    *PermitRootLogin*yes*) crit "sshd: $line" ;;
                    *PermitEmptyPasswords*yes*) crit "sshd: $line" ;;
                    *PasswordAuthentication*yes*) warn "sshd: $line (password auth разрешён)" ;;
                    *AuthorizedKeysCommand*) warn "sshd: $line (проверить безопасность скрипта)" ;;
                    *ForceCommand*) warn "sshd: $line" ;;
                    *) print_info "$line" ;;
                esac
            done < <(echo "$settings")
        else
            print_dim "(явных настроек не найдено, используются дефолты)"
        fi

        # Недавние изменения
        local mtime_sec age_days
        mtime_sec=$(stat -c %Y /etc/ssh/sshd_config 2>/dev/null || echo 0)
        age_days=$(( ($(date +%s) - mtime_sec) / 86400 ))
        if [[ $age_days -le 30 ]]; then
            warn "/etc/ssh/sshd_config изменён $age_days дней назад"
        fi
    fi

    # Authorized_keys всех пользователей (требует root для чужих /home)
    print_subsection "authorized_keys всех пользователей"
    local found_keys=0
    while IFS=: read -r user _ uid _ _ home _; do
        [[ -n "$home" && -d "$home" ]] || continue
        for ak in "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2"; do
            if [[ -f "$ak" ]]; then
                if [[ -r "$ak" ]]; then
                    local key_count mtime_str age_days mtime_sec
                    key_count=$(grep -cE '^(ssh-|ecdsa-|sk-|ssh2-)' "$ak" 2>/dev/null || echo 0)
                    mtime_str=$(file_mtime "$ak")
                    mtime_sec=$(stat -c %Y "$ak" 2>/dev/null || echo 0)
                    age_days=$(( ($(date +%s) - mtime_sec) / 86400 ))
                    found_keys=1
                    if [[ $age_days -le 14 ]]; then
                        warn "$user: $ak ($key_count ключ(ей), mtime $mtime_str — СВЕЖАЯ модификация)"
                    else
                        print_info "$user: $ak ($key_count ключ(ей), mtime $mtime_str)"
                    fi
                    # Проверка на Command= и from= ограничения
                    if grep -qE '^(command|from)=' "$ak" 2>/dev/null; then
                        print_dim "  ↳ содержит command=/from= ограничения"
                    fi
                else
                    print_dim "$user: $ak (нет прав на чтение — запустите от root)"
                fi
            fi
        done
    done < /etc/passwd
    [[ $found_keys -eq 0 ]] && print_dim "(authorized_keys не найдено ни у одного пользователя)"

    # Host keys mtime
    print_subsection "Host keys (изменения <30 дней подозрительны)"
    for hk in /etc/ssh/ssh_host_*_key.pub; do
        [[ -f "$hk" ]] || continue
        local mtime_sec age_days
        mtime_sec=$(stat -c %Y "$hk" 2>/dev/null || echo 0)
        age_days=$(( ($(date +%s) - mtime_sec) / 86400 ))
        if [[ $age_days -le 30 ]]; then
            warn "$(basename "$hk") изменён $age_days дней назад"
        else
            print_dim "$(basename "$hk") — $age_days дней"
        fi
    done
}

# =============================================================================
# CHECK 5: CRON / AT / SYSTEMD TIMERS (все источники)
# =============================================================================
check_scheduled() {
    print_section "ОТЛОЖЕННЫЕ ЗАДАЧИ (cron / at / timers)"

    # /etc/crontab
    if [[ -r /etc/crontab ]]; then
        local entries
        entries=$(grep -vE '^\s*(#|$)' /etc/crontab 2>/dev/null | grep -vE '^\s*(SHELL|PATH|MAILTO|HOME)=' || true)
        if [[ -n "$entries" ]]; then
            print_subsection "/etc/crontab"
            while IFS= read -r line; do print_info "$line"; done < <(echo "$entries")
        fi
    fi

    # /etc/cron.d/*
    local crond_files
    crond_files=$(find /etc/cron.d -maxdepth 1 -type f 2>/dev/null || true)
    if [[ -n "$crond_files" ]]; then
        print_subsection "/etc/cron.d/"
        while IFS= read -r f; do
            local mtime_sec age_days
            mtime_sec=$(stat -c %Y "$f" 2>/dev/null || echo 0)
            age_days=$(( ($(date +%s) - mtime_sec) / 86400 ))
            if [[ $age_days -le 7 ]]; then
                warn "$f (изменён $age_days дней назад)"
            else
                print_info "$f"
            fi
        done < <(echo "$crond_files")
    fi

    # Hourly/daily/weekly/monthly
    for dir in /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly; do
        [[ -d "$dir" ]] || continue
        local items
        items=$(find "$dir" -maxdepth 1 -type f -mtime -14 2>/dev/null || true)
        if [[ -n "$items" ]]; then
            print_subsection "$dir (изменения <14 дней)"
            while IFS= read -r f; do
                warn "$f (mtime $(file_mtime "$f"))"
            done < <(echo "$items")
        fi
    done

    # Пользовательские crontabs — требует root для полного обхода
    print_subsection "Пользовательские crontabs"
    local user_crons_found=0
    for spool in /var/spool/cron/crontabs /var/spool/cron; do
        [[ -d "$spool" ]] || continue
        if [[ $IS_ROOT -eq 1 ]] || [[ -r "$spool" ]]; then
            while IFS= read -r f; do
                [[ -f "$f" ]] || continue
                local u
                u=$(basename "$f")
                local entries
                entries=$(grep -cvE '^\s*(#|$)' "$f" 2>/dev/null || echo 0)
                if [[ "$entries" -gt 0 ]]; then
                    user_crons_found=1
                    warn "user '$u': $entries запис(и/ей) в $f"
                fi
            done < <(find "$spool" -maxdepth 1 -type f 2>/dev/null)
        fi
    done
    # Fallback: хотя бы свой crontab
    if [[ $IS_ROOT -eq 0 ]]; then
        local mycron
        mycron=$(crontab -l 2>/dev/null | grep -cvE '^\s*(#|$)' || echo 0)
        if [[ "$mycron" -gt 0 ]]; then
            user_crons_found=1
            warn "Ваш собственный crontab: $mycron запис(и/ей) (запустите от root для проверки других)"
        fi
    fi
    [[ $user_crons_found -eq 0 ]] && print_dim "(пользовательских crontab не обнаружено)"

    # at jobs
    if have atq; then
        local at_jobs
        at_jobs=$(safe_run 2 atq 2>/dev/null | wc -l)
        if [[ "$at_jobs" -gt 0 ]]; then
            warn "at-задачи: $at_jobs (посмотреть: atq)"
        fi
    fi

    # Systemd timers
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        print_subsection "Systemd timers"
        local timers
        timers=$(safe_run 3 systemctl list-timers --all --no-pager --no-legend 2>/dev/null | head -15 || true)
        if [[ -n "$timers" ]]; then
            while IFS= read -r line; do print_dim "$line"; done < <(echo "$timers")
        else
            print_dim "(таймеры не найдены)"
        fi
    fi

    # Anacrontab
    if [[ -r /etc/anacrontab ]]; then
        local mtime_sec age_days
        mtime_sec=$(stat -c %Y /etc/anacrontab 2>/dev/null || echo 0)
        age_days=$(( ($(date +%s) - mtime_sec) / 86400 ))
        if [[ $age_days -le 14 ]]; then
            warn "/etc/anacrontab изменён $age_days дней назад"
        fi
    fi
}

# =============================================================================
# CHECK 6: PERSISTENCE — SHELL RC, PROFILE.D, SYSTEMD UNITS, PAM
# =============================================================================
check_persistence() {
    print_section "PERSISTENCE-ВЕКТОРЫ"

    # Shell rc-файлы (свежие модификации — признак бэкдора)
    print_subsection "Shell rc-файлы с изменениями <14 дней"
    local rc_paths=(
        /etc/profile /etc/bash.bashrc /etc/zsh/zshrc
        /root/.bashrc /root/.bash_profile /root/.profile /root/.zshrc
        /root/.bash_login /root/.bash_logout
    )
    local rc_found=0
    for rc in "${rc_paths[@]}"; do
        [[ -f "$rc" ]] || continue
        local mtime_sec age_days
        mtime_sec=$(stat -c %Y "$rc" 2>/dev/null || echo 0)
        age_days=$(( ($(date +%s) - mtime_sec) / 86400 ))
        if [[ $age_days -le 14 ]]; then
            warn "$rc изменён $age_days дней назад"
            rc_found=1
        fi
    done
    # /home/*/.*rc
    local home_rcs
    home_rcs=$(find /home -maxdepth 3 -mtime -14 \
        \( -name '.bashrc' -o -name '.bash_profile' -o -name '.profile' \
           -o -name '.zshrc' -o -name '.bash_login' -o -name '.bash_logout' \
           -o -name '.bash_aliases' \) 2>/dev/null || true)
    if [[ -n "$home_rcs" ]]; then
        while IFS= read -r f; do
            warn "$f изменён $(file_mtime "$f")"
        done < <(echo "$home_rcs")
        rc_found=1
    fi
    [[ $rc_found -eq 0 ]] && ok "rc-файлы без свежих изменений"

    # /etc/profile.d/*
    local profile_d
    profile_d=$(find /etc/profile.d -maxdepth 1 -type f -mtime -14 2>/dev/null || true)
    if [[ -n "$profile_d" ]]; then
        print_subsection "/etc/profile.d/ (изменения <14 дней)"
        while IFS= read -r f; do
            warn "$f (mtime $(file_mtime "$f"))"
        done < <(echo "$profile_d")
    fi

    # rc.local
    if [[ -f /etc/rc.local ]] && [[ -s /etc/rc.local ]]; then
        if grep -qvE '^\s*(#|exit|$)' /etc/rc.local 2>/dev/null; then
            warn "/etc/rc.local содержит исполняемый код (mtime $(file_mtime /etc/rc.local))"
        fi
    fi

    # Systemd services: свежие или с подозрительным ExecStart
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        print_subsection "Systemd unit-файлы с изменениями <14 дней"
        local systemd_recent
        systemd_recent=$(find /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system /run/systemd/system \
            -maxdepth 3 -name '*.service' -o -name '*.timer' -o -name '*.socket' 2>/dev/null | \
            xargs -r stat -c '%Y %n' 2>/dev/null | \
            awk -v cutoff="$(($(date +%s) - 14*86400))" '$1 > cutoff {print $2}' || true)
        if [[ -n "$systemd_recent" ]]; then
            while IFS= read -r f; do
                warn "$f (mtime $(file_mtime "$f"))"
            done < <(echo "$systemd_recent" | head -10)
        else
            print_dim "(свежих unit-файлов не найдено)"
        fi

        # Failed units
        local failed
        failed=$(safe_run 3 systemctl --failed --no-pager --no-legend --plain 2>/dev/null | awk '{print $1}' | head -10 || true)
        if [[ -n "$failed" ]]; then
            print_subsection "Failed systemd units"
            while IFS= read -r u; do warn "$u"; done < <(echo "$failed")
        fi
    fi

    # PAM — подозрительные модули и свежие изменения
    print_subsection "PAM конфигурация"
    local pam_recent
    pam_recent=$(find /etc/pam.d -maxdepth 1 -type f -mtime -7 2>/dev/null || true)
    if [[ -n "$pam_recent" ]]; then
        local pam_count
        pam_count=$(echo "$pam_recent" | wc -l)
        if [[ $pam_count -ge 5 ]]; then
            # Массовое изменение — скорее всего обновление пакетов
            info "Изменено $pam_count файлов в /etc/pam.d за 7 дней (вероятно обновление пакетов)"
        else
            while IFS= read -r f; do
                warn "$f изменён $(file_mtime "$f")"
            done < <(echo "$pam_recent")
        fi
    fi
    # pam_exec/pam_python в sshd/login/sudo
    for pam_f in /etc/pam.d/sshd /etc/pam.d/login /etc/pam.d/sudo /etc/pam.d/common-auth; do
        [[ -r "$pam_f" ]] || continue
        local susp
        susp=$(grep -HE '(pam_exec|pam_python|pam_script)\.so' "$pam_f" 2>/dev/null || true)
        if [[ -n "$susp" ]]; then
            warn "Подозрительный PAM-модуль в $pam_f:"
            while IFS= read -r line; do print_info "${YEL}${line}${NC}"; done < <(echo "$susp")
        fi
    done
    # Недавно созданные .so в security/ (чаще всего это обновления пакетов,
    # но стоит проверить пакетную принадлежность)
    local pam_so_recent
    pam_so_recent=$(find /lib/security /lib64/security /usr/lib/security \
        /usr/lib/x86_64-linux-gnu/security /lib/x86_64-linux-gnu/security \
        -name 'pam_*.so' -mtime -14 2>/dev/null || true)
    if [[ -n "$pam_so_recent" ]]; then
        while IFS= read -r f; do
            # Если есть пакетный менеджер — проверяем принадлежность
            local owned=0
            if [[ "$PKG_MANAGER" == "dpkg" ]] && dpkg -S "$f" >/dev/null 2>&1; then
                owned=1
            elif [[ "$PKG_MANAGER" == "rpm" ]] && rpm -qf "$f" >/dev/null 2>&1; then
                owned=1
            fi
            if [[ $owned -eq 1 ]]; then
                print_dim "Свежий PAM .so (принадлежит пакету): $f"
            else
                crit "Свежий PAM .so НЕ от пакета: $f ($(file_mtime "$f"))"
            fi
        done < <(echo "$pam_so_recent")
    fi
}

# =============================================================================
# CHECK 7: KERNEL MODULES & eBPF (rootkit detection)
# =============================================================================
check_kernel() {
    print_section "ЯДРО: МОДУЛИ И eBPF"

    if [[ $IS_CONTAINER -eq 1 ]]; then
        print_dim "(внутри контейнера — ядро хоста, пропускаем)"
        return 0
    fi

    # Сверка lsmod и /proc/modules
    if have lsmod && [[ -r /proc/modules ]]; then
        local lsmod_list proc_list diff_out
        lsmod_list=$(lsmod 2>/dev/null | tail -n +2 | awk '{print $1}' | sort -u)
        proc_list=$(awk '{print $1}' /proc/modules 2>/dev/null | sort -u)
        diff_out=$(comm -3 <(echo "$lsmod_list") <(echo "$proc_list") 2>/dev/null || true)
        if [[ -n "$diff_out" ]]; then
            crit "lsmod и /proc/modules расходятся (возможен LKM rootkit):"
            while IFS= read -r m; do print_info "${RED}${m}${NC}"; done < <(echo "$diff_out")
        else
            local count
            count=$(echo "$lsmod_list" | wc -l)
            ok "Загружено $count модулей (lsmod == /proc/modules)"
        fi

        # Известные имена-кандидаты в rootkit (эвристика, не гарантия)
        local known_bad
        known_bad=$(echo "$lsmod_list" | grep -iE '^(diamorphine|reptile|suterusu|azazel|knark|adore|kbeast|modhide)' || true)
        if [[ -n "$known_bad" ]]; then
            crit "Модули с именами известных rootkit: $known_bad"
        fi
    else
        print_dim "(lsmod или /proc/modules недоступны)"
    fi

    # eBPF
    if have bpftool; then
        local bpf_prog_count
        bpf_prog_count=$(safe_run 3 bpftool prog show 2>/dev/null | grep -cE '^[0-9]+:' || echo 0)
        if [[ "$bpf_prog_count" -gt 0 ]]; then
            info "Активных eBPF-программ: $bpf_prog_count (бывают легитимные: systemd, tracing; но также основа BPFDoor/Symbiote)"
            # Показать короткий список
            safe_run 3 bpftool prog show 2>/dev/null | grep -E '^[0-9]+:' | head -8 | \
                while IFS= read -r line; do print_dim "$line"; done
        else
            ok "eBPF-программ не загружено"
        fi
    else
        print_dim "(bpftool не установлен — проверка eBPF пропущена)"
    fi

    # dmesg последние тревожные строки
    if [[ $IS_ROOT -eq 1 ]] || [[ -r /dev/kmsg ]]; then
        local dmesg_susp
        dmesg_susp=$(safe_run 2 dmesg -T 2>/dev/null | \
            grep -iE '(segfault|oops|BUG:|tainted|killed process|denied|unauthorized)' | \
            tail -5 || true)
        if [[ -n "$dmesg_susp" ]]; then
            print_subsection "dmesg — подозрительные строки"
            while IFS= read -r line; do print_dim "$line"; done < <(echo "$dmesg_susp")
        fi
    fi
}

# =============================================================================
# CHECK 8: PROCESSES vs /proc (hidden PID detection)
# =============================================================================
check_processes() {
    print_section "ПРОЦЕССЫ"

    # Сверка /proc и ps для детекции скрытых PID
    local proc_pids ps_pids hidden
    proc_pids=$(find /proc -maxdepth 1 -regex '/proc/[0-9]+' -printf '%f\n' 2>/dev/null | sort -n)
    ps_pids=$(ps -eo pid= 2>/dev/null | awk '{print $1}' | sort -n)
    if [[ -n "$proc_pids" && -n "$ps_pids" ]]; then
        hidden=$(comm -23 <(echo "$proc_pids") <(echo "$ps_pids") 2>/dev/null || true)
        if [[ -n "$hidden" ]]; then
            local hcount
            hcount=$(echo "$hidden" | wc -l)
            # Небольшое расхождение нормально (процессы стартуют/умирают во время сверки)
            if [[ "$hcount" -gt 5 ]]; then
                crit "В /proc найдено $hcount PID, отсутствующих в ps (возможен rootkit):"
                while IFS= read -r pid; do
                    local comm
                    comm=$(cat "/proc/$pid/comm" 2>/dev/null || echo "?")
                    print_info "${RED}PID $pid ($comm)${NC}"
                done < <(echo "$hidden" | head -10)
            else
                print_dim "/proc и ps синхронизированы (±$hcount — норма)"
            fi
        else
            ok "PID в /proc и ps совпадают"
        fi
    fi

    # LD_PRELOAD в окружении других процессов
    if [[ $IS_ROOT -eq 1 ]]; then
        local preload_pids=""
        for envf in /proc/[0-9]*/environ; do
            [[ -r "$envf" ]] || continue
            if tr '\0' '\n' < "$envf" 2>/dev/null | grep -qE '^LD_(PRELOAD|AUDIT)='; then
                local pid
                pid=$(basename "$(dirname "$envf")")
                [[ "$pid" == "$$" ]] && continue
                local comm
                comm=$(cat "/proc/$pid/comm" 2>/dev/null || echo "?")
                preload_pids="${preload_pids}PID $pid ($comm)\n"
            fi
        done
        if [[ -n "$preload_pids" ]]; then
            crit "Процессы с LD_PRELOAD/LD_AUDIT в окружении:"
            while IFS= read -r line; do
                [[ -n "$line" ]] && print_info "${RED}${line}${NC}"
            done < <(echo -e "$preload_pids" | head -10)
        else
            ok "LD_PRELOAD в запущенных процессах не обнаружен"
        fi
    fi

    # Процессы с удалёнными бинарями (deleted) — частый признак компрометации
    if [[ $IS_ROOT -eq 1 ]]; then
        local deleted_procs=""
        for exe in /proc/[0-9]*/exe; do
            [[ -L "$exe" ]] || continue
            local target
            target=$(readlink "$exe" 2>/dev/null || true)
            if [[ "$target" == *"(deleted)"* ]]; then
                local pid comm
                pid=$(basename "$(dirname "$exe")")
                comm=$(cat "/proc/$pid/comm" 2>/dev/null || echo "?")
                deleted_procs="${deleted_procs}PID $pid ($comm): $target\n"
            fi
        done
        if [[ -n "$deleted_procs" ]]; then
            warn "Процессы, запущенные с удалённых бинарей (может быть легитимно после обновления пакетов):"
            while IFS= read -r line; do
                [[ -n "$line" ]] && print_info "$line"
            done < <(echo -e "$deleted_procs" | head -10)
        fi
    fi

    # Топ процессов по CPU и памяти
    print_subsection "Топ-5 процессов по памяти"
    safe_run 3 ps -eo user,pid,pcpu,pmem,comm --sort=-pmem 2>/dev/null | \
        awk 'NR>1 && NR<=6 {printf "    %-12s %-8s %-6s %-6s %s\n", $1, $2, $3, $4, $5}' || true

    print_subsection "Топ-5 процессов по CPU"
    safe_run 3 ps -eo user,pid,pcpu,pmem,comm --sort=-pcpu 2>/dev/null | \
        awk 'NR>1 && NR<=6 {printf "    %-12s %-8s %-6s %-6s %s\n", $1, $2, $3, $4, $5}' || true
}

# =============================================================================
# CHECK 9: NETWORK (listen + established, без "магических" портов)
# =============================================================================
check_network() {
    print_section "СЕТЕВЫЕ СОЕДИНЕНИЯ"

    if ! have ss; then
        print_dim "(ss не установлен — пропуск)"
        return 0
    fi

    # LISTEN — показываем всё с процессами, без маркировки "подозрительных портов"
    print_subsection "Слушающие порты (LISTEN)"
    local listen_out
    if [[ $IS_ROOT -eq 1 ]]; then
        listen_out=$(safe_run 3 ss -tulnpH 2>/dev/null || true)
    else
        listen_out=$(safe_run 3 ss -tulnH 2>/dev/null || true)
        print_dim "(без root — имена процессов недоступны)"
    fi
    if [[ -n "$listen_out" ]]; then
        echo "$listen_out" | awk '{printf "    %-5s %-30s %-30s %s\n", $1, $5, $6, $7}' | head -20
        local listen_count
        listen_count=$(echo "$listen_out" | wc -l)
        [[ "$listen_count" -gt 20 ]] && print_dim "... и ещё $((listen_count - 20)) строк"
    fi

    # Сверка ss и /proc/net/tcp (детекция скрытых портов rootkit'ами)
    if [[ -r /proc/net/tcp ]]; then
        local ss_ports proc_ports hidden_ports
        ss_ports=$(safe_run 2 ss -tlnH 2>/dev/null | awk '{print $4}' | awk -F: '{print $NF}' | sort -u -n)
        proc_ports=$(awk 'NR>1 && $4=="0A" {print $2}' /proc/net/tcp 2>/dev/null | cut -d: -f2 | \
                     while read h; do printf "%d\n" "0x$h" 2>/dev/null; done | sort -u -n)
        hidden_ports=$(comm -13 <(echo "$ss_ports") <(echo "$proc_ports") 2>/dev/null | head -5 || true)
        if [[ -n "$hidden_ports" ]]; then
            crit "Порты в /proc/net/tcp, не видимые через ss:"
            while IFS= read -r p; do print_info "${RED}port $p${NC}"; done < <(echo "$hidden_ports")
        fi
    fi

    # ESTABLISHED — реверс-шеллы и C2
    print_subsection "Установленные соединения (ESTABLISHED) — топ-15"
    local est_out
    if [[ $IS_ROOT -eq 1 ]]; then
        est_out=$(safe_run 3 ss -tanpH state established 2>/dev/null | head -15 || true)
    else
        est_out=$(safe_run 3 ss -tanH state established 2>/dev/null | head -15 || true)
    fi
    if [[ -n "$est_out" ]]; then
        echo "$est_out" | awk '{printf "    %-25s %-25s %s\n", $3, $4, $5}' | head -15
    else
        print_dim "(нет установленных соединений)"
    fi

    # UNIX sockets в необычных местах (tmp/shm)
    local susp_unix
    susp_unix=$(safe_run 2 ss -xlnH 2>/dev/null | awk '{print $5}' | \
                grep -E '^(/tmp|/dev/shm|/var/tmp)' | head -5 || true)
    if [[ -n "$susp_unix" ]]; then
        warn "UNIX-сокеты в tmp/shm (нетипично):"
        while IFS= read -r s; do print_info "${YEL}${s}${NC}"; done < <(echo "$susp_unix")
    fi

    # Firewall status (коротко)
    print_subsection "Firewall"
    if have nft; then
        local nft_rules
        nft_rules=$(safe_run 2 nft list ruleset 2>/dev/null | grep -cE '^\s+(iif|oif|ip |tcp |udp )' || echo 0)
        print_info "nftables: $nft_rules правил"
    elif have iptables; then
        local ipt_rules
        ipt_rules=$(safe_run 2 iptables -S 2>/dev/null | wc -l)
        print_info "iptables: $ipt_rules правил"
    else
        print_dim "(ни nft, ни iptables не установлены)"
    fi
}

# =============================================================================
# CHECK 10: RECENT FILESYSTEM CHANGES
# =============================================================================
check_recent_changes() {
    print_section "НЕДАВНИЕ ИЗМЕНЕНИЯ ФС"

    # /etc за последние 2 дня
    print_subsection "/etc (mtime <2 дней)"
    local etc_changes
    etc_changes=$(safe_run 5 find /etc -xdev -type f -mtime -2 \
        ! -path '/etc/mtab' ! -path '/etc/resolv.conf' 2>/dev/null | head -20 || true)
    if [[ -n "$etc_changes" ]]; then
        while IFS= read -r f; do
            warn "$(file_mtime "$f") — $f"
        done < <(echo "$etc_changes")
    else
        ok "В /etc нет изменений за последние 2 дня"
    fi

    # Внимание на mtime vs ctime несоответствие (признак touch -r)
    # Для краткости показываем только /etc
    if [[ $IS_ROOT -eq 1 ]]; then
        local ctime_mismatch=""
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            local m c
            m=$(stat -c %Y "$f" 2>/dev/null)
            c=$(stat -c %Z "$f" 2>/dev/null)
            if [[ -n "$m" && -n "$c" ]] && (( c - m > 86400 )); then
                ctime_mismatch="${ctime_mismatch}${f} (mtime назад на $((  (c-m) / 86400 )) дней от ctime)\n"
            fi
        done < <(safe_run 3 find /etc -xdev -type f -ctime -7 2>/dev/null | head -50)
        if [[ -n "$ctime_mismatch" ]]; then
            print_subsection "Файлы с ctime > mtime (возможна подделка mtime через touch -r)"
            while IFS= read -r line; do
                [[ -n "$line" ]] && warn "$line"
            done < <(echo -e "$ctime_mismatch" | head -5)
        fi
    fi

    # /tmp, /var/tmp, /dev/shm — исполняемые файлы
    print_subsection "Исполняемые файлы в /tmp, /var/tmp, /dev/shm"
    local susp_exec
    susp_exec=$(safe_run 3 find /tmp /var/tmp /dev/shm -xdev -type f -executable 2>/dev/null | head -10 || true)
    if [[ -n "$susp_exec" ]]; then
        while IFS= read -r f; do
            warn "$f ($(file_mtime "$f"))"
        done < <(echo "$susp_exec")
    else
        ok "В /tmp, /var/tmp, /dev/shm исполняемых файлов нет"
    fi

    # Скрытые файлы и директории в /tmp и /dev/shm (частый приём)
    local hidden_tmp
    hidden_tmp=$(safe_run 3 find /tmp /dev/shm -xdev -maxdepth 2 -name '.*' \
                 ! -name '.' ! -name '..' ! -name '.ICE-unix' ! -name '.X11-unix' \
                 ! -name '.font-unix' ! -name '.Test-unix' ! -name '.XIM-unix' 2>/dev/null | head -10 || true)
    if [[ -n "$hidden_tmp" ]]; then
        warn "Скрытые файлы в /tmp или /dev/shm:"
        while IFS= read -r f; do print_info "${YEL}${f}${NC}"; done < <(echo "$hidden_tmp")
    fi

    # /root mtime за 14 дней
    if [[ $IS_ROOT -eq 1 ]] && [[ -d /root ]]; then
        local root_changes
        root_changes=$(safe_run 3 find /root -maxdepth 2 -type f -mtime -14 \
            ! -name '.bash_history' ! -name '.viminfo' ! -name '.lesshst' \
            ! -name '.wget-hstsmt' ! -name '.sudo_as_admin_successful' 2>/dev/null | head -10 || true)
        if [[ -n "$root_changes" ]]; then
            print_subsection "/root (mtime <14 дней)"
            while IFS= read -r f; do
                info "$(file_mtime "$f") — $f"
            done < <(echo "$root_changes")
        fi
    fi
}

# =============================================================================
# CHECK 11: SUID/SGID & CAPABILITIES (полный режим)
# =============================================================================
check_suid_caps() {
    print_section "SUID/SGID И CAPABILITIES"

    if [[ "$MODE" != "full" ]]; then
        print_dim "(пропущено в quick-режиме; запустите с --full)"
        return 0
    fi

    # SUID/SGID
    print_subsection "SUID/SGID бинарники (может занять 10-30 сек)"
    local suid_list
    suid_list=$(safe_run 30 find / -xdev -type f \( -perm -4000 -o -perm -2000 \) \
        ! -path '/proc/*' ! -path '/sys/*' 2>/dev/null || true)
    if [[ -n "$suid_list" ]]; then
        local total
        total=$(echo "$suid_list" | wc -l)
        print_info "Всего найдено: $total"

        # Пытаемся фильтровать те, что не принадлежат пакетам
        if [[ "$PKG_MANAGER" == "dpkg" ]]; then
            local unowned=""
            while IFS= read -r f; do
                if ! dpkg -S "$f" >/dev/null 2>&1; then
                    unowned="${unowned}${f}\n"
                fi
            done <<< "$suid_list"
            if [[ -n "$unowned" ]]; then
                crit "SUID/SGID бинарники, НЕ принадлежащие ни одному dpkg-пакету:"
                while IFS= read -r f; do
                    [[ -n "$f" ]] && print_info "${RED}${f}${NC} ($(file_mtime "$f"))"
                done < <(echo -e "$unowned" | head -10)
            else
                ok "Все SUID/SGID бинарники принадлежат пакетам"
            fi
        elif [[ "$PKG_MANAGER" == "rpm" ]]; then
            local unowned=""
            while IFS= read -r f; do
                if ! rpm -qf "$f" >/dev/null 2>&1; then
                    unowned="${unowned}${f}\n"
                fi
            done <<< "$suid_list"
            if [[ -n "$unowned" ]]; then
                crit "SUID/SGID бинарники, НЕ принадлежащие ни одному rpm-пакету:"
                while IFS= read -r f; do
                    [[ -n "$f" ]] && print_info "${RED}${f}${NC} ($(file_mtime "$f"))"
                done < <(echo -e "$unowned" | head -10)
            fi
        else
            # Показываем только первые 20
            while IFS= read -r f; do print_dim "$f"; done < <(echo "$suid_list" | head -20)
        fi
    fi

    # Capabilities
    if have getcap; then
        print_subsection "Файлы с capabilities"
        local caps
        caps=$(safe_run 15 getcap -r / 2>/dev/null | head -15 || true)
        if [[ -n "$caps" ]]; then
            while IFS= read -r line; do
                case "$line" in
                    *cap_sys_admin*|*cap_sys_ptrace*|*cap_dac_override*|*cap_setuid*|*cap_sys_module*)
                        warn "$line" ;;
                    *) print_dim "$line" ;;
                esac
            done < <(echo "$caps")
        else
            print_dim "(файлов с capabilities не найдено)"
        fi
    fi
}

# =============================================================================
# CHECK 12: PACKAGE INTEGRITY (полный режим)
# =============================================================================
check_package_integrity() {
    print_section "ЦЕЛОСТНОСТЬ ПАКЕТОВ"

    if [[ "$MODE" != "full" ]]; then
        print_dim "(пропущено в quick-режиме; запустите с --full)"
        return 0
    fi

    case "$PKG_MANAGER" in
        dpkg)
            if have debsums; then
                print_subsection "debsums -s (только failed)"
                local failed
                failed=$(safe_run 60 debsums -s 2>&1 | head -20 || true)
                if [[ -n "$failed" ]]; then
                    crit "debsums нашёл несоответствия:"
                    while IFS= read -r line; do print_info "${RED}${line}${NC}"; done < <(echo "$failed")
                else
                    ok "debsums: все пакеты целы (но базу могли модифицировать)"
                fi
            else
                print_dim "(debsums не установлен: apt install debsums)"
            fi
            ;;
        rpm)
            print_subsection "rpm -Va (только modified)"
            local rpm_mods
            rpm_mods=$(safe_run 60 rpm -Va --nomtime --nosize 2>/dev/null | \
                       grep -E '^\S*5' | head -20 || true)
            if [[ -n "$rpm_mods" ]]; then
                crit "rpm нашёл изменённые файлы (S = size, 5 = md5, M = mode):"
                while IFS= read -r line; do print_info "${RED}${line}${NC}"; done < <(echo "$rpm_mods")
            else
                ok "rpm -Va: все пакеты целы"
            fi
            ;;
        apk)
            print_subsection "apk audit (Alpine)"
            local apk_audit
            apk_audit=$(safe_run 30 apk audit 2>/dev/null | head -20 || true)
            if [[ -n "$apk_audit" ]]; then
                warn "apk audit нашёл изменённые файлы:"
                while IFS= read -r line; do print_info "$line"; done < <(echo "$apk_audit")
            else
                ok "apk audit: все пакеты целы"
            fi
            ;;
        pacman)
            print_subsection "pacman -Qkk (Arch)"
            local pac
            pac=$(safe_run 60 pacman -Qkk 2>/dev/null | grep -vE '(0 altered|warning:)' | head -20 || true)
            if [[ -n "$pac" ]]; then
                warn "pacman нашёл несоответствия:"
                while IFS= read -r line; do print_info "$line"; done < <(echo "$pac")
            fi
            ;;
        *)
            print_dim "(пакетный менеджер не распознан)"
            ;;
    esac
}

# =============================================================================
# CHECK 13: SYSTEM HEALTH (uptime, disk, logs)
# =============================================================================
check_system_health() {
    print_section "СОСТОЯНИЕ СИСТЕМЫ"

    # Uptime и load
    print_subsection "Uptime и нагрузка"
    print_info "$(uptime 2>/dev/null || cat /proc/uptime)"

    # Disk usage
    print_subsection "Использование дисков"
    local df_out
    df_out=$(df -hT -x tmpfs -x devtmpfs -x squashfs -x overlay -x 9p \
        -x fuse.lxcfs -x fuse.snapfuse -x nsfs 2>/dev/null | tail -n +2 || true)
    if [[ -n "$df_out" ]]; then
        while IFS= read -r line; do
            local usage
            usage=$(echo "$line" | awk '{print $6}' | tr -d '%')
            if [[ "$usage" =~ ^[0-9]+$ ]]; then
                if [[ "$usage" -ge 90 ]]; then
                    crit "$line"
                elif [[ "$usage" -ge 80 ]]; then
                    warn "$line"
                else
                    print_info "$line"
                fi
            fi
        done < <(echo "$df_out")
    fi

    # Inode usage (часто забывают)
    local inode_crit
    inode_crit=$(df -i -x tmpfs -x devtmpfs 2>/dev/null | awk 'NR>1 && $5+0 >= 90 {print}' || true)
    if [[ -n "$inode_crit" ]]; then
        print_subsection "Критическое использование inode"
        while IFS= read -r line; do warn "$line"; done < <(echo "$inode_crit")
    fi

    # Logs с ошибками
    if [[ "$INIT_SYSTEM" == "systemd" ]] && have journalctl; then
        print_subsection "journalctl — ошибки за сутки (последние 5)"
        local jerr
        jerr=$(safe_run 5 journalctl --since "1 day ago" --priority=err --no-pager -q 2>/dev/null | tail -5 || true)
        if [[ -n "$jerr" ]]; then
            while IFS= read -r line; do print_dim "$line"; done < <(echo "$jerr")
        else
            ok "(ошибок не найдено)"
        fi

        # Неудачные SSH-входы
        print_subsection "Неудачные SSH-входы за сутки (последние 5)"
        local ssh_fails
        ssh_fails=$(safe_run 5 journalctl --since "1 day ago" -u ssh -u sshd --no-pager -q 2>/dev/null | \
                    grep -iE '(failed|invalid user)' | tail -5 || true)
        if [[ -n "$ssh_fails" ]]; then
            local fc
            fc=$(safe_run 5 journalctl --since "1 day ago" -u ssh -u sshd --no-pager -q 2>/dev/null | \
                 grep -icE '(failed|invalid user)' || echo 0)
            if [[ "$fc" -gt 100 ]]; then
                warn "$fc неудачных SSH-попыток за сутки — brute-force"
            else
                info "$fc неудачных SSH-попыток за сутки"
            fi
            while IFS= read -r line; do print_dim "$line"; done < <(echo "$ssh_fails")
        else
            ok "(неудачных SSH-входов не найдено)"
        fi
    else
        # Для systems без journald
        for log in /var/log/auth.log /var/log/secure; do
            if [[ -r "$log" ]]; then
                local count
                count=$(grep -icE '(failed|invalid user)' "$log" 2>/dev/null || echo 0)
                [[ "$count" -gt 0 ]] && info "$log: $count неудачных попыток"
                break
            fi
        done
    fi

    # История перезагрузок
    if [[ $IS_CONTAINER -eq 0 ]]; then
        print_subsection "История перезагрузок (последние 3)"
        safe_run 3 last -x reboot -n 3 2>/dev/null | sed '/^$/d;/^wtmp begins/d' | \
            while IFS= read -r line; do print_dim "$line"; done || true
    fi
}

# =============================================================================
# SUMMARY & EXIT
# =============================================================================
print_summary() {
    local elapsed=$(($(date +%s) - START_TIME))
    print_section "ИТОГОВАЯ СВОДКА"
    printf '    %sВремя выполнения:%s %d сек\n' "${BLD}" "${NC}" "$elapsed"
    printf '    %sCRIT:%s %d  %sWARN:%s %d  %sINFO:%s %d\n' \
        "${RED}" "${NC}" "$CRIT_COUNT" \
        "${YEL}" "${NC}" "$WARN_COUNT" \
        "${BLU}" "${NC}" "$INFO_COUNT"

    if [[ $CRIT_COUNT -gt 0 ]]; then
        printf '\n    %s%s✗ КРИТИЧЕСКИЕ ПРОБЛЕМЫ — возможна компрометация%s\n' "${BLD}" "${RED}" "${NC}"
        printf '    %sТребуется немедленное расследование с доверенной системы%s\n' "${RED}" "${NC}"
        echo
        printf '    %sКлючевые находки:%s\n' "${BLD}" "${NC}"
        for f in "${CRIT_FINDINGS[@]}"; do
            printf '      %s• %s%s\n' "${RED}" "$f" "${NC}"
        done
    elif [[ $WARN_COUNT -gt 0 ]]; then
        printf '\n    %s%s⚠ ПРЕДУПРЕЖДЕНИЯ — требуется внимание%s\n' "${BLD}" "${YEL}" "${NC}"
        if [[ $WARN_COUNT -le 10 ]]; then
            echo
            printf '    %sНайдено:%s\n' "${BLD}" "${NC}"
            for f in "${WARN_FINDINGS[@]}"; do
                printf '      %s• %s%s\n' "${YEL}" "$f" "${NC}"
            done
        fi
    else
        printf '\n    %s%s✓ Базовые проверки пройдены%s\n' "${BLD}" "${GRN}" "${NC}"
    fi

    # Честный disclaimer
    echo
    printf '    %sNB:%s это pre-flight проверка, не замена HIDS/AIDE/Wazuh.\n' "${DIM}" "${NC}"
    printf '    %sСкомпрометированная система может скрывать следы от любого%s\n' "${DIM}" "${NC}"
    printf '    %sинструмента, работающего внутри неё. При серьёзных подозрениях%s\n' "${DIM}" "${NC}"
    printf '    %s— изолируйте хост и анализируйте с доверенной системы.%s\n' "${DIM}" "${NC}"

    if [[ -n "$OUTPUT_FILE" ]]; then
        printf '\n    %sПолный отчёт сохранён: %s%s\n' "${BLD}" "$OUTPUT_FILE" "${NC}"
    fi
}

main() {
    print_header
    check_env_sanity
    check_sessions
    check_users_privs
    check_ssh
    check_scheduled
    check_persistence
    check_kernel
    check_processes
    check_network
    check_recent_changes
    check_suid_caps
    check_package_integrity
    check_system_health
    print_summary

    # Exit code
    if [[ $CRIT_COUNT -gt 0 ]]; then
        exit 2
    elif [[ $WARN_COUNT -gt 0 ]]; then
        exit 1
    else
        exit 0
    fi
}

# Обработчик прерывания
trap 'printf "\n%sПрервано пользователем%s\n" "${YEL}" "${NC}"; exit 3' INT TERM

main "$@"