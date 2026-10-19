#!/usr/bin/env bash
# fix-ssh.sh — возвращает доступ по SSH (порт 22). Запускать под root в веб-консоли хостинга:
#     bash fix-ssh.sh
# Ничего не удаляет и не ломает бота: только проверяет и чинит SSH-службу, файрвол и баны.
set -u
G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'
say(){ echo "${G}✔${N} $*"; }; warn(){ echo "${Y}!${N} $*"; }; err(){ echo "${R}✘${N} $*"; }
[[ $EUID -eq 0 ]] || { err "Запусти под root (sudo -i)"; exit 1; }

echo "== 0. Диск и память =="
df -h / | tail -1; free -m | sed -n 2p
USE=$(df / --output=pcent | tail -1 | tr -dc 0-9)
if [[ ${USE:-0} -ge 97 ]]; then
  warn "Диск почти полон — чищу кэш и журналы"
  apt-get clean 2>/dev/null; journalctl --vacuum-size=50M >/dev/null 2>&1 || true
fi

echo "== 1. SSH-сервер =="
if ! command -v sshd >/dev/null 2>&1 && [[ ! -x /usr/sbin/sshd ]]; then
  warn "openssh-server не установлен — ставлю"
  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server
fi
mkdir -p /run/sshd
CFG=/etc/ssh/sshd_config
[[ -f $CFG.bak-fix ]] || cp -a $CFG $CFG.bak-fix
if ! sshd -t 2>/tmp/sshd_err; then
  err "Конфиг sshd с ошибкой: $(cat /tmp/sshd_err)"
  if [[ -f $CFG.bak-fix ]]; then cp -a $CFG.bak-fix $CFG; warn "Вернул сохранённый конфиг"; fi
  sshd -t || { err "Конфиг всё ещё не проходит проверку"; }
fi
# порт(ы), на которых должен слушать sshd
PORTS="$(sshd -T 2>/dev/null | awk '/^port /{print $2}' | sort -u | tr '\n' ' ')"
PORTS="${PORTS:-22}"
say "sshd должен слушать порт(ы): $PORTS"
systemctl unmask ssh sshd ssh.socket 2>/dev/null || true
systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
sleep 2
for p in $PORTS; do
  if ss -ltn "( sport = :$p )" | grep -q LISTEN; then say "порт $p слушается"; else err "порт $p НЕ слушается — смотри: journalctl -u ssh -n 30 --no-pager"; fi
done

echo "== 2. Файрвол =="
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  for p in $PORTS; do ufw allow "$p"/tcp >/dev/null && say "ufw: порт $p разрешён"; done
  ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
else
  say "ufw не активен — не мешает"
fi
# явные блокировки в iptables/nft
for p in $PORTS; do
  while iptables -C INPUT -p tcp --dport "$p" -j DROP 2>/dev/null; do iptables -D INPUT -p tcp --dport "$p" -j DROP; warn "удалил DROP для порта $p"; done
  while iptables -C INPUT -p tcp --dport "$p" -j REJECT 2>/dev/null; do iptables -D INPUT -p tcp --dport "$p" -j REJECT; warn "удалил REJECT для порта $p"; done
  iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
done

echo "== 3. Баны (fail2ban) =="
if command -v fail2ban-client >/dev/null 2>&1; then
  fail2ban-client unban --all >/dev/null 2>&1 && say "все баны fail2ban сняты" || warn "fail2ban не ответил"
else
  say "fail2ban не установлен"
fi

echo "== 4. Итог =="
ss -ltnp | grep -E ":($(echo $PORTS | tr ' ' '|'))\b" || true
IP="$(curl -fsS -m 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
echo
say "Готово. Пробуй: ssh root@$IP -p $(echo $PORTS | awk '{print $1}')"
echo "Если снаружи всё равно не заходит — закрыт порт в панели хостинга (Firewall / Security Group) или в вашей сети."
echo "Проверь: с телефона через мобильный интернет или с VPN."
