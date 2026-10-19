#!/usr/bin/env bash
# nano.sh — полная установка «Мини-фермы» С НУЛЯ на чистый Ubuntu/Debian (игра + бот + ивенты + HTTPS + оплата Stars + админ-панель + рассылка).
#   Если server.py/.env уже есть — просто обновляет. Запросит только BOT_TOKEN и ADMIN_ID.
#   0) останавливает старую версию бота (сервис и любые запущенные server.py)
#   1) проверяет .env, ставит venv и зависимости
#   2) скачивает НОВУЮ игру с GitHub Pages и подменяет ею старые копии index.html на сервере
#   3) создаёт и запускает сервис minifarm
#   4) ставит Caddy и выдаёт HTTPS-адрес (Let's Encrypt, домен <ip>.sslip.io)
#   5) прописывает в .env WEBAPP_URL = ссылка на игру + ?api=адрес сервера
#   6) проверяет, что всё отвечает
# Повторный запуск безопасен.
#
# Запуск:       bash nano.sh        (из любой папки; всё ставится в /root/farm-bot)
# Без вопросов: BOT_TOKEN=123:AA.. ADMIN_ID=123456789 bash nano.sh
# Свой домен:   DOMAIN=farm.example.com bash nano.sh
set -euo pipefail

APP_DIR="${APP_DIR:-/root/farm-bot}"
SERVICE="minifarm"
VENV="$APP_DIR/venv"
PY="$VENV/bin/python3"
ENV_FILE="$APP_DIR/.env"
GAME_URL="${GAME_URL:-https://xnin228.github.io/everyday/}"
GAME_URL="${GAME_URL%/}/"
RAW_URL="${RAW_URL:-https://raw.githubusercontent.com/xnin228/everyday/main/index.html}"
WWW_DIR="/var/www/minifarm"
ORIGIN="$(echo "$GAME_URL" | sed -E 's#^(https?://[^/]+).*#\1#')"

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
say()  { echo -e "${G}[+]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
err()  { echo -e "${R}[x]${N} $*" >&2; }

[[ $EUID -eq 0 ]] || { err "Запусти от root (sudo -i)"; exit 1; }
command -v apt-get >/dev/null || { err "Скрипт рассчитан на Ubuntu/Debian (нужен apt-get)"; exit 1; }
say "Ставлю системные пакеты (python, curl…)…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null 2>&1 || warn "apt-get update завершился с предупреждением"
apt-get install -y python3 python3-venv python3-pip curl ca-certificates nano >/dev/null 2>&1 || { err "Не удалось поставить пакеты (python3, curl). Проверь интернет на сервере."; exit 1; }
mkdir -p "$APP_DIR"
cd "$APP_DIR"
if [[ ! -f "$APP_DIR/server.py" ]]; then
  say "server.py нет — создаю (бот + API ивентов и рейтинга)."
  cat > "$APP_DIR/server.py" <<'SRVEOF'
"""server.py — бот «Мини-ферма» (pyTelegramBotAPI) + HTTP-API для игры.

HTTP (слушает 127.0.0.1:PORT, наружу его отдаёт Caddy):
    GET  /event        -> {"now": мс, "event": {...} | null}   — активный ивент (x2, x3 …)
    GET  /top          -> [{"id","name","xp"}, ...]            — рейтинг ферм
    POST /score        -> {"id","name","xp","lvl"}             — игра присылает свой результат
Команды бота:
    /start             — кнопка «Играть»
    админ (ADMIN_ID):  /event x2 60 · /x3 30 · /event xp 2 30 · /event off · /event
Оплата Stars, админ-панель (/panel) и рассылка подключаются отдельными модулями (их вставляет nano.sh).
"""
import json, os, re, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import telebot
from telebot import types

HERE = os.path.dirname(os.path.abspath(__file__))
env = {}
try:
    for line in open(os.path.join(HERE, ".env"), encoding="utf-8"):
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.strip().split("=", 1)
            env[k] = v.strip().strip("\"'")
except FileNotFoundError:
    pass
TOKEN = env.get("BOT_TOKEN") or os.environ.get("BOT_TOKEN", "")
ADMIN = str(env.get("ADMIN_ID") or os.environ.get("ADMIN_ID", "")).strip()
WEBAPP = env.get("WEBAPP_URL") or os.environ.get("WEBAPP_URL", "")
PORT = int(env.get("PORT") or os.environ.get("PORT") or 3000)
if not TOKEN:
    raise SystemExit("В .env не задан BOT_TOKEN")

DATA = os.path.join(HERE, "data.json")
LK = threading.Lock()


def load():
    try:
        with open(DATA, encoding="utf-8") as f:
            d = json.load(f)
    except Exception:
        d = {}
    d.setdefault("subs", []); d.setdefault("scores", {}); d.setdefault("event", None)
    return d


def save(d):
    tmp = DATA + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False)
    os.replace(tmp, DATA)


def clean(s, n=24):
    return re.sub(r"[<>&\"'`]", "", str(s or ""))[:n].strip()


def active_event():
    d = load()
    e = d.get("event")
    if e and e.get("end", 0) > time.time() * 1000:
        return e
    return None


# ---------------- HTTP ----------------
class H(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        b = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers(); self.wfile.write(b)

    def do_GET(self):
        p = self.path.split("?")[0]
        if p == "/event":
            return self._send(200, {"now": int(time.time() * 1000), "event": active_event()})
        if p == "/top":
            with LK:
                sc = load()["scores"]
            rows = sorted(sc.items(), key=lambda kv: kv[1].get("xp", 0), reverse=True)[:50]
            return self._send(200, [{"id": k, "name": v.get("name", "Фермер"), "xp": v.get("xp", 0)} for k, v in rows])
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path.split("?")[0] != "/score":
            return self._send(404, {"error": "not found"})
        try:
            n = int(self.headers.get("Content-Length") or 0)
            if n > 4000:
                return self._send(413, {"error": "too large"})
            b = json.loads(self.rfile.read(n) or b"{}")
            i = clean(b.get("id"), 32)
            if not i:
                return self._send(400, {"error": "no id"})
            xp = max(0, min(10 ** 9, int(b.get("xp") or 0)))
            with LK:
                d = load()
                d["scores"][i] = {"name": clean(b.get("name")) or "Фермер", "xp": xp, "lvl": int(b.get("lvl") or 1), "t": int(time.time())}
                save(d)
            self._send(200, {"ok": True})
        except Exception as e:
            self._send(400, {"error": str(e)[:80]})

    def log_message(self, *a):
        pass


def run_http():
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()


# ---------------- бот ----------------
bot = telebot.TeleBot(TOKEN)


def is_admin(m):
    return str(m.from_user.id) == ADMIN


def play_kb():
    if not WEBAPP.startswith("https://"):
        return None
    kb = types.InlineKeyboardMarkup()
    kb.add(types.InlineKeyboardButton("🌾 Играть", web_app=types.WebAppInfo(WEBAPP)))
    return kb


@bot.message_handler(commands=["start", "help"])
def start(m):
    with LK:
        d = load()
        if m.chat.id not in d["subs"]:
            d["subs"].append(m.chat.id); save(d)
    bot.send_message(m.chat.id, "🌱 Добро пожаловать на «Мини-ферму»!\nСажайте, собирайте урожай, стройте и растите ферму.", reply_markup=play_kb())


PRESETS = {
    "x2": ("⚡", "Двойной опыт и монеты", {"xp": 2, "coins": 2}),
    "x3": ("🔥", "Тройной опыт и монеты", {"xp": 3, "coins": 3}),
    "x4": ("🔥", "×4 опыт и монеты", {"xp": 4, "coins": 4}),
    "x5": ("💥", "×5 опыт и монеты", {"xp": 5, "coins": 5}),
    "x10": ("💎", "×10 опыт и монеты", {"xp": 10, "coins": 10}),
}
KEYS = {"xp": "опыт", "coins": "цены", "speed": "рост", "yield": "урожай"}


def start_event(key_or_name, mult, minutes):
    if key_or_name in PRESETS:
        em, name, vals = PRESETS[key_or_name]
    elif key_or_name in KEYS:
        em, name, vals = "🎉", "Ивент: %s ×%s" % (KEYS[key_or_name], mult), {key_or_name: mult}
    else:
        return None
    e = {"id": "ev%d" % int(time.time()), "name": name, "emoji": em, "desc": "", "end": int((time.time() + minutes * 60) * 1000)}
    e.update(vals)
    with LK:
        d = load(); d["event"] = e; save(d)
    return e


def notify_subs(text):
    with LK:
        subs = list(load()["subs"])
    kb = play_kb()
    for cid in subs:
        try:
            bot.send_message(cid, text, reply_markup=kb)
        except Exception:
            pass
        time.sleep(0.05)


def event_cmd(m, args):
    if not is_admin(m):
        return
    if not args:
        e = active_event()
        left = int((e["end"] - time.time() * 1000) / 60000) if e else 0
        return bot.reply_to(m, ("Сейчас: %s %s (ещё %d мин)\n\n" % (e["emoji"], e["name"], left) if e else "Ивента нет.\n\n")
                            + "Примеры:\n/event x2 60 — ×2 опыт и монеты на 60 минут\n/x3 30\n/event xp 2 30 — только опыт\n"
                            "/event speed 2 30 — быстрее рост\n/event off — выключить")
    if args[0] == "off":
        with LK:
            d = load(); d["event"] = None; save(d)
        return bot.reply_to(m, "Ивент выключен.")
    try:
        if args[0] in PRESETS:
            mins = int(args[1]) if len(args) > 1 else 60
            e = start_event(args[0], None, mins)
        else:
            mult = float(args[1]); mins = int(args[2]) if len(args) > 2 else 60
            mult = max(1.0, min(50.0, mult)); mult = int(mult) if mult == int(mult) else mult
            e = start_event(args[0], mult, mins)
    except Exception:
        e = None
    if not e:
        return bot.reply_to(m, "Не понял. Пример: /event x2 60")
    bot.reply_to(m, "✅ Запущено: %s %s на %d мин. Игроки увидят баннер сразу." % (e["emoji"], e["name"], mins))
    threading.Thread(target=notify_subs, args=("%s %s!\nЗаходите играть — это ненадолго." % (e["emoji"], e["name"]),), daemon=True).start()


@bot.message_handler(commands=["event"])
def _event(m):
    event_cmd(m, (m.text or "").split()[1:])


for _k in PRESETS:
    def _mk(k):
        @bot.message_handler(commands=[k])
        def _h(m):
            a = (m.text or "").split()[1:]
            event_cmd(m, [k] + a)
    _mk(_k)


if __name__ == "__main__":
    threading.Thread(target=run_http, daemon=True).start()
    print("Мини-ферма: бот запущен, HTTP на 127.0.0.1:%d" % PORT, flush=True)
    bot.infinity_polling(skip_pending=True, allowed_updates=["message", "callback_query", "pre_checkout_query"])
SRVEOF
fi
if [[ ! -f "$APP_DIR/requirements.txt" ]]; then
  echo "pyTelegramBotAPI>=4.14" > "$APP_DIR/requirements.txt"; say "Создан requirements.txt"
fi

set_env() {
  local k="$1" v="$2" tmp
  if grep -qE "^${k}=" "$ENV_FILE"; then
    tmp="$(mktemp)"
    awk -v k="$k" -v v="$v" 'BEGIN{FS=OFS="="} $1==k{print k"="v; next} {print}' "$ENV_FILE" > "$tmp"
    cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"
  else
    echo "$k=$v" >> "$ENV_FILE"
  fi
}
get_env() { grep -E "^$1=" "$ENV_FILE" | head -n1 | cut -d= -f2- | tr -d '"'"'"' ' || true; }

# ---------- 0. останавливаем старую версию ----------
say "Останавливаю старую версию…"
systemctl stop "$SERVICE" 2>/dev/null || true
kill_old() {
  local sig="$1" pid cwd cmd
  for pid in $(pgrep -f 'server\.py' 2>/dev/null || true); do
    [[ "$pid" == "$$" ]] && continue
    cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || true)"
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    if [[ "$cwd" == "$APP_DIR" || "$cmd" == *"$APP_DIR"* ]]; then
      kill "-$sig" "$pid" 2>/dev/null && warn "Остановлен старый процесс server.py (PID $pid)"
    fi
  done
  return 0
}
kill_old TERM; sleep 2; kill_old KILL
say "Старая версия остановлена."

# ---------- 1. .env ----------
if [[ ! -f "$ENV_FILE" ]]; then
  warn ".env нет — создаю."
  cat > "$ENV_FILE" <<'EOF'
BOT_TOKEN=
ADMIN_ID=
WEBAPP_URL=
PORT=3000
EOF
  chmod 600 "$ENV_FILE"
fi
if [[ -z "$(get_env BOT_TOKEN)" ]]; then
  _T="${BOT_TOKEN:-}"
  if [[ -z "$_T" && -t 0 ]]; then read -rp "Вставь BOT_TOKEN (из @BotFather): " _T; fi
  [[ -n "$_T" ]] && set_env BOT_TOKEN "$(echo "$_T" | tr -d ' \r')"
fi
if [[ -z "$(get_env ADMIN_ID)" ]]; then
  _A="${ADMIN_ID:-}"
  if [[ -z "$_A" && -t 0 ]]; then read -rp "Вставь свой Telegram ID (число, узнать у @userinfobot): " _A; fi
  [[ -n "$_A" ]] && set_env ADMIN_ID "$(echo "$_A" | tr -d ' \r')"
fi
if [[ -z "$(get_env BOT_TOKEN)" || -z "$(get_env ADMIN_ID)" ]]; then
  err "В .env пустые BOT_TOKEN или ADMIN_ID. Открой: nano $ENV_FILE"
  echo "    BOT_TOKEN=123456:AA...   (из @BotFather)"
  echo "    ADMIN_ID=123456789       (узнать у @userinfobot)"
  exit 1
fi
PORT_VAL="$(get_env PORT)"; PORT_VAL="${PORT_VAL:-3000}"
grep -qE '^PORT=' "$ENV_FILE" || set_env PORT "$PORT_VAL"
say ".env в порядке (порт $PORT_VAL)."

# ---------- 2. venv + зависимости ----------
if [[ ! -x "$PY" ]]; then
  warn "venv не найден — создаю."
  python3 -m venv "$VENV" || { apt-get update -y >/dev/null; apt-get install -y python3-venv python3-pip >/dev/null; python3 -m venv "$VENV"; }
fi
say "Проверяю зависимости…"
"$VENV/bin/pip" install --upgrade pip wheel >/dev/null
"$VENV/bin/pip" install -r "$APP_DIR/requirements.txt" >/dev/null
# для оплаты Stars нужна свежая pyTelegramBotAPI (create_invoice_link)
"$VENV/bin/pip" install -U "pyTelegramBotAPI>=4.14" >/dev/null
[[ -f "$APP_DIR/data.json" ]] || { echo '{"subs": [], "scores": {}, "event": null}' > "$APP_DIR/data.json"; say "Создан data.json"; }

# ---------- 2б. оплата Stars: файлы и подключение к server.py ----------
say "Устанавливаю модуль оплаты…"
cat > "$APP_DIR/payments.py" <<'PAYEOF'
"""payments.py — оплата Telegram Stars для «Мини-фермы».
Подключение в server.py (бот на pyTelegramBotAPI):

    import payments
    payments.install(bot, BOT_TOKEN)          # после создания bot
    # два маршрута HTTP (POST, JSON), ответ — JSON:
    #   /invoice  ->  payments.api_invoice(bot, body)   # body = {"sku": "...", "initData": "..."}
    #   /claim    ->  payments.api_claim(body)

Цены считаются здесь, на сервере: игре доверять нельзя.
"""
import hashlib, hmac, json, os, threading, time
from urllib.parse import parse_qsl
from telebot import types

FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "grants.json")
LOCK = threading.Lock()
try:
    import fcntl
except ImportError:
    fcntl = None

class _Lock:
    # общая блокировка для двух процессов (бот и HTTP-сервис оплаты)
    def __enter__(self):
        LOCK.acquire()
        if fcntl:
            self.f = open(FILE + ".lock", "w"); fcntl.flock(self.f, fcntl.LOCK_EX)
    def __exit__(self, *a):
        if fcntl:
            fcntl.flock(self.f, fcntl.LOCK_UN); self.f.close()
        LOCK.release()
_TOKEN = ""

def price(sku):
    p = sku.split("_")
    try:
        if p[0] == "chest" and p[1] in ("c", "r", "l"):
            return {"c": 15, "r": 45, "l": 120}[p[1]]
        if p[0] == "bx" and 2 <= int(p[1]) <= 10 and int(p[2]) in (1, 3, 7):
            return int(p[1]) * int(p[2]) * 5
        if sku == "vip": return 150
        if sku == "bp": return 100
    except (IndexError, ValueError):
        pass
    return None

def _load():
    try:
        with open(FILE, encoding="utf-8") as f: return json.load(f)
    except Exception:
        return {"grants": {}, "paid": []}

def _save(d):
    tmp = FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f: json.dump(d, f, ensure_ascii=False)
    os.replace(tmp, FILE)

def user_id(init_data):
    """Проверяет подпись Telegram и возвращает id игрока (или None)."""
    try:
        kv = dict(parse_qsl(init_data, keep_blank_values=True))
        h = kv.pop("hash")
        if time.time() - int(kv.get("auth_date", "0")) > 7 * 86400: return None
        chk = "\n".join(f"{k}={v}" for k, v in sorted(kv.items()))
        secret = hmac.new(b"WebAppData", _TOKEN.encode(), hashlib.sha256).digest()
        if not hmac.compare_digest(hmac.new(secret, chk.encode(), hashlib.sha256).hexdigest(), h): return None
        return str(json.loads(kv["user"])["id"])
    except Exception:
        return None

def api_invoice(bot, body):
    uid, sku = user_id(body.get("initData", "")), str(body.get("sku", ""))
    amount = price(sku)
    if not uid or amount is None: return {"error": "bad request"}
    link = bot.create_invoice_link(
        title="Мини-ферма", description=sku, payload=f"{uid}:{sku}",
        provider_token="", currency="XTR", prices=[types.LabeledPrice(label=sku, amount=amount)])
    return {"link": link}

def api_claim(body):
    uid = user_id(body.get("initData", ""))
    if not uid: return {"grants": []}
    with _Lock():
        d = _load(); g = d["grants"].pop(uid, []); _save(d)
    return {"grants": g}

def install(bot, token):
    global _TOKEN; _TOKEN = token
    if getattr(bot, '_pay_installed', False): return
    bot._pay_installed = True

    @bot.pre_checkout_query_handler(func=lambda q: True)
    def _pre(q):
        try:
            uid, sku = q.invoice_payload.split(":", 1)
            ok = price(sku) == q.total_amount and uid == str(q.from_user.id)
        except Exception:
            ok = False
        bot.answer_pre_checkout_query(q.id, ok=ok, error_message=None if ok else "Ошибка заказа")

    @bot.message_handler(content_types=["successful_payment"])
    def _paid(m):
        sp = m.successful_payment
        uid, sku = sp.invoice_payload.split(":", 1)
        with _Lock():
            d = _load()
            if sp.telegram_payment_charge_id in d["paid"]: return
            d["paid"].append(sp.telegram_payment_charge_id)
            d["grants"].setdefault(uid, []).append(sku)
            _save(d)

    # платёжные обработчики — раньше общих «ловушек» из server.py
    bot.pre_checkout_query_handlers.insert(0, bot.pre_checkout_query_handlers.pop())
    bot.message_handlers.insert(0, bot.message_handlers.pop())
PAYEOF
cat > "$APP_DIR/payments_http.py" <<'PAYEOF'
"""HTTP-сервис игры (порт 3001): оплата Stars, выдачи админа, снимки и просмотр ферм.
POST /invoice, /claim, /snap   GET /farms, /farm?id=..   Caddy направляет их сюда."""
import json, os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
import telebot, payments, admin

here = os.path.dirname(os.path.abspath(__file__))
env = {}
for line in open(os.path.join(here, ".env"), encoding="utf-8"):
    if "=" in line and not line.lstrip().startswith("#"):
        k, v = line.strip().split("=", 1); env[k] = v.strip().strip("\"'")
token = env["BOT_TOKEN"]; bot = telebot.TeleBot(token); payments._TOKEN = token

class H(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        b = json.dumps(obj, ensure_ascii=False).encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8"); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        u = urlparse(self.path)
        try:
            if u.path == "/farms": return self._send(200, admin.farms_list(50))
            if u.path == "/farm":
                f = admin.get_farm((parse_qs(u.query).get("id") or [""])[0])
                return self._send(200 if f else 404, f or {"error": "not found"})
        except Exception as e:
            return self._send(500, {"error": str(e)[:100]})
        self._send(404, {"error": "not found"})
    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
            if n > 60000: return self._send(413, {"error": "too large"})
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception: return self._send(400, {"error": "bad json"})
        try:
            if self.path == "/invoice": return self._send(200, payments.api_invoice(bot, body))
            if self.path == "/claim": return self._send(200, payments.api_claim(body))
            if self.path == "/snap":
                uid = payments.user_id(body.get("initData", ""))
                if not uid: return self._send(200, {"ok": False})
                ok = admin.record_snapshot(uid, body.get("name"), body.get("lvl"), body.get("xp"), body.get("coins"), body.get("snap"))
                return self._send(200, {"ok": bool(ok)})
        except Exception as e:
            return self._send(500, {"error": str(e)[:100]})
        self._send(404, {"error": "not found"})
    def log_message(self, *a): pass

ThreadingHTTPServer(("127.0.0.1", 3001), H).serve_forever()
PAYEOF
cat > "$APP_DIR/admin.py" <<'ADMEOF'
"""admin.py — админ-панель в боте (/panel) и хранилище снимков ферм для «Мини-фермы».

Подключение в server.py (делает nano.sh автоматически):
    import admin; admin.install(bot)

Что умеет админ (только ADMIN_ID из .env):
    /panel                      — меню: игроки, статистика, поиск, команды
    /give <игрок> <что> [N]     — выдать: coins, fert, level (+N уровней), setlevel (=N),
                                  chest_c|chest_r|chest_l, vip, bp, bx_<мн>_<дни>
    /take <игрок> coins <N>     — забрать монеты
    /find <часть имени>         — поиск игрока
    /stats                      — статистика
<игрок> — Telegram id или часть имени/названия фермы.

Выдачи не меняют данные напрямую: они кладутся в очередь grants.json, а игра забирает их
через /claim при открытии (и каждые ~25 секунд, пока открыта).
"""
import hashlib, json, os, re, threading, time

import payments as P

HERE = os.path.dirname(os.path.abspath(__file__))
PFILE = os.path.join(HERE, "players.json")
LOGF = os.path.join(HERE, "admin.log")
_last = {}
_lk = threading.Lock()


# ---------- хранилище игроков ----------
def _pload():
    try:
        with open(PFILE, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def _psave(d):
    tmp = PFILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False)
    os.replace(tmp, PFILE)


def hid(uid):
    return hashlib.sha1(("mf:" + str(uid)).encode()).hexdigest()[:10]


def _clean(s, n=24):
    return re.sub(r"[<>&\"'`]", "", str(s or ""))[:n].strip()


def record_snapshot(uid, name, lvl, xp, coins, snap):
    """Сохраняет снимок фермы игрока (вызывается из HTTP-сервиса)."""
    now = time.time()
    with _lk:
        if now - _last.get(uid, 0) < 15:
            return False
        _last[uid] = now
    if not isinstance(snap, dict) or len(json.dumps(snap)) > 24000:
        return False
    with P._Lock():
        d = _pload()
        d[str(uid)] = {
            "name": _clean(name) or "Фермер",
            "lvl": max(1, min(999, int(lvl or 1))),
            "xp": max(0, min(10 ** 9, int(xp or 0))),
            "coins": max(0, min(10 ** 12, int(coins or 0))),
            "seen": int(now),
            "snap": snap,
        }
        _psave(d)
    return True


def farms_list(limit=50):
    d = _pload()
    cutoff = time.time() - 60 * 86400
    rows = [(u, v) for u, v in d.items() if v.get("seen", 0) > cutoff]
    rows.sort(key=lambda r: r[1].get("xp", 0), reverse=True)
    return [{"id": hid(u), "name": v.get("name", "Фермер"), "lvl": v.get("lvl", 1),
             "xp": v.get("xp", 0), "w": (v.get("snap") or {}).get("w", "farm")} for u, v in rows[:limit]]


def get_farm(h):
    for u, v in _pload().items():
        if hid(u) == h:
            return {"name": v.get("name"), "lvl": v.get("lvl"), "xp": v.get("xp"), "snap": v.get("snap")}
    return None


# ---------- выдачи ----------
def grant_str(code):
    """Переводит короткий код в строку выдачи или None, если код неверный."""
    m = re.fullmatch(r"coins:(-?\d{1,9})", code)
    if m: return "adm_coins_" + m.group(1)
    m = re.fullmatch(r"fert:(-?\d{1,6})", code)
    if m: return "adm_fert_" + m.group(1)
    m = re.fullmatch(r"lvl:([+-]\d{1,3})", code)
    if m: return "adm_lvl_" + m.group(1)
    m = re.fullmatch(r"setlvl:(\d{1,3})", code)
    if m: return "adm_lvl_=" + m.group(1)
    if P.price(code) is not None and not code.startswith("w_"):
        return code
    return None


def queue(uid, grant):
    with P._Lock():
        d = P._load()
        d["grants"].setdefault(str(uid), []).append(grant)
        P._save(d)


def log(admin, uid, grant):
    try:
        with open(LOGF, "a", encoding="utf-8") as f:
            f.write("%s admin=%s -> %s : %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), admin, uid, grant))
    except Exception:
        pass


def resolve(q):
    """Telegram id или часть имени -> (uid, запись) либо (None, список совпадений)."""
    q = q.strip().lstrip("@")
    d = _pload()
    if q.isdigit():
        return q, d.get(q)
    hits = [(u, v) for u, v in d.items() if q.lower() in (v.get("name") or "").lower()]
    if len(hits) == 1:
        return hits[0][0], hits[0][1]
    return None, hits


def describe(grant):
    if grant.startswith("adm_coins_"):
        n = int(grant[10:]); return ("+%d 🪙" if n >= 0 else "%d 🪙") % n
    if grant.startswith("adm_fert_"): return "+%s 🧪" % grant[9:]
    if grant.startswith("adm_lvl_="): return "уровень = %s" % grant[9:]
    if grant.startswith("adm_lvl_"): return "уровень %s" % grant[8:]
    names = {"chest_c": "📦 обычный сундук", "chest_r": "💎 редкий сундук", "chest_l": "👑 легендарный сундук",
             "vip": "👑 VIP на 30 дней", "bp": "🎫 премиум-пропуск"}
    if grant in names: return names[grant]
    if grant.startswith("bx_"):
        _, m, dd = grant.split("_"); return "⚡ множитель ×%s на %s дн." % (m, dd)
    return grant


# ---------- бот ----------
def _admin_id():
    v = os.environ.get("ADMIN_ID", "")
    if not v:
        try:
            for line in open(os.path.join(HERE, ".env"), encoding="utf-8"):
                if line.startswith("ADMIN_ID="):
                    v = line.split("=", 1)[1].strip().strip("\"'")
        except Exception:
            pass
    return str(v).strip()


def install(bot):
    from telebot import types
    AID = _admin_id()
    if getattr(bot, "_admin_installed", False) or not AID:
        return
    bot._admin_installed = True

    def is_admin(uid):
        return str(uid) == AID

    def first(handlers_attr, n):
        # наши обработчики должны стоять раньше общих «ловушек» из server.py
        lst = getattr(bot, handlers_attr)
        for _ in range(n):
            lst.insert(0, lst.pop())

    def kb(rows):
        m = types.InlineKeyboardMarkup()
        for r in rows:
            m.row(*[types.InlineKeyboardButton(t, callback_data=c) for t, c in r])
        return m

    def main_menu():
        return ("🛠 <b>Админ-панель «Мини-ферма»</b>\nВыберите раздел.",
                kb([[("👥 Игроки", "adm:l:0"), ("📊 Статистика", "adm:s")],
                    [("ℹ️ Команды", "adm:h")]]))

    def stats_text():
        d = _pload(); now = time.time()
        day = sum(1 for v in d.values() if now - v.get("seen", 0) < 86400)
        week = sum(1 for v in d.values() if now - v.get("seen", 0) < 7 * 86400)
        coins = sum(v.get("coins", 0) for v in d.values())
        top = sorted(d.values(), key=lambda v: v.get("xp", 0), reverse=True)[:3]
        t = "📊 <b>Статистика</b>\nИгроков: %d\nЗа сутки: %d · за неделю: %d\nМонет у всех: %d" % (len(d), day, week, coins)
        if top:
            t += "\n\nТоп: " + ", ".join("%s (ур. %s)" % (v.get("name"), v.get("lvl")) for v in top)
        return t

    HELP = ("ℹ️ <b>Команды</b>\n"
            "/panel — меню\n"
            "/give &lt;игрок&gt; coins 500 — выдать монеты\n"
            "/take &lt;игрок&gt; coins 500 — забрать монеты\n"
            "/give &lt;игрок&gt; level 5 — +5 уровней (setlevel 25 — установить)\n"
            "/give &lt;игрок&gt; fert 10 — удобрение\n"
            "/give &lt;игрок&gt; chest_c | chest_r | chest_l — сундук\n"
            "/give &lt;игрок&gt; vip | bp | bx_5_1 — VIP, пропуск, множитель ×5 на 1 день\n"
            "/find &lt;имя&gt; — поиск\n/stats — статистика\n"
            "&lt;игрок&gt; — Telegram id или часть имени.\n"
            "Выдача придёт игроку при открытии игры (в течение ~25 секунд, если игра открыта).")

    def page(p):
        d = _pload()
        rows = sorted(d.items(), key=lambda r: r[1].get("seen", 0), reverse=True)
        per = 8; pages = max(1, (len(rows) + per - 1) // per); p = max(0, min(p, pages - 1))
        btn = [[("%s · ур. %s" % (v.get("name"), v.get("lvl")), "adm:p:" + u)] for u, v in rows[p * per:(p + 1) * per]]
        nav = []
        if p > 0: nav.append(("◀", "adm:l:%d" % (p - 1)))
        nav.append(("%d/%d" % (p + 1, pages), "adm:l:%d" % p))
        if p < pages - 1: nav.append(("▶", "adm:l:%d" % (p + 1)))
        btn.append(nav); btn.append([("⬅ Меню", "adm:m")])
        return "👥 <b>Игроки</b> (%d), недавние сверху" % len(rows), kb(btn)

    def card(uid):
        v = _pload().get(str(uid))
        if v:
            ago = int((time.time() - v.get("seen", 0)) / 60)
            seen = "%d мин назад" % ago if ago < 120 else "%d ч назад" % (ago // 60)
            t = ("👤 <b>%s</b>\nid: <code>%s</code>\nУровень %s · опыт %s\nМонет (по последним данным): %s\nБыл: %s"
                 % (v.get("name"), uid, v.get("lvl"), v.get("xp"), v.get("coins"), seen))
        else:
            t = "👤 id <code>%s</code> (данных о ферме пока нет)" % uid
        u = str(uid)
        k = kb([
            [("🪙 +100", "adm:g:%s:coins:100" % u), ("+1000", "adm:g:%s:coins:1000" % u), ("+10000", "adm:g:%s:coins:10000" % u)],
            [("🪙 −100", "adm:g:%s:coins:-100" % u), ("−1000", "adm:g:%s:coins:-1000" % u), ("−10000", "adm:g:%s:coins:-10000" % u)],
            [("⬆ +1 ур", "adm:g:%s:lvl:+1" % u), ("⬆ +5 ур", "adm:g:%s:lvl:+5" % u), ("⬇ −1 ур", "adm:g:%s:lvl:-1" % u)],
            [("🧪 +10", "adm:g:%s:fert:10" % u), ("📦", "adm:g:%s:chest_c" % u), ("💎", "adm:g:%s:chest_r" % u), ("👑", "adm:g:%s:chest_l" % u)],
            [("👑 VIP 30д", "adm:g:%s:vip" % u), ("🎫 Пропуск", "adm:g:%s:bp" % u)],
            [("⚡×2 1д", "adm:g:%s:bx_2_1" % u), ("⚡×5 1д", "adm:g:%s:bx_5_1" % u), ("⚡×10 1д", "adm:g:%s:bx_10_1" % u)],
            [("⬅ К списку", "adm:l:0"), ("🔄", "adm:p:%s" % u)]])
        return t, k

    def do_grant(admin, uid, code):
        g = grant_str(code)
        if not g:
            return None
        queue(uid, g); log(admin, uid, g)
        try:
            bot.send_message(int(uid), "🎁 Вам выдано: %s\nОткройте игру — получите." % describe(g))
        except Exception:
            pass
        return g

    @bot.message_handler(commands=["panel", "admin"])
    def _panel(m):
        if not is_admin(m.from_user.id): return
        t, k = main_menu(); bot.send_message(m.chat.id, t, reply_markup=k, parse_mode="HTML")

    @bot.message_handler(commands=["stats"])
    def _stats(m):
        if not is_admin(m.from_user.id): return
        bot.send_message(m.chat.id, stats_text(), parse_mode="HTML")

    @bot.message_handler(commands=["find"])
    def _find(m):
        if not is_admin(m.from_user.id): return
        q = (m.text or "").split(None, 1)
        if len(q) < 2:
            return bot.reply_to(m, "Использование: /find имя")
        uid, hits = resolve(q[1])
        if uid:
            t, k = card(uid); return bot.send_message(m.chat.id, t, reply_markup=k, parse_mode="HTML")
        if not hits:
            return bot.reply_to(m, "Никого не нашёл.")
        bot.send_message(m.chat.id, "Найдено: %d. Уточните запрос или выберите:" % len(hits),
                         reply_markup=kb([[("%s · ур. %s" % (v.get("name"), v.get("lvl")), "adm:p:" + u)] for u, v in hits[:10]]))

    def give_take(m, sign):
        if not is_admin(m.from_user.id): return
        a = (m.text or "").split()
        if len(a) < 3:
            return bot.reply_to(m, "Пример: /%s 123456789 coins 500\nПодробнее: /panel → Команды" % ("give" if sign > 0 else "take"))
        uid, rec = resolve(a[1])
        if not uid:
            return bot.reply_to(m, "Игрок не найден или найдено несколько. Используйте /find.")
        what = a[2].lower(); n = a[3] if len(a) > 3 else ""
        if what in ("coins", "fert"):
            if not re.fullmatch(r"\d{1,9}", n): return bot.reply_to(m, "Укажите число: /give id %s 500" % what)
            code = "%s:%d" % (what, sign * int(n))
        elif what == "level":
            if not re.fullmatch(r"\d{1,3}", n): return bot.reply_to(m, "Укажите число уровней")
            code = "lvl:%s%d" % ("+" if sign > 0 else "-", int(n))
        elif what == "setlevel" and sign > 0:
            if not re.fullmatch(r"\d{1,3}", n): return bot.reply_to(m, "Укажите уровень")
            code = "setlvl:" + n
        elif sign > 0:
            code = what
        else:
            return bot.reply_to(m, "Забирать можно только coins, fert, level.")
        g = do_grant(m.from_user.id, uid, code)
        name = (rec or {}).get("name", uid)
        bot.reply_to(m, ("✅ %s: %s" % (name, describe(g))) if g else "Неверное значение. Смотрите /panel → Команды.")

    @bot.message_handler(commands=["give"])
    def _give(m): give_take(m, 1)

    @bot.message_handler(commands=["take"])
    def _take(m): give_take(m, -1)

    @bot.callback_query_handler(func=lambda c: (c.data or "").startswith("adm:"))
    def _cb(c):
        if not is_admin(c.from_user.id):
            return bot.answer_callback_query(c.id, "Нет доступа")
        p = c.data.split(":", 2)[1:]
        act = p[0]; rest = p[1] if len(p) > 1 else ""
        chat, mid = c.message.chat.id, c.message.message_id

        def show(text, markup=None):
            try:
                bot.edit_message_text(text, chat, mid, reply_markup=markup, parse_mode="HTML")
            except Exception:
                pass

        if act == "m": show(*main_menu())
        elif act == "s": show(stats_text(), kb([[("⬅ Меню", "adm:m")]]))
        elif act == "h": show(HELP, kb([[("⬅ Меню", "adm:m")]]))
        elif act == "l": show(*page(int(rest or 0)))
        elif act == "p": show(*card(rest))
        elif act == "g":
            uid, _, code = rest.partition(":")
            g = do_grant(c.from_user.id, uid, code)
            bot.answer_callback_query(c.id, ("Выдано: " + describe(g)) if g else "Ошибка")
            if g: show(*card(uid))
            return
        bot.answer_callback_query(c.id)

    try:
        import broadcast
        broadcast.install(bot)          # рассылка-приглашение: свои 4 обработчика (запись, /stop, /resume, /bc)
    except Exception as e:
        print("broadcast не подключён:", e, flush=True)
    first("message_handlers", 9)
    first("callback_query_handlers", 1)
ADMEOF
cat > "$APP_DIR/broadcast.py" <<'BCEOF'
"""broadcast.py — рассылка-приглашение в игру всем, кто запускал бота.

Подключается сам из admin.install(bot). Настройки в .env (все необязательные):
    BROADCAST_MIN=43        — период в минутах (по умолчанию 43)
    BROADCAST_QUIET=0-0     — «тихие часы» по Москве, например 23-9 (не слать с 23:00 до 9:00); 0-0 = слать всегда
    BROADCAST_ON=1          — 0 выключает рассылку
Игрок может отключить рассылку командой /stop и включить /resume.
Админ: /bc — статус, /bc on|off, /bc test (отправить только себе).
"""
import json, os, random, threading, time
from datetime import datetime, timedelta, timezone

import payments as P

HERE = os.path.dirname(os.path.abspath(__file__))
UF = os.path.join(HERE, "bc_users.json")     # {chat_id: {"n": имя, "off": 0/1, "t": когда добавлен}}
SF = os.path.join(HERE, "bc_state.json")     # {"last": ts, "i": номер сообщения, "on": 1}

TEXTS = [
    "🌱 {n}, ваша ферма скучает! Урожай уже, наверное, созрел — заходите собирать.",
    "🐔 Куры снесли яйца, коровы дали молоко. Загляните на двор и заберите 🥚🥛",
    "🚚 Появились новые заказы в городе! Выполните их и получите монеты и опыт.",
    "🏗 Стройте на своей ферме как в Hay Day: колодец, мельница, силос — и расширяйте землю!",
    "🏡 Загляните в гости к другим фермерам — вдруг у кого-то ферма красивее вашей?",
    "🌍 Новые миры ждут: болото, будущее и динозавры открываются по уровню — бесплатно!",
    "🎁 Не забудьте забрать ежедневную награду — серия дней даёт всё больше монет.",
    "⚡ Заходите играть: сегодня опыт и монеты можно ускорить множителем в разделе «Донат».",
    "🥧 В пекарне что-то печётся… Не дайте хлебу остыть — заходите на ферму!",
    "🦊 Лиса опять замечена у курятника! Прогоните её и получите монеты.",
    "🌽 Посадите новые семена, пока есть время: чем раньше посев — тем раньше урожай!",
    "🏆 Поднимайтесь в рейтинге ферм! Каждый уровень — шаг к первому месту.",
]

_lk = threading.Lock()


def _load(f, default):
    try:
        with open(f, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return default


def _save(f, d):
    tmp = f + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(d, fh, ensure_ascii=False)
    os.replace(tmp, f)


def _env(name, default=""):
    v = os.environ.get(name, "")
    if not v:
        try:
            for line in open(os.path.join(HERE, ".env"), encoding="utf-8"):
                if line.startswith(name + "="):
                    v = line.split("=", 1)[1].strip().strip("\"'")
        except Exception:
            pass
    return v or default


def remember(chat_id, name=None):
    k = str(chat_id)
    with _lk:
        d = _load(UF, {})
        u = d.get(k)
        if u is None:
            d[k] = {"n": (name or "")[:24], "off": 0, "t": int(time.time())}
            _save(UF, d)
        elif name and not u.get("n"):
            u["n"] = name[:24]; _save(UF, d)


def set_off(chat_id, off):
    with _lk:
        d = _load(UF, {})
        if str(chat_id) in d:
            d[str(chat_id)]["off"] = 1 if off else 0
        else:
            d[str(chat_id)] = {"n": "", "off": 1 if off else 0, "t": int(time.time())}
        _save(UF, d)


def recipients():
    """Все, кто писал боту, плюс все, кто открывал игру (личный чат = id пользователя)."""
    with _lk:
        d = _load(UF, {})
    out = {}
    for k, v in d.items():
        if not v.get("off"):
            out[k] = v.get("n") or ""
    try:
        import admin
        for k, v in admin._pload().items():
            if k not in d and str(k).isdigit():
                out[k] = v.get("name") or ""
    except Exception:
        pass
    return out


def quiet_now():
    q = _env("BROADCAST_QUIET", "0-0")
    try:
        a, b = [int(x) for x in q.split("-")]
    except Exception:
        return False
    if a == b:
        return False
    h = (datetime.now(timezone.utc) + timedelta(hours=3)).hour     # Москва
    return (a <= h < b) if a < b else (h >= a or h < b)


def send_round(bot, only=None, text_i=None):
    from telebot import types
    st = _load(SF, {})
    i = st.get("i", 0) if text_i is None else text_i
    url = _env("WEBAPP_URL")
    kb = None
    if url.startswith("https://"):
        kb = types.InlineKeyboardMarkup()
        kb.add(types.InlineKeyboardButton("🌾 Играть", web_app=types.WebAppInfo(url)))
    targets = {str(only): ""} if only else recipients()
    sent = 0
    for cid, name in targets.items():
        txt = TEXTS[i % len(TEXTS)].replace("{n}, ", (name + ", ") if name else "").replace("{n}", name or "фермер")
        txt += "\n\nОтключить напоминания: /stop"
        try:
            bot.send_message(int(cid), txt, reply_markup=kb)
            sent += 1
        except Exception as e:
            s = str(e)
            if "403" in s or "blocked" in s or "deactivated" in s or "chat not found" in s:
                set_off(cid, 1)               # заблокировал бота — больше не пишем
            elif "429" in s:
                time.sleep(5)
        time.sleep(0.05)                      # ~20 сообщений в секунду, в пределах лимита Telegram
    if not only:
        st["last"] = int(time.time()); st["i"] = i + 1
        _save(SF, st)
    return sent


def _loop(bot):
    time.sleep(20)
    while True:
        try:
            st = _load(SF, {})
            period = max(5, int(_env("BROADCAST_MIN", "43"))) * 60
            on = _env("BROADCAST_ON", "1") != "0" and st.get("on", 1)
            if on and time.time() - st.get("last", 0) >= period:
                if quiet_now():
                    pass                      # ночью пропускаем, отсчёт не сбрасываем
                else:
                    P_ = send_round(bot)
                    print("broadcast: отправлено", P_, flush=True)
        except Exception as e:
            print("broadcast error:", e, flush=True)
        time.sleep(30)


def install(bot):
    if getattr(bot, "_bc_installed", False):
        return
    bot._bc_installed = True
    AID = str(_env("ADMIN_ID"))

    # записываем всех, кто пишет боту, но не перехватываем сообщения (func всегда False)
    def _rec(m):
        try:
            if m.chat.type == "private":
                remember(m.chat.id, getattr(m.from_user, "first_name", "") or "")
        except Exception:
            pass
        return False

    @bot.message_handler(func=_rec)
    def _never(m): pass

    @bot.message_handler(commands=["stop"])
    def _stop(m):
        set_off(m.chat.id, 1)
        bot.send_message(m.chat.id, "Хорошо, напоминания отключены. Вернуть: /resume")

    @bot.message_handler(commands=["resume"])
    def _resume(m):
        set_off(m.chat.id, 0)
        bot.send_message(m.chat.id, "Напоминания снова включены 🌾")

    @bot.message_handler(commands=["bc"])
    def _bc(m):
        if str(m.from_user.id) != AID:
            return
        a = (m.text or "").split()[1:]
        st = _load(SF, {})
        if a and a[0] == "off":
            st["on"] = 0; _save(SF, st); return bot.reply_to(m, "Рассылка выключена.")
        if a and a[0] == "on":
            st["on"] = 1; _save(SF, st); return bot.reply_to(m, "Рассылка включена.")
        if a and a[0] == "test":
            n = send_round(bot, only=m.chat.id, text_i=random.randrange(len(TEXTS)))
            return bot.reply_to(m, "Отправил тестовое сообщение: %d" % n)
        if a and a[0] == "now":
            n = send_round(bot); return bot.reply_to(m, "Разослано: %d" % n)
        r = recipients()
        left = max(0, int(_env("BROADCAST_MIN", "43")) * 60 - (time.time() - st.get("last", 0)))
        bot.reply_to(m, "📣 Рассылка: %s\nПолучателей: %d\nПериод: %s мин\nТихие часы (МСК): %s\nСледующая через ~%d мин\n\n/bc on | off | test | now"
                     % ("вкл" if st.get("on", 1) else "выкл", len(r), _env("BROADCAST_MIN", "43"),
                        _env("BROADCAST_QUIET", "0-0"), left // 60))

    threading.Thread(target=_loop, args=(bot,), daemon=True).start()
BCEOF
cp -a "$APP_DIR/server.py" "$APP_DIR/server.py.bak-pay"
PATCH_RES="$("$PY" - "$APP_DIR/server.py" <<'PATCHPY'
import re, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
if "payments.install" in s: print("already"); sys.exit(0)
m = re.search(r"^([ \t]*)(\w+)\.(infinity_polling|polling)\(", s, re.M)
if not m: print("NOPOLL"); sys.exit(0)
ins = f"{m.group(1)}import payments; payments.install({m.group(2)}, {m.group(2)}.token)\n"
open(p, "w", encoding="utf-8").write(s[:m.start()] + ins + s[m.start():]); print("patched")
PATCHPY
)"
if grep -n "allowed_updates" "$APP_DIR/server.py" >/dev/null 2>&1; then
  warn "В server.py задан allowed_updates — для оплаты в нём должны быть 'message' и 'pre_checkout_query'. Проверь: grep -n allowed_updates $APP_DIR/server.py"
fi
case "$PATCH_RES" in
  patched) "$PY" -m py_compile "$APP_DIR/server.py" || { cp -a "$APP_DIR/server.py.bak-pay" "$APP_DIR/server.py"; err "server.py после правки не компилируется — вернул как было."; exit 1; }
           say "server.py: подключена обработка платежей ✅" ;;
  already) say "server.py: оплата уже подключена." ;;
  *)       warn "В server.py не найден запуск polling — платежи не подключены. Добавь перед запуском бота: import payments; payments.install(bot, bot.token)" ;;
esac

ADM_RES="$("$PY" - "$APP_DIR/server.py" <<'PATCHPY'
import re, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
if "admin.install" in s: print("already"); sys.exit(0)
m = re.search(r"^([ \t]*)(\w+)\.(infinity_polling|polling)\(", s, re.M)
if not m: print("NOPOLL"); sys.exit(0)
ins = f"{m.group(1)}import admin; admin.install({m.group(2)})\n"
open(p, "w", encoding="utf-8").write(s[:m.start()] + ins + s[m.start():]); print("patched")
PATCHPY
)"
case "$ADM_RES" in
  patched) "$PY" -m py_compile "$APP_DIR/server.py" || { cp -a "$APP_DIR/server.py.bak-pay" "$APP_DIR/server.py"; err "server.py после правки не компилируется — вернул как было."; exit 1; }
           say "server.py: подключена админ-панель (/panel) ✅" ;;
  already) say "server.py: админ-панель уже подключена." ;;
  *)       warn "В server.py не найден запуск polling — админ-панель не подключена. Добавь перед запуском бота: import admin; admin.install(bot)" ;;
esac

# ---------- 3. адрес сервера ----------
if [[ -z "${DOMAIN:-}" ]]; then
  PUB_IP="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)"
  if ! [[ "$PUB_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    err "Не смог определить публичный IP. Запусти так: DOMAIN=твой.домен bash $0"
    exit 1
  fi
  DOMAIN="${PUB_IP//./-}.sslip.io"
fi
API_URL="https://$DOMAIN"
say "Адрес сервера: $API_URL"

# ---------- 4. новая игра: скачиваем и подменяем старые копии ----------
say "Скачиваю новую версию игры (GitHub raw — не зависит от Pages)…"
TMP_HTML="$(mktemp)"
GOT=0
if curl -fsSL --max-time 90 "$RAW_URL?nocache=$(date +%s)" -o "$TMP_HTML" && grep -q 'API_DEFAULT' "$TMP_HTML"; then GOT=1
elif curl -fsSL --max-time 90 "${GAME_URL}index.html?nocache=$(date +%s)" -o "$TMP_HTML" && grep -q 'API_DEFAULT' "$TMP_HTML"; then GOT=1; fi
if [[ $GOT -eq 1 ]]; then
  mkdir -p "$WWW_DIR"; cp "$TMP_HTML" "$WWW_DIR/index.html"
  sed -i "s#var API_DEFAULT='[^']*'#var API_DEFAULT='$API_URL'#" "$WWW_DIR/index.html"
  say "Игра выложена на сервере: $API_URL/game/"
  # адрес сервера по умолчанию — для случая, когда игру отдаёт сам сервер
  sed -i "s#var API_DEFAULT='[^']*'#var API_DEFAULT='$API_URL'#" "$TMP_HTML"
  FOUND=0
  while IFS= read -r f; do
    FOUND=1
    [[ -f "$f.bak-old" ]] || cp -a "$f" "$f.bak-old"
    cp "$TMP_HTML" "$f"
    say "Обновлена копия игры на сервере: $f"
  done < <(find "$APP_DIR" -name 'index.html' -not -path '*/venv/*' 2>/dev/null)
  [[ $FOUND -eq 1 ]] || warn "На сервере нет своей копии index.html — игра берётся только с GitHub Pages."
  # если где-то остался сломанный адрес вида var API='https://...github.io/...?api=...'
  grep -rIl "var API='https://[^']*?api=" "$APP_DIR" --exclude-dir=venv 2>/dev/null | while IFS= read -r f; do
    sed -i "s#var API='https://[^']*?api=[^']*'#var API='$API_URL'#" "$f" && warn "Исправлен адрес API в $f"
  done || true
else
  warn "GitHub Pages ещё отдаёт старую версию (нет API_DEFAULT) или недоступен."
  warn "Проверь, что новый index.html загружен в репозиторий и подожди 1–2 минуты. Серверные копии не менял."
fi
rm -f "$TMP_HTML"

# ---------- 5. systemd-сервис ----------
say "Создаю сервис $SERVICE…"
cat > "/etc/systemd/system/$SERVICE.service" <<EOF
[Unit]
Description=Mini Farm Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
ExecStart=$PY $APP_DIR/server.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
cat > "/etc/systemd/system/$SERVICE-pay.service" <<EOF
[Unit]
Description=Mini Farm payments API
After=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
ExecStart=$PY $APP_DIR/payments_http.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "$SERVICE" "$SERVICE-pay" >/dev/null 2>&1

# ---------- 6. ссылка на игру для бота (те же ссылки + ?api=) ----------
cp -a "$ENV_FILE" "$ENV_FILE.bak"
FULL_URL="${GAME_URL}?api=$API_URL"      # основная: GitHub Pages
BACKUP_URL="$API_URL/game/"              # запасная: игра с этого сервера
set_env WEBAPP_URL "$FULL_URL"
say "WEBAPP_URL (основная) = $FULL_URL; запасная: $BACKUP_URL (старый .env сохранён как .env.bak)"

systemctl restart "$SERVICE" "$SERVICE-pay"
say "Жду, пока поднимется HTTP-API на порту $PORT_VAL…"
LOCAL_OK=0
for _ in $(seq 1 25); do
  if curl -fsS --max-time 2 "http://127.0.0.1:$PORT_VAL/event" >/dev/null 2>&1; then LOCAL_OK=1; break; fi
  sleep 1
done
if [[ $LOCAL_OK -ne 1 ]]; then
  err "Сервис не отвечает на http://127.0.0.1:$PORT_VAL/event. Последние логи:"
  journalctl -u "$SERVICE" -n 40 --no-pager || true
  echo "Частые причины: неверный BOT_TOKEN, занят порт $PORT_VAL, в server.py нет маршрута /event."
  exit 1
fi
say "Бот запущен, /event отвечает ✅"
curl -fsS --max-time 3 "http://127.0.0.1:$PORT_VAL/top" >/dev/null 2>&1 \
  && say "/top отвечает ✅" \
  || warn "/top не отвечает — рейтинг ферм в игре не будет работать (проверь server.py)."
if journalctl -u "$SERVICE" -n 30 --no-pager 2>/dev/null | grep -q "409"; then
  warn "В логах ошибка 409: этот же бот (тот же токен) запущен ещё где-то — например, на компьютере с Windows. Останови его там."
fi

# ---------- 7. порты 80/443 ----------
BUSY="$(ss -ltnpH '( sport = :80 or sport = :443 )' 2>/dev/null | grep -v caddy || true)"
if [[ -n "$BUSY" ]]; then
  err "Порты 80/443 заняты другой программой (nginx/apache?):"
  echo "$BUSY"
  echo "Останови её (systemctl stop nginx) или настрой проксирование на 127.0.0.1:$PORT_VAL вручную."
  exit 1
fi
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 22/tcp >/dev/null; ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
  say "ufw: порты 22 (SSH), 80 и 443 открыты"
fi

# ---------- 8. Caddy ----------
if ! command -v caddy >/dev/null; then
  say "Устанавливаю Caddy…"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y curl gpg debian-keyring debian-archive-keyring apt-transport-https >/dev/null
  if curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
     && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list \
     && apt-get update -y >/dev/null && apt-get install -y caddy >/dev/null; then
    :
  else
    warn "Официальный репозиторий Caddy недоступен — ставлю из репозитория системы."
    rm -f /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -y >/dev/null
    apt-get install -y caddy >/dev/null
  fi
fi

CF="/etc/caddy/Caddyfile"
MARK_B="# >>> minifarm >>>"; MARK_E="# <<< minifarm <<<"
mkdir -p /etc/caddy; touch "$CF"
cp -a "$CF" "$CF.bak.$(date +%s)"
if grep -q "/usr/share/caddy" "$CF" && ! grep -q "$MARK_B" "$CF"; then : > "$CF"; fi
sed -i "/$MARK_B/,/$MARK_E/d" "$CF"
cat >> "$CF" <<EOF
$MARK_B
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
$MARK_E
EOF
caddy validate --config "$CF" --adapter caddyfile >/dev/null 2>&1 || { err "Caddyfile не прошёл проверку:"; caddy validate --config "$CF" --adapter caddyfile || true; exit 1; }
systemctl enable caddy >/dev/null 2>&1 || true
systemctl restart caddy
say "Caddy настроен: $API_URL → 127.0.0.1:$PORT_VAL"

# ---------- 9. проверка снаружи ----------
say "Проверяю HTTPS (сертификат выпускается до минуты)…"
HTTPS_OK=0
for _ in $(seq 1 30); do
  if curl -fsS --max-time 6 "$API_URL/event" >/dev/null 2>&1; then HTTPS_OK=1; break; fi
  sleep 3
done
if [[ $HTTPS_OK -ne 1 ]]; then
  err "$API_URL/event не отвечает."
  echo "  • Открой порты 80 и 443 в панели хостинга (Security Group / Firewall)."
  echo "  • Логи Caddy: journalctl -u caddy -n 40 --no-pager"
  exit 1
fi
say "HTTPS работает ✅"
CORS="$(curl -fsS -D - -o /dev/null -H "Origin: $ORIGIN" "$API_URL/event" 2>/dev/null | tr -d '\r' | grep -i '^access-control-allow-origin' || true)"
if echo "$CORS" | grep -qi "$ORIGIN"; then say "CORS для $ORIGIN включён ✅"; else warn "CORS-заголовок не найден: $CORS"; fi
if curl -fsS --max-time 8 -X POST -H 'Content-Type: application/json' -d '{}' "$API_URL/claim" 2>/dev/null | grep -q grants; then
  say "Оплата Stars (/claim) отвечает ✅"
else
  warn "/claim не отвечает — смотри: journalctl -u $SERVICE-pay -n 30"
fi
if curl -fsS --max-time 8 "$API_URL/farms" 2>/dev/null | grep -q '^\['; then
  say "Просмотр ферм (/farms) отвечает ✅"
else
  warn "/farms не отвечает — смотри: journalctl -u $SERVICE-pay -n 30"
fi
if curl -fsS --max-time 10 "$API_URL/game/" 2>/dev/null | grep -q 'viewBuild'; then
  say "Игра на сервере открывается по $API_URL/game/ — новая версия ✅"
fi
echo
say "Ответ /event сейчас:"; curl -fsS "$API_URL/event"; echo

# --- проверки оплаты ---
BOT_TOKEN_VAL="$(get_env BOT_TOKEN)"
if curl -fsS --max-time 10 "https://api.telegram.org/bot$BOT_TOKEN_VAL/getMe" 2>/dev/null | grep -q '"ok":true'; then
  say "Токен бота рабочий ✅"
else
  warn "Telegram не принял BOT_TOKEN — проверь токен в .env"
fi
INV="$(curl -sS --max-time 8 -X POST -H 'Content-Type: application/json' -d '{"sku":"vip","initData":""}' "$API_URL/invoice" 2>/dev/null || true)"
if echo "$INV" | grep -q 'bad request'; then say "Маршрут /invoice работает (без подписи Telegram отклоняет — это верно) ✅"; else warn "/invoice ответил неожиданно: $INV — смотри: journalctl -u $SERVICE-pay -n 30"; fi
"$PY" -c "import telebot; assert hasattr(telebot.TeleBot,'create_invoice_link')" 2>/dev/null \
  && say "pyTelegramBotAPI поддерживает Stars ✅" || warn "Устарела pyTelegramBotAPI: $VENV/bin/pip install -U pyTelegramBotAPI"
systemctl is-active --quiet "$SERVICE-pay" && say "Сервис оплаты $SERVICE-pay активен ✅" || warn "Сервис $SERVICE-pay не активен: journalctl -u $SERVICE-pay -n 30"

systemctl is-active --quiet "$SERVICE" || { err "Сервис $SERVICE не активен"; journalctl -u "$SERVICE" -n 40 --no-pager; exit 1; }

echo
say "Готово! Ссылка на игру для бота и @BotFather:"
echo "  $FULL_URL"
echo "Запасная ссылка (если GitHub Pages недоступен):"
echo "  $BACKUP_URL"
echo
echo "Если игра открывается через Menu Button в @BotFather, замени там ссылку на эту."
echo "Telegram мог закэшировать старую версию — закрой игру полностью и открой заново."
echo
echo "Полезные команды:"
echo "  journalctl -u $SERVICE -f      # логи бота"
echo "  systemctl restart $SERVICE     # рестарт после правки .env"
echo "  journalctl -u caddy -n 40      # логи HTTPS"
