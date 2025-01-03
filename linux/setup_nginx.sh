#!/bin/bash

# Скрипт для установки и базовой настройки Nginx

setup_nginx() {
    echo "Устанавливаем Nginx..."
    sudo apt update && sudo apt install -y nginx
    
    echo "Создаем базовую конфигурацию..."
    sudo bash -c 'cat > /etc/nginx/sites-available/default' << EOF
server {
    listen 80;
    server_name _;
    root /var/www/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

    echo "Перезапускаем сервис Nginx..."
    sudo systemctl restart nginx
    echo "Nginx успешно установлен и настроен."
    sudo systemctl status nginx

}

# Если скрипт запускается напрямую, выполнить настройку Nginx
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    setup_nginx
    exit 0
fi