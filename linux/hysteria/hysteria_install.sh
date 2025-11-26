#!/bin/bash

# Hysteria2 Auto Installer with Self-Signed Certificate
# Author: spoveddd

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16
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

create_config() {
    local password="$1"
    
    print_status "Создание конфигурации..."
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

show_connection_info() {
    local password="$1"
    local server_ip
    server_ip=$(curl -4 -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    
    echo ""
    echo "=========================================="
    echo -e "${GREEN}Hysteria2 успешно установлена!${NC}"
    echo "=========================================="
    echo ""
    echo "Ключ для подключения:"
    echo -e "${YELLOW}hy2://${password}@${server_ip}:443/?insecure=1${NC}"
    echo ""
    echo "Клиенты: Streisand, v2box, sing-box, nekobox, hiddify, furious"
    echo "Важно: в клиенте выставить insecure=true"
    echo ""
}

main() {
    echo "╔═══════════════════════════════════════╗"
    echo "║   Hysteria2 Auto Installer            ║"
    echo "╚═══════════════════════════════════════╝"
    echo ""
    
    check_root
    
    # Запрос пароля или генерация
    read -p "Введите пароль (Enter для автогенерации): " user_password
    if [[ -z "$user_password" ]]; then
        user_password=$(generate_password)
        print_status "Сгенерирован пароль: $user_password"
    fi
    
    install_hysteria
    generate_certificate
    create_config "$user_password"
    start_service
    
    if verify_installation; then
        show_connection_info "$user_password"
    else
        print_error "Установка завершена с ошибками"
        exit 1
    fi
}

main "$@"

