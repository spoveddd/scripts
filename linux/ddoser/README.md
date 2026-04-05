# DDoSer 2.0 — Анализатор access-логов для защиты от DDoS

Один проход по всем логам, автоопределение панели и ОС, GeoIP, DNS-проверки, наглядный вывод с графиком, готовые рекомендации по блокировке.

```
DDoSer 2.0.0 
```

---

## Быстрый старт

```bash
bash <(curl -s https://raw.githubusercontent.com/spoveddd/scripts/main/linux/ddoser/ddoser.sh)
```

Сохранить отчёт в файл:

```bash
bash <(curl -s https://raw.githubusercontent.com/spoveddd/scripts/main/linux/ddoser/ddoser.sh) -s > report.txt
```

Быстрый запуск (без per-site URIs, без рекомендаций, без промптов):

```bash
bash <(curl -s https://raw.githubusercontent.com/spoveddd/scripts/main/linux/ddoser/ddoser.sh) -fqy
```

На серверах с 50+ сайтами лучше скачать и запускать из файла:

```bash
curl -sL https://raw.githubusercontent.com/spoveddd/scripts/main/linux/ddoser/ddoser.sh -o /tmp/ddoser.sh
bash /tmp/ddoser.sh -y -p
```

---

## Что показывает

| Секция | Описание |
|--------|----------|
| System info | ОС, PHP, LA, RAM, панель и дата обновления, диски, сервисы, iptables, соединения, GeoIP |
| Summary | Запросы, трафик (bot/desktop/mobile), HTTP-статусы, bandwidth |
| Chart | График запросов по часам |
| Top IPs | IP, страна (GeoIP + whois fallback), клиент (браузер/бот/proxy) |
| Top Subnets | Агрегация по /24 (IPv4) |
| Top Bots | Статистика по ботам с цветовой классификацией |
| Top Sites | Топ-10 сайтов по запросам + URI на каждом + DNS-проверки |
| Recommendations | Готовые конфиги nginx для блокировки ботов, iptables, защита wp-login/xmlrpc |

---

## Опции

| Флаг | Описание |
|------|----------|
| `-t`, `--time P` | Период: `1h`, `6h`, `24h`, `3` (дня). По умолчанию: `24h` |
| `-n`, `--top N` | Кол-во строк в топе IP/ботов. По умолчанию: 50 |
| `-u`, `--uris N` | Кол-во URI на сайт. По умолчанию: 10 |
| `-f`, `--fast` | Пропустить per-site URIs, DNS-проверки |
| `-q`, `--quiet` | Пропустить рекомендации |
| `-y`, `--yes` | Автоматически подтверждать все промпты |
| `-s`, `--script` | Без цветов и промптов (для записи в файл) |
| `-p`, `--priority` | Низкий приоритет (nice/ionice) |
| `-D`, `--debug` | Включить `set -x` для отладки |
| `-V`, `--version` | Версия |
| `-h`, `--help` | Справка |

Флаги можно комбинировать: `-fqy`, `-sy`, `-fp`.

---

## Примеры

```bash
bash ddoser.sh                  # Интерактивный запуск
bash ddoser.sh -fqy             # Быстро, без промптов
bash ddoser.sh -t 1h -n 20     # Последний час, топ-20 IP
bash ddoser.sh -s > report.txt  # Отчёт в файл
bash ddoser.sh -t 6h -f        # За 6 часов, без per-site
```

---

## Поддерживаемые панели

| Панель | Пути к логам |
|--------|-------------|
| ISPManager | `/var/www/httpd-logs/*.access.log` |
| FastPanel | `/var/www/*/data/logs/*-backend.access.log` (frontend как fallback) |
| Hestia | `/var/log/apache2/domains/*.log` или `/var/log/nginx/domains/*.log` |
| Без панели | `/var/log/nginx/access.log` или `/var/log/apache2/access.log` |

---

## Цветовая схема

**IP-адреса (колонка COUNTRY):**

| Цвет | Значение |
|------|----------|
| Зелёный | Страна из списка безопасных (RU, DE, FR, US, UA и др.) |
| Красный | Страна не в списке или не определена |
| Жёлтый | IP самого сервера |

**Боты (при 1000+ запросов):**

| Цвет | Значение |
|------|----------|
| Зелёный | Поисковики (Google, Yandex) |
| Жёлтый | SEO/AI/соцсети (Bing, Semrush, Ahrefs, Meta) |
| Красный | Нежелательные или неизвестные |

**Клиент (колонка CLIENT):**

| Формат | Значение |
|--------|----------|
| `Chrome 120` | Один User-Agent с этого IP |
| `Safari 17 (10 UA)` | Основной UA + всего 10 разных |
| `proxy (142 UA)` | 100+ разных UA — прокси или скрапер |
| `empty` | Пустой User-Agent |

**Per-site DNS:**

| Тег | Значение |
|-----|----------|
| `→SRV` | Домен указывает на этот сервер |
| `→CDN` | Домен за CDN (Cloudflare, Akamai и др.) |
| `→EXT` | Домен указывает на другой сервер |
| `→???` | Домен не резолвится |

---

## Как устроен

1. Определяется панель управления и пути к логам
2. При необходимости устанавливаются `geoiplookup`, `whois`, `dig`
3. Собираются лог-файлы: текущие + ротированные (`.log.1`) при периоде ≥ 24ч
4. Все логи прогоняются через **один проход awk** — собираются IP, UA, URI, статусы, байты, почасовая статистика
5. GeoIP-резолв всех IP делается батчем
6. DNS-проверки по сайтам (опционально)
7. Весь вывод рендерится в буфер и печатается одним `cat`

---

## Рекомендации

Скрипт не блокирует ничего автоматически. Вместо этого генерирует готовые команды:

- **nginx** — конфиг для блокировки ботов (`if ($http_user_agent ~* ...)`)
- **iptables** — команды для блокировки подозрительных подсетей и IP
- **WordPress** — защита `wp-login.php`, `xmlrpc.php` через `limit_req` или `deny`
- **Пустые UA** — блокировка пустых User-Agent

---

## Зависимости

Устанавливаются автоматически. Если репозитории недоступны, скрипт продолжит без них.

| Пакет | Команда | Назначение |
|-------|---------|-----------|
| `geoip-bin` / `GeoIP` | `geoiplookup` | Определение страны по IP |
| `whois` | `whois` | Fallback для GeoIP |
| `dnsutils` / `bind-utils` | `dig` | DNS-проверки (только без `-f`) |

---

## Совместимость

- **ОС:** Debian 8+, Ubuntu 16.04+, CentOS/RHEL 7+
- **Bash:** 4.2+
- **Awk:** mawk или gawk
- **Панели:** ISPManager, FastPanel, Hestia или без панели
- **Формат логов:** nginx combined

---

## Автор

**Vladislav Pavlovich** · TG [@sysadminctl](https://t.me/sysadminctl)

## Репозиторий

[github.com/spoveddd/scripts/tree/main/linux/ddoser](https://github.com/spoveddd/scripts/tree/main/linux/ddoser)