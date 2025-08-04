# 📁 Directory Monitor with Telegram Notifications

Скрипт для мониторинга изменений в директории с отправкой уведомлений в Telegram.

## 🚀 Возможности

- 🔍 Мониторинг файловых операций (создание, удаление, изменение, перемещение)
- 📱 Уведомления в Telegram с подробной информацией
- 📊 Логирование всех событий
- 🖥️ Информация о сервере в уведомлениях
- ⏰ Временные метки для всех событий

## 📋 Требования

### Системные требования
- Linux система с поддержкой `inotify`
- Bash shell
- `curl` для отправки HTTP запросов
- `inotify-tools` пакет

### Установка зависимостей

**Ubuntu/Debian:**
```bash
sudo apt-get update
sudo apt-get install inotify-tools curl
```

**CentOS/RHEL:**
```bash
sudo yum install inotify-tools curl
```

**Arch Linux:**
```bash
sudo pacman -S inotify-tools curl
```

## ⚙️ Настройка

### 1. Создание Telegram бота

1. Найдите [@BotFather](https://t.me/BotFather) в Telegram
2. Отправьте команду `/newbot`
3. Следуйте инструкциям для создания бота
4. Сохраните полученный токен

### 2. Получение Chat ID

1. Напишите что-нибудь вашему боту
2. Выполните запрос:
   ```
   https://api.telegram.org/bot<ВАШ_ТОКЕН>/getUpdates
   ```
3. Найдите `chat_id` в ответе

### 3. Настройка скрипта

Отредактируйте файл `monitor.sh`:

```bash
# Замените на ваши данные
BOT_TOKEN="ВАШ_ТОКЕН"
CHAT_ID="ВАШ ЧАТ ID"

# Укажите директорию для мониторинга
WATCH_DIR="/var/www/mint_change__usr/data/www/mint-change.ru/"
```

## 🚀 Запуск

### Обычный запуск
```bash
chmod +x monitor.sh
./monitor.sh
```

### Запуск в фоне
```bash
nohup ./monitor.sh > monitor.log 2>&1 &
```

### Запуск как системный сервис

Создайте файл `/etc/systemd/system/directory-monitor.service`:

```ini
[Unit]
Description=Directory Monitor with Telegram Notifications
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=/path/to/script/directory
ExecStart=/path/to/script/directory/monitor.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Затем:
```bash
sudo systemctl daemon-reload
sudo systemctl enable directory-monitor
sudo systemctl start directory-monitor
```

## 📱 Формат уведомлений

Скрипт отправляет уведомления в следующем формате:

### Запуск мониторинга
```
🚀 Мониторинг запущен
📂 Директория: /var/www/example/
🖥️ Сервер: server-name
⏰ Время: 2024-01-15 10:30:00
```

### События файлов
```
📝 Файл создан
📁 Путь: /new-file.txt
⏰ Время: 2024-01-15 10:35:00
🖥️ Сервер: server-name
```

### Иконки событий
- 📝 - Создание файла
- 🗑️ - Удаление файла
- ✏️ - Изменение файла
- 📤 - Перемещение файла (из)
- 📥 - Перемещение файла (в)

## 📊 Логирование

Скрипт ведет логи в консоль с временными метками:
```
2024-01-15 10:30:00 - Starting directory monitoring for: /var/www/example/
2024-01-15 10:35:00 - создан: /new-file.txt
2024-01-15 10:40:00 - изменен: /existing-file.txt
```

## 🔧 Настройка мониторинга

### Изменение типов событий

В строке 47 можно изменить типы отслеживаемых событий:

```bash
# Текущие события: create,delete,modify,move
inotifywait -m -e create,delete,modify,move "$WATCH_DIR"

# Добавить отслеживание атрибутов
inotifywait -m -e create,delete,modify,move,attrib "$WATCH_DIR"

# Только создание и удаление
inotifywait -m -e create,delete "$WATCH_DIR"
```

### Рекурсивный мониторинг

Для мониторинга поддиректорий раскомментируйте строку 46:
```bash
inotifywait -m -r -e create,delete,modify,move "$WATCH_DIR"
```

## 🛠️ Устранение неполадок

### Ошибка "inotifywait is not installed"
```bash
# Ubuntu/Debian
sudo apt-get install inotify-tools

# CentOS/RHEL
sudo yum install inotify-tools
```

### Ошибка "Directory does not exist"
Проверьте путь в переменной `WATCH_DIR` и убедитесь, что директория существует.

### Уведомления не приходят
1. Проверьте правильность `BOT_TOKEN` и `CHAT_ID`
2. Убедитесь, что бот добавлен в чат
3. Проверьте интернет-соединение
4. Посмотрите логи на наличие ошибок curl

### Высокая нагрузка на систему
Для больших директорий используйте фильтры:
```bash
inotifywait -m -e create,delete,modify,move "$WATCH_DIR" --exclude '\.(log|tmp)$'
```

## 📝 Примеры использования

### Мониторинг веб-сайта
```bash
WATCH_DIR="/var/www/mysite.com/"
```

### Мониторинг логов
```bash
WATCH_DIR="/var/log/"
```

### Мониторинг с фильтрацией
```bash
# Добавить в скрипт для исключения временных файлов
inotifywait -m -e create,delete,modify,move "$WATCH_DIR" \
    --exclude '\.(tmp|swp|bak)$' \
    --exclude '/\.git/' \
    --exclude '/node_modules/'
```

## 🔒 Безопасность

- Храните токен бота в безопасном месте
- Используйте отдельного бота для каждого сервера
- Ограничьте права доступа к скрипту
- Регулярно обновляйте токен бота

## 📄 Лицензия

Этот скрипт предоставляется "как есть" без каких-либо гарантий.

## 🤝 Поддержка

При возникновении проблем:
1. Проверьте логи скрипта
2. Убедитесь в правильности настроек
3. Проверьте системные требования
4. Создайте issue с подробным описанием проблемы 