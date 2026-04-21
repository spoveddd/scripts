# diaglinux.sh — Linux Server Diagnostic Script

**v2.0.0**  · Bash 4+

Быстрая диагностика Linux-сервера одной командой. Подходит для сотрудников техподдержки: запустил — получил за 10–30 секунд  отчёт о состоянии сервера.

---

## Быстрый старт

```bash
# Скачать и запустить одной командой
bash <(curl -fsSL https://raw.githubusercontent.com/spoveddd/scripts/main/linux/diaglinuxscript/diaglinuxscript.sh)

# Локально
wget https://raw.githubusercontent.com/spoveddd/scripts/main/linux/diaglinuxscript/diaglinuxscript.sh
chmod +x diaglinuxscript.sh
sudo ./diaglinuxscript.sh
```

Рекомендуется запускать под `root` (иначе SMART, atop, часть systemd-деталей будут недоступны — скрипт честно скажет об этом в выводе и продолжит остальные проверки).

---

## Что умеет

- **Окружение**: ОС, uptime, внешний IP (с проверкой локальных интерфейсов), автодетект панелей управления (FastPanel/ISPmanager/cPanel/VestaCP/DirectAdmin) с генерацией ссылок на вход.
- **Ресурсы**: Load Average, RAM/SWAP (с топом потребителей swap), дисковое пространство + inodes (с указанием худшего раздела и количеством свободного места), read-only разделы.
- **Диски и RAID**: `/proc/mdstat` (degraded/rebuild/RAID0), SMART для всех HDD/SSD/NVMe (Reallocated_Sector_Ct, Current_Pending_Sector, Reported_Uncorrect, Percentage_Used и др.), MegaCLI, arcconf.
- **Сервисы**: упавшие systemd units, проверка конфигов Nginx и Apache, `/proc/user_beancounters` (OpenVZ).
- **Логи**: большие файлы в `/var/log`, `/var/www/*/logs`, `/home/*/logs` (с раскрытием глобов), большие `*tmp` (вызывают зависания SSH-сессий).
- **Анализ логов**: syslog, journalctl, dmesg, kern.log, messages, apache/nginx error, daemon.log, fastpanel, php-fpm. Паттерны группируются, нормализуются (IP/PID/пути), раскрашиваются по степени опасности.
- **TOP процессов**: по CPU, по RAM; TOP пользователей по количеству процессов / CPU / RAM; нагрузка на диск через `atop`.
- **Итоговый summary** со статистикой OK/WARN/FAIL/N/A и списком критических проблем.
- **Корректный exit-код** для использования в мониторинге/cron (0 / 1 / 2).
- **JSON-вывод** для парсинга в автоматизированных пайплайнах.

---

## Опции командной строки

| Опция | Описание |
|---|---|
| `-h, --help` | Показать встроенную справку |
| `-V, --version` | Показать версию |
| `-v, --verbose` | Подробный вывод с debug-сообщениями |
| `-q, --quiet` | Только WARN/FAIL в выводе (для быстрого триажа) |
| `--no-color` | Без ANSI-цветов (для `tee`, CI, грепа) |
| `--json` | Добавить JSON-отчёт в конец вывода |
| `--skip-logs` | Пропустить анализ логов (быстрый режим) |
| `--skip-smart` | Пропустить SMART-проверку дисков |
| `--skip-top` | Пропустить TOP-рейтинги процессов/пользователей |
| `--skip-panel` | Не детектить панель управления |
| `--no-panel-login` | Детектить панель, но не генерировать логин-ссылки (не создавать пользователей в `.htpasswd`) |

---

## Переменные окружения

Все пороги можно переопределить:

| Переменная | По умолчанию | Описание |
|---|---|---|
| `LOG_DEPTH` | `10000` | Сколько строк лога анализировать |
| `LOG_TAIL` | `30` | Число уникальных паттернов в отчёте |
| `LARGE_LOG_SIZE` | `500M` | Порог "большого" лога для алерта |
| `LARGE_LAST_SIZE` | `128` | Порог `/var/log/*tmp` в МБ |
| `LA_WARN` / `LA_FAIL` | `4.0` / `8.0` | Пороги Load Average |
| `DISK_WARN_PCT` / `DISK_FAIL_PCT` | `85` / `90` | Пороги заполнения диска в % |
| `MEM_FREE_MIN_MB` | `50` | Минимум свободной RAM |
| `MEM_AVAIL_MIN_MB` | `200` | Минимум available RAM |
| `SWAP_WARN_MB` | `100` | Порог использования swap |
| `DEBUG` | `0` | Общие debug-сообщения |
| `SMART_DEBUG` | `0` | Debug SMART-парсинга (0–7) |

---

## Exit-коды

| Код | Значение |
|---|---|
| `0` | Все проверки [OK] |
| `1` | Есть [WARN] — внимание, но не критично |
| `2` | Есть [FAIL] — критические проблемы (SMART, degraded RAID, I/O errors в логах, упавшие systemd-сервисы) |
| `127` | Неподдерживаемая среда (bash < 4.0) |

Это делает скрипт пригодным для запуска из cron / Zabbix / Nagios / Icinga:

```bash
# В cron — отчёт только при наличии проблем
0 */6 * * * /usr/local/bin/diaglinux.sh --no-color --quiet || mail -s "diag alert on $(hostname)" ops@example.com < /dev/null
```

---

## Примеры использования

```bash
# Обычный интерактивный запуск
sudo ./diaglinux.sh

# Быстрая проверка без логов и SMART (за 1–2 секунды)
sudo ./diaglinux.sh --skip-logs --skip-smart

# Сохранить отчёт в файл (без ANSI)
sudo ./diaglinux.sh --no-color | tee /root/diag-$(date +%F).log

# Только проблемы — идеально для триажа
sudo ./diaglinux.sh --quiet

# JSON для последующего парсинга
sudo ./diaglinux.sh --json --no-color | awk '/^--- JSON ---/{p=1; next} p' | jq '.summary'

# Глубокий анализ логов
LOG_DEPTH=50000 LOG_TAIL=100 sudo ./diaglinux.sh

# Паранойя по дискам
DISK_WARN_PCT=70 DISK_FAIL_PCT=80 sudo ./diaglinux.sh

# Без создания временного пользователя в FastPanel
sudo ./diaglinux.sh --no-panel-login
```

---

## Пример вывода

```
diaglinux v2.0.0 — диагностика сервера web-01

━━━ Окружение ━━━
  ОС                                       [ИНФО]       Ubuntu 22.04.3 LTS, uptime 47d 12h 3m
  Внешний IP                               [ИНФО]       203.0.113.45 (локальный)
  Панель: FastPanel 2                      [ИНФО]       /usr/local/fastpanel2
      → Ссылка входа в FastPanel 2:
        https://203.0.113.45:8888/login/...

━━━ Ресурсы ━━━
  Load Average                             [ОК]         LA=0.85 (cores=4)
  RAM                                      [ОК]         3412/16000MB (свободно 11840MB)
  SWAP                                     [ОК]         12/2000MB
  Место на диске                           [ВНИМАНИЕ]   макс 87% на /var (свободно 6.2G)
      WARN: /var = 87% (доступно 6.2G)
  Inodes                                   [ОК]         макс 14% на /
  Read-only разделы                        [ОК]

━━━ Диски и RAID ━━━
  /proc/mdstat                             [ОК]         /dev/md0=raid1
  SMART /dev/sda                           [ОК]         HDD, S/N: WD-WMC...
  SMART /dev/sdb                           [ОШИБКА]     HDD, S/N: WD-WMC...
      Reallocated_Sector_Ct = 612
      Current_Pending_Sector = 248

━━━ Сервисы ━━━
  systemd (failed units)                   [ОК]
  Nginx config                             [ОК]
  Apache config                            [Н/Д]

━━━ Анализ логов ━━━
  Лог: syslog                              [ВНИМАНИЕ]   уникальных паттернов: 4, всего: 127
      [  89] sshd: Failed password for invalid user from IP
      [  22] postfix: warning: hostname IP: hostname verification failed
      [   9] kernel: TCP: Possible SYN flooding on port 443
      [   7] mysql.service: Failed with result 'exit-code'

━━━ ИТОГО ━━━

  Всего проверок: 21
  ✓ OK:        17
  ⚠ WARN:      2
  ✗ FAIL:      1
  — N/A:       1
  Время:       12s

Критические проблемы:
  ✗ SMART /dev/sdb — HDD, S/N: WD-WMC...

Предупреждения:
  ⚠ Место на диске — макс 87% на /var (свободно 6.2G)
  ⚠ Лог: syslog — уникальных паттернов: 4, всего: 127
```

---

## Архитектура

Весь скрипт — один файл, чтобы запускать через `curl | bash`. Внутри — модульная структура из ~50 функций:

- `report(name, status, details)` — единая точка вывода статуса; собирает результаты в ассоциативные массивы для итогового summary и JSON.
- `analyze_log(name, source_cmd, filter)` — кэширует вывод источника в `mktemp` один раз, затем все поисковые операции идут по файлу. Нормализует строки (отрубает таймстампы, PID, IP, пути) перед дедупликацией через `sort | uniq -c`.
- Все пороги вынесены в top-level переменные, переопределяемые из env.
- Вывод корректно работает с UTF-8 (выравнивание столбцов через `${#var}` под правильной locale).

---

## Что нового в v2.0 по сравнению с v1.0

**Исправленные баги:**
- `os_version` больше не ломается на системах с множественными release-файлами — читается из `/etc/os-release`.
- Uptime берётся из `/proc/uptime`, а не парсится из вывода `uptime` регексом.
- Glob-паттерны `/var/www/*/data/logs/` в `find_large_logs` теперь раскрываются правильно (в v1 находились как литерал со звёздочкой).
- `analyze_log` больше не перечитывает лог N раз (по разу для каждой найденной ошибки) — вывод кэшируется один раз в `mktemp`. **На больших логах это даёт ускорение в 5–20 раз.**

**Новые возможности:**
- Итоговый summary с количеством OK/WARN/FAIL/N/A и списком критических проблем.
- Корректные exit-коды для мониторинга (0/1/2).
- Флаги: `--help`, `-v`/`-q`, `--no-color`, `--json`, `--skip-logs`/`--skip-smart`/`--skip-top`/`--skip-panel`, `--no-panel-login`.
- Детали о ресурсах в статусах (фактическое использование, а не только `[OK]`).
- JSON-вывод для автоматизации.
- Прогресс-бары показываются только если `stderr` — терминал (не ломают `| tee` и редиректы).
- Раскраска отключается при `--no-color` или когда вывод не в терминал.


---

## Системные требования

- **Bash ≥ 4.0** (для ассоциативных массивов). Скрипт явно проверяет версию и выходит с кодом 127, если bash старее.
- **coreutils**: `df`, `free`, `uptime`, `find`, `sort`, `uniq`, `awk`, `sed`, `grep`, `mktemp`.
- **Опционально**: `curl` или `wget` (для внешнего IP), `smartctl` (для SMART), `atop` (для нагрузки на диск), `systemctl`, `nginx`/`apache2ctl`, `mdadm`, `megacli`, `arcconf`.

Скрипт **не падает**, если опциональные утилиты отсутствуют — соответствующие проверки помечаются как `[Н/Д]`.

---

## Troubleshooting

**Скрипт говорит "требуется bash >= 4.0"**
На старом CentOS 6 / MacOS bash может быть 3.2. Установите новый bash отдельно или запустите через `bash5 diaglinux.sh`.

**"Внешний IP — не удалось получить"**
На машине нет доступа наружу либо не установлены `curl`/`wget`. Не критично — часть проверок панелей может не сработать, остальное работает.

**Цвета в выводе `| tee file.log`**
Используйте `--no-color`. Скрипт автоматически отключает цвета при `! -t 1`, но `tee` формально наследует TTY у `stdout`.

**Ложные срабатывания в логах (типа "Segmenting fault lines")**
Паттерн `[^e]fault` ловит любое слово, оканчивающееся на `fault` (не `default`). Если конкретный паттерн шумит на вашем стеке — добавьте его в `LOG_EXCLUDE` в начале секции анализа логов.

**На сервере много дисков — SMART идёт долго**
Используйте `--skip-smart`. Или раз в сутки запускайте полный прогон, а в интерактиве — быстрый.

---

## Лицензия

Распространяется свободно для использования и модификации.

## Автор

**Vladislav Pavlovich** — v1.0.0 (оригинал)
v2.0.0 — рефакторинг с исправлением багов, добавлением флагов, JSON-вывода, оптимизацией `analyze_log` и единой системы статусов.