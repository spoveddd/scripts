# syscheck.sh v2.0

🔍 **Быстрая проверка безопасности Linux-системы перед началом работы**

Скрипт `syscheck.sh` — это pre-flight security check, который за 5–15 секунд (quick mode) или 30–90 секунд (full mode) показывает состояние системы и помогает быстро выявить наиболее распространённые persistence-векторы, индикаторы компрометации и конфигурационные проблемы.

---

## Зачем

Многие администраторы заходят по SSH и сразу начинают работать, не проверив состояние системы. Это опасно, особенно на:

- общих/унаследованных серверах
- машинах, которые какое-то время были без присмотра
- системах после инцидентов
- хостах, про которые вы не уверены, кто туда заходил

`syscheck.sh` за пару секунд покажет: подозрительных пользователей с UID 0, изменённые authorized_keys, cron-бэкдоры, подгруженные eBPF-программы, расхождения между `ps` и `/proc`, свежие модификации в `/etc/pam.d/`, ESTABLISHED-соединения, rc-файлы с недавними изменениями и ещё ~20 типовых проверок.

---

## Что это НЕ

Чтобы не создавать ложного чувства безопасности:

- ❌ Это **не** замена HIDS (Wazuh, OSSEC, Falco)
- ❌ Это **не** замена baseline-систем (AIDE, tripwire)
- ❌ Это **не** замена антирут-сканеров (rkhunter, chkrootkit, Lynis, unhide)
- ❌ Это **не** forensic-инструмент — скомпрометированная система может лгать любому софту, работающему внутри неё

Скрипт — это быстрый **pre-flight check**. Подходит как первая линия проверки, не как последняя.

---

## Что проверяется

### Quick mode (по умолчанию, ~5–15 сек)

| # | Секция | Что ищем |
|---|---|---|
| 1 | **Целостность окружения** | `LD_PRELOAD`/`LD_AUDIT` в env и в `/etc/ld.so.preload`, подозрительный `PATH` |
| 2 | **Сессии и входы** | `who`, `last`, неудачные попытки (`lastb` — root only) |
| 3 | **Пользователи и привилегии** | UID 0 / GID 0 дубликаты, пустые пароли, `sudoers` + `NOPASSWD`, sudo-группы (sudo/wheel/admin), свежие изменения `/etc/passwd`, `/etc/shadow` |
| 4 | **SSH** | Ключевые настройки `sshd_config` (PermitRootLogin, PasswordAuthentication, AuthorizedKeysCommand), `authorized_keys` **всех** пользователей с mtime, host keys |
| 5 | **Отложенные задачи** | `/etc/crontab`, `/etc/cron.d/`, `/etc/cron.{hourly,daily,weekly,monthly}/`, user crontabs, `at`, systemd timers, `/etc/anacrontab` |
| 6 | **Persistence** | shell rc-файлы (`.bashrc`, `.profile` и т.д.) всех пользователей, `/etc/profile.d/`, `/etc/rc.local`, systemd unit-файлы с свежими изменениями, failed units, PAM-модули (включая `pam_exec`/`pam_python` и свежие `pam_*.so` не от пакета) |
| 7 | **Ядро** | Сверка `lsmod` и `/proc/modules` (детекция LKM rootkit), известные имена (Diamorphine, Reptile, Azazel и т.д.), eBPF-программы через `bpftool`, подозрительные строки в `dmesg` |
| 8 | **Процессы** | Сверка PID в `/proc` и `ps` (скрытые процессы), `LD_PRELOAD` в окружении других процессов, процессы с удалёнными бинарями, топ-5 по CPU/памяти |
| 9 | **Сеть** | LISTEN с процессами, сверка `ss` и `/proc/net/tcp` (скрытые порты), ESTABLISHED-соединения (reverse shells), UNIX-сокеты в `/tmp`/`/dev/shm`, firewall (nft/iptables) |
| 10 | **Файловая система** | Изменения в `/etc` (mtime < 2 дней), mtime/ctime несоответствия (детекция `touch -r`), исполняемые и скрытые файлы в `/tmp`, `/var/tmp`, `/dev/shm`, изменения в `/root` |
| 11 | **Состояние системы** | uptime/load, disk usage с цветовыми порогами, inode usage, журнал ошибок, неудачные SSH-входы с подсчётом, история перезагрузок |

### Full mode (добавляет ~30–60 сек, флаг `--full`)

| # | Секция | Что ищем |
|---|---|---|
| 12 | **SUID/SGID и capabilities** | Полный поиск по ФС с фильтрацией «не принадлежащих пакетам» бинарников, `getcap -r /` с маркировкой опасных capabilities (cap_sys_admin, cap_sys_module, cap_setuid и т.д.) |
| 13 | **Целостность пакетов** | `debsums -s` (Debian/Ubuntu), `rpm -Va` (RHEL/Fedora), `apk audit` (Alpine), `pacman -Qkk` (Arch) |

---

## Использование

### Быстрый запуск

```bash
bash <(curl -sL https://raw.githubusercontent.com/spoveddd/scripts/main/linux/syscheck/syscheck.sh)
```

### Локальная установка

```bash
# Скачать
curl -sL -o syscheck.sh https://raw.githubusercontent.com/spoveddd/scripts/main/linux/syscheck/syscheck.sh
chmod +x syscheck.sh

# Запустить (quick mode)
./syscheck.sh

# Полный режим — с проверкой SUID и целостности пакетов
sudo ./syscheck.sh --full

# Сохранить отчёт в файл
sudo ./syscheck.sh --full --output /var/log/syscheck-$(date +%F).txt
```

### Установить системно

```bash
sudo curl -sL -o /usr/local/bin/syscheck https://raw.githubusercontent.com/spoveddd/scripts/main/linux/syscheck/syscheck.sh
sudo chmod +x /usr/local/bin/syscheck
syscheck --help
```

### CLI-опции

```
-f, --full            Полный режим (SUID-скан, целостность пакетов)
-o, --output FILE     Сохранить полный вывод в файл
-n, --no-color        Отключить цветной вывод
-q, --quiet           Только сводка и CRIT/WARN-находки
-v, --version         Версия
-h, --help            Справка
```

### Exit codes

- `0` — всё чисто
- `1` — есть WARN (требуется внимание)
- `2` — есть CRIT (вероятная компрометация, расследуйте!)
- `3` — ошибка выполнения самого скрипта

Удобно для интеграции:

```bash
syscheck --quiet || {
    logger -t syscheck "syscheck returned non-zero"
    # тут можно отправить алерт
}
```

---

## Уровни серьёзности находок

| Уровень | Значение | Примеры |
|---|---|---|
| 🔴 **CRIT** | Высокая вероятность компрометации | Второй UID 0, непустой `/etc/ld.so.preload`, скрытые PID, расхождение `lsmod`/`/proc/modules`, LKM с именами известных rootkit, процесс с `LD_PRELOAD`, свежий PAM-модуль не от пакета, PermitRootLogin=yes |
| 🟡 **WARN** | Требует проверки, может быть легитимно | Свежие изменения в `/etc`, cron-задания, NOPASSWD-правила, ESTABLISHED к неизвестным адресам, uncommon authorized_keys, password auth в SSH |
| 🔵 **INFO** | К сведению | Массовые обновления пакетов, количество eBPF-программ, количество неудачных SSH-попыток |
| 🟢 **OK** | Проверка пройдена | — |

---

## Совместимость

**Дистрибутивы:** Debian/Ubuntu, RHEL/CentOS/Fedora/Rocky, Alpine, Arch — с graceful degradation (если утилита недоступна, её проверка пропускается с пометкой).

**Init-системы:** systemd (полная поддержка), openrc/sysvinit (частичная — пропускаются systemd-специфичные проверки).

**Контейнеры:** Docker/Podman/LXC/Kubernetes — автодетект, kernel-проверки (lsmod, eBPF, dmesg) пропускаются, так как ядро хоста.

**Без root:** работает, но с урезанным покрытием. Недоступны: `/etc/shadow`, `/var/spool/cron/*`, `authorized_keys` чужих пользователей, имена процессов за чужими портами, `lastb`, полный `dmesg`, проверка environment других PID, debsums/rpm -Va.

---

## Производительность

На reference-системе (Ubuntu 24.04, 4 CPU, 4 GB RAM, SSD):

| Режим | Время |
|---|---|
| `quick` | ~5–10 сек |
| `quick --quiet` | ~5 сек |
| `full` | ~30–60 сек (доминирует `find / -perm` и `debsums`) |

Все внешние команды обёрнуты в `timeout` (по умолчанию 3–5 сек на команду), чтобы зависший `journalctl` или `ss` не подвесил весь скрипт.

---

## Что этот скрипт НЕ обнаружит

Честный список для калибровки ожиданий:

- Руткит, скрывающий себя одинаково от `ps`, `ss`, `/proc` и `lsmod` (мощные LKM/eBPF-руткиты перехватывают всё сразу — детектируется только через внешнюю систему)
- Бэкдор, встроенный в легитимный бинарь пакета (если хэши в базе пакетного менеджера тоже подменены)
- Persistence через внешние механизмы: initrd, GRUB, UEFI, firmware
- C2, использующие DNS-tunneling или легитимные каналы (Telegram/Discord/GitHub webhooks)
- Compromised bastion в сети (атака не на этот хост)
- Компрометация на уровне гипервизора для VM
- Supply-chain атаки в зависимостях приложений (pip/npm/cargo packages)

**Если есть реальные подозрения на компрометацию:** изолируйте хост и анализируйте со снимка диска с доверенной системы. Живой хост может лгать.

---

## Примеры вывода

### Чистая система

```
🔍 syscheck.sh v2.0 — security pre-flight check
Время:       2026-04-21 10:00:00 UTC
Хост:        prod-web-01
Kernel:      Linux 6.8.0-45-generic
Дистрибутив: Ubuntu 24.04.2 LTS
Init:        systemd
Pkg mgr:     dpkg
Режим:       quick

=== ЦЕЛОСТНОСТЬ ОКРУЖЕНИЯ ===
    ✓ /etc/ld.so.preload отсутствует

=== ПОЛЬЗОВАТЕЛИ И ПРИВИЛЕГИИ ===
    ✓ UID 0 только у root
    ...

=== ИТОГОВАЯ СВОДКА ===
    Время выполнения: 7 сек
    CRIT: 0  WARN: 0  INFO: 2

    ✓ Базовые проверки пройдены
```

### Скомпрометированная система

```
=== ЦЕЛОСТНОСТЬ ОКРУЖЕНИЯ ===
    ✗ /etc/ld.so.preload НЕПУСТОЙ (возможен LD_PRELOAD rootkit):
      /usr/lib/libxstat.so

=== ПОЛЬЗОВАТЕЛИ И ПРИВИЛЕГИИ ===
    ✗ Пользователи с UID 0 помимо root:
      backup_admin

=== SSH КОНФИГУРАЦИЯ И КЛЮЧИ ===
    ⚠ www-data: /var/www/.ssh/authorized_keys (1 ключ(ей), mtime 2026-04-20 — СВЕЖАЯ модификация)

=== ЯДРО: МОДУЛИ И eBPF ===
    ✗ Модули с именами известных rootkit: diamorphine

=== ИТОГОВАЯ СВОДКА ===
    CRIT: 3  WARN: 2  INFO: 0
    ✗ КРИТИЧЕСКИЕ ПРОБЛЕМЫ — возможна компрометация
    Требуется немедленное расследование с доверенной системы
```

---

## Рекомендуемая связка инструментов

`syscheck.sh` — это **первая линия**. Для production используйте:

- **Baseline integrity:** [AIDE](https://aide.github.io/) или [tripwire](https://github.com/Tripwire/tripwire-open-source) — сравнивает текущее состояние с известно-чистым снимком
- **HIDS / realtime:** [Wazuh](https://wazuh.com/), [OSSEC](https://www.ossec.net/), [Falco](https://falco.org/) (для контейнеров)
- **Rootkit scanners:** `rkhunter`, `chkrootkit`, `unhide`, [Linux Malware Detect (LMD)](https://www.rfxn.com/projects/linux-malware-detect/)
- **Общий аудит:** [Lynis](https://cisofy.com/lynis/) — глубокий security audit (запускать раз в неделю/месяц)
- **Audit daemon:** `auditd` с нормальным правилом-сетом (например, [Neo23x0/auditd](https://github.com/Neo23x0/auditd))
- **eBPF runtime security:** Falco, [Tetragon](https://github.com/cilium/tetragon), [Tracee](https://github.com/aquasecurity/tracee)

---

## Требования

- Linux с bash ≥ 4.0
- Стандартные утилиты: `ps`, `find`, `stat`, `awk`, `grep`, `sort`, `comm`
- Желательно: `ss`, `systemctl`, `journalctl`, `bpftool`, `getcap`, `dpkg`/`rpm`
- Отсутствующие утилиты обрабатываются gracefully (проверка пропускается)

---

## Лицензия

MIT

## Обратная связь

Telegram: @sysadminctl