# mxchecker v2.0

Комплексный bash-чекер почтовой инфраструктуры домена: IPv4 + IPv6, параллельные проверки, JSON-вывод, корректные exit codes.

---

## Что проверяется

| Проверка | Детали |
|---|---|
| **DNS** | A, AAAA, MX (с сортировкой по приоритету) |
| **PTR** | FCrDNS (forward-confirmed reverse DNS) для IPv4 и IPv6 |
| **SPF** | Несколько записей (permerror), подсчёт DNS lookups (лимит 10), `+all`, устаревший `ptr` |
| **DKIM** | ~40 популярных селекторов + пользовательские через `--dkim-selector` |
| **DMARC** | `p=`, `sp=`, `pct=`, `rua=`, subdomain-loophole (sp=none при строгом p) |
| **MTA-STS** | TXT-запись **+ реальная загрузка policy** по HTTPS, проверка `mode: enforce` |
| **TLS-RPT** | `_smtp._tls` TXT-запись |
| **SMTP-порты** | 25 / 465 / 587 параллельно, IPv4 и IPv6 |
| **SMTP-баннер** | Через `/dev/tcp` или nc с корректным таймаутом |
| **TLS/StartTLS** | Валидность цепочки, **срок действия**, **совпадение CN/SAN с hostname** |
| **DNSBL** | Spamhaus / SpamCop / Barracuda / SORBS / PSBL, параллельно, с корректной интерпретацией кодов (SBL vs PBL vs XBL) |

---

## Быстрый запуск

```bash
# через curl (без авто-установки dig — сознательное ограничение для безопасности)
bash <(curl -sL https://raw.githubusercontent.com/spoveddd/scripts/main/linux/mxchecker/mxchecker.sh) example.com
```

## Локальный запуск

```bash
wget https://raw.githubusercontent.com/spoveddd/scripts/main/linux/mxchecker/mxchecker.sh
chmod +x mxchecker.sh
./mxchecker.sh example.com
```

В CLI-режиме (когда передан домен аргументом) скрипт при отсутствии `dig` предложит установить пакет (`dnsutils` / `bind-utils` / `bind-tools` в зависимости от дистрибутива).

---

## Опции

```
--json                   Машинно-читаемый JSON
--quiet                  Только итоги
--no-color               Отключить цвета (также работает NO_COLOR env)
--no-ipv6                Не проверять AAAA/IPv6
--dns=<server>           DNS-сервер (по умолчанию 8.8.8.8)
--dns-timeout=<sec>      Таймаут DNS (3)
--smtp-timeout=<sec>     Таймаут SMTP/TLS (10)
--parallel=<N>           Параллельных сетевых задач (8)
--dkim-selector=<s>      Доп. DKIM-селектор (можно несколько раз)
--log=<path>             Лог-файл действий
```

---

## Exit codes

| Код | Смысл |
|---|---|
| `0` | Всё хорошо |
| `1` | Есть предупреждения |
| `2` | Есть критичные проблемы |
| `3` | Ошибка запуска (невалидный домен, нет зависимостей) |

Удобно для CI/мониторинга:

```bash
mxchecker --quiet example.com || echo "Проблемы с $?"
```

---

## JSON-вывод

```bash
mxchecker --json example.com | jq '.summary, .spf, .dmarc'
```

Пример структуры:

```json
{
  "domain": "example.com",
  "status": "warning",
  "summary": { "critical": 0, "warning": 2 },
  "mx": { "hosts": ["..."], "priorities": [10], "ipv4": [...], "ipv6": [...] },
  "spf": { "present": true, "all": "-all", "lookups": 7, "uses_ptr": false },
  "dmarc": { "present": true, "policy": "reject", "sp": "" },
  "mta_sts": { "dns": true, "policy": true, "mode": "enforce" },
  "tls": { "1.2.3.4|25": { "status": "ok", "days_left": 62 } },
  "dnsbl": { "any": false, "hits": {} },
  "issues": { "critical": [], "warning": ["..."] }
}
```

---

## Требования

- **Обязательно:** `bash 4.0+`, `dig`
- **Рекомендуется:** `openssl` (TLS), `curl` (MTA-STS policy), `nc` или bash 5+ c `/dev/tcp` (SMTP-порты)
- **Опционально:** `jq` (красивый JSON-вывод), `netcat`/`ncat`

---

## Отличия от v1

- **IPv6** в MX, PTR, портах, TLS
- **Сортировка MX** по приоритету
- **Параллельные** проверки DNSBL / портов (регулятор через `--parallel`)
- **Таймауты** на все DNS-запросы (`+time=3 +tries=2`)
- **SPF**: детект нескольких записей, подсчёт 10 lookup limit, устаревший ptr
- **DMARC**: парсер учитывает `sp=`, `pct=`, пробелы, регистр
- **MTA-STS**: фактическая загрузка policy по HTTPS + проверка `mode: enforce`
- **TLS-RPT** (было: не проверялось)
- **TLS cert**: срок действия (warning <14 дней), SAN/CN-match
- **DNSBL**: корректная интерпретация кодов (PBL ≠ репутационный блок)
- **JSON-вывод** для CI/автоматизации
- **Exit codes** (0/1/2/3)
- **Цвета только в TTY**, поддержка `NO_COLOR`
- **SMTP-баннер** через `/dev/tcp` (без проблем с разными вариантами `nc`)
- **Авто-установка dig** только в CLI-режиме (не при `bash <(curl ...)`)
- **Ловушка** cleanup на выходе (удаление tmpdir)

---

## Репозиторий

[github.com/spoveddd/scripts/tree/main/linux/mxchecker](https://github.com/spoveddd/scripts/tree/main/linux/mxchecker)