#!/bin/bash

# Hysteria2 Auto Installer with Self-Signed Certificate
# Author: spoveddd

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

CONFIG_PATH="/etc/hysteria/config.yaml"
CERT_PATH="/etc/hysteria/cert.pem"
KEY_PATH="/etc/hysteria/key.pem"

print_status() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Скрипт должен быть запущен от root"
        exit 1
    fi
}

generate_password() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 10
}

install_hysteria() {
    print_status "Установка Hysteria2..."
    HYSTERIA_USER=root bash <(curl -fsSL https://get.hy2.sh/)
    print_status "Hysteria2 установлена"
}

generate_certificate() {
    print_status "Генерация самоподписанного сертификата (10 лет)..."
    mkdir -p /etc/hysteria
    cd /etc/hysteria
    openssl req -x509 -newkey rsa:4096 -nodes \
        -keyout key.pem -out cert.pem \
        -days 3650 -subj "/CN=localhost" 2>/dev/null
    print_status "Сертификат создан"
}

# Создание конфига для одного пользователя (password auth)
create_config_single() {
    local password="$1"
    
    print_status "Создание конфигурации (1 пользователь)..."
    cat > "$CONFIG_PATH" << EOF
listen: 0.0.0.0:443

tls:
  cert: $CERT_PATH
  key: $KEY_PATH

auth:
  type: password
  password: "$password"

quic:
  congestionControl: brutal
  fallback:
    type: proxy
    proxy:
      url: https://pinterest.com/
      rewriteHost: true
      insecure: true

bandwidth:
  up: 100mbps
  down: 100mbps

resolver:
  type: udp
  udp:
    addr: 1.1.1.1:53
    timeout: 4s

masquerade:
  type: proxy
  proxy:
    url: https://pinterest.com/
    rewriteHost: true
EOF
    print_status "Конфигурация создана: $CONFIG_PATH"
}

# Создание конфига для нескольких пользователей (userpass auth)
create_config_multi() {
    local -n users_ref=$1
    
    print_status "Создание конфигурации (${#users_ref[@]} пользователей)..."
    
    # Формируем блок userpass
    local userpass_block=""
    for username in "${!users_ref[@]}"; do
        userpass_block+="    $username: ${users_ref[$username]}"$'\n'
    done
    
    cat > "$CONFIG_PATH" << EOF
listen: 0.0.0.0:443

tls:
  cert: $CERT_PATH
  key: $KEY_PATH

auth:
  type: userpass
  userpass:
${userpass_block}
quic:
  congestionControl: brutal
  fallback:
    type: proxy
    proxy:
      url: https://pinterest.com/
      rewriteHost: true
      insecure: true

bandwidth:
  up: 100mbps
  down: 100mbps

resolver:
  type: udp
  udp:
    addr: 1.1.1.1:53
    timeout: 4s

masquerade:
  type: proxy
  proxy:
    url: https://pinterest.com/
    rewriteHost: true
EOF
    print_status "Конфигурация создана: $CONFIG_PATH"
}

start_service() {
    print_status "Запуск и добавление в автозагрузку..."
    systemctl enable --now hysteria-server.service
    print_status "Сервис запущен"
}

verify_installation() {
    print_status "Проверка установки..."
    
    if ! command -v hysteria &>/dev/null; then
        print_error "Hysteria не установлена"
        return 1
    fi
    
    if [[ ! -f "$CERT_PATH" ]] || [[ ! -f "$KEY_PATH" ]]; then
        print_error "Сертификаты не найдены"
        return 1
    fi
    
    if [[ ! -f "$CONFIG_PATH" ]]; then
        print_error "Конфигурация не найдена"
        return 1
    fi
    
    if ! systemctl is-active --quiet hysteria-server.service; then
        print_error "Сервис не запущен"
        return 1
    fi
    
    if ss -tulpn | grep -q ':443'; then
        print_status "Порт 443 UDP слушает"
    else
        print_warning "Порт 443 не обнаружен (возможно требуется время)"
    fi
    
    print_status "Все проверки пройдены!"
    return 0
}

show_connection_info_single() {
    local password="$1"
    local server_ip
    server_ip=$(curl -4 -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    
    echo ""
    echo "=========================================="
    echo -e "${GREEN}Установка завершена!${NC}"
    echo "=========================================="
    echo ""
    echo "Hysteria2 установлена на ваш сервер и настроена."
    echo ""
    echo -e "${CYAN}Ключ для подключения:${NC}"
    echo -e "${YELLOW}hy2://${password}@${server_ip}:443/?insecure=1${NC}"
    echo ""
    show_clients_info
}

show_connection_info_multi() {
    local -n users_ref=$1
    local server_ip
    server_ip=$(curl -4 -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    
    echo ""
    echo "=========================================="
    echo -e "${GREEN}Установка завершена!${NC}"
    echo "=========================================="
    echo ""
    echo "Hysteria2 установлена на ваш сервер и настроена."
    echo ""
    echo -e "${CYAN}Ключи для подключения:${NC}"
    echo ""
    for username in "${!users_ref[@]}"; do
        echo -e "${YELLOW}hy2://${username}:${users_ref[$username]}@${server_ip}:443/?insecure=1${NC}"
    done
    echo ""
    show_clients_info
}

show_clients_info() {
    echo -e "${CYAN}Для подключения можно использовать следующее ПО:${NC}"
    echo "  • Streisand (iOS)"
    echo "  • v2box (iOS/Android)"
    echo "  • sing-box (Windows/macOS/Linux/Android)"
    echo "  • nekobox (Android)"
    echo "  • hiddify (Windows/macOS/Linux/iOS/Android)"
    echo "  • furious (Windows/macOS/Linux)"
    echo ""
    echo -e "${YELLOW}Важно:${NC} В клиенте, если имеется настройка TLS/SSL,"
    echo "       выставить insecure = true (или skip cert verify)"
    echo ""
}

main() {
    echo "╔═══════════════════════════════════════╗"
    echo "║   Hysteria2 Auto Installer            ║"
    echo "╚═══════════════════════════════════════╝"
    echo ""
    
    check_root
    
    # Спрашиваем количество пользователей
    echo -e "Сколько ключей создать?"
    echo -e "  ${CYAN}1${NC} - Один ключ (по умолчанию)"
    echo -e "  ${CYAN}N${NC} - Несколько ключей (введите число)"
    echo ""
    read -p "Количество [1]: " user_count
    user_count=${user_count:-1}
    
    # Валидация ввода
    if ! [[ "$user_count" =~ ^[0-9]+$ ]] || [[ "$user_count" -lt 1 ]]; then
        print_error "Некорректное число"
        exit 1
    fi
    
    install_hysteria
    generate_certificate
    
    if [[ "$user_count" -eq 1 ]]; then
        # Один пользователь - простой password auth
        user_password=$(generate_password)
        print_status "Сгенерирован пароль: $user_password"
        create_config_single "$user_password"
        start_service
        
        if verify_installation; then
            show_connection_info_single "$user_password"
        else
            print_error "Установка завершена с ошибками"
            exit 1
        fi
    else
        # Несколько пользователей - userpass auth
        declare -A users
        echo ""
        print_status "Генерация $user_count ключей..."
        for i in $(seq 1 $user_count); do
            username="user$i"
            password=$(generate_password)
            users[$username]=$password
            echo "  $username: $password"
        done
        echo ""
        
        create_config_multi users
        start_service
        
        if verify_installation; then
            show_connection_info_multi users
        else
            print_error "Установка завершена с ошибками"
            exit 1
        fi
    fi
}

main "$@"
