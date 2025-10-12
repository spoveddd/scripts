# Site Copy Script

Автоматическое копирование сайтов с CMS (WordPress, DLE) включая БД, файлы и выпуск SSL сертификатов.

**Поддержка:** Наиболее популярные панели управления: FastPanel, ISPManager и Hestia. 

## Быстрый старт:

```bash
sudo bash <(curl -s https://raw.githubusercontent.com/spoveddd/scripts/main/linux/copy_site/copy_site.sh)
```

или классический вариант:

```bash
wget https://raw.githubusercontent.com/spoveddd/scripts/main/linux/copy_site/copy_site.sh
chmod +x copy_site.sh
sudo ./copy_site.sh
```

## Что делает скрипт?

- Автоматически определяет панель управления 
- Создает новый сайт и БД через CLI панели (либо определяет, что он создан)
- Копирует файлы исходного сайта в директорию целевого
- Импортирует БД с сохранением данных
- Обновляет конфигурацию (только для CMS WordPress/DLE)
- Выпускает SSL Let's Encrypt сертификат (если есть DNS-записи)
- Скрипт логирует все операции в `/var/log/site_copy_script_*.log`

## Требования

- OS Linux (Debian-based, RHEL)
- root-доступ
- запущенная MySQL/MariaDB
- Зависимости: `rsync`, `mysql`, `mysqldump`, `sed`, `grep`, `find`

## Как работает

1. Введите домен исходного сайта
2. Введите домен нового сайта
3. Подтвердите параметры БД
4. Остальное скрипт делает автоматически и предоставляет подробные действия 

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