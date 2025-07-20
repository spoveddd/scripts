# firewiz — Универсальный интерактивный менеджер firewall для Linux

**by Vladislav Pavlovich**

---

## Описание

`firewiz` — это мощный и удобный интерактивный скрипт для управления всеми основными системами firewall в Linux:  
- **iptables**
- **ip6tables**
- **nftables**
- **ufw**
- **firewalld**

Скрипт автоматически определяет, какие firewall-системы установлены и активны, и позволяет:
- Просматривать текущие правила в удобном и цветном виде
- Добавлять и удалять правила (по портам, протоколам, IP, подсетям)
- Блокировать адреса одной командой
- Сохранять и восстанавливать конфигурации firewall
- Включать/отключать firewall
- Работать с systemd и init

---

## Скачивание и запуск

### Способ 1: Скачать и запустить одной командой

```bash
wget https://raw.githubusercontent.com/spoveddd/scripts/main/linux/firewiz/firewiz.sh -O firewiz.sh && chmod +x firewiz.sh && sudo ./firewiz.sh
```

### Способ 2: Установка вручную

1. Скачайте скрипт:
    ```bash
    wget https://raw.githubusercontent.com/spoveddd/scripts/main/linux/copy_site/firewiz.sh
    ```
2. Установите права на выполнение:
    ```bash
    chmod +x firewiz.sh
    ```
3. Запустите скрипт:
    ```bash
    sudo ./firewiz.sh
    ```

---


## Возможности

- **Автоматическое определение и поддержка всех популярных firewall**
- **Интерактивное меню** — не нужно помнить синтаксис команд
- **Цветной и структурированный вывод**
- **Безопасность** — автоматические бэкапы перед отключением, восстановление из бэкапа
- **Проверка валидности IP/подсетей**
- **Быстрая блокировка адреса одной командой**
- **Работает на большинстве современных Linux-дистрибутивов**

---

## Пример меню

```
===== Linux Firewall Analyzer =====
===== by Vladislav Pavlovich =====

Обнаружены firewall-системы:  ufw nftables iptables ip6tables
Init-система: systemd

Меню:
1 - Показать правила
2 - Добавить правило
3 - Удалить правило
4 - Заблокировать адрес полностью
5 - Сохранить изменения
6 - Включить/отключить firewall
7 - Восстановить правила из бэкапа
0 - Выход
```

---

## Требования

- Linux (Debian, Ubuntu, CentOS, RHEL, Fedora и др.)
- bash
- root-права
- Установленные утилиты: `iptables`, `ip6tables`, `nft`, `ufw`, `firewalld`, `tput`, `awk`, `grep`, `systemctl`/`service` (в зависимости от дистрибутива)

---

## Лицензия

MIT

---

## Автор

[Vladislav Pavlovich](https://github.com/spoveddd)

--- 