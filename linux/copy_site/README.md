# Site Copy Script

Автоматическое копирование сайтов с CMS (WordPress, DLE) включая БД, файлы и SSL сертификаты.

**Поддержка:** FastPanel, ISPManager, Hestia

## Быстрый старт

```bash
sudo bash <(curl -s https://raw.githubusercontent.com/spoveddd/scripts/main/linux/copy_site/copy_site.sh)
```

или

```bash
wget https://raw.githubusercontent.com/spoveddd/scripts/main/linux/copy_site/copy_site.sh
chmod +x copy_site.sh
sudo ./copy_site.sh
```

## Что делает

- Определяет панель управления автоматически
- Создает новый сайт и БД через CLI панели
- Копирует файлы исходного сайта
- Импортирует БД с сохранением данных
- Обновляет конфигурацию (WordPress/DLE)
- Выпускает SSL Let's Encrypt сертификат
- Логирует все операции в `/var/log/site_copy_script_*.log`

## Требования

- Linux (Debian-based)
- root доступ
- MySQL/MariaDB запущена
- Зависимости: `rsync`, `mysql`, `mysqldump`, `sed`, `grep`, `find`

## Как работает

1. Введите домен исходного сайта
2. Введите домен нового сайта
3. Подтвердите параметры БД
4. Скрипт сам всё остальное сделает

## Структура панелей

| Панель | Путь |
|--------|------|
| **FastPanel** | `/var/www/username/data/www/sitename/` |
| **ISPManager** | `/var/www/www-root/data/www/sitename/` |
| **Hestia** | `/home/user/web/sitename/public_html/` |

## Особенности

✅ Проверка прав и свободного места  
✅ Резервные копии конфигов перед изменением  
✅ Автоматическое определение CMS  
✅ Умный выбор IPv4 адреса  
✅ Детальная диагностика ошибок  
✅ Автоочистка временных файлов  

## Ограничения

- Только MySQL/MariaDB
- Требует root доступ
- SSL сертификаты не копируются (генерируются заново)

## Отладка

Посмотрите лог:
```bash
tail -f /var/log/site_copy_script_*.log
```

Или перезапустите с отладкой:
```bash
bash -x copy_site.sh 2>&1 | tee debug.log
```

## Версия

v3.0 — CLI интеграция, SSL, wp-cli для WordPress, умный выбор IP

Автор: Vladislav Pavlovich