# Hysteria2 Auto Installer

Автоматическая установка Hysteria2 с самоподписанным сертификатом.

## Быстрый запуск

```bash
bash <(curl -s https://raw.githubusercontent.com/spoveddd/scripts/main/linux/hysteria/hysteria_install.sh)
```

## Что делает скрипт

- Устанавливает Hysteria2 от имени root
- Генерирует самоподписанный сертификат на 10 лет
- Создаёт конфигурацию `/etc/hysteria/config.yaml`
- Запускает сервис и добавляет в автозагрузку
- Проверяет корректность установки
- Выводит готовый ключ для подключения

## Формат ключа

```
hy2://PASSWORD@SERVER_IP:443/?insecure=1
```

## Поддерживаемые клиенты

- Streisand
- v2box
- sing-box
- nekobox
- hiddify
- furious

## Важно

В клиенте обязательно выставить `insecure=true` для самоподписанного сертификата.

## Полезные команды

```bash
# Статус сервиса
systemctl status hysteria-server

# Проверка порта
ss -tulpn | grep 443

# Логи
journalctl -u hysteria-server -f
```

## Ссылки

- [Traffic Stats API](https://v2.hysteria.network/docs/advanced/Traffic-Stats-API/)
- [Full Client Config](https://v2.hysteria.network/docs/advanced/Full-Client-Config/)
- [Port Hopping](https://v2.hysteria.network/docs/advanced/Port-Hopping/)

