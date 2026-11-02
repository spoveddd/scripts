#!/bin/bash
# CVE-2026-98432 — проверка: фикс в работающем ядре / установлен, но не загружен / доступен в репо / защита
PAT='CVE-2026-98432|free inet_opt and ireq_opt'
R=$(uname -r); . /etc/os-release 2>/dev/null; ID=${ID:-unknown}
say(){ printf '%-22s %s\n' "$1" "$2"; }
say "Хост:" "$(hostname)  $PRETTY_NAME  ядро $R"

# Контейнер (OpenVZ/LXC) — ядро хоста, внутри ничего не исправить
if [ -d /proc/vz ] && [ ! -d /proc/bc ] || grep -qa 'container=' /proc/1/environ 2>/dev/null; then
  say "ИТОГ:" "КОНТЕЙНЕР — ядро общее с нодой, проверять и чинить на ноде"; exit 0; fi

# Debian: сравнение версии пакета с исправленными (DSA-6568-1 / DLA-4841-1 / DLA-4850-1)
deb_fixed(){ local v=$1 f=""
  case $v in 6.1.*) f=6.1.190-1;; 6.12.*) f=6.12.113-1;; 6.18.*) f=6.18.56-1;; 7.*) f=7.2.13-1;; *) return 2;; esac
  dpkg --compare-versions "$v" ge "$f"; }

# Есть ли фикс в конкретной версии ядра (аргумент: uname-строка ядра)
kfixed(){ local k=$1 v
  if command -v dpkg >/dev/null; then
    if [ "$ID" = debian ]; then v=$(dpkg-query -W -f='${Version}' "linux-image-$k" 2>/dev/null || dpkg-query -W -f='${Version}' "linux-image-$k-unsigned" 2>/dev/null)
      if [ -n "$v" ]; then deb_fixed "$v"; r=$?; [ $r != 2 ] && return $r; fi; fi
    zgrep -qE "$PAT" /usr/share/doc/linux-{modules,image}-"$k"*/changelog.Debian.gz 2>/dev/null && return 0
    ls /usr/share/doc/linux-{modules,image}-"$k"*/changelog.Debian.gz >/dev/null 2>&1 && return 1; return 2
  elif command -v rpm >/dev/null; then
    { rpm -q --changelog "kernel-core-$k" 2>/dev/null || rpm -q --changelog "kernel-$k" 2>/dev/null || rpm -q --changelog "kernel-uek-core-$k" 2>/dev/null || rpm -q --changelog "kernel-uek-$k" 2>/dev/null; } | grep -qE "$PAT" && return 0
    rpm -q "kernel-core-$k" "kernel-$k" "kernel-uek-$k" 2>/dev/null | grep -qv 'not installed' && return 1; return 2
  fi; return 2; }

kfixed "$R"; RUN=$?
case $RUN in 0) say "Работающее ядро:" "ИСПРАВЛЕНО";; 1) say "Работающее ядро:" "уязвимо";; *) say "Работающее ядро:" "не определить (нестандартное ядро: pve/кастом?)";; esac

# Установленные, но не загруженные ядра
INST=""
if command -v dpkg >/dev/null; then
  for d in /lib/modules/*; do k=${d##*/}; [ -d "$d" ] && [ "$k" != "$R" ] && kfixed "$k" && INST="$INST $k"; done
elif command -v rpm >/dev/null; then
  for k in $(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core kernel kernel-uek 2>/dev/null | grep -v 'not installed'); do [ "$k" != "$R" ] && kfixed "$k" && INST="$INST $k"; done
fi
[ -n "$INST" ] && say "Установлено с фиксом:" "$INST  -> НУЖНА ПЕРЕЗАГРУЗКА"

# Доступно в репозиториях
AV=""
if command -v apt-get >/dev/null; then
  apt-get update -qq >/dev/null 2>&1
  for m in $(dpkg-query -W -f='${Package} ${Status}\n' 'linux-image-*' 2>/dev/null | awk '/ installed$/ && $1 !~ /^linux-image-[0-9]/ {print $1}'); do
    c=$(apt-cache policy "$m" | awk '/Candidate:/{print $2}')
    if [ "$ID" = debian ]; then deb_fixed "$c" && AV="$AV $m=$c"
    else dep=$(apt-cache depends "$m" 2>/dev/null | awk '/Depends: linux-image-[0-9]/{print $2; exit}')
      [ -n "$dep" ] && timeout 60 apt-get changelog "$dep" 2>/dev/null | grep -qE "$PAT" && AV="$AV $dep"; fi
  done
elif command -v dnf >/dev/null || command -v yum >/dev/null; then
  P=$(command -v dnf || command -v yum)
  $P -q updateinfo list --cve CVE-2026-98432 2>/dev/null | grep -q kernel && AV=" $($P -q updateinfo list --cve CVE-2026-98432 2>/dev/null | awk '/kernel/{print $NF}' | sort -u | tr '\n' ' ')"
fi
if [ -n "$AV" ]; then say "В репозитории:" "фикс ЕСТЬ:$AV"; else say "В репозитории:" "фикса нет"; fi

# Защита и MPTCP
MIT=no
nft list table ip cve_2026_98432 >/dev/null 2>&1 && MIT=nft
iptables -t raw -S PREROUTING 2>/dev/null | grep -q 'CVE-2026-98432' && MIT=iptables
say "Правило-блок:" "$MIT"
M=$(sysctl -n net.mptcp.enabled 2>/dev/null); L=$(ss -lnMH 2>/dev/null | wc -l)
say "MPTCP:" "enabled=${M:-нет в ядре}, слушателей=$L"
[ "$(sysctl -n net.ipv4.tcp_migrate_req 2>/dev/null)" = 1 ] && say "tcp_migrate_req:" "1 (второй путь атаки открыт!)"

if [ $RUN = 0 ]; then V="OK — исправлено, правило можно снять"
elif [ -n "$INST" ]; then V="ПЕРЕЗАГРУЗИТЬ — фикс установлен"
elif [ -n "$AV" ]; then V="ОБНОВИТЬ ЯДРО И ПЕРЕЗАГРУЗИТЬ"
elif [ $MIT != no ]; then V="уязвимо, но ЗАЩИЩЕНО правилом — ждать ядро"
else V="УЯЗВИМО — ставить правило"; fi
say "ИТОГ:" "$V"