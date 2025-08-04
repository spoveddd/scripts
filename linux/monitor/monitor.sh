#!/bin/bash

# Telegram Bot Configuration
BOT_TOKEN="ВАШ ТОКЕН"
CHAT_ID="ВАШ ЧАТ ID - узнать можно обратившись по https://api.telegram.org/bot<ВАШ_ТОКЕН>/getUpdates - предварительно боту что-то написать"

# Directory to monitor
WATCH_DIR="/var/www/data/директория_вашего_сайта/"

# Telegram API URL
TELEGRAM_URL="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"

# Function to send message to Telegram
send_telegram_message() {
    local message="$1"
    curl -s -X POST "${TELEGRAM_URL}" \
        -d chat_id="${CHAT_ID}" \
        -d text="${message}" \
        -d parse_mode="HTML" > /dev/null 2>&1
}

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Check if inotifywait is installed
if ! command -v inotifywait &> /dev/null; then
    echo "Error: inotifywait is not installed. Please install inotify-tools package."
    echo "On Ubuntu/Debian: sudo apt-get install inotify-tools"
    echo "On CentOS/RHEL: sudo yum install inotify-tools"
    exit 1
fi

# Check if directory exists
if [ ! -d "$WATCH_DIR" ]; then
    echo "Error: Directory $WATCH_DIR does not exist."
    exit 1
fi

# Send startup notification
HOSTNAME=$(hostname)
send_telegram_message "🚀 <b>Мониторинг запущен</b>
📂 Директория: <code>${WATCH_DIR}</code>
🖥️ Сервер: <code>${HOSTNAME}</code>
⏰ Время: $(date '+%Y-%m-%d %H:%M:%S')"

log_message "Starting directory monitoring for: $WATCH_DIR"

# Main monitoring loop
#inotifywait -m -r -e create,delete,modify,move "$WATCH_DIR" --format '%w%f %e %T' --timefmt '%Y-%m-%d %H:%M:%S' |
inotifywait -m -e create,delete,modify,move "$WATCH_DIR" --format '%w%f %e %T' --timefmt '%Y-%m-%d %H:%M:%S' |

while read file event time; do
    # Get relative path for cleaner display
    relative_path=${file#$WATCH_DIR}

    # Determine event icon and description
    case $event in
        CREATE)
            icon="📝"
            action="создан"
            ;;
        DELETE)
            icon="🗑️"
            action="удален"
            ;;
        MODIFY)
            icon="✏️"
            action="изменен"
            ;;
        MOVED_FROM)
            icon="📤"
            action="перемещен (из)"
            ;;
        MOVED_TO)
            icon="📥"
            action="перемещен (в)"
            ;;
        *)
            icon="📋"
            action="изменен"
            ;;
    esac

    # Create message
    message="${icon} <b>Файл ${action}</b>
📁 Путь: <code>${relative_path}</code>
⏰ Время: <code>${time}</code>
🖥️ Сервер: <code>${HOSTNAME}</code>"

    # Log the event
    log_message "$action: $relative_path"

    # Send notification to Telegram
    send_telegram_message "$message"
done
