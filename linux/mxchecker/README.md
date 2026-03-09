# mxchecker

Bash-скрипт для проверки почтовой инфраструктуры домена.

Проверяет: A, MX, PTR, SPF, DKIM, DMARC, MTA-STS, SMTP-порты, TLS/StartTLS, DNSBL.

---

## Быстрый запуск

```bash
bash <(curl -s https://raw.githubusercontent.com/spoveddd/scripts/main/linux/mxchecker/mxchecker.sh)
```

Скрипт запросит домен и выполнит полную проверку.

---

## Локальный запуск

```bash
wget https://raw.githubusercontent.com/spoveddd/scripts/main/linux/mxchecker/mxchecker.sh
chmod +x mxchecker.sh
./mxchecker.sh example.com
```

---

## Что проверяется

| Проверка | Описание |
|---|---|
| DNS A / MX / PTR | Наличие записей и совпадение PTR с MX |
| SPF | Наличие и строгость политики (-all / ~all / +all) |
| DKIM | Поиск по популярным селекторам |
| DMARC | Политика p= и защита субдоменов sp= |
| MTA-STS | Защита от StartTLS-downgrade |
| SMTP-порты | Доступность 25 / 465 / 587 |
| TLS/StartTLS | Валидность сертификатов |
| DNSBL | Проверка IP в Spamhaus, SpamCop, Barracuda |

---

## Требования

- `dig` или `host`
- `nc` / `ncat` / `netcat`
- `openssl`
- Права обычного пользователя (root не нужен)

---

## Репозиторий

[github.com/spoveddd/scripts](https://github.com/spoveddd/scripts/tree/main/linux/mxchecker)