#!/bin/bash
# CVE-2026-98432 — временная защита: режем IPv4 TCP с IP-опциями + выключаем MPTCP. Постоянно (systemd).
# Снять: bash cve98432-block.sh --undo
set -u
[ "$(id -u)" = 0 ] || { echo "нужен root"; exit 1; }
U=/etc/systemd/system/cve-2026-98432.service; NF=/etc/cve-2026-98432.nft; SC=/etc/sysctl.d/90-cve-2026-98432-mptcp.conf
IPT_ARGS='-p tcp -m u32 --u32 0>>24&0xF=6:15 -m comment --comment CVE-2026-98432 -j DROP'

if [ "${1:-}" = --undo ]; then
  systemctl disable --now cve-2026-98432 2>/dev/null; rm -f "$U" "$NF" "$SC"; systemctl daemon-reload
  nft delete table ip cve_2026_98432 2>/dev/null
  while iptables -t raw -D PREROUTING $IPT_ARGS 2>/dev/null; do :; done
  sysctl -qw net.mptcp.enabled=1 2>/dev/null; echo "Снято."; exit 0; fi

if [ -d /proc/vz ] && [ ! -d /proc/bc ] || grep -qa 'container=' /proc/1/environ 2>/dev/null; then
  echo "Это контейнер (OpenVZ/LXC) — правило ставится на ноде, не здесь."; exit 1; fi

# 1. Правило: nft, если работает, иначе iptables u32
if command -v nft >/dev/null && nft list tables >/dev/null 2>&1; then
  cat > "$NF" <<'EOF'
table ip cve_2026_98432
delete table ip cve_2026_98432
table ip cve_2026_98432 {
  chain pre {
    type filter hook prerouting priority -300; policy accept;
    meta l4proto tcp ip hdrlength gt 5 counter drop
  }
}
EOF
  START="$(command -v nft) -f $NF"; STOP="$(command -v nft) delete table ip cve_2026_98432"; MODE=nft
else
  modprobe xt_u32 2>/dev/null
  IPT=$(command -v iptables)
  START="-$IPT -t raw -D PREROUTING $IPT_ARGS
ExecStart=$IPT -t raw -I PREROUTING $IPT_ARGS"
  STOP="$IPT -t raw -D PREROUTING $IPT_ARGS"; MODE=iptables
fi

cat > "$U" <<EOF
[Unit]
Description=CVE-2026-98432 mitigation (drop IPv4 TCP with IP options)
After=network-pre.target nftables.service firewalld.service iptables.service netfilter-persistent.service
PartOf=nftables.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$START
ExecStop=$STOP
[Install]
WantedBy=multi-user.target nftables.service
EOF
systemctl daemon-reload && systemctl enable cve-2026-98432 >/dev/null 2>&1 && systemctl restart cve-2026-98432
if [ $MODE = nft ]; then nft list table ip cve_2026_98432 >/dev/null 2>&1 && R=OK || R=FAIL
else iptables -t raw -C PREROUTING $IPT_ARGS 2>/dev/null && R=OK || R=FAIL; fi
echo "Правило ($MODE): $R"

# 2. MPTCP
if sysctl -n net.mptcp.enabled >/dev/null 2>&1; then
  echo 'net.mptcp.enabled = 0' > "$SC"; sysctl -qw net.mptcp.enabled=0; echo "MPTCP: выключен"
  L=$(ss -lnMpH 2>/dev/null); [ -n "$L" ] && { echo "MPTCP-слушатели остались — перезапустить их сервисы:"; echo "$L"; }
fi
[ "$(sysctl -n net.ipv4.tcp_migrate_req 2>/dev/null)" = 1 ] && echo "ВНИМАНИЕ: net.ipv4.tcp_migrate_req=1 — проверь, зачем, и по возможности поставь 0"
[ $R = OK ]