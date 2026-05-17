# Server Manager — LEMP/LAMP stack & control-panel provisioning

<p align="center">
  <strong>Инструмент для автоматической установки, настройки и сопровождения LEMP/LAMP-стека и панелей управления на Ubuntu / Debian / Rocky / AlmaLinux.</strong>
</p>

<p align="center">
  Версия: <code>3.4.0</code> · Лицензия: GPL-3.0 · Одним bash-скриптом, без внешних зависимостей
</p>

---

## Обзор

`servermanager.sh` — это единый bash-скрипт, который берёт чистый VPS и превращает его в готовую площадку для веб-сайтов:

- разворачивает **LEMP или LAMP** (Nginx / Apache / Nginx+Apache),
- ставит **любые версии PHP одновременно** (7.4 – 8.5) с per-site FPM-пулами,
- поднимает **MariaDB** или **MySQL** с безопасными дефолтами и оптимизированным `innodb_buffer_pool`,
- выпускает **SSL через acme.sh** (http-01 webroot / standalone / dns-01 — без certbot и без остановки nginx),
- управляет сайтами: **добавление, удаление, переключение PHP-версии, выпуск SSL**,
- делает **per-site бэкапы** (tar + mysqldump) с ротацией и восстановлением,
- имеет команду **`doctor`** для диагностики,
- включает **rollback-transactions**: Ctrl+C или падение посередине `add-site` не оставит половину конфига.

Альтернативно умеет ставить **панели управления** (ISPManager, HestiaCP, FastPanel, aaPanel) через их официальные инсталляторы.

---

## Содержание

- [Что нового в 3.4.0](#что-нового-в-340)
- [Поддерживаемые ОС](#поддерживаемые-ос)
- [Быстрый старт](#быстрый-старт)
- [CLI-команды](#cli-команды)
- [SSL через acme.sh](#ssl-через-acmesh)
- [Бэкапы](#бэкапы)
- [Диагностика (`doctor`)](#диагностика-doctor)
- [Non-interactive режим (CI/CD)](#non-interactive-режим-cicd)
- [Файлы и пути](#файлы-и-пути)
- [Концепции](#концепции)
- [Безопасность](#безопасность)
- [Деинсталляция](#деинсталляция)
- [Troubleshooting](#troubleshooting)

---

## Что нового в 3.4.0

| Область | Изменение |
|---|---|
| **SSL** | `certbot` убран целиком. Теперь `acme.sh` с тремя режимами: `webroot` (default), `standalone`, `dns-01`. Работает за Cloudflare proxy (через DNS-01). |
| **Бэкапы** | Per-site (файлы + mysqldump), а не tar всего `/var/lib/mysql`. FIFO-ротация, отдельный system-бэкап, опциональный cron. |
| **Диагностика** | Новая команда `doctor` — прогоняет nginx/apache/PHP-FPM/DB/диск/SSL-expiry/DNS и даёт сводку. |
| **Надёжность** | `flock`-блокировка (нет гонки cron ↔ пользователь), `trap INT/TERM` с rollback незавершённых `add-site`. |
| **acme.sh** | Распознавание ошибок LE (rate-limit, unauthorized, DNS-01 misconfig) и подсказки с готовыми командами. |
| **Fail2ban** | На RHEL проверяются фильтры nginx и задаются явные `logpath` + `backend = polling` — jail'ы больше не падают тихо. |
| **Uninstall** | Чистит cron-задачи servermanager и acme.sh. Опционально удаляет acme.sh целиком. Снимает lock-file. |
| **Логи** | Корректный подсчёт "запросов за 24ч" — парсим `[DD/Mon/YYYY:...]` через awk (а не `find -mtime`). |

---

## Поддерживаемые ОС

| Дистрибутив | Версии |
|---|---|
| Ubuntu | 20.04, 22.04, 24.04 |
| Debian | 11 (Bullseye), 12 (Bookworm) |
| Rocky Linux / AlmaLinux | 8, 9 |

> Старые ветки (Ubuntu 18.04, Debian 10, CentOS 7) **официально не поддерживаются** — пакеты EOL, PHP 8.x и MariaDB 11.x в их репозиториях либо отсутствуют, либо работают некорректно.

---

## Быстрый старт

### Из репозитория

```bash
wget https://raw.githubusercontent.com/spoveddd/LEMPScript/main/servermanager.sh
chmod +x servermanager.sh
sudo ./servermanager.sh
```

При первом запуске откроется **wizard** — выбор веб-сервера, PHP-версий, БД, swap, firewall. Далее — главное меню с разделами:

```
1) Сайты        (добавить / удалить / сменить PHP / выпустить SSL)
2) PHP          (доп. версии, default, обновить)
3) SSL          (статус, выпуск, renewal)
4) Бэкапы       (per-site / system / restore / cron)
5) Безопасность (firewall / fail2ban / обновления)
6) БД           (пользователи, дампы, оптимизация)
7) Диагностика  (doctor, логи, uptime)
8) Обслуживание (очистка кэшей, статус, обновления ОС)
```

### One-liner (без скачивания)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/spoveddd/LEMPScript/main/servermanager.sh)
```

---

## CLI-команды

### Основное

```bash
sudo ./servermanager.sh                          # wizard или меню (авто)
sudo ./servermanager.sh menu                     # форсировать меню
sudo ./servermanager.sh wizard                   # форсировать wizard
sudo ./servermanager.sh status                   # краткий статус
sudo ./servermanager.sh doctor                   # полный health-check
sudo ./servermanager.sh uninstall                # удалить стек
sudo ./servermanager.sh uninstall-cron           # только cron-задачи sm/acme.sh
```

### Сайты

```bash
sudo ./servermanager.sh list-sites
sudo ./servermanager.sh add-site                 # интерактивно
sudo ./servermanager.sh remove-site example.com
sudo ./servermanager.sh change-site-php example.com 8.3
sudo ./servermanager.sh issue-ssl example.com
```

### PHP

```bash
sudo ./servermanager.sh install-php 8.3
sudo ./servermanager.sh remove-php 7.4
sudo ./servermanager.sh set-default-php 8.3
```

### Бэкапы

```bash
sudo ./servermanager.sh backup-site example.com
sudo ./servermanager.sh backup-all
sudo ./servermanager.sh backup-system
sudo ./servermanager.sh backup-list [example.com]
sudo ./servermanager.sh restore-site example.com_20260423_120000.tar.gz
sudo ./servermanager.sh backup-setup-cron        # ежедневно 03:00
sudo ./servermanager.sh backup-remove-cron
```

---

## SSL через acme.sh

В 3.4.0 полностью отказались от `certbot` в пользу [`acme.sh`](https://github.com/acmesh-official/acme.sh). Преимущества:

- **Не нужен Python / виртуалка** — чистый shell.
- **Не останавливает nginx** — http-01 через webroot (файл в `.well-known/acme-challenge/`).
- **DNS-01 из коробки** — работает даже за Cloudflare proxy, с любого хоста.
- **Автообновление** через cron, который ставится самим `acme.sh --install-cronjob`.

### Режимы валидации

| Режим | Когда использовать | Пример |
|---|---|---|
| **webroot** (default) | Обычный случай. Домен резолвится на сервер, `:80` открыт. | `sudo ./servermanager.sh issue-ssl example.com` |
| **standalone** | `:80` открыт, но nginx/apache не отдают `.well-known` (нестандартный конфиг). | `SM_ACME_MODE=standalone SM_ACME_STOP_WEB=1 sudo ./servermanager.sh issue-ssl example.com` |
| **dns-01** | Сайт за Cloudflare proxy, `:80` закрыт, wildcard-сертификат. | `export CF_Token=...; export CF_Account_ID=...`<br>`SM_ACME_MODE=dns SM_ACME_DNS_PROVIDER=dns_cf sudo ./servermanager.sh issue-ssl example.com` |

Список DNS-провайдеров: [acme.sh DNS API wiki](https://github.com/acmesh-official/acme.sh/wiki/dnsapi).

### Staging (тесты без лимитов LE)

Let's Encrypt лимитирует 5 выпусков на одинаковый набор доменов за 7 дней. Для отладки используйте staging CA (30000/час, но сертификаты недоверенные):

```bash
SM_ACME_STAGING=1 sudo ./servermanager.sh issue-ssl example.com
```

### Переменные окружения SSL

| ENV | Значение по умолчанию | Описание |
|---|---|---|
| `SM_ACME_MODE` | `webroot` | `webroot` / `standalone` / `dns` |
| `SM_ACME_DNS_PROVIDER` | — | Имя провайдера для DNS-01 (`dns_cf`, `dns_digitalocean`, …) |
| `SM_ACME_STOP_WEB` | `0` | Для standalone — временно стопит nginx/apache |
| `SM_ACME_STAGING` | `0` | `1` → staging LE (для тестов) |
| `SSL_EMAIL` | `admin@<domain>` | Email для аккаунта LE |
| `SM_ACME_HOME` | `/root/.acme.sh` | Установочная директория acme.sh |
| `SM_ACME_SSL_DIR` | `/etc/ssl/acme` | Куда устанавливаются сертификаты |

Сертификаты хранятся в `${SM_ACME_SSL_DIR}/<domain>.{cer,key,fullchain.cer}` с правами `0600`. Nginx-конфиги ссылаются на них напрямую.

---

## Бэкапы

Архитектура per-site, без `tar /var/lib/mysql` (который в 3.2 падал на живом InnoDB).

### Структура хранилища

```
/var/backups/servermanager/
├── sites/
│   └── example.com/
│       ├── example.com_20260423_030000.tar.gz
│       └── example.com_20260423_030000.meta
└── system/
    ├── system_20260423_030000.tar.gz
    └── system_20260423_030000.meta
```

### Что внутри архива сайта

```
example.com_20260423_030000/
├── meta.txt              # format_version, sm_version, domain, php, backend, ssl, db_name, ...
├── site.conf             # /etc/servermanager/sites/<domain>.conf
├── nginx.conf            # /etc/nginx/sites-available/<domain>.conf
├── apache.conf           # /etc/apache2/sites-available/<domain>.conf (если есть)
├── fpm-pool.conf         # per-site FPM-пул
├── db.sql.gz             # mysqldump --single-transaction --quick --routines --triggers
└── files.tar             # DOCUMENT_ROOT (с exclude-масками)
```

### Exclude-маски tar (для сайта)

- `node_modules`
- `vendor/composer/tmp-*`
- `wp-content/cache`, `wp-content/uploads/cache`, `wp-content/upgrade`
- `*.log`, `*.tmp`
- `.git`, `.svn`, `.cache`, `__pycache__`

### Ротация

Хранится **7 последних** бэкапов на сайт (`SM_BACKUP_KEEP=7`). При создании нового самый старый удаляется (FIFO по mtime). Метаданные (`.meta`) удаляются вместе с архивом.

### Автобэкап

```bash
sudo ./servermanager.sh backup-setup-cron     # 0 3 * * * → backup-all, лог в /var/log/servermanager-backup.log
sudo ./servermanager.sh backup-remove-cron
```

### Восстановление

```bash
sudo ./servermanager.sh restore-site example.com_20260423_030000.tar.gz
```

Восстановление:
1. Проверяет `meta.txt` (формат, домен).
2. Предлагает опционально очистить DOCUMENT_ROOT.
3. Распаковывает `files.tar`.
4. Импортирует `db.sql.gz` через mysql (используя креды из `/root/.servermanager/db-<domain>.txt`).
5. Опционально перезаписывает nginx/apache-конфиги с `nginx -t` перед reload.
6. Выставляет владельца `www-data` / `apache`.

### Переменные окружения бэкапа

| ENV | Значение по умолчанию | Описание |
|---|---|---|
| `SM_BACKUP_DIR` | `/var/backups/servermanager` | Корень хранилища |
| `SM_BACKUP_KEEP` | `7` | Retention (штук на сайт / system) |

---

## Диагностика (`doctor`)

```bash
sudo ./servermanager.sh doctor
```

Проверяет:

| Проверка | Статусы |
|---|---|
| **Nginx** | `nginx -v`, `nginx -t`, `systemctl is-active nginx` |
| **Apache** | config test + service (если установлен) |
| **PHP-FPM** | service для каждой установленной версии + per-site `.sock` файлы |
| **БД** | systemd service, SQL-ping через `/root/.my.cnf`, количество пользовательских БД |
| **Диск** | `/`, `/var/www`, `/var/backups`, `/var/lib/mysql` — >80% warn, >90% fail |
| **SSL expiry** | acme.sh + certbot (legacy) — <14 дн. warn, <0 дн. fail |
| **DNS** | A-запись каждого сайта vs IP сервера — детектит Cloudflare proxy |
| **Автобэкап** | Есть ли запись в cron |

Возвращает **exit code 1** если были FAIL'ы — подходит для мониторинга.

Пример вывода:

```
Nginx:
  [i] version: nginx/1.22.1
  [✓] nginx -t: конфиг валиден
  [✓] nginx service: active

PHP-FPM:
  [✓] php8.3-fpm: active
  [✓] socket /run/php/php8.3-fpm-example.com.sock

Диск:
  [✓] /: 34% used (свободно: 24.1 GiB)
  [!] /var/www: 82% used (свободно: 1.8 GiB)

SSL-сертификаты:
  [✓] example.com: 87 дн. до истечения
  [!] staging.example.com: 11 дн.

DNS A-записи:
  [i] IP сервера: 203.0.113.10
  [✓] example.com → 203.0.113.10
  [!] behindcf.example.com → 104.21.1.2 (НЕ совпадает — возможно, Cloudflare proxy)

Итог:
  Проблем: 0, предупреждений: 2
```

---

## Non-interactive режим (CI/CD)

Устанавливается стек без интерактивных подсказок через env-vars:

```bash
SM_NON_INTERACTIVE=1 \
WEB_SERVER=nginx \
PHP_TO_INSTALL="8.2 8.3 8.5" \
PHP_DEFAULT=8.3 \
DATABASE=mariadb \
DB_VERSION=11.4 \
ENABLE_SWAP=true SWAP_SIZE=2G \
ENABLE_FIREWALL=true \
sudo -E ./servermanager.sh wizard
```

Добавление сайта в non-interactive:

```bash
SM_NON_INTERACTIVE=1 \
DOMAIN=example.com \
SITE_PHP_VERSION=8.3 \
SITE_BACKEND=php-fpm \
CREATE_DB=true \
ENABLE_SSL=true \
sudo -E ./servermanager.sh add-site
```

Поддерживаемые ENV для `add-site`:

| ENV | Описание |
|---|---|
| `DOMAIN` | Домен сайта (обязательно) |
| `SITE_DIR` | DOCUMENT_ROOT (default: `/var/www/<domain>`) |
| `SITE_PHP_VERSION` | Версия PHP (default: default PHP стека) |
| `SITE_BACKEND` | `php-fpm` / `apache-mod-php` / `apache-php-fpm` |
| `SITE_WWW_ALIAS` | `true`/`false` — добавить www-поддомен |
| `CREATE_DB` | `true`/`false` — создать БД + пользователя |
| `DB_NAME`, `DB_USER`, `DB_PASS` | Если `CREATE_DB=true`; пустые — сгенерируются |
| `ENABLE_SSL` | `true`/`false` |

---

## Файлы и пути

| Путь | Назначение |
|---|---|
| `/etc/servermanager/` | Метаданные скрипта: `state.conf`, `sites/*.conf` |
| `/root/.servermanager/` | Креды БД (`db-root.txt`, `db-<domain>.txt`, chmod 600) |
| `/var/log/servermanager.log` | Лог работы скрипта (ANSI-коды стрипаются) |
| `/var/log/servermanager-backup.log` | Лог cron-бэкапа |
| `/var/backups/servermanager/` | Бэкапы (см. выше) |
| `/etc/ssl/acme/` | SSL-сертификаты от acme.sh |
| `/root/.acme.sh/` | acme.sh (бинарник + аккаунт LE) |
| `/var/run/servermanager.lock` | Lockfile для flock (concurrency guard) |
| `/var/cache/servermanager/` | Загруженные официальные инсталляторы панелей |

---

## Концепции

### Изоляция сайтов

- Каждый сайт = **отдельный FPM-пул** с своим сокетом `/run/php/php${v}-fpm-${domain}.sock`.
- Смена PHP-версии сайта → пул на старой версии удаляется, на новой создаётся, nginx-конфиг полностью перерендеривается (не патчится через sed) с `nginx -t` и rollback при ошибке.
- БД и пользователь — отдельные для каждого сайта, в `/root/.servermanager/db-<domain>.txt`.

### Concurrency guard

`flock` на `/var/run/servermanager.lock` — два параллельных запуска (например, cron-бэкап в 03:00 и пользователь в меню) не могут повредить конфиг. Ожидание 10 секунд, потом отказ с понятным сообщением.

**Read-only команды не блокируют лок**: `status`, `list-sites`, `backup-list`, `doctor` — запускаются параллельно.

### Rollback transactions

`add-site` регистрирует откат на каждом шаге: создал директорию → зарегистрировал `rm -rf`, создал DB → зарегистрировал `DROP DATABASE`, создал nginx-конфиг → зарегистрировал `rm`. При Ctrl+C / SIGTERM / внутренней ошибке всё откатывается в обратном порядке. Сайт или добавится полностью, или не оставит следов.

### State

`/etc/servermanager/state.conf` — KV-формат (читается через `awk`, не через `grep` — чтобы `key_not_found` не ломал `set -e`). Содержит:

- `installed_php_versions=8.2 8.3 8.5`
- `default_php_version=8.3`
- `web_server=nginx`
- `database=mariadb`
- `state_format=1`

---

## Безопасность

- **Firewall**: UFW (Debian/Ubuntu) или firewalld (RHEL). Открываются только `22` (или кастомный SSH-порт, автодетект), `80`, `443`.
- **Fail2ban**:
  - `[sshd]` — всегда включён, `backend = systemd` на RHEL.
  - `[nginx-http-auth]` / `[nginx-botsearch]` — включаются только если в системе есть соответствующие filter-файлы (на минимальном RHEL их может не быть — тогда jail'ы тихо пропускаются, а не ломают fail2ban).
- **Per-site ownership**: `chown www-data:www-data` (Debian) / `apache:apache` (RHEL) на `DOCUMENT_ROOT`, `.well-known/acme-challenge/`.
- **Секреты**: креды БД — в `/root/.servermanager/` c `chmod 600` (под root'ом). Не коммитятся в архивы бэкапа как plaintext отдельно (только внутри `db.sql.gz`, который сам по себе защищён правами).
- **MariaDB hardening**: во время `setup_mariadb` выполняется эквивалент `mysql_secure_installation` (удаление anonymous users, test-database, root-remote-login).

---

## Деинсталляция

```bash
sudo ./servermanager.sh uninstall
```

**Удалит:**
- nginx / apache2 / httpd
- все PHP-версии (включая php-fpm / модули)
- MariaDB / MySQL (сервис + бинарники; **данные** в `/var/lib/mysql` остаются)
- Fail2ban
- метаданные скрипта (`/etc/servermanager/`, `/root/.servermanager/`)
- legacy certbot (если был установлен до 3.2)
- **cron-задачи** servermanager и acme.sh

**Не удалит** (нужно вручную):
- `/var/www/` — файлы сайтов
- `/var/lib/mysql/` — данные БД
- `/var/backups/servermanager/` — архивы
- `/root/.acme.sh/` и `/etc/ssl/acme/` — сертификаты и аккаунт LE (с опциональным подтверждением в процессе)

Отдельная команда для очистки только cron'а:

```bash
sudo ./servermanager.sh uninstall-cron
```

---

## Troubleshooting

### `rateLimited` от Let's Encrypt

Лимит: 5 сертификатов на одинаковый набор доменов за 7 дней. Что делать:

1. Подождать (дата снятия лимита указана в ошибке).
2. Использовать staging для тестов: `SM_ACME_STAGING=1 sudo ./servermanager.sh issue-ssl domain.com`.
3. [Docs](https://letsencrypt.org/docs/rate-limits/).

### HTTP-01 validation failed / `urn:ietf:params:acme:error:unauthorized`

Проверьте:
- A-запись домена → IP сервера (`sudo ./servermanager.sh doctor` покажет расхождения).
- Порт 80 открыт (`curl -I http://domain.com/`).
- Сайт не за Cloudflare proxy (оранжевое облако) — LE не сможет достучаться.

Альтернативы:
- **standalone**: `SM_ACME_MODE=standalone SM_ACME_STOP_WEB=1 sudo ./servermanager.sh issue-ssl domain.com`
- **DNS-01** (работает за CF): `SM_ACME_MODE=dns SM_ACME_DNS_PROVIDER=dns_cf sudo ./servermanager.sh issue-ssl domain.com`

### "Другой экземпляр servermanager уже работает"

flock-файл удерживается другим запуском (вероятно, cron-бэкап в 03:00). Подождите или проверьте процессы: `lsof /var/run/servermanager.lock`. Если процесс мёртв, но файл остался — удалите вручную: `sudo rm /var/run/servermanager.lock`.

### `nginx -t` OK, но сайт отвечает 502

Проверьте per-site FPM-сокет: `sudo ./servermanager.sh doctor` покажет отсутствующие сокеты. Если `.sock` файла нет — пересоздайте пул: `sudo ./servermanager.sh change-site-php domain.com <текущая_версия>` (это перерендерит конфиг атомарно).

### Полная диагностика

```bash
sudo ./servermanager.sh doctor
```

Лог работы: `/var/log/servermanager.log`.

---

## Лицензия

GNU General Public License v3.0

## Автор

**Павлович Владислав** — [pavlovich.live](https://pavlovich.live)

Поддержка: Telegram [@sysadminctl](https://t.me/sysadminctl)

## Вклад в проект

Issues и pull requests приветствуются. При репорте бага приложите:

1. `sudo ./servermanager.sh doctor` (вывод).
2. Последние 100 строк `/var/log/servermanager.log`.
3. Версию ОС: `cat /etc/os-release`.
4. Версию скрипта: `grep SM_VERSION= servermanager.sh`.

---

### Примечание по безопасности

Скрипт применяет best-practices для типичного веб-хостинга, но **не заменяет** аудит безопасности для production-сервера с критическими данными. Для чувствительных нагрузок рекомендуется дополнительная проверка настроек и консультация со специалистом.
