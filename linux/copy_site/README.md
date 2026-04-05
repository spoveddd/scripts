# copy_site.sh

Инструмент удобного копирования сайтов на сервере — файлы, БД, конфиги, SSL.  
Поддерживает **FastPanel**, **ISPManager**, **Hestia**.

## Быстрый старт

```bash
bash <(curl -s https://raw.githubusercontent.com/spoveddd/scripts/main/linux/copy_site/copy_site.sh)
```

Или скачать и запустить:

```bash
wget https://raw.githubusercontent.com/spoveddd/scripts/main/linux/copy_site/copy_site.sh
chmod +x copy_site.sh
./copy_site.sh source.ru copy.ru
```

## Использование

```
./copy_site.sh [OPTIONS] [SOURCE TARGET]
```

**Аргументы:**

| Аргумент | Описание |
|---|---|
| `SOURCE` | Домен исходного сайта (например: `site.ru`) |
| `TARGET` | Домен нового сайта (например: `copy.ru`) |

**Опции:**

| Флаг | Описание |
|---|---|
| `--dry-run` | Симуляция без реальных изменений |
| `--force` | Перезаписать существующий сайт без переспросов |
| `--no-ssl` | Не выпускать SSL сертификат |
| `--panel=PANEL` | Принудительно задать панель: `fastpanel` / `hestia` / `ispmanager` |
| `--php=VERSION` | Версия PHP для wp-cli (например: `7.4`, `8.2`) |
| `-h, --help` | Справка |

**Примеры:**

```bash
# Интерактивный режим
./copy_site.sh

# С аргументами
./copy_site.sh site.ru copy.ru

# Симуляция без изменений
./copy_site.sh --dry-run site.ru test.ru

# Принудительно указать панель
./copy_site.sh --panel=hestia site.ru copy.ru
```

## Что делает скрипт

1. Определяет панель управления (FastPanel / ISPManager / Hestia)
2. Проверяет совместимость CLI-команд панели и их наличие
3. Определяет CMS исходного сайта (WordPress, DLE, Joomla, OpenCart)
4. Определяет IP сервера — из nginx-конфига сайта, затем из системных интерфейсов
5. Проверяет DNS нового домена через `8.8.8.8` — если домен не направлен на сервер, SSL не запрашивается (Let's Encrypt всё равно не выпустит)
6. Создаёт новый сайт через CLI панели, подбирая handler и версию PHP с исходного
7. Создаёт БД через CLI панели с автоматически сгенерированными именем и паролем
8. Копирует файлы через `rsync` с прогрессом
9. Импортирует дамп БД
10. Обновляет конфигурационные файлы CMS (БД, URL, домен)
11. Для WordPress — заменяет домены через `wp-cli` (устанавливает автоматически)
12. Выпускает SSL через Let's Encrypt (если DNS настроен)
13. Показывает итог: что сделано, что нужно сделать со стороны DNS/регистратора

При ошибке на любом этапе — откатывает созданный сайт и БД.

## Поддерживаемые CMS

| CMS | Что обновляется |
|---|---|
| **WordPress** | `wp-config.php`, URL в БД через `wp search-replace` |
| **DLE** | `engine/data/dbconfig.php`, `engine/data/config.php` |
| **Joomla** | `configuration.php` |
| **OpenCart** | `config.php`, `admin/config.php` |
| Другие | Только файлы и БД, конфиги не трогаются |

## Структура путей по панелям

| Панель | Путь к файлам сайта |
|---|---|
| **FastPanel** | `/var/www/username/data/www/domain/` |
| **ISPManager** | `/var/www/www-root/data/www/domain/` |
| **Hestia** | `/home/username/web/domain/public_html/` |

## Требования

- Linux (Debian/Ubuntu, RHEL/CentOS)
- Запуск от `root`
- MySQL / MariaDB
- Утилиты: `rsync`, `mysql`, `mysqldump`, `curl`, `sed`, `awk`

Для DNS-проверки нужен `dig` (пакет `dnsutils`/`bind-utils`) — скрипт попробует установить его автоматически. Если репозитории недоступны — DNS-проверка пропускается, скрипт продолжает работу.

## Кириллические домены

Скрипт автоматически конвертирует кириллические домены в punycode.  
Требуется одна из утилит: `idn2` (предпочтительно), `idn`, или `python3`.

```bash
apt install libidn2-utils   # Debian/Ubuntu
yum install libidn2         # RHEL/CentOS
```

## Логи и отладка

Лог каждого запуска сохраняется в:
```
/var/log/site_copy_YYYYMMDD_HHMMSS.log
```

Посмотреть последний лог:
```bash
tail -f /var/log/site_copy_*.log
```

Запуск с отладкой bash:
```bash
bash -x copy_site.sh 2>&1 | tee debug.log
```

Симуляция без изменений:
```bash
./copy_site.sh --dry-run site.ru copy.ru
```

## Версия

**v4.0** — полная переработка: CLI-аргументы, DNS-проверка, умные рекомендации,  
совместимость панелей, поддержка Joomla/OpenCart, откат при ошибках, punycode.

Автор: Vladislav Pavlovich · TG [@femid00](https://t.me/femid00)
