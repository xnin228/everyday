#!/usr/bin/env bash
# standby.sh — РЕЗЕРВНЫЙ сервер «Мини-фермы» (горячий резерв с копией данных).
#
#   bash standby.sh setup      — установка на НОВЫЙ сервер: тянет код и данные с основного, ставит всё, но бота НЕ запускает
#   bash standby.sh sync       — разовая синхронизация (по таймеру запускается сама каждые 5 минут)
#   bash standby.sh status     — состояние: свежесть копии, доступен ли основной сервер
#   bash standby.sh failover   — ОСНОВНОЙ УПАЛ: запустить бота здесь (спросит подтверждение; --force без вопросов)
#   bash standby.sh rearm      — вернуть режим резерва (после того как основной снова работает): остановить бота здесь
#
# ВАЖНО: бота с одним токеном нельзя запускать на двух серверах сразу (конфликт 409, двойная обработка платежей).
# Поэтому здесь бот выключен, пока ты сам не сделаешь failover.
# Запуск от root на новом сервере (Ubuntu/Debian). Повторный запуск безопасен.
set -euo pipefail

APP_DIR="${APP_DIR:-/root/farm-bot}"
CONF=/root/.standby.conf
KEY=/root/.ssh/standby_key
WWW_DIR=/var/www/minifarm
GAME_URL="${GAME_URL:-https://xnin228.github.io/everyday/}"; GAME_URL="${GAME_URL%/}/"
ORIGIN="$(echo "$GAME_URL" | sed -E 's#^(https?://[^/]+).*#\1#')"
SELF="/root/standby.sh"

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
say(){ echo -e "${G}[+]${N} $*"; }; warn(){ echo -e "${Y}[!]${N} $*"; }; err(){ echo -e "${R}[x]${N} $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || err "Запусти от root."

CMD="${1:-}"
load_conf(){ [[ -f "$CONF" ]] && source "$CONF" || true; }
ssh_cmd(){ echo "ssh -i $KEY -p ${P_PORT:-22} -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"; }
my_ip(){ curl -s -m 6 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}'; }
env_get(){ grep -E "^$1=" "$APP_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "\"'" || true; }
set_env(){ local k="$1" v="$2"; touch "$APP_DIR/.env"; if grep -qE "^$k=" "$APP_DIR/.env"; then sed -i "s#^$k=.*#$k=$v#" "$APP_DIR/.env"; else echo "$k=$v" >> "$APP_DIR/.env"; fi; }

# ---------- синхронизация ----------
do_sync(){
  load_conf; [[ -n "${P_HOST:-}" ]] || err "Нет настроек основного сервера. Сначала: bash standby.sh setup"
  local SSH; SSH="$(ssh_cmd)"
  # код и данные (кроме .env, venv и бэкапов); .env берётся только при установке
  rsync -az -e "$SSH" --timeout=60 \
    --include='*.py' --include='*.json' --include='requirements.txt' --include='*.txt' \
    --exclude='.env*' --exclude='venv/' --exclude='backup-*/' --exclude='__pycache__/' --exclude='*' \
    "root@$P_HOST:/root/farm-bot/" "$APP_DIR/" || return 1
  rsync -az -e "$SSH" --timeout=60 "root@$P_HOST:$WWW_DIR/" "$WWW_DIR/" 2>/dev/null || true
  date +%s > /root/.standby.last
}

# ---------- setup ----------
do_setup(){
  say "Ставлю пакеты…"
  export DEBIAN_FRONTEND=noninteractive
  for _i in $(seq 1 60); do fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/lib/dpkg/lock >/dev/null 2>&1 || break; sleep 5; done
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y python3 python3-venv python3-pip curl rsync openssh-client ca-certificates >/dev/null 2>&1 || err "Не удалось поставить пакеты (apt)."

  load_conf
  P_HOST="${P_HOST:-${PRIMARY:-}}"; P_PORT="${P_PORT:-${PRIMARY_PORT:-22}}"
  [[ -n "$P_HOST" ]] || read -rp "IP основного сервера: " P_HOST
  [[ -n "$P_HOST" ]] || err "Нужен IP основного сервера."
  if [[ -t 0 && -z "${PRIMARY_PORT:-}" ]]; then read -rp "SSH-порт основного сервера [${P_PORT}]: " _p; P_PORT="${_p:-$P_PORT}"; fi
  printf 'P_HOST=%s\nP_PORT=%s\n' "$P_HOST" "$P_PORT" > "$CONF"; chmod 600 "$CONF"

  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  [[ -f "$KEY" ]] || ssh-keygen -t ed25519 -N '' -f "$KEY" -C "minifarm-standby" >/dev/null
  if ! $(ssh_cmd) "root@$P_HOST" true 2>/dev/null; then
    say "Нужно один раз войти на основной сервер по паролю, чтобы разрешить доступ резерву."
    ssh-copy-id -i "$KEY.pub" -p "$P_PORT" -o StrictHostKeyChecking=accept-new "root@$P_HOST" || err "Не удалось войти на основной сервер ($P_HOST:$P_PORT)."
    $(ssh_cmd) "root@$P_HOST" true || err "Вход по ключу не заработал."
  fi
  say "Доступ к основному серверу есть."

  mkdir -p "$APP_DIR" "$WWW_DIR"
  say "Копирую код и данные с основного сервера…"
  rsync -az -e "$(ssh_cmd)" --timeout=120 --exclude='venv/' --exclude='backup-*/' --exclude='__pycache__/' --exclude='*.log' \
    "root@$P_HOST:/root/farm-bot/" "$APP_DIR/" || err "Копирование не удалось."
  rsync -az -e "$(ssh_cmd)" "root@$P_HOST:$WWW_DIR/" "$WWW_DIR/" 2>/dev/null || true
  [[ -f "$APP_DIR/server.py" && -f "$APP_DIR/.env" ]] || err "На основном сервере не нашёл /root/farm-bot/server.py или .env."
  date +%s > /root/.standby.last

  say "Ставлю окружение Python…"
  [[ -x "$APP_DIR/venv/bin/python3" ]] || python3 -m venv "$APP_DIR/venv"
  "$APP_DIR/venv/bin/pip" install --upgrade pip wheel >/dev/null
  [[ -f "$APP_DIR/requirements.txt" ]] && "$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt" >/dev/null
  "$APP_DIR/venv/bin/pip" install -U "pyTelegramBotAPI>=4.14" >/dev/null

  say "Создаю сервисы (выключены)…"
  for S in minifarm minifarm-pay; do
    EXE=server.py; [[ $S == minifarm-pay ]] && EXE=payments_http.py
    cat > "/etc/systemd/system/$S.service" <<EOF
[Unit]
Description=Mini Farm ($S)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/python3 $APP_DIR/$EXE
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  done
  systemctl daemon-reload
  systemctl disable --now minifarm minifarm-pay >/dev/null 2>&1 || true

  # Caddy: HTTPS-адрес этого сервера (<ip>.sslip.io)
  PORT_VAL="$(env_get PORT)"; PORT_VAL="${PORT_VAL:-3000}"
  IP="$(my_ip)"; DOMAIN="${DOMAIN:-${IP//./-}.sslip.io}"
  say "Ставлю Caddy для $DOMAIN…"
  if ! command -v caddy >/dev/null; then
    apt-get install -y caddy >/dev/null 2>&1 || {
      apt-get install -y debian-keyring debian-archive-keyring apt-transport-https gpg >/dev/null 2>&1 || true
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
      apt-get update -y >/dev/null 2>&1; apt-get install -y caddy >/dev/null 2>&1 || err "Не удалось поставить Caddy."
    }
  fi
  cat > /etc/caddy/Caddyfile <<EOF
# >>> minifarm >>>
$DOMAIN {
    encode gzip

    @preflight method OPTIONS
    handle @preflight {
        header Access-Control-Allow-Origin "$ORIGIN"
        header Access-Control-Allow-Methods "GET, POST, OPTIONS"
        header Access-Control-Allow-Headers "Content-Type"
        header Access-Control-Max-Age "86400"
        respond 204
    }

    @pay path /invoice /claim /snap /farms /farm
    handle @pay {
        reverse_proxy 127.0.0.1:3001 {
            header_down Access-Control-Allow-Origin "$ORIGIN"
            header_down Vary "Origin"
        }
    }

    handle_path /game/* {
        root * $WWW_DIR
        header Cache-Control "no-cache, must-revalidate"
        file_server
    }

    handle {
        reverse_proxy 127.0.0.1:$PORT_VAL {
            header_down Access-Control-Allow-Origin "$ORIGIN"
            header_down Vary "Origin"
        }
    }
}
# <<< minifarm <<<
EOF
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || err "Caddyfile не прошёл проверку."
  systemctl enable caddy >/dev/null 2>&1 || true; systemctl restart caddy
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null; fi

  # автосинхронизация каждые 5 минут
  cp -f "$(readlink -f "$0")" "$SELF" 2>/dev/null || true; chmod +x "$SELF"
  cat > /etc/systemd/system/minifarm-sync.service <<EOF
[Unit]
Description=Mini Farm standby sync
[Service]
Type=oneshot
ExecStart=/bin/bash $SELF sync
EOF
  cat > /etc/systemd/system/minifarm-sync.timer <<EOF
[Unit]
Description=Mini Farm standby sync every 5 min
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload; systemctl enable --now minifarm-sync.timer >/dev/null 2>&1

  echo
  say "РЕЗЕРВНЫЙ СЕРВЕР ГОТОВ. Бот здесь выключен, данные копируются с основного раз в 5 минут."
  echo "   Адрес резерва:  https://$DOMAIN"
  echo "   Проверка:       bash $SELF status"
  echo "   Если основной упал:  bash $SELF failover"
}

# ---------- status ----------
do_status(){
  load_conf
  local last; last=$(cat /root/.standby.last 2>/dev/null || echo 0)
  local age=$(( $(date +%s) - last ))
  [[ $last -gt 0 ]] && say "Последняя синхронизация: $((age/60)) мин назад" || warn "Синхронизаций ещё не было"
  [[ $age -gt 1800 ]] && warn "Копия старше 30 минут — проверь: systemctl status minifarm-sync.timer; bash $SELF sync"
  for S in minifarm minifarm-pay caddy; do echo "  $S: $(systemctl is-active $S 2>/dev/null || true)"; done
  if [[ -n "${P_HOST:-}" ]]; then
    local pd="${P_HOST//./-}.sslip.io"
    if curl -fsS -m 6 "https://$pd/event" >/dev/null 2>&1; then say "Основной сервер ОТВЕЧАЕТ ($pd)"; else warn "Основной сервер НЕ отвечает ($pd)"; fi
  fi
  [[ -f "$APP_DIR/players.json" ]] && echo "  игроков в копии: $("$APP_DIR/venv/bin/python3" -c "import json;print(len(json.load(open('$APP_DIR/players.json'))))" 2>/dev/null || echo ?)"
}

# ---------- failover ----------
do_failover(){
  load_conf
  local pd="${P_HOST//./-}.sslip.io"
  if [[ "${2:-}" != "--force" ]]; then
    if curl -fsS -m 6 "https://$pd/event" >/dev/null 2>&1; then
      warn "Основной сервер ($pd) СЕЙЧАС ОТВЕЧАЕТ. Запуск бота здесь вызовет конфликт 409 и двойную обработку платежей."
    fi
    read -rp "Запустить бота НА ЭТОМ сервере? Напиши ДА: " a; [[ "$a" == "ДА" ]] || err "Отменено."
  fi
  say "Последняя попытка забрать свежие данные с основного…"
  do_sync 2>/dev/null && say "Данные обновлены" || warn "Основной недоступен — работаю с копией (свежесть: $(( ($(date +%s) - $(cat /root/.standby.last 2>/dev/null || echo 0)) / 60 )) мин назад)"
  systemctl disable --now minifarm-sync.timer >/dev/null 2>&1 || true
  PORT_VAL="$(env_get PORT)"; PORT_VAL="${PORT_VAL:-3000}"
  DOMAIN="$(grep -m1 -E '^[a-z0-9.-]+\.sslip\.io \{|^[A-Za-z0-9.-]+ \{' /etc/caddy/Caddyfile | awk '{print $1}')"
  [[ -n "$DOMAIN" ]] || err "Не нашёл домен в Caddyfile."
  set_env WEBAPP_URL "${GAME_URL}?api=https://$DOMAIN"
  systemctl enable --now minifarm minifarm-pay >/dev/null 2>&1
  say "Жду, пока бот поднимется…"
  ok=0; for _ in $(seq 1 30); do curl -fsS -m 2 "http://127.0.0.1:$PORT_VAL/event" >/dev/null 2>&1 && { ok=1; break; }; sleep 1; done
  [[ $ok == 1 ]] || { journalctl -u minifarm -n 30 --no-pager; err "Бот не поднялся — смотри логи выше."; }
  journalctl -u minifarm -n 20 --no-pager | grep -q 409 && warn "В логах 409: бот с этим токеном запущен ещё где-то (основной сервер?). Останови его там."
  say "ГОТОВО: бот работает на резерве. https://$DOMAIN"
  echo "   • Игроки, открывающие игру кнопкой из бота (/start), автоматически подключатся к новому серверу."
  echo "   • Кнопку меню в @BotFather (Menu Button) обнови на: ${GAME_URL}?api=https://$DOMAIN"
  echo "   • Когда основной оживёт — НЕ запускай там бота. Вернуть роли: bash $SELF rearm (здесь) и переключи данные обратно вручную."
}

do_rearm(){
  systemctl disable --now minifarm minifarm-pay >/dev/null 2>&1 || true
  systemctl enable --now minifarm-sync.timer >/dev/null 2>&1 || true
  say "Бот здесь остановлен, режим резерва включён (синхронизация каждые 5 минут)."
}

case "$CMD" in
  setup) do_setup ;;
  sync) do_sync && say "Синхронизировано" ;;
  status) do_status ;;
  failover) do_failover "$@" ;;
  rearm) do_rearm ;;
  *) sed -n 2,13p "$0"; exit 1 ;;
esac
