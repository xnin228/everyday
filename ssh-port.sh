#!/usr/bin/env bash
# ssh-port.sh — безопасная смена порта SSH.
#   bash ssh-port.sh            -> порт 24822, ОБА порта (22 и новый) работают — можно проверить и не потерять доступ
#   bash ssh-port.sh 33777      -> свой порт
#   bash ssh-port.sh 33777 only -> оставить ТОЛЬКО новый порт (делай после того, как проверил вход по новому)
# Не закрывай текущее окно SSH, пока не зайдёшь по новому порту во втором окне.
set -euo pipefail
PORT="${1:-24822}"; MODE="${2:-both}"
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
say(){ echo -e "${G}[+]${N} $*"; }; warn(){ echo -e "${Y}[!]${N} $*"; }; err(){ echo -e "${R}[x]${N} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "Запусти от root."
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1024 && PORT <= 65535 )) || err "Порт должен быть числом 1024–65535."
(( PORT == 80 || PORT == 443 || PORT == 3000 || PORT == 3001 )) && err "Порт $PORT занят под игру/Caddy, выбери другой."
if ss -tln | awk '{print $4}' | grep -qE "[:.]${PORT}$"; then
  # свой же sshd на этом порту — это нормально при повторном запуске
  ss -tlnp | grep -E "[:.]${PORT} " | grep -q sshd || err "Порт $PORT уже занят другой программой."
fi

PORTS="$PORT"; [[ "$MODE" == "only" ]] || PORTS="22 $PORT"
CFG=/etc/ssh/sshd_config; BK="/root/sshd-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK"; cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.d "$BK/" 2>/dev/null || true
say "Копия настроек SSH: $BK"

# 1. убираем старые Port из основного конфига и drop-in файлов (они бы перебили наш)
sed -i -E 's/^[[:space:]]*Port[[:space:]]+.*/# &/' "$CFG"
for f in /etc/ssh/sshd_config.d/*.conf; do [[ -f "$f" ]] && sed -i -E 's/^[[:space:]]*Port[[:space:]]+.*/# &/' "$f"; done
mkdir -p /etc/ssh/sshd_config.d
{ echo "# ssh-port.sh"; for p in $PORTS; do echo "Port $p"; done; } > /etc/ssh/sshd_config.d/00-port.conf
grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d' "$CFG" || { { for p in $PORTS; do echo "Port $p"; done; echo; cat "$CFG"; } > "$CFG.new" && mv "$CFG.new" "$CFG"; }
sshd -t || { rm -f /etc/ssh/sshd_config.d/00-port.conf; cp -a "$BK/sshd_config" "$CFG"; err "Конфиг SSH не прошёл проверку — вернул как было."; }

# 2. брандмауэр: открываем новый порт
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow "$PORT/tcp" >/dev/null && say "ufw: порт $PORT открыт"
elif command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="$PORT/tcp" >/dev/null && firewall-cmd --reload >/dev/null && say "firewalld: порт $PORT открыт"
elif command -v iptables >/dev/null; then
  iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
  say "iptables: порт $PORT открыт (до перезагрузки; если у тебя iptables-persistent — сохрани: netfilter-persistent save)"
fi

# 3. Ubuntu 22.10+/24.04: порт задаёт ssh.socket, а не sshd_config
if systemctl list-unit-files 2>/dev/null | grep -q '^ssh.socket' && systemctl is-active --quiet ssh.socket; then
  mkdir -p /etc/systemd/system/ssh.socket.d
  { echo "[Socket]"; echo "ListenStream="; for p in $PORTS; do echo "ListenStream=0.0.0.0:$p"; echo "ListenStream=[::]:$p"; done; } > /etc/systemd/system/ssh.socket.d/port.conf
  systemctl daemon-reload; systemctl restart ssh.socket
  say "ssh.socket перенастроен"
fi

# 4. перезапуск SSH (текущие сессии не обрываются)
if systemctl list-unit-files 2>/dev/null | grep -q '^ssh.service'; then systemctl restart ssh; else systemctl restart sshd; fi
sleep 1
if ! ss -tln | awk '{print $4}' | grep -qE "[:.]${PORT}$"; then
  warn "SSH не слушает порт $PORT — откатываю."
  rm -f /etc/ssh/sshd_config.d/00-port.conf /etc/systemd/system/ssh.socket.d/port.conf
  cp -a "$BK/sshd_config" "$CFG"; systemctl daemon-reload
  systemctl restart ssh.socket 2>/dev/null || true; systemctl restart ssh 2>/dev/null || systemctl restart sshd
  err "Откатил. Копия: $BK"
fi

IP=$(curl -s -m 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
say "Готово. SSH слушает: $(ss -tln | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un | tr '\n' ' ')"
echo
echo "  Проверь во ВТОРОМ окне:  ssh -p $PORT root@$IP"
echo "  Если зашёл — выключи 22:  bash ssh-port.sh $PORT only"
echo "  В панели хостера (если там есть файрвол) тоже открой TCP $PORT."
