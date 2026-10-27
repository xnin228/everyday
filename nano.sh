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
# на свежем сервере apt часто занят автообновлением — ждём, пока освободится
for _i in $(seq 1 60); do
  fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/lib/dpkg/lock >/dev/null 2>&1 || break
  [[ $_i == 1 ]] && warn "apt занят другим процессом (автообновление системы) — жду…"
  sleep 5
done
# нет DNS — подставляем публичный
if ! getent hosts deb.debian.org >/dev/null 2>&1 && ! getent hosts archive.ubuntu.com >/dev/null 2>&1; then
  warn "DNS не отвечает — добавляю 1.1.1.1 и 8.8.8.8"
  echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf 2>/dev/null || true
fi
dpkg --configure -a >/dev/null 2>&1 || true
APT_OK=0
for _i in 1 2 3 4; do
  apt-get update -y 2>&1 | tail -4
  if apt-get install -y python3 python3-venv python3-pip curl ca-certificates nano 2>&1 | tail -4; then
    command -v python3 >/dev/null && command -v curl >/dev/null && { APT_OK=1; break; }
  fi
  warn "apt не сработал, повтор $_i/3 через 10 секунд…"; sleep 10
  dpkg --configure -a 2>&1 | tail -3 || true
  apt-get -f install -y 2>&1 | tail -3 || true
  apt-get update -y >/dev/null 2>&1; apt-get dist-upgrade -y -o Dpkg::Options::=--force-confold 2>&1 | tail -3 || true
done
[[ $APT_OK == 1 ]] || { err "Не удалось поставить пакеты (python3, curl). Ошибка apt видна выше — пришли её мне."; exit 1; }
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
    админ (ADMIN_ID):  /event · /event x2 60 · /event off [x2] · /weather · /weather rain 60 · /weather off  (подробно: /event и /weather без параметров)
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
    if "events" not in d:                       # перенос старого одиночного ивента в список (данные игроков не трогаем)
        old = d.get("event")
        d["events"] = [dict(old, key=old.get("key") or "old")] if old else []
    d.setdefault("weather", {"type": "auto", "end": 0})
    return d


def save(d):
    tmp = DATA + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False)
    os.replace(tmp, DATA)


def clean(s, n=24):
    return re.sub(r"[<>&\"'`]", "", str(s or ""))[:n].strip()


def active_events():
    now = time.time() * 1000
    return [e for e in load().get("events", []) if e.get("end", 0) > now]


def active_event():
    a = active_events()
    return a[0] if a else None          # для старых версий игры


def weather_now():
    w = load().get("weather") or {}
    t = w.get("type", "auto")
    if t in ("auto", "off"):
        return {"type": t, "end": 0}
    if w.get("end", 0) > time.time() * 1000:
        return {"type": t, "end": w["end"]}
    return {"type": "auto", "end": 0}


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
            return self._send(200, {"now": int(time.time() * 1000), "event": active_event(), "events": active_events(), "weather": weather_now()})
        if p == "/top":
            try:
                import admin
                return self._send(200, admin.top_all(50))
            except Exception:
                return self._send(200, [])
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
                return self._send(200, {"ok": True})     # рейтинг теперь считается из проверенных снимков (/snap), этот приём отключён
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
    lang = (getattr(m.from_user, "language_code", "") or "").lower()
    ru = lang[:2] in ("ru", "uk", "be", "kk")
    note = ""
    parts = (m.text or "").split(maxsplit=1)
    if len(parts) > 1 and parts[1].startswith("ref_"):       # приглашение друга: t.me/бот?start=ref_<код>
        try:
            import admin as _adm
            r = _adm.ref_set(m.from_user.id, parts[1][4:], bot)
            if r.get("ok"):
                note = ("\n\n🎁 Вас пригласил друг: в игре вас ждёт бонус %d 🪙!" if ru else "\n\n🎁 A friend invited you: a %d 🪙 bonus is waiting in the game!") % r["welcome"]
        except Exception:
            pass
    txt = ("🌱 Добро пожаловать на «Мини-ферму»!\nСажайте, собирайте урожай, стройте и растите ферму." if ru
           else "🌱 Welcome to Mini Farm!\nPlant, harvest, build and grow your farm.")
    bot.send_message(m.chat.id, txt + note, reply_markup=play_kb())


PRESETS = {
    "x2": ("⚡", "Двойной опыт и монеты", {"xp": 2, "coins": 2}),
    "x3": ("🔥", "Тройной опыт и монеты", {"xp": 3, "coins": 3}),
    "x4": ("🔥", "×4 опыт и монеты", {"xp": 4, "coins": 4}),
    "x5": ("💥", "×5 опыт и монеты", {"xp": 5, "coins": 5}),
    "x10": ("💎", "×10 опыт и монеты", {"xp": 10, "coins": 10}),
}
KEYS = {"xp": "опыт", "coins": "цены", "speed": "рост", "yield": "урожай"}


def parse_mins(x, default=60):
    """'90' / '90m' / '2h' / '1d' -> минуты (1 … 10080)."""
    x = (x or "").lower().strip()
    if not x:
        return default
    k = 1
    if x[-1] in "mмhчdд":
        k = {"m": 1, "м": 1, "h": 60, "ч": 60, "d": 1440, "д": 1440}[x[-1]]
        x = x[:-1]
    return max(1, min(10080, int(float(x) * k)))


def fmt_left(ms):
    m = max(0, int(round(ms / 60000.0)))
    return "%d ч %d мин" % (m // 60, m % 60) if m >= 60 else "%d мин" % m


def start_event(key_or_name, mult, minutes):
    if key_or_name in PRESETS:
        em, name, vals = PRESETS[key_or_name]
    elif key_or_name in KEYS:
        em, name, vals = "🎉", "Ивент: %s ×%s" % (KEYS[key_or_name], mult), {key_or_name: mult}
    else:
        return None
    e = {"id": "ev%d" % int(time.time()), "key": key_or_name, "name": name, "emoji": em, "desc": "",
         "end": int((time.time() + minutes * 60) * 1000)}
    e.update(vals)
    with LK:
        d = load()
        d["events"] = [x for x in d["events"] if x.get("key") != key_or_name] + [e]   # тот же ключ — заменяем
        d["event"] = None
        save(d)
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


EV_HELP = ("Команды ивентов (акций):\n"
           "/event — что сейчас активно\n"
           "/event x2 60 — ×2 опыт и монеты на 60 минут (x2 x3 x4 x5 x10; время: 90, 90m, 2h, 1d)\n"
           "/event xp 2 30 — только опыт · coins — цены · speed — рост · yield — урожай\n"
           "добавь слово «тихо» в конец — без рассылки игрокам\n"
           "/event off x2 — выключить только акцию x2 (или xp, coins, speed, yield, x3…)\n"
           "/event off — выключить ВСЕ акции\n"
           "Акции с разными ключами работают одновременно и суммируются: x2 + xp 3 = ×4 опыта.\n"
           "Донат-множитель игрока тоже суммируется с акцией: донат ×7 + акция ×2 = ×8 (7+2−1).")


def event_cmd(m, args):
    if not is_admin(m):
        return
    quiet = False
    if args and args[-1].lower() in ("тихо", "quiet", "q", "silent"):
        quiet = True; args = args[:-1]
    if not args:
        a = active_events(); now = time.time() * 1000
        head = ("Сейчас активно:\n" + "\n".join("• %s %s [%s] — ещё %s" % (e["emoji"], e["name"], e.get("key", "?"), fmt_left(e["end"] - now)) for e in a) + "\n\n") if a else "Акций нет.\n\n"
        return bot.reply_to(m, head + EV_HELP)
    if args[0] == "off":
        with LK:
            d = load()
            if len(args) > 1:
                k = args[1]
                n0 = len(d["events"])
                d["events"] = [x for x in d["events"] if x.get("key") != k and x.get("id") != k]
                gone = n0 - len(d["events"])
            else:
                gone = len(d["events"]); d["events"] = []
            d["event"] = None; save(d)
        return bot.reply_to(m, ("Выключено акций: %d." % gone) if gone else "Такой акции нет. Список: /event")
    try:
        if args[0] in PRESETS:
            mins = parse_mins(args[1] if len(args) > 1 else "")
            e = start_event(args[0], None, mins)
        else:
            mult = float(args[1].replace(",", ".")); mins = parse_mins(args[2] if len(args) > 2 else "")
            mult = max(1.0, min(50.0, mult)); mult = int(mult) if mult == int(mult) else mult
            e = start_event(args[0], mult, mins)
    except Exception:
        e = None
    if not e:
        return bot.reply_to(m, "Не понял.\n\n" + EV_HELP)
    bot.reply_to(m, "✅ Запущено: %s %s на %s%s. Игроки увидят баннер в течение 15 секунд." % (e["emoji"], e["name"], fmt_left((e["end"] - time.time() * 1000)), "" if quiet else " (рассылка идёт)"))
    if not quiet:
        threading.Thread(target=notify_subs, args=("%s %s!\nЗаходите играть — это ненадолго." % (e["emoji"], e["name"]),), daemon=True).start()


@bot.message_handler(commands=["event", "events"])
def _event(m):
    event_cmd(m, (m.text or "").split()[1:])


for _k in PRESETS:
    def _mk(k):
        @bot.message_handler(commands=[k])
        def _h(m):
            a = (m.text or "").split()[1:]
            event_cmd(m, [k] + a)
    _mk(_k)


# ---------------- погода ----------------
WEATHER = {
    "rain": ("🌧", "Дождь", "урожай +1 с грядки"),
    "snow": ("❄️", "Снег", "красиво, без бонуса"),
    "sun": ("☀️", "Солнечно", "тёплый свет, без бонуса"),
    "storm": ("⛈", "Гроза", "тёмное небо и молнии, без бонуса"),
}
WX_HELP = ("Команды погоды:\n"
           "/weather — что сейчас\n"
           "/weather rain 60 — включить дождь на 60 минут (rain, snow, sun, storm; время: 90, 90m, 2h, 1d)\n"
           "/weather snow 2h push — то же, но с рассылкой игрокам\n"
           "/weather off — ПОЛНОСТЬЮ выключить погоду (и случайный дождь тоже), пока не включишь снова\n"
           "/weather auto — вернуть обычное поведение (иногда сам идёт дождь)\n"
           "Короткие: /rain 60 · /snow 60 · /sun 60 · /storm 60\n"
           "Дождь даёт +1 к урожаю с грядки, остальная погода — только картинка. Погода не мешает акциям.")


def weather_cmd(m, args):
    if not is_admin(m):
        return
    push = bool(args and args[-1].lower() in ("push", "всем", "рассылка"))
    if push:
        args = args[:-1]
    w = weather_now()
    if not args:
        if w["type"] == "off":
            st = "Погода выключена (команда /weather off)."
        elif w["type"] == "auto":
            st = "Автопогода: иногда сам идёт дождь."
        else:
            em, nm, _ = WEATHER[w["type"]]
            st = "Сейчас: %s %s — ещё %s." % (em, nm, fmt_left(w["end"] - time.time() * 1000))
        return bot.reply_to(m, st + "\n\n" + WX_HELP)
    t = args[0].lower()
    if t in ("off", "выкл", "stop", "none"):
        with LK:
            d = load(); d["weather"] = {"type": "off", "end": 0}; save(d)
        return bot.reply_to(m, "☁️ Погода выключена полностью (дождь тоже). Вернуть: /weather auto")
    if t in ("auto", "авто"):
        with LK:
            d = load(); d["weather"] = {"type": "auto", "end": 0}; save(d)
        return bot.reply_to(m, "🔄 Автопогода включена.")
    if t not in WEATHER:
        return bot.reply_to(m, "Не понял.\n\n" + WX_HELP)
    try:
        mins = parse_mins(args[1] if len(args) > 1 else "")
    except Exception:
        return bot.reply_to(m, "Время не понял. Пример: /weather rain 90")
    end = int((time.time() + mins * 60) * 1000)
    with LK:
        d = load(); d["weather"] = {"type": t, "end": end}; save(d)
    em, nm, note = WEATHER[t]
    bot.reply_to(m, "✅ %s %s на %s (%s). Игроки увидят в течение 15 секунд.%s" % (em, nm, fmt_left(mins * 60000), note, " Рассылка идёт." if push else ""))
    if push:
        threading.Thread(target=notify_subs, args=("%s %s в «Мини-ферме»!\nЗаходите посмотреть." % (em, nm),), daemon=True).start()


@bot.message_handler(commands=["weather", "pogoda"])
def _weather(m):
    weather_cmd(m, (m.text or "").split()[1:])


for _w in WEATHER:
    def _mw(k):
        @bot.message_handler(commands=[k])
        def _h(m):
            weather_cmd(m, [k] + (m.text or "").split()[1:])
    _mw(_w)


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
  _T="${BOT_TOKEN:-8944057158:AAFoTzSe3g1ojdu2EC3knaUsKRYkxcA0xcg}"
  if [[ -z "$_T" && -t 0 ]]; then read -rp "Вставь BOT_TOKEN (из @BotFather): " _T; fi
  [[ -n "$_T" ]] && set_env BOT_TOKEN "$(echo "$_T" | tr -d ' \r')"
fi
if [[ -z "$(get_env ADMIN_ID)" ]]; then
  _A="${ADMIN_ID:-694228839}"
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
import hashlib, hmac, json, os, threading, time, uuid
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

# платные скины: skin_<категория>_<id> -> цена в ⭐ (должно совпадать с каталогом SKD в index.html)
_BLD = {"purple": 25, "gold": 45, "neon": 75}
SKINS = {
    "soil": {"moss": 25, "moon": 45, "gold": 75},
    "fence": {"stone": 25, "neon": 45, "gold": 75},
    "path": {"brick": 25, "moon": 45, "gold": 75},
    "barn": _BLD, "stall": _BLD, "coop": _BLD, "obj": _BLD,
    "lake": {"emerald": 25, "lagoon": 45, "lava": 75},
    "grass": {"sakura": 25, "winter": 45, "night": 75},
}

# скины питомцев: pskin_<id> -> цена в ⭐ (должно совпадать с PSK в index.html)
PSKINS = {"ice": 45, "candy": 45, "neon": 60, "shadow": 60, "gold": 75, "holo": 100}

def price(sku):
    p = sku.split("_")
    try:
        if p[0] == "skin" and len(p) == 3 and p[1] in SKINS and p[2] in SKINS[p[1]]:
            return SKINS[p[1]][p[2]]
        if p[0] == "egg" and len(p) == 3 and p[1] in ("farm", "swamp", "halloween", "future", "dino", "aqua") and p[2] in ("s", "e"):
            return {"s": 25, "e": 75}[p[2]]
        if p[0] == "chest" and p[1] in ("c", "r", "l"):
            return {"c": 15, "r": 45, "l": 120}[p[1]]
        if p[0] == "bx" and 2 <= int(p[1]) <= 10 and int(p[2]) in (1, 3, 7):
            return int(p[1]) * int(p[2]) * 5
        if p[0] == "pskin" and len(p) == 2 and p[1] in PSKINS: return PSKINS[p[1]]
        if sku == "vip": return 150
        if sku == "bp": return 100
    except (IndexError, ValueError):
        pass
    return None

def led_add(d, uid, sku):
    """Журнал того, что сервер выдал игроку: сундуки по видам и удобрение. Нужен для проверки, что на руках не больше выданного."""
    try:
        p = str(sku).split("_"); L = d.setdefault("led", {}).setdefault(str(uid), {})
        if p[0] == "chest" and p[1] in ("c", "r", "l"): L[p[1]] = L.get(p[1], 0) + 1
        elif p[0] == "pskin" and p[1] in PSKINS:
            ps = L.setdefault("ps", [])
            if p[1] not in ps: ps.append(p[1])
        elif sku.startswith("adm_fert_"):
            n = int(sku[9:])
            if n > 0: L["fe"] = L.get("fe", 0) + n
    except Exception:
        pass

def _load():
    try:
        with open(FILE, encoding="utf-8") as f: return json.load(f)
    except Exception:
        return {"grants": {}, "paid": [], "hist": []}

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

def _norm(d, uid):
    """Выдачи хранятся как строки (старый формат) или {"id","sku"}; приводим к {"id","sku"}."""
    out = []
    for g in d["grants"].get(uid, []):
        if isinstance(g, str): g = {"id": uuid.uuid4().hex[:12], "sku": g}
        out.append(g)
    d["grants"][uid] = out
    return out

def api_claim(body):
    """v=2: выдачи НЕ удаляются при получении — игра подтверждает их сама (ack),
    поэтому покупка не пропадёт, даже если ответ потерялся по дороге.
    Без v (старая версия игры): как раньше — отдали и удалили."""
    uid = user_id(body.get("initData", ""))
    if not uid: return {"grants": [], "items": []}
    with _Lock():
        d = _load(); items = _norm(d, uid)
        ack = set(str(x) for x in (body.get("ack") or []))
        if ack:
            items = [g for g in items if g["id"] not in ack]; d["grants"][uid] = items
            for h in d.get("hist", []):
                if h.get("uid") == uid and h.get("gid") in ack: h["got"] = int(time.time())
        if body.get("v") == 2:
            if not d["grants"].get(uid): d["grants"].pop(uid, None)
            _save(d)
            return {"items": items, "grants": []}
        d["grants"].pop(uid, None); _save(d)
    return {"grants": [g["sku"] for g in items], "items": []}

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
            gid = uuid.uuid4().hex[:12]
            d["grants"].setdefault(uid, []).append({"id": gid, "sku": sku})
            led_add(d, uid, sku)
            d.setdefault("hist", []).append({"uid": uid, "sku": sku, "gid": gid, "amt": sp.total_amount, "t": int(time.time()), "got": 0})
            d["hist"] = d["hist"][-500:]
            # партнёрка: пригласивший получает % от покупки (в монетах игры)
            inv = (d.get("ref") or {}).get(uid); rb = 0
            if inv and sp.total_amount > 0:
                try:
                    import admin as _a
                    rb = _a.ref_bonus(sp.total_amount)
                    d["grants"].setdefault(inv, []).append({"id": uuid.uuid4().hex[:12], "sku": "ref_%d" % rb})
                    st = d.setdefault("refstat", {}).setdefault(inv, {"n": 0, "coins": 0}); st["coins"] += rb
                except Exception:
                    rb = 0
            _save(d)
        try:
            import admin as _an
            _an.notify("pay", "💰 Покупка: %s — <code>%s</code>, %s ⭐" % (_an._nm(uid), sku, sp.total_amount))
        except Exception: pass
        if rb and inv:
            try: bot.send_message(int(inv), "🤝 Ваш друг сделал покупку: вам +%d 🪙 (партнёрская программа). Заберите в игре!" % rb)
            except Exception: pass

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

admin._BOT = bot
import time as _t, collections as _c
_RL = {}
def _rate_ok(ip, limit=240, window=60):
    """Не больше `limit` запросов в минуту с одного адреса."""
    now = _t.time(); q = _RL.setdefault(ip, _c.deque())
    while q and q[0] < now - window: q.popleft()
    if len(q) >= limit: return False
    q.append(now)
    if len(_RL) > 5000:
        for k in [k for k, v in _RL.items() if not v or v[-1] < now - window]: _RL.pop(k, None)
    return True

class H(BaseHTTPRequestHandler):
    def _ip(self):
        return (self.headers.get("X-Forwarded-For") or self.client_address[0]).split(",")[0].strip()
    def _send(self, code, obj):
        b = json.dumps(obj, ensure_ascii=False).encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8"); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if not _rate_ok(self._ip()): return self._send(429, {"error": "too many requests"})
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
        if not _rate_ok(self._ip()):
            admin.notify("sec", "⚠️ Много запросов с IP <code>%s</code> (лимит сработал)" % self._ip(), key="rl" + self._ip(), every=900)
            return self._send(429, {"error": "too many requests"})
        try:
            n = int(self.headers.get("Content-Length") or 0)
            if n > 60000: return self._send(413, {"error": "too large"})
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception: return self._send(400, {"error": "bad json"})
        try:
            _u0 = payments.user_id(body.get("initData", "")) if isinstance(body, dict) else None
            if _u0:
                _b = admin.ban_get(_u0)
                if body.get("op") == "ban":
                    return self._send(200, {"ok": True, "ban": _b})
                if _b:
                    admin.notify("sec", "🚫 Забаненный пытается играть: %s" % admin._nm(_u0), key="bt" + str(_u0), every=3600)
                    return self._send(200, {"ok": False, "err": "ban", "ban": _b})
            elif body.get("op") == "ban":
                return self._send(200, {"ok": False})
            if self.path == "/clan": return self._send(200, admin.clan_api(body, bot))
            if self.path == "/invoice": return self._send(200, payments.api_invoice(bot, body))
            if self.path == "/claim":
                if body.get("op") in ("box", "send", "ack"): return self._send(200, admin.mail_api(body, bot))
                if body.get("op") == "ann": return self._send(200, {"ok": True, "ann": admin.ann_get()})
                if body.get("op") == "help": return self._send(200, admin.help_api(body, bot))
                if body.get("op") == "topweek":
                    u = payments.user_id(body.get("initData", ""))
                    return self._send(200, admin.top_week(u) if u else {"ok": False})
                if body.get("op") in ("ref", "refset", "ping"): return self._send(200, admin.ref_api(body, bot))
                return self._send(200, payments.api_claim(body))
            if self.path == "/snap":
                uid = payments.user_id(body.get("initData", ""))
                if not uid: return self._send(200, {"ok": False})
                ok = admin.record_snapshot(uid, body.get("name"), body.get("lvl"), body.get("xp"), body.get("coins"), body.get("snap"), 1 if body.get("tm") else 0, {"ch": body.get("ch"), "fe": body.get("fe"), "cd": body.get("cd")})
                return self._send(200, {"ok": bool(ok)})
        except Exception as e:
            admin.notify("err", "❗ Ошибка сервера <code>%s</code>: %s" % (self.path, str(e)[:150]), key=self.path + str(e)[:40], every=600)
            return self._send(500, {"error": str(e)[:100]})
        self._send(404, {"error": "not found"})
    def log_message(self, *a): pass

import threading, time
def _weekly():
    time.sleep(30)
    while True:
        try: admin.week_tick(bot)
        except Exception as e: print("week_tick:", e, flush=True)
        time.sleep(600)
threading.Thread(target=_weekly, daemon=True).start()
admin.notify("boot", "🟢 Сервис платежей и API запущен")
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
import hashlib, json, os, re, threading, time, uuid

import payments as P

HERE = os.path.dirname(os.path.abspath(__file__))
PFILE = os.path.join(HERE, "players.json")
LOGF = os.path.join(HERE, "admin.log")
_last = {}
_on = {}            # игроки онлайн: uid -> время последнего сигнала
ONLINE_SEC = 150
_lk = threading.Lock()


# ---------- хранилище игроков ----------
_pc = {"m": None, "d": {}}


def _pload():
    """Читает players.json; повторно не парсит, пока файл не изменился (разгрузка сервера)."""
    try:
        m = os.stat(PFILE).st_mtime_ns
    except Exception:
        return {}
    if _pc["m"] == m:
        return _pc["d"]
    try:
        with open(PFILE, encoding="utf-8") as f:
            d = json.load(f)
    except Exception:
        return {}
    _pc["m"], _pc["d"] = m, d
    return d


def _psave(d):
    tmp = PFILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False)
    os.replace(tmp, PFILE)


def hid(uid):
    return hashlib.sha1(("mf:" + str(uid)).encode()).hexdigest()[:10]


def _clean(s, n=24):
    return re.sub(r"[<>&\"'`]", "", str(s or ""))[:n].strip()


XP_ABS_MAX = 30_000_000      # выше — нереально, сразу под подозрение
XP_NEW_MAX = 5_000_000       # потолок для самого первого снимка игрока
XP_BASE = 30_000             # разрешённый рост опыта между снимками: база + в час
XP_PER_H = 60_000
COINS_ABS_MAX = 500_000_000
LVX = 32                     # как в игре: уровень = floor(sqrt(xp / 32)) + 1
_BOT = None                  # сюда payments_http кладёт объект бота — для уведомлений админу


def _suspicious(old, xp, lvl, coins, now, tm, ex=None):
    """Возвращает причину подозрения или None."""
    if old.get("trust") or old.get("tu", 0) > now:
        return None
    if tm: return "изменено сохранение на телефоне (подпись не совпала)"
    ex = ex or {}
    cd = ex.get("cd"); led = ex.get("led") or {}; lb = old.get("lb")
    if isinstance(cd, dict) and lb:
        lt = old.get("lt") or {}
        for t, bp, nm in (("c", 0, "обычных"), ("r", 3, "редких"), ("l", 1, "легендарных")):
            hand = int(cd.get(t) or 0)
            allow = int(lb.get(t, 0)) + max(0, int(led.get(t, 0)) - int(lt.get(t, 0))) + bp
            if hand > allow:
                return "сундуков (%s) на руках %d, а выдано/заработано не больше %d" % (nm, hand, allow)
    if lb and ex.get("fe") is not None:
        hrs = max(0.0, (now - old.get("lbt", now)) / 3600.0)
        allow = int(old.get("fb", 0)) + 600 + int(400 * hrs) + max(0, int(led.get("fe", 0)) - int((old.get("lt") or {}).get("fe", 0)))
        if int(ex.get("fe") or 0) > allow:
            return "удобрение выросло быстрее возможного: %s при допустимых ~%d" % (ex.get("fe"), allow)
    if int(ex.get("ch") or 0) > 100: return "сундуков на руках: %s (нереально много)" % ex.get("ch")
    if int(ex.get("fe") or 0) > 20000: return "удобрения на руках: %s (нереально много)" % ex.get("fe")
    if xp >= XP_ABS_MAX: return "опыт %d выше возможного" % xp
    if coins >= COINS_ABS_MAX: return "монет %d выше возможного" % coins
    lv2 = int((xp / LVX) ** 0.5) + 1
    if abs(int(lvl or 1) - lv2) > 1: return "уровень %s не соответствует опыту %d" % (lvl, xp)
    if not old:
        if xp > XP_NEW_MAX: return "новый игрок сразу с опытом %d" % xp
        return None
    dt = max(0.0, now - old.get("seen", now)); hours = min(dt / 3600.0, 24 * 30)
    allowed = XP_BASE + XP_PER_H * hours
    if xp - old.get("xp", 0) > allowed:
        return "опыт вырос на %d за %.1f ч (допустимо ~%d)" % (xp - old.get("xp", 0), hours, allowed)
    oc = old.get("coins", 0)
    if coins > oc * 50 + 5_000_000: return "монеты выросли с %d до %d" % (oc, coins)
    return None


def out_of_rating(uid, v, hd=None):
    hd = hidden_ids() if hd is None else hd
    return str(uid) in hd or bool(v.get("flag"))


def _alert(uid, rec, why, claimed):
    """Сообщение админу с кнопками (не чаще раза в 6 часов на игрока)."""
    notify("sec", "🚨 Флаг: %s — %s" % (_nm(uid), _mclean(why, 100)), key="flag" + str(uid), every=21600)
    bot = _BOT; aid = _admin_id()
    if not bot or not aid: return
    if time.time() - rec.get("fa", 0) < 6 * 3600: return
    rec["fa"] = int(time.time())
    from telebot import types
    k = types.InlineKeyboardMarkup()
    k.row(types.InlineKeyboardButton("✅ Оставить", callback_data="adm:fk:%s" % uid),
          types.InlineKeyboardButton("🗑 Обнулить", callback_data="adm:fr:%s" % uid))
    k.row(types.InlineKeyboardButton("🙈 Спрятать навсегда", callback_data="adm:fh:%s" % uid))
    txt = ("🚨 <b>Подозрение на накрутку</b>\nИгрок: <b>%s</b> (<code>%s</code>)\nПричина: %s\n"
           "Заявлено: опыт %s, монет %s\n\nПока он скрыт из рейтингов и списка ферм, его цифры не приняты."
           % (_clean(rec.get("name"), 24), uid, _mclean(why, 160), claimed[0], claimed[1]))
    def _s():
        try: bot.send_message(int(aid), txt, parse_mode="HTML", reply_markup=k)
        except Exception: pass
    threading.Thread(target=_s, daemon=True).start()


PSK_IDS = ("ice", "candy", "neon", "shadow", "gold", "holo")


def _snap_clean(snap, led):
    """Питомцы в снимке для гостей: скин показываем только купленный, бирку чистим от разметки."""
    try:
        pt = snap.get("pt")
        if isinstance(pt, list):
            own = set((led or {}).get("ps") or []); out = []
            for q in pt[:3]:
                if not isinstance(q, list) or not q: continue
                sk = str(q[3]) if len(q) > 3 else ""
                nm = _clean(q[4], 12) if len(q) > 4 else ""
                out.append([q[0], q[1] if len(q) > 1 else 1, q[2] if len(q) > 2 else 0, sk if (sk in own and sk in PSK_IDS) else "", nm])
            snap["pt"] = out
    except Exception:
        pass
    return snap


def record_snapshot(uid, name, lvl, xp, coins, snap, tm=0, ex=None):
    """Сохраняет снимок фермы игрока (вызывается из HTTP-сервиса)."""
    now = time.time()
    with _lk:
        if now - _last.get(uid, 0) < 15:
            return False
        _last[uid] = now
    _on[str(uid)] = now
    if not isinstance(snap, dict) or len(json.dumps(snap)) > 24000:
        return False
    with P._Lock():
        d = _pload()
        old = d.get(str(uid)) or {}
        nxp = max(0, min(10 ** 9, int(xp or 0)))
        ncoins = max(0, min(10 ** 12, int(coins or 0)))
        ex = dict(ex or {}); ex["led"] = (P._load().get("led") or {}).get(str(uid)) or {}
        why = _suspicious(old, nxp, lvl, ncoins, now, 1 if tm else 0, ex)
        if why:
            # цифры не принимаем: оставляем старые данные, помечаем игрока
            bad = dict(old) if old else {"name": _clean(name) or "Фермер", "lvl": 1, "xp": 0, "coins": 0, "snap": {"w": "farm"}}
            bad["seen"] = int(now); bad["flag"] = {"t": int(now), "why": why, "xp": nxp, "coins": ncoins}
            _alert(str(uid), bad, why, (nxp, ncoins))
            d[str(uid)] = bad; _psave(d)
            return False
        if not old:
            notify("new", "🆕 Новый игрок: <b>%s</b> (<code>%s</code>), ур. %s" % (_clean(name) or "Фермер", uid, max(1, int(lvl or 1))))
        snap = _snap_clean(snap, ex.get("led"))
        wk = week_id(now)
        rec = {
            "name": _clean(name) or "Фермер",
            "lvl": max(1, min(999, int(lvl or 1))),
            "xp": nxp,
            "coins": ncoins,
            "seen": int(now),
            "snap": snap,
        }
        for _k in ("flag", "trust", "tu", "fa", "lb", "lt", "lbt", "fb"):
            if _k in old: rec[_k] = old[_k]
        _cd = ex.get("cd")
        if "lb" not in rec and isinstance(_cd, dict) and ex.get("fe") is not None:
            # точка отсчёта: что у игрока на руках сейчас (уже проверено выше), дальше растёт только по журналу
            rec["lb"] = {t: max(0, int(_cd.get(t) or 0)) for t in ("c", "r", "l")}
            rec["lt"] = dict(ex["led"]); rec["lbt"] = int(now); rec["fb"] = max(0, int(ex.get("fe") or 0))
        if old.get("wk") == wk:
            rec["wk"], rec["wb"] = wk, min(old.get("wb", nxp), nxp)
            if "pwk" in old:
                rec["pwk"], rec["pg"] = old["pwk"], old.get("pg", 0)
        else:
            if "wk" in old:                      # неделя сменилась: запоминаем итог прошлой
                rec["pwk"], rec["pg"] = old["wk"], max(0, old.get("xp", 0) - old.get("wb", old.get("xp", 0)))
            rec["wk"], rec["wb"] = wk, min(old.get("xp", nxp), nxp)
        d[str(uid)] = rec
        _psave(d)
    return True


WEEK_PRIZES = [(10000, "egg_farm_e", "👑 королевское яйцо"), (5000, "egg_farm_s", "💎 яйцо"), (2500, None, "")]


def week_id(t=None):
    """Номер недели; неделя начинается в понедельник 00:00 UTC (03:00 по Москве)."""
    return int(((t or time.time()) - 4 * 86400) // 604800)


def _week_gain(v, w):
    if v.get("wk") == w:
        return max(0, v.get("xp", 0) - v.get("wb", v.get("xp", 0)))
    if v.get("pwk") == w:
        return max(0, v.get("pg", 0))
    return 0


def top_week(uid):
    """Недельный рейтинг: прирост опыта с понедельника."""
    w = week_id(); d = _pload()
    hd = hidden_ids()
    rows = [(u, _week_gain(v, w), v) for u, v in d.items() if not out_of_rating(u, v, hd)]
    rows = [r for r in rows if r[1] > 0]
    rows.sort(key=lambda r: r[1], reverse=True)
    ce = clan_emoji_map()
    out = [{"id": hid(u), "name": v.get("name", "Фермер"), "lvl": v.get("lvl", 1), "gain": g, "ce": ce.get(u, ""),
            "me": 1 if u == str(uid) else 0} for u, g, v in rows[:20]]
    me = next((i + 1 for i, r in enumerate(rows) if r[0] == str(uid)), 0)
    mg = next((r[1] for r in rows if r[0] == str(uid)), 0)
    left = int((w + 1) * 604800 + 4 * 86400 - time.time())
    return {"ok": True, "rows": out, "me": me, "mg": mg, "left": left, "prizes": [p[0] for p in WEEK_PRIZES]}


# ---------- кланы (без войн: общая цель недели) ----------
CLAN_MAX = 20
CLAN_GOAL_PER = 2000          # опыта в неделю на каждого участника — общая цель клана
CLAN_MINC = 200               # минимальный вклад, чтобы получить награду
CLAN_CD = 86400               # пауза после выхода из клана
# (доля цели, монеты каждому, удобрение, яйцо, значок)
CLAN_TIERS = [(1.0, 400, 0, None, "🥉"), (1.5, 900, 5, None, "🥈"), (2.0, 1800, 10, "egg_farm_s", "🥇")]
CLAN_EMO = ["🏰", "🌻", "🐄", "🌾", "🍎", "🐔", "🐝", "🍯", "🥕", "🌽", "🍓", "🐑", "🐴", "🦆", "🐸", "🐻", "🦊", "🌙", "⭐", "🔥", "💎", "🍀", "🎃", "❄️"]


def _cinit(d):
    d.setdefault("clans", {}); d.setdefault("clanof", {}); d.setdefault("clanl", {})


def _cname(s):
    s = re.sub(r"[<>&\"'`]", "", str(s or "")); s = re.sub(r"\s+", " ", s).strip()
    return s[:16]


def _ccode(d):
    import random
    al = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    used = set(c.get("c") for c in d["clans"].values())
    for _ in range(50):
        c = "".join(random.choice(al) for _ in range(6))
        if c not in used: return c
    return uuid.uuid4().hex[:8].upper()


def _cgain(uid, v, w, mrec, hd):
    if not v or out_of_rating(uid, v, hd): return 0
    g = _week_gain(v, w)
    if mrec.get("jw") == w: g -= mrec.get("jg", 0)
    return max(0, min(g, 150000))


def _cstat(c, pl, w, hd):
    rows = []
    for u, m in c["m"].items():
        v = pl.get(u) or {}
        rows.append((u, _cgain(u, v, w, m, hd), v, m))
    total = sum(r[1] for r in rows); goal = CLAN_GOAL_PER * max(1, len(rows))
    return rows, total, goal


def _ctier(total, goal):
    t = -1
    for i, x in enumerate(CLAN_TIERS):
        if total >= goal * x[0]: t = i
    return t


def clan_emoji_map():
    try:
        d = P._load(); cl = d.get("clans") or {}
        return {u: cl[c]["e"] for u, c in (d.get("clanof") or {}).items() if c in cl}
    except Exception:
        return {}


CLAN_COST = 100000            # стоимость создания клана, монет
CLAN_HELPERS = 3              # сколько помощников может быть у главы
CLAN_REQ_TTL = 7 * 86400      # заявки живут неделю
CLAN_JM = ("open", "req", "code")   # свободный вход · по заявке · только по коду (скрыт из поиска)


def _cdesc(s):
    s = re.sub(r"[<>&\"'`]", "", str(s or "")); return re.sub(r"\s+", " ", s).strip()[:60]


def _crole(c, u):
    return "o" if c["o"] == u else ("d" if u in (c.get("r") or {}) else "m")


def _cjoin(d, uid, cid, w, me):
    c = d["clans"][cid]
    c["m"][uid] = {"j": int(time.time()), "jw": w, "jg": _week_gain(me, w)}
    d["clanof"][uid] = cid
    for x in d["clans"].values(): (x.get("req") or {}).pop(uid, None)


def _cremove(d, c, cid, u):
    c["m"].pop(u, None); (c.get("r") or {}).pop(u, None); d["clanof"].pop(u, None)
    if not c["m"]: d["clans"].pop(cid, None); return
    if c["o"] == u:
        hs = [x for x in (c.get("r") or {}) if x in c["m"]]
        pool = hs or list(c["m"])
        c["o"] = min(pool, key=lambda x: (c.get("r") or {}).get(x, {}).get("t", c["m"][x].get("j", 0)) if hs else c["m"][x].get("j", 0))
        (c.get("r") or {}).pop(c["o"], None)


def _cinfo_row(k, c, pl, w, hd):
    rows, total, goal = _cstat(c, pl, w, hd)
    return {"id": k, "n": c["n"], "e": c["e"], "ds": c.get("ds", ""), "k": len(rows), "t": total,
            "pct": int(100 * total / goal), "jm": c.get("jm", "code"), "full": 1 if len(rows) >= CLAN_MAX else 0}


def _cview(d, uid, w, q=None):
    pl = _pload(); hd = hidden_ids(); cl = d["clans"]; cid = d["clanof"].get(uid); now = time.time()
    out = {"ok": True, "per": CLAN_GOAL_PER, "emo": CLAN_EMO, "max": CLAN_MAX, "cost": CLAN_COST, "helpers": CLAN_HELPERS,
           "left": int((w + 1) * 604800 + 4 * 86400 - now),
           "tiers": [{"f": x[0], "c": x[1], "fe": x[2], "egg": 1 if x[3] else 0, "i": x[4]} for x in CLAN_TIERS], "minc": CLAN_MINC}
    cd = d["clanl"].get(uid, 0) + CLAN_CD - now
    if cd > 0: out["cd"] = int(cd)
    allr = [dict(_cinfo_row(k, c, pl, w, hd), me=1 if k == cid else 0) for k, c in cl.items()]
    allr.sort(key=lambda r: (r["pct"], r["t"]), reverse=True)
    out["rank"] = allr[:12]
    out["apps"] = [k for k, c in cl.items() if uid in (c.get("req") or {})]
    if q is not None:
        q = str(q).strip().lower()[:16]
        f = [r for r in allr if r["jm"] != "code" and (not q or q in r["n"].lower())]
        out["found"] = f[:20]
    if cid in cl:
        c = cl[cid]; rows, total, goal = _cstat(c, pl, w, hd)
        order = {"o": 0, "d": 1, "m": 2}
        rows.sort(key=lambda r: (order[_crole(c, r[0])], -r[1]))
        my = _crole(c, uid)
        out["clan"] = {"n": c["n"], "e": c["e"], "code": c["c"], "ds": c.get("ds", ""), "jm": c.get("jm", "code"), "role": my,
                       "owner": 1 if my == "o" else 0, "total": total, "goal": goal, "tier": _ctier(total, goal),
                       "members": [{"h": hid(u), "name": _clean(v.get("name"), 16) or "Фермер", "lvl": v.get("lvl", 1), "g": g,
                                    "r": _crole(c, u), "me": 1 if u == uid else 0} for u, g, v, m in rows]}
        if my in ("o", "d"):
            out["clan"]["reqs"] = [{"h": hid(u), "name": _clean((pl.get(u) or {}).get("name"), 16) or "Фермер", "lvl": (pl.get(u) or {}).get("lvl", 1)}
                                   for u, x in (c.get("req") or {}).items() if now - x.get("t", 0) < CLAN_REQ_TTL and u not in d["clanof"]]
    return out


def clan_api(body, bot=None):
    """POST /clan. op: info · search{q} · create{name,e,jm,ds} · join{code} · joinopen{id} · apply{id} · accept{h} · decline{h} ·
    kick{h} · promote{h} · demote{h} · transfer{h} · set{jm,ds} · newcode · leave · disband."""
    uid = P.user_id(body.get("initData", ""))
    if not uid: return {"ok": False, "err": "auth"}
    op = body.get("op"); w = week_id(); now = time.time(); err = None; ev = None; tell = []
    with P._Lock():
        d = P._load(); _cinit(d); cl = d["clans"]
        cid = d["clanof"].get(uid)
        if cid and cid not in cl: d["clanof"].pop(uid, None); cid = None
        c = cl.get(cid) if cid else None
        pl = _pload(); me = pl.get(uid) or {}
        my = _crole(c, uid) if c else None

        def tgt():
            return next((u for u in c["m"] if hid(u) == str(body.get("h", ""))), None) if c else None

        if op == "create":
            name = _cname(body.get("name")); e = str(body.get("e") or ""); jm = body.get("jm") if body.get("jm") in CLAN_JM else "req"
            if c: err = "Вы уже в клане"
            elif d["clanl"].get(uid, 0) + CLAN_CD > now: err = "После выхода из клана нужно подождать до суток"
            elif len(name) < 2: err = "Название: от 2 до 16 символов"
            elif e not in CLAN_EMO: err = "Выберите значок клана"
            elif any(x["n"].lower() == name.lower() for x in cl.values()): err = "Такое название уже занято"
            elif len(cl) >= 500: err = "Слишком много кланов"
            elif not me: err = "Откройте ферму и подождите минуту — потом можно создать клан"
            elif int(me.get("coins", 0)) < CLAN_COST: err = "Нужно %d монет для создания клана" % CLAN_COST
            else:
                cid = uuid.uuid4().hex[:8]
                cl[cid] = {"n": name, "e": e, "o": uid, "c": _ccode(d), "t": int(now), "jm": jm, "ds": _cdesc(body.get("ds")), "r": {}, "req": {},
                           "m": {uid: {"j": int(now), "jw": w, "jg": _week_gain(me, w)}}}
                d["clanof"][uid] = cid
                for x in cl.values(): (x.get("req") or {}).pop(uid, None)
                d["grants"].setdefault(uid, []).append({"id": uuid.uuid4().hex[:12], "sku": "adm_coins_-%d" % CLAN_COST})
                ev = "🏰 Клан создан: %s %s (−%d 🪙)" % (e, name, CLAN_COST)
        elif op == "join":
            code = re.sub(r"[^A-Z0-9]", "", str(body.get("code") or "").upper())
            tc = next((k for k, x in cl.items() if x["c"] == code), None) if code else None
            if c: err = "Вы уже в клане"
            elif d["clanl"].get(uid, 0) + CLAN_CD > now: err = "После выхода из клана нужно подождать до суток"
            elif not tc: err = "Клан с таким кодом не найден"
            elif len(cl[tc]["m"]) >= CLAN_MAX: err = "В клане нет мест (макс. %d)" % CLAN_MAX
            else:
                _cjoin(d, uid, tc, w, me); cid = tc; ev = "🏰 Вступил в клан %s %s" % (cl[tc]["e"], cl[tc]["n"])
        elif op in ("joinopen", "apply"):
            tc = str(body.get("id") or ""); x = cl.get(tc)
            if c: err = "Вы уже в клане"
            elif d["clanl"].get(uid, 0) + CLAN_CD > now: err = "После выхода из клана нужно подождать до суток"
            elif not x: err = "Клан не найден"
            elif len(x["m"]) >= CLAN_MAX: err = "В клане нет мест (макс. %d)" % CLAN_MAX
            elif op == "joinopen":
                if x.get("jm") != "open": err = "В этот клан вход по заявке"
                else: _cjoin(d, uid, tc, w, me); cid = tc; ev = "🏰 Вступил в клан %s %s" % (x["e"], x["n"])
            else:
                if x.get("jm") != "req": err = "В этот клан нельзя подать заявку"
                else:
                    rq = x.setdefault("req", {})
                    for k2 in [k for k, v in rq.items() if now - v.get("t", 0) > CLAN_REQ_TTL]: rq.pop(k2, None)
                    if uid in rq: err = "Заявка уже подана"
                    elif sum(1 for y in cl.values() if uid in (y.get("req") or {})) >= 3: err = "Не больше 3 заявок одновременно"
                    elif len(rq) >= 30: err = "У клана слишком много заявок"
                    else:
                        rq[uid] = {"t": int(now)}
                        tell.append((x["o"], "📨 В клан «%s» подана заявка от %s. Откройте игру → Клан → Заявки." % (x["n"], _clean(me.get("name"), 16) or "игрока")))
        elif op in ("accept", "decline"):
            if not c or my not in ("o", "d"): err = "Это могут только глава и помощники"
            else:
                tu = next((u for u in (c.get("req") or {}) if hid(u) == str(body.get("h", ""))), None)
                if not tu: err = "Заявка не найдена"
                elif op == "decline": c["req"].pop(tu, None)
                elif tu in d["clanof"]: c["req"].pop(tu, None); err = "Игрок уже вступил в другой клан"
                elif len(c["m"]) >= CLAN_MAX: err = "В клане нет мест"
                else:
                    _cjoin(d, tu, cid, w, pl.get(tu) or {}); ev = "🏰 В клан %s принят игрок %s" % (c["n"], (pl.get(tu) or {}).get("name", "?"))
                    tell.append((tu, "🏰 Вас приняли в клан «%s»! Откройте игру → Клан." % c["n"]))
        elif op == "leave":
            if not c: err = "Вы не в клане"
            else:
                _cremove(d, c, cid, uid); d["clanl"][uid] = int(now); ev = "🏰 Вышел из клана %s" % c["n"]
        elif op in ("kick", "promote", "demote", "transfer", "set", "newcode", "disband"):
            if not c: err = "Вы не в клане"
            elif op == "kick":
                tu = tgt()
                if my not in ("o", "d"): err = "Исключать могут глава и помощники"
                elif not tu or tu == uid: err = "Нельзя исключить этого игрока"
                elif my == "d" and _crole(c, tu) != "m": err = "Помощник может исключать только участников"
                else:
                    _cremove(d, c, cid, tu); d["clanl"][tu] = int(now)
                    ev = "🏰 Исключён из клана %s: %s" % (c["n"], (pl.get(tu) or {}).get("name", "?"))
                    tell.append((tu, "🏰 Вас исключили из клана «%s»." % c["n"]))
            elif my != "o": err = "Это может только глава клана"
            elif op == "newcode": c["c"] = _ccode(d)
            elif op == "set":
                if body.get("jm") in CLAN_JM: c["jm"] = body.get("jm")
                if "ds" in body: c["ds"] = _cdesc(body.get("ds"))
            elif op == "disband":
                for u in list(c["m"]): d["clanof"].pop(u, None)
                cl.pop(cid, None); ev = "🏰 Клан распущен: %s" % c["n"]
            else:
                tu = tgt()
                if not tu or tu == uid: err = "Выберите другого игрока"
                elif op == "promote":
                    r_ = c.setdefault("r", {})
                    if tu in r_: err = "Он уже помощник"
                    elif len(r_) >= CLAN_HELPERS: err = "Помощников может быть не больше %d" % CLAN_HELPERS
                    else: r_[tu] = {"t": int(now)}
                elif op == "demote": (c.setdefault("r", {})).pop(tu, None)
                else:
                    c["o"] = tu; r_ = c.setdefault("r", {}); r_.pop(tu, None)
                    if len(r_) < CLAN_HELPERS: r_[uid] = {"t": int(now)}
                    ev = "🏰 Глава клана %s передал клан: %s" % (c["n"], (pl.get(tu) or {}).get("name", "?"))
                    tell.append((tu, "👑 Вы теперь глава клана «%s»!" % c["n"]))
        elif op not in ("info", "search"):
            err = "op"
        if not err and op not in ("info", "search"): P._save(d)
        res = _cview(d, uid, w, body.get("q", "") if op == "search" else None)
    if err: res["ok"] = False; res["err"] = err
    elif ev: notify("act", ev + " (игрок %s)" % _nm(uid))
    if tell and bot and not err:
        def _tell(items=tell):
            for u, t in items:
                try: bot.send_message(int(u), t)
                except Exception: pass
        threading.Thread(target=_tell, daemon=True).start()
    return res


def clan_award(dd, last, pl, hd):
    """Конец недели: награды участникам кланов, выполнивших цель. Возвращает [(uid, текст)]."""
    _cinit(dd); out = []
    for cid, c in dd["clans"].items():
        rows, total, goal = _cstat(c, pl, last, hd)
        t = _ctier(total, goal)
        if t < 0: continue
        pct, coins, fe, egg, ic = CLAN_TIERS[t]
        for u, g, v, m in rows:
            if g < CLAN_MINC: continue
            gl = dd["grants"].setdefault(u, [])
            gl.append({"id": uuid.uuid4().hex[:12], "sku": "adm_coins_%d" % coins})
            if fe:
                gl.append({"id": uuid.uuid4().hex[:12], "sku": "adm_fert_%d" % fe}); P.led_add(dd, u, "adm_fert_%d" % fe)
            if egg: gl.append({"id": uuid.uuid4().hex[:12], "sku": egg})
            out.append((u, "%s Клан «%s» выполнил цель недели (%d из %d)!\nВаша награда: %d 🪙%s%s. Откройте игру — она уже ждёт." % (
                ic, c["n"], total, goal, coins, (" + %d 🧪" % fe) if fe else "", " + 🥚" if egg else "")))
    return out


def week_tick(bot=None):
    """Раз в неделю выдаёт призы топ-3 прошлой недели (вызывается из фонового потока)."""
    w = week_id(); wins = []
    with P._Lock():
        dd = P._load(); last = dd.get("wkaward")
        if last is None or last >= w:
            if last is None:
                dd["wkaward"] = w; P._save(dd)
            return
        pl = _pload()
        hd = hidden_ids()
        rows = sorted([(u, _week_gain(v, last)) for u, v in pl.items() if not out_of_rating(u, v, hd)], key=lambda r: r[1], reverse=True)
        rows = [r for r in rows if r[1] > 0][:3]
        for i, (u, g) in enumerate(rows):
            c, egg, et = WEEK_PRIZES[i]
            gl = dd["grants"].setdefault(u, [])
            gl.append({"id": uuid.uuid4().hex[:12], "sku": "adm_coins_%d" % c})
            if egg:
                gl.append({"id": uuid.uuid4().hex[:12], "sku": egg})
            wins.append((u, i + 1, c, et))
        try: cmsgs = clan_award(dd, last, pl, hd)
        except Exception as _e: cmsgs = []; notify("err", "❗ Кланы, награды недели: %s" % str(_e)[:120])
        dd["wkaward"] = w; P._save(dd)
    if bot:
        for u, txt in cmsgs:
            try: bot.send_message(int(u), txt)
            except Exception: pass
        for u, place, c, et in wins:
            try:
                bot.send_message(int(u), "🏆 Итоги недели: вы заняли %d место в рейтинге ферм!\nНаграда: %d 🪙%s. Откройте игру — награда уже ждёт." % (place, c, (" + " + et) if et else ""))
            except Exception:
                pass


def top_all(limit=50):
    """Общий рейтинг из проверенных снимков (для GET /top)."""
    d = _pload(); hd = hidden_ids(); cutoff = time.time() - 90 * 86400
    rows = [(u, v) for u, v in d.items() if v.get("seen", 0) > cutoff and not out_of_rating(u, v, hd) and v.get("xp", 0) < XP_ABS_MAX]
    rows.sort(key=lambda r: r[1].get("xp", 0), reverse=True)
    ce = clan_emoji_map()
    return [{"id": u, "name": v.get("name", "Фермер"), "xp": v.get("xp", 0), "ce": ce.get(u, "")} for u, v in rows[:limit]]


def farms_list(limit=50):
    d = _pload()
    cutoff = time.time() - 60 * 86400
    hd = hidden_ids()
    rows = [(u, v) for u, v in d.items() if v.get("seen", 0) > cutoff and not out_of_rating(u, v, hd)]
    rows.sort(key=lambda r: r[1].get("xp", 0), reverse=True)
    t = time.time() - ONLINE_SEC
    return [{"id": hid(u), "name": v.get("name", "Фермер"), "lvl": v.get("lvl", 1),
             "xp": v.get("xp", 0), "w": (v.get("snap") or {}).get("w", "farm"),
             "on": 1 if _on.get(u, 0) > t else 0} for u, v in rows[:limit]]


def online_count():
    t = time.time() - ONLINE_SEC
    for u in [u for u, x in _on.items() if x < t - 3600]:
        _on.pop(u, None)
    return sum(1 for x in _on.values() if x > t)


def get_farm(h):
    for u, v in _pload().items():
        if hid(u) == h:
            return {"name": v.get("name"), "lvl": v.get("lvl"), "xp": v.get("xp"), "snap": v.get("snap")}
    return None


# ---------- партнёрка «приведи друга» ----------
REF_PCT = 10              # % от покупки приглашённого, который получает пригласивший
REF_COINS_PER_STAR = 100  # 1 ⭐ = 100 🪙 для расчёта бонуса (10% => 10 🪙 за каждую потраченную ⭐)
REF_WELCOME = 200         # приветственный бонус приглашённому (🪙)
_bu = {"n": ""}


def ref_bonus(stars):
    """Бонус пригласившему в монетах за покупку на `stars` ⭐."""
    return max(1, int(stars * REF_COINS_PER_STAR * REF_PCT / 100))


def _bot_name(bot):
    if not _bu["n"] and bot is not None:
        try: _bu["n"] = bot.get_me().username or ""
        except Exception: pass
    return _bu["n"]


def ref_set(uid, code, bot=None):
    """Привязывает игрока uid к пригласившему (код = публичный id фермы). Один раз и навсегда.
    Нельзя: себя, того, кого пригласил сам, и после своей первой покупки."""
    uid = str(uid); code = str(code or "").strip().lower()
    if not re.fullmatch(r"[0-9a-f]{10}", code): return {"ok": False, "err": "code"}
    inv = None
    for u in _pload():
        if hid(u) == code: inv = u; break
    if not inv: return {"ok": False, "err": "Приглашение не найдено"}
    if inv == uid: return {"ok": False, "err": "Нельзя пригласить самого себя"}
    with P._Lock():
        d = P._load(); r = d.setdefault("ref", {})
        if uid in r: return {"ok": False, "err": "Вы уже приглашены"}
        if r.get(inv) == uid: return {"ok": False, "err": "Это ваш приглашённый"}
        if any(h.get("uid") == uid for h in d.get("hist", [])): return {"ok": False, "err": "Уже есть покупки"}
        r[uid] = inv
        st = d.setdefault("refstat", {}).setdefault(inv, {"n": 0, "coins": 0})
        st["n"] += 1
        d["grants"].setdefault(uid, []).append({"id": uuid.uuid4().hex[:12], "sku": "refw_%d" % REF_WELCOME})
        P._save(d)
    if bot is not None:
        try: bot.send_message(int(inv), "🤝 По вашей ссылке пришёл новый фермер! Вы получите %d%% бонусом с его покупок." % REF_PCT)
        except Exception: pass
    return {"ok": True, "welcome": REF_WELCOME}


def ref_api(body, bot=None):
    """POST /claim с op: ref (моя ссылка и статистика) · refset (принять приглашение) · ping (я онлайн)."""
    uid = P.user_id(body.get("initData", ""))
    if not uid: return {"ok": False, "err": "auth"}
    op = body.get("op")
    if op == "ping":
        _on[uid] = time.time()
        return {"ok": True, "online": online_count()}
    if op == "refset":
        return ref_set(uid, body.get("code"), bot)
    d = P._load()
    st = (d.get("refstat") or {}).get(uid) or {"n": 0, "coins": 0}
    return {"ok": True, "bot": _bot_name(bot), "code": hid(uid), "n": st["n"], "coins": st["coins"],
            "pct": REF_PCT, "by": 1 if uid in (d.get("ref") or {}) else 0, "online": online_count()}


# ---------- почта: подарки друзьям ----------
MAIL_DAY_LIMIT = 5        # подарков в сутки от одного игрока
MAIL_BOX_MAX = 40         # подарков в ящике одного игрока


def _mclean(s, n):
    return re.sub(r"[<>&\"'`\\]", "", str(s or "")).strip()[:n]


def mail_api(body, bot=None):
    """Почта игроков. POST /claim с полем op: box (мой ящик) · send (отправить) · ack (подтвердить получение)."""
    uid = P.user_id(body.get("initData", ""))
    if not uid:
        return {"ok": False, "err": "auth"}
    op = body.get("op")
    notify = None
    with P._Lock():
        d = P._load(); box = d.setdefault("mail", {})
        mine = box.get(uid, [])
        if op == "box":
            return {"ok": True, "items": mine}
        if op == "ack":
            ids = set(str(x) for x in (body.get("ack") or []))
            left = [m for m in mine if m["id"] not in ids]
            if left: box[uid] = left
            else: box.pop(uid, None)
            P._save(d)
            return {"ok": True}
        if op != "send":
            return {"ok": False, "err": "op"}
        to = str(body.get("to", ""))
        rid = None
        for u in _pload():
            if hid(u) == to: rid = u; break
        if not rid: return {"ok": False, "err": "Игрок не найден"}
        if rid == uid: return {"ok": False, "err": "Нельзя дарить самому себе"}
        kind = body.get("kind")
        try: n = int(body.get("n", 0))
        except Exception: n = 0
        k = ""
        if kind == "coins":
            if not 10 <= n <= 1000: return {"ok": False, "err": "Монеты: от 10 до 1000"}
        elif kind == "fert":
            if not 1 <= n <= 5: return {"ok": False, "err": "Удобрение: от 1 до 5"}
        elif kind == "item":
            k = str(body.get("k", ""))
            if not re.fullmatch(r"[a-z]{2,12}", k) or not 1 <= n <= 20: return {"ok": False, "err": "Неверный подарок"}
        else:
            return {"ok": False, "err": "Неверный подарок"}
        today = time.strftime("%Y-%m-%d")
        q = d.setdefault("mailq", {}).get(uid) or {}
        if q.get("d") != today: q = {"d": today, "n": 0}
        if q["n"] >= MAIL_DAY_LIMIT:
            return {"ok": False, "err": "Лимит: %d подарков в сутки" % MAIL_DAY_LIMIT}
        sp = _pload().get(uid)
        if not sp:
            return {"ok": False, "err": "Откройте ферму и подождите минуту — потом можно дарить"}
        now_ = time.time()
        if kind == "coins":
            # монеты у отправителя сервер не списывает, поэтому сверяем с его последними данными
            since = sum(x[1] for x in (q.get("l") or []) if x[0] >= sp.get("seen", 0))
            if n + since > int(sp.get("coins", 0)) + 500: return {"ok": False, "err": "Не хватает монет"}
            q["l"] = ((q.get("l") or []) + [[now_, n]])[-20:]
        elif kind == "item":
            if q.get("i", 0) + n > 60: return {"ok": False, "err": "Лимит предметов в подарках: 60 в сутки"}
            q["i"] = q.get("i", 0) + n
        rbox = box.get(rid, [])
        if len(rbox) >= MAIL_BOX_MAX: return {"ok": False, "err": "У получателя переполнен ящик"}
        pd = _pload()
        fn = _mclean(body.get("fn"), 16) or _mclean((pd.get(uid) or {}).get("name"), 16) or "Друг"
        g = {"id": uuid.uuid4().hex[:12], "fn": fn, "kind": kind, "k": k, "n": n, "msg": _mclean(body.get("msg"), 40), "t": int(time.time())}
        rbox.append(g); box[rid] = rbox
        if kind == "fert": d.setdefault("led", {}).setdefault(rid, {})["fe"] = d["led"][rid].get("fe", 0) + n
        q["n"] += 1; d["mailq"][uid] = q
        P._save(d)
        notify = (rid, fn)
    if notify and bot:
        def _n():
            try: bot.send_message(int(notify[0]), "🎁 %s прислал(а) вам подарок!\nОткройте игру → вкладка «Почта»." % notify[1])
            except Exception: pass
        threading.Thread(target=_n, daemon=True).start()
    return {"ok": True, "left": MAIL_DAY_LIMIT - q["n"]}


HELP_DAY_LIMIT = 10      # ферм в сутки, которым можно помочь
HELP_OWNER = 30           # монет владельцу за помощь


def help_api(body, bot=None):
    """POST /claim, op=help: помочь чужой ферме. Владелец получает подарок в почту, помогающий — награду в клиенте."""
    uid = P.user_id(body.get("initData", ""))
    if not uid: return {"ok": False, "err": "auth"}
    to = str(body.get("to", "")); rid = None
    for u in _pload():
        if hid(u) == to: rid = u; break
    if not rid: return {"ok": False, "err": "Игрок не найден"}
    if rid == uid: return {"ok": False, "err": "Это ваша ферма"}
    with P._Lock():
        d = P._load(); box = d.setdefault("mail", {})
        today = time.strftime("%Y-%m-%d")
        hq = d.setdefault("helpq", {}).get(uid) or {}
        if hq.get("d") != today: hq = {"d": today, "to": []}
        if rid in hq["to"]: return {"ok": False, "err": "Сегодня вы уже помогали этой ферме"}
        if len(hq["to"]) >= HELP_DAY_LIMIT: return {"ok": False, "err": "Лимит помощи: %d ферм в сутки" % HELP_DAY_LIMIT}
        rbox = box.get(rid, [])
        if len(rbox) >= MAIL_BOX_MAX: return {"ok": False, "err": "У владельца переполнен ящик"}
        fn = _mclean(body.get("fn"), 16) or _mclean((_pload().get(uid) or {}).get("name"), 16) or "Сосед"
        rbox.append({"id": uuid.uuid4().hex[:12], "fn": fn, "kind": "coins", "k": "", "n": HELP_OWNER,
                     "msg": "помог(ла) на ферме", "t": int(time.time())})
        box[rid] = rbox; hq["to"].append(rid); d["helpq"][uid] = hq
        P._save(d)
        left = HELP_DAY_LIMIT - len(hq["to"])
    if bot:
        def _n():
            try: bot.send_message(int(rid), "🤝 %s помог(ла) вашей ферме! +%d 🪙 ждут в «Почте»." % (fn, HELP_OWNER))
            except Exception: pass
        threading.Thread(target=_n, daemon=True).start()
    return {"ok": True, "left": left}


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
    try:
        big = grant.startswith("adm_lvl") or (grant.startswith("adm_coins_") and abs(int(grant[10:] or 0)) >= 1_000_000)
        if big:
            with P._Lock():
                pl = _pload(); r = pl.get(str(uid))
                if r is not None: r["tu"] = int(time.time()) + 3600; _psave(pl)
    except Exception:
        pass
    with P._Lock():
        d = P._load()
        d["grants"].setdefault(str(uid), []).append({"id": uuid.uuid4().hex[:12], "sku": grant})
        P.led_add(d, uid, grant)
        P._save(d)


def log(admin, uid, grant):
    try: notify("adm", "🛠 Админ <code>%s</code> → <code>%s</code>: %s" % (admin, uid, _mclean(grant, 160)))
    except Exception: pass
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
    if grant.startswith("egg_"): return "🥚 кейс с яйцом %s" % grant[4:].replace("_", " / ")
    if grant.startswith("skin_"): return "🎨 скин %s" % grant[5:].replace("_", " / ")
    if grant.startswith("bx_"):
        _, m, dd = grant.split("_"); return "⚡ множитель ×%s на %s дн." % (m, dd)
    return grant


# ---------- бот ----------
DFILE = os.path.join(HERE, "data.json")


def _dload():
    try:
        with open(DFILE, encoding="utf-8") as f: return json.load(f)
    except Exception:
        return {}


def _dsave(d):
    tmp = DFILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f: json.dump(d, f, ensure_ascii=False)
    os.replace(tmp, DFILE)


def hidden_ids():
    return set(str(x) for x in (_dload().get("hidden") or []))


def score_drop(uid):
    """Убирает игрока из общего рейтинга (data.json)."""
    d = _dload(); sc = d.get("scores") or {}
    n = 1 if sc.pop(str(uid), None) is not None else 0
    d["scores"] = sc; _dsave(d)
    return n


def hide_set(uid, on):
    """Прячет игрока из рейтингов, списка ферм и недельного топа (для читеров). Игра для него не блокируется."""
    d = _dload(); h = set(str(x) for x in (d.get("hidden") or []))
    (h.add if on else h.discard)(str(uid)); d["hidden"] = sorted(h)
    if on: (d.get("scores") or {}).pop(str(uid), None)
    _dsave(d)


_BC = {"m": -1, "v": {}}


def bans():
    """Список банов {uid: {r, t}} из data.json (с кэшем по времени изменения файла)."""
    try: m = os.path.getmtime(DFILE)
    except Exception: return {}
    if m != _BC["m"]:
        _BC["v"] = _dload().get("bans") or {}; _BC["m"] = m
    return _BC["v"]


def ban_get(uid):
    return bans().get(str(uid))


def ban_set(admin_id, uid, reason):
    uid = str(uid); reason = _mclean(reason, 300) or "Нарушение правил игры"
    d = _dload(); b = d.get("bans") or {}
    b[uid] = {"r": reason, "t": int(time.time())}; d["bans"] = b
    (d.get("scores") or {}).pop(uid, None)
    _dsave(d); _BC["m"] = -1
    hide_set(uid, True)
    log(admin_id, uid, "BAN: " + reason)
    notify("sec", "🚫 Бан: %s — %s" % (_nm(uid), _mclean(reason, 120)))


def unban(admin_id, uid):
    uid = str(uid); d = _dload(); b = d.get("bans") or {}
    ok = b.pop(uid, None) is not None; d["bans"] = b
    _dsave(d); _BC["m"] = -1
    hide_set(uid, False)
    log(admin_id, uid, "UNBAN")
    return ok


LOGKINDS = [("new", "🆕 Новые игроки", 1), ("pay", "💰 Покупки", 1), ("sec", "🚨 Безопасность и баны", 1),
            ("adm", "🛠 Действия админов", 1), ("err", "❗ Ошибки сервера", 1), ("boot", "🟢 Запуск сервисов", 1),
            ("act", "🤝 Почта и помощь соседям", 0)]
JF = os.path.join(HERE, "events.log")
_nt = {}            # троттлинг одинаковых событий
_nq = []            # метки времени последних отправок


def _logcfg():
    c = _dload().get("logcfg") or {}
    return {k: bool(c.get(k, dflt)) for k, _t, dflt in LOGKINDS}


def notify(kind, text, key=None, every=0):
    """Журнал событий: пишет в events.log всегда, а админу в личку присылает, если вид событий включён.
    every — не чаще раза в N секунд для одного key."""
    try:
        now = time.time()
        if every:
            kk = (kind, key or text)
            if now - _nt.get(kk, 0) < every: return
            _nt[kk] = now
            if len(_nt) > 2000: _nt.clear()
        plain = re.sub(r"<[^>]+>", "", str(text))
        try:
            if os.path.exists(JF) and os.path.getsize(JF) > 2_000_000:
                os.replace(JF, JF + ".1")
            with open(JF, "a", encoding="utf-8") as f:
                f.write("%s [%s] %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), kind, plain.replace("\n", " | ")))
        except Exception: pass
        bot = _BOT; aid = _admin_id()
        if not bot or not aid or not _logcfg().get(kind, False): return
        _nq[:] = [t for t in _nq if now - t < 60]
        if len(_nq) >= 20: return              # защита от лавины: в журнал пишется, в личку нет
        _nq.append(now)
        def _s():
            try: bot.send_message(int(aid), text, parse_mode="HTML", disable_notification=kind in ("act", "adm"))
            except Exception: pass
        threading.Thread(target=_s, daemon=True).start()
    except Exception:
        pass


def _nm(uid):
    v = _pload().get(str(uid)) or {}
    return "<b>%s</b> (<code>%s</code>)" % (_clean(v.get("name"), 24) or "?", uid)


def audit_text():
    """Сверка платежей: что куплено, что доставлено, где есть расхождения."""
    d = P._load(); hist = d.get("hist") or []; now = time.time()
    pl = _pload(); bad = []
    def seg(sec):
        r = [h for h in hist if now - h.get("t", 0) < sec]
        return len(r), sum(h.get("amt", 0) for h in r), len(set(h.get("uid") for h in r))
    n1, s1, u1 = seg(86400); n7, s7, u7 = seg(7 * 86400); na, sa, ua = seg(10 ** 10)
    by = {}
    for h in hist:
        if now - h.get("t", 0) < 7 * 86400:
            by[h["sku"].split("_")[0]] = by.get(h["sku"].split("_")[0], 0) + 1
    # не доставлено игроку дольше 15 минут
    stuck = [h for h in hist if not h.get("got") and now - h.get("t", 0) > 900]
    # сумма не совпала с ценой
    wrong = [h for h in hist if P.price(h.get("sku", "")) is not None and P.price(h["sku"]) != h.get("amt")]
    pend = sum(len(v) for v in (d.get("grants") or {}).values())
    pend_u = len(d.get("grants") or {})
    paidn = len(d.get("paid") or [])
    led = d.get("led") or {}
    led_ch = sum(sum(L.get(t, 0) for t in ("c", "r", "l")) for L in led.values())
    flags = [(u, v) for u, v in pl.items() if v.get("flag")]
    t = ["🧾 <b>Сверка платежей</b>",
         "За сутки: %d покупок на %d ⭐ (%d игроков)" % (n1, s1, u1),
         "За 7 дней: %d на %d ⭐ (%d игроков)" % (n7, s7, u7),
         "В журнале: %d на %d ⭐ · счетов Telegram: %d" % (na, sa, paidn)]
    if by: t.append("Типы за 7 дн.: " + ", ".join("%s ×%d" % kv for kv in sorted(by.items(), key=lambda kv: -kv[1])))
    t.append("")
    if stuck:
        t.append("⚠️ <b>Оплачено, но не получено игроком (&gt;15 мин): %d</b>" % len(stuck))
        for h in stuck[-8:]:
            t.append("   %s — %s, %s ⭐, %s" % (_clean((pl.get(h["uid"]) or {}).get("name"), 16) or "?", h["sku"], h.get("amt"), time.strftime("%d.%m %H:%M", time.localtime(h.get("t", 0)))))
        t.append("   Игрок получит при следующем заходе в игру. Если давно — напишите ему.")
    else:
        t.append("✅ Все оплаченные покупки доставлены игрокам")
    t.append(("⚠️ Сумма не совпала с ценой: %d" % len(wrong)) if wrong else "✅ Суммы платежей совпадают с ценами")
    t.append("📬 В очереди выдач: %d у %d игроков" % (pend, pend_u))
    t.append("📦 Сундуков выдано сервером всего: %d" % led_ch)
    t.append("🚨 Под флагом: %d" % len(flags) + (" (/flags)" if flags else ""))
    t.append("🚫 В бане: %d" % len(bans()))
    return "\n".join(t)


def reset_player(admin_id, uid, reason):
    """Обнуляет прогресс игрока: в очередь ставится выдача adm_reset с причиной (игра покажет её на экране)."""
    uid = str(uid); reason = _mclean(reason, 300) or "Решение администрации"
    gid = uuid.uuid4().hex[:12]
    with P._Lock():
        d = P._load()
        d["grants"].setdefault(uid, []).insert(0, {"id": gid, "sku": "adm_reset", "msg": reason})
        P._save(d)
        pl = _pload()
        v = pl.get(uid)
        if v:
            v.update({"xp": 0, "lvl": 1, "coins": 0, "wb": 0}); v.pop("flag", None)
            v.pop("pwk", None); v.pop("pg", None)
            for _k in ("lb", "lt", "lbt", "fb"): v.pop(_k, None)
            _psave(pl)
    try: score_drop(uid)
    except Exception: pass
    log(admin_id, uid, "RESET: " + reason)
    return gid


_mail0 = mail_api
_help0 = help_api


def mail_api(body, bot=None):
    r = _mail0(body, bot)
    try:
        if body.get("op") == "send" and isinstance(r, dict) and r.get("ok"):
            uid = P.user_id(body.get("initData", ""))
            notify("act", "✉️ Почта: %s отправил подарок" % _nm(uid))
    except Exception: pass
    return r


def help_api(body, bot=None):
    r = _help0(body, bot)
    try:
        if isinstance(r, dict) and r.get("ok"):
            uid = P.user_id(body.get("initData", ""))
            notify("act", "🤝 Помощь: %s помог соседу" % _nm(uid))
    except Exception: pass
    return r


def ann_get():
    d = P._load()
    return d.get("ann")


def announce(bot, admin_id, text, report_chat=None):
    """Объявление: сохраняется для показа в игре и рассылается в личку всем, кто активировал бота."""
    text = str(text or "").strip()[:700]
    if not text: return 0
    with P._Lock():
        d = P._load()
        d["ann"] = {"id": uuid.uuid4().hex[:8], "text": text, "t": int(time.time())}
        P._save(d)
    log(admin_id, "ALL", "ANNOUNCE: " + text[:80])

    def _run():
        from telebot import types
        try:
            import broadcast
            targets = broadcast.recipients()
            url = broadcast._env("WEBAPP_URL")
        except Exception:
            targets = {}; url = ""
        kb = None
        if url.startswith("https://"):
            kb = types.InlineKeyboardMarkup()
            kb.add(types.InlineKeyboardButton("🌾 Открыть игру", web_app=types.WebAppInfo(url)))
        sent = 0
        for cid in targets:
            try:
                bot.send_message(int(cid), "📢 " + text, reply_markup=kb)
                sent += 1
            except Exception as e:
                s = str(e)
                if "429" in s: time.sleep(5)
            time.sleep(0.05)
        if report_chat:
            try: bot.send_message(report_chat, "📢 Объявление разослано: %d из %d." % (sent, len(targets)))
            except Exception: pass
    threading.Thread(target=_run, daemon=True).start()
    return 1


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
    global _BOT
    if _BOT is None: _BOT = bot
    notify("boot", "🟢 Бот запущен")

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
                    [("📢 Объявление", "adm:an"), ("📜 Логи", "adm:lgm")],
                    [("🧾 Сверка платежей", "adm:au"), ("ℹ️ Команды", "adm:h")]]))

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
            "/buys [игрок] — последние покупки за ⭐ и дошли ли они до игрока (⏳ — ещё не забрал; можно выдать заново через /give)\n"
            "\n<b>Акции и погода</b> (подробно — просто напиши команду без параметров)\n"
            "/event — список акций · /event x2 60 — запустить · /event off x2 — выключить одну · /event off — все\n"
            "/weather — статус · /weather rain 60 — включить · /weather off — выключить совсем · /weather auto — по умолчанию\n"
            "/stop /resume — рассылка-приглашение, /bc — разослать сейчас\n"
            "\n<b>Объявления и сброс</b>\n"
            "/announce &lt;текст&gt; — объявление всем, кто активировал бота (в личку + окно в игре), с подтверждением\n"
            "/flags — кого пометила защита от накрутки (кнопки: оставить / обнулить / спрятать)\n"
            "/clans — список кланов, /clandel КОД — удалить клан (с подтверждением)\n"
            "/audit — сверка платежей: покупки, недоставленное, расхождения\n"
            "/logs — какие события присылать в личку · /journal [N] [вид] — последние события\n"
            "/ban &lt;игрок&gt; &lt;причина&gt; — ЗАБАНИТЬ (игра блокируется, причина на экране), /unban &lt;игрок&gt;, /bans — список\n"
            "/hide &lt;игрок&gt; — спрятать из рейтингов и списка ферм (читеры), /unhide — вернуть\n"
            "/reset &lt;игрок&gt; &lt;причина&gt; — ОБНУЛИТЬ прогресс игрока; причина покажется у него на экране (с подтверждением)\n\n"
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
            [("🗑 Обнулить прогресс", "adm:rs:%s" % u), ("🚫 Забанить", "adm:bn:%s" % u)],
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

    @bot.message_handler(commands=["buys"])
    def _buys(m):
        if not is_admin(m.from_user.id): return
        q = (m.text or "").split(None, 1)
        uid = None
        if len(q) > 1:
            uid, rec = resolve(q[1])
            if not uid: return bot.reply_to(m, "Игрок не найден или несколько совпадений. /find <имя>")
        with P._Lock():
            d = P._load()
        hist = [h for h in d.get("hist", []) if not uid or h.get("uid") == uid][-15:]
        pend = {u: len(v) for u, v in d.get("grants", {}).items() if v and (not uid or u == uid)}
        pd = _pload()
        t = "🧾 <b>Покупки за ⭐</b>%s\n" % (" — " + ((pd.get(uid) or {}).get("name") or uid) if uid else "")
        if not hist: t += "Покупок в журнале пока нет (журнал ведётся с этой версии).\n"
        for h in reversed(hist):
            nm = (pd.get(h["uid"]) or {}).get("name") or h["uid"]
            st = "✅ получено" if h.get("got") else "⏳ ждёт игрока"
            t += "%s · %s · %s · %s⭐ · %s\n" % (time.strftime("%d.%m %H:%M", time.localtime(h["t"])), nm, describe(h["sku"]), h.get("amt", "?"), st)
        if pend: t += "\nНе забрано выдач: " + ", ".join("%s — %d" % (((pd.get(u) or {}).get("name")) or u, n) for u, n in pend.items())
        bot.reply_to(m, t, parse_mode="HTML")

    @bot.message_handler(commands=["give"])
    def _give(m): give_take(m, 1)

    @bot.message_handler(commands=["take"])
    def _take(m): give_take(m, -1)

    PEND = {}                           # токен -> ожидающее подтверждения действие

    def ask(chat, kind, payload, text):
        tok = uuid.uuid4().hex[:8]
        PEND[tok] = (kind, payload)
        if len(PEND) > 50: PEND.pop(next(iter(PEND)))
        bot.send_message(chat, text, parse_mode="HTML", reply_markup=kb([[("✅ Да, выполнить", "adm:ok:" + tok), ("❌ Отмена", "adm:no:" + tok)]]))

    def ask_reset(chat, uid, reason):
        v = _pload().get(str(uid)) or {}
        ask(chat, "reset", (str(uid), reason),
            "⚠️ <b>Обнулить прогресс?</b>\nИгрок: <b>%s</b> (<code>%s</code>), ур. %s\nПричина на экране игрока:\n<i>%s</i>\n\nЭто нельзя отменить." % (
                v.get("name", "?"), uid, v.get("lvl", "?"), _mclean(reason, 300)))

    @bot.message_handler(commands=["reset"])
    def _reset(m):
        if not is_admin(m.from_user.id): return
        a_ = (m.text or "").split(None, 2)
        if len(a_) < 3:
            return bot.reply_to(m, "Пример: /reset 123456789 Накрутка опыта через баг\nПричина обязательна — игрок увидит её на экране.")
        uid, rec = resolve(a_[1])
        if not uid:
            return bot.reply_to(m, "Игрок не найден или найдено несколько. Используйте /find.")
        ask_reset(m.chat.id, uid, a_[2])

    @bot.message_handler(commands=["announce"])
    def _announce(m):
        if not is_admin(m.from_user.id): return
        q = (m.text or "").split(None, 1)
        if len(q) < 2 or not q[1].strip():
            return bot.reply_to(m, "Пример: /announce Завтра в 20:00 стартует новый ивент!\nТекст уйдёт всем, кто активировал бота, и появится окном в игре.")
        try:
            import broadcast
            n = len(broadcast.recipients())
        except Exception:
            n = 0
        ask(m.chat.id, "ann", q[1].strip()[:700], "📢 <b>Отправить объявление %d получателям?</b>\n\n%s" % (n, _mclean(q[1], 700)))

    def hide_cmd(m, on):
        if not is_admin(m.from_user.id): return
        q = (m.text or "").split(None, 1)
        if len(q) < 2: return bot.reply_to(m, "Пример: /%s 123456789 (id или часть имени)" % ("hide" if on else "unhide"))
        uid, rec = resolve(q[1])
        if not uid: return bot.reply_to(m, "Игрок не найден или найдено несколько. Используйте /find.")
        hide_set(uid, on)
        bot.reply_to(m, ("🙈 %s спрятан из рейтингов и списка ферм." if on else "👁 %s снова виден в рейтингах.") % ((rec or {}).get("name") or uid))

    @bot.message_handler(commands=["hide"])
    def _hide(m): hide_cmd(m, True)

    @bot.message_handler(commands=["unhide"])
    def _unhide(m): hide_cmd(m, False)

    @bot.message_handler(commands=["flags"])
    def _flags(m):
        if not is_admin(m.from_user.id): return
        pl = _pload(); hd = hidden_ids()
        fl = [(u, v) for u, v in pl.items() if v.get("flag")]
        t = "🚨 <b>Помечены проверкой</b> (%d)\n" % len(fl)
        for u, v in fl[:20]:
            t += "• %s (<code>%s</code>): %s\n" % (_clean(v.get("name"), 20), u, _mclean((v.get("flag") or {}).get("why"), 100))
        t += "\n🙈 Спрятаны вручную: %d" % len(hd)
        bot.send_message(m.chat.id, t, parse_mode="HTML",
                         reply_markup=kb([[(_clean(v.get("name"), 18), "adm:p:" + u)] for u, v in fl[:8]]) if fl else None)

    def ask_ban(chat, uid, reason):
        v = _pload().get(str(uid)) or {}
        ask(chat, "ban", (str(uid), reason),
            "🚫 <b>Забанить игрока?</b>\nИгрок: <b>%s</b> (<code>%s</code>), ур. %s\nПричина на экране игрока:\n<i>%s</i>\n\nИгра у него заблокируется, платежи и почта тоже. Снять бан: /unban." % (
                v.get("name", "?"), uid, v.get("lvl", "?"), _mclean(reason, 300)))

    @bot.message_handler(commands=["ban"])
    def _ban(m):
        if not is_admin(m.from_user.id): return
        q = (m.text or "").split(None, 2)
        if len(q) < 3:
            return bot.reply_to(m, "Пример: /ban 123456789 Накрутка через изменение сохранения\nПричина обязательна — игрок увидит её на экране.")
        uid, rec = resolve(q[1])
        if not uid: return bot.reply_to(m, "Игрок не найден или найдено несколько. Используйте /find.")
        if is_admin(int(uid)) if str(uid).isdigit() else False: return bot.reply_to(m, "Админа банить нельзя.")
        ask_ban(m.chat.id, uid, q[2])

    @bot.message_handler(commands=["unban"])
    def _unban(m):
        if not is_admin(m.from_user.id): return
        q = (m.text or "").split(None, 1)
        if len(q) < 2: return bot.reply_to(m, "Пример: /unban 123456789")
        uid, rec = resolve(q[1])
        if not uid: uid = q[1].strip()
        if unban(m.from_user.id, uid):
            bot.reply_to(m, "✅ Бан снят. Игра разблокируется у игрока при следующей проверке (до минуты).")
            try: bot.send_message(int(uid), "✅ Блокировка в «Мини-ферме» снята.")
            except Exception: pass
        else:
            bot.reply_to(m, "Этот игрок не в бане.")

    @bot.message_handler(commands=["bans"])
    def _bans(m):
        if not is_admin(m.from_user.id): return
        b = bans()
        if not b: return bot.reply_to(m, "Банов нет.")
        pl = _pload(); rows = []
        for u, x in sorted(b.items(), key=lambda kv: kv[1].get("t", 0), reverse=True)[:40]:
            rows.append("🚫 <b>%s</b> <code>%s</code>\n   %s" % ((pl.get(u) or {}).get("name", "?"), u, _mclean(x.get("r", ""), 120)))
        bot.send_message(m.chat.id, "<b>Баны (%d)</b>\n\n%s\n\nСнять: /unban id" % (len(b), "\n".join(rows)), parse_mode="HTML")

    def logs_menu():
        c = _logcfg()
        rows = [[("%s %s" % ("✅" if c[k] else "▫️", t), "adm:lg:" + k)] for k, t, _d in LOGKINDS]
        rows.append([("🔔 Все вкл", "adm:lg:+"), ("🔕 Все выкл", "adm:lg:-")])
        rows.append([("📜 Последние события", "adm:lj"), ("⬅ Меню", "adm:m")])
        return ("📜 <b>Уведомления о событиях</b>\nНажмите на пункт, чтобы включить или выключить личные сообщения. "
                "Журнал в любом случае ведётся: /journal [число]", kb(rows))

    def journal_text(n=25, kind=None):
        try:
            with open(JF, encoding="utf-8") as f: lines = f.read().splitlines()[-4000:]
        except Exception:
            lines = []
        if kind: lines = [l for l in lines if "[%s]" % kind in l]
        lines = lines[-n:]
        if not lines: return "Журнал пуст."
        import html as _h
        return "<b>Последние события (%d)</b>\n<pre>%s</pre>" % (len(lines), _h.escape("\n".join(l[5:] for l in lines))[-3500:])

    @bot.message_handler(commands=["logs"])
    def _logs(m):
        if not is_admin(m.from_user.id): return
        t, k = logs_menu(); bot.send_message(m.chat.id, t, parse_mode="HTML", reply_markup=k)

    @bot.message_handler(commands=["journal"])
    def _journal(m):
        if not is_admin(m.from_user.id): return
        q = (m.text or "").split()[1:]
        n = int(q[0]) if q and q[0].isdigit() else 25
        kind = next((x for x in q if x in [k for k, _t, _d in LOGKINDS]), None)
        bot.send_message(m.chat.id, journal_text(max(1, min(n, 60)), kind), parse_mode="HTML")

    @bot.message_handler(commands=["audit"])
    def _audit(m):
        if not is_admin(m.from_user.id): return
        bot.send_message(m.chat.id, audit_text(), parse_mode="HTML")

    @bot.message_handler(commands=["clans"])
    def _clans(m):
        if not is_admin(m.from_user.id): return
        d = P._load(); _cinit(d); pl = _pload(); hd = hidden_ids(); w = week_id(); rows = []
        for k, c in d["clans"].items():
            r, total, goal = _cstat(c, pl, w, hd)
            rows.append((int(100 * total / goal), "%s <b>%s</b> · код <code>%s</code> · %d/%d чел. · цель %d%%\n   создатель: %s" % (
                c["e"], c["n"], c["c"], len(c["m"]), CLAN_MAX, int(100 * total / goal), _nm(c["o"]))))
        if not rows: return bot.reply_to(m, "Кланов пока нет.")
        rows.sort(reverse=True)
        bot.send_message(m.chat.id, "<b>Кланы (%d)</b>\n\n%s\n\nУдалить: /clandel КОД" % (len(rows), "\n".join(x[1] for x in rows[:30])), parse_mode="HTML")

    @bot.message_handler(commands=["clandel"])
    def _clandel(m):
        if not is_admin(m.from_user.id): return
        q = (m.text or "").split(None, 1)
        if len(q) < 2: return bot.reply_to(m, "Пример: /clandel ABC123 (код клана из /clans)")
        code = re.sub(r"[^A-Z0-9]", "", q[1].upper())
        d = P._load(); _cinit(d)
        cid = next((k for k, c in d["clans"].items() if c["c"] == code), None)
        if not cid: return bot.reply_to(m, "Клан с таким кодом не найден.")
        c = d["clans"][cid]
        ask(m.chat.id, "cdel", cid, "🗑 <b>Удалить клан?</b>\n%s <b>%s</b>, участников: %d\nУчастники останутся без клана." % (c["e"], c["n"], len(c["m"])))

    @bot.message_handler(commands=["cancel"])
    def _cancel(m):
        if not is_admin(m.from_user.id): return
        bot.send_message(m.chat.id, "Отменено.")

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
        elif act == "an":
            show("📢 <b>Объявление</b>\nОтправьте команду:\n<code>/announce Текст объявления</code>\nПредпросмотр и подтверждение будут перед отправкой.", kb([[("⬅ Меню", "adm:m")]]))
        elif act == "rs":
            bot.answer_callback_query(c.id)
            v = _pload().get(str(rest)) or {}
            msg = bot.send_message(chat, "🗑 Обнуление игрока <b>%s</b>. Напишите причину одним сообщением (она появится у игрока на экране) или /cancel." % v.get("name", rest), parse_mode="HTML")
            def _got(mm, uid=str(rest)):
                if not is_admin(mm.from_user.id) or not (mm.text or "").strip() or mm.text.startswith("/"):
                    return bot.send_message(mm.chat.id, "Отменено.")
                ask_reset(mm.chat.id, uid, mm.text.strip()[:300])
            bot.register_next_step_handler(msg, _got)
            return
        elif act == "lg":
            d_ = _dload(); cfg_ = d_.get("logcfg") or {}; cur_ = _logcfg()
            if rest in ("+", "-"):
                cfg_ = {k: rest == "+" for k, _t, _d in LOGKINDS}
            elif rest in cur_:
                cfg_[rest] = not cur_[rest]
            d_["logcfg"] = cfg_; _dsave(d_)
            show(*logs_menu()); bot.answer_callback_query(c.id); return
        elif act == "au":
            show(audit_text(), kb([[("🔄 Обновить", "adm:au"), ("⬅ Меню", "adm:m")]])); bot.answer_callback_query(c.id); return
        elif act == "lj":
            show(journal_text(25), kb([[("⬅ Назад", "adm:lgm")]])); bot.answer_callback_query(c.id); return
        elif act == "lgm":
            show(*logs_menu()); bot.answer_callback_query(c.id); return
        elif act == "bn":
            bot.answer_callback_query(c.id)
            v = _pload().get(str(rest)) or {}
            msg = bot.send_message(chat, "🚫 Бан игрока <b>%s</b>. Напишите причину одним сообщением (покажется у игрока на экране) или /cancel." % v.get("name", rest), parse_mode="HTML")
            def _gotb(mm, uid=str(rest)):
                if not is_admin(mm.from_user.id) or not (mm.text or "").strip() or mm.text.startswith("/"):
                    return bot.send_message(mm.chat.id, "Отменено.")
                ask_ban(mm.chat.id, uid, mm.text.strip()[:300])
            bot.register_next_step_handler(msg, _gotb)
            return
        elif act in ("fk", "fr", "fh"):
            uid_ = str(rest)
            if act == "fk":
                with P._Lock():
                    pl = _pload(); r = pl.get(uid_)
                    if r is not None: r.pop("flag", None); r["trust"] = 1; _psave(pl)
                show("✅ Оставлен. Игрок доверенный, проверки для него отключены."); bot.answer_callback_query(c.id); return
            if act == "fh":
                with P._Lock():
                    pl = _pload(); r = pl.get(uid_)
                    if r is not None: r.pop("flag", None); _psave(pl)
                hide_set(uid_, True)
                show("🙈 Спрятан из рейтингов и списка ферм навсегда."); bot.answer_callback_query(c.id); return
            reason_ = "Подозрение на накрутку: данные игры не прошли проверку сервера"
            with P._Lock():
                pl = _pload(); r = pl.get(uid_)
                if r is not None: r.pop("flag", None); _psave(pl)
            reset_player(c.from_user.id, uid_, reason_)
            try: bot.send_message(int(uid_), "⚠️ Ваш прогресс в «Мини-ферме» обнулён.\nПричина: %s" % reason_)
            except Exception: pass
            show("🗑 Прогресс обнулён, игрок увидит причину в игре."); bot.answer_callback_query(c.id); return
        elif act in ("ok", "no"):
            pe = PEND.pop(rest, None)
            if not pe:
                bot.answer_callback_query(c.id, "Уже обработано или устарело"); return
            if act == "no":
                show("❌ Отменено."); bot.answer_callback_query(c.id); return
            kind, pl = pe
            if kind == "reset":
                reset_player(c.from_user.id, pl[0], pl[1])
                try: bot.send_message(int(pl[0]), "⚠️ Ваш прогресс в «Мини-ферме» обнулён.\nПричина: %s" % pl[1])
                except Exception: pass
                show("✅ Прогресс игрока обнулён. Он увидит причину при открытии игры.")
            elif kind == "ban":
                ban_set(c.from_user.id, pl[0], pl[1])
                try: bot.send_message(int(pl[0]), "🚫 Ваш аккаунт в «Мини-ферме» заблокирован.\nПричина: %s" % pl[1])
                except Exception: pass
                show("🚫 Игрок забанен. Игра заблокируется у него при следующей проверке (до минуты). Снять: /unban %s" % pl[0])
            elif kind == "cdel":
                with P._Lock():
                    dd_ = P._load(); _cinit(dd_); cc_ = dd_["clans"].pop(pl, None)
                    for u_ in list((cc_ or {}).get("m", {})): dd_["clanof"].pop(u_, None)
                    P._save(dd_)
                show("🗑 Клан удалён.")
            elif kind == "ann":
                announce(bot, c.from_user.id, pl, chat)
                show("📢 Рассылка запущена, отчёт придёт сообщением.")
            bot.answer_callback_query(c.id); return
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
    first("message_handlers", 25)
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
  SERVER_IP="46.21.80.141"      # IP твоего сервера (если определить сам не удалось — берётся он)
  if ! [[ "$PUB_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then PUB_IP="$SERVER_IP"; warn "IP не определился автоматически, использую $SERVER_IP"; fi
  [[ "$PUB_IP" != "$SERVER_IP" ]] && warn "IP этого сервера $PUB_IP отличается от $SERVER_IP — домен сделаю из текущего IP: $PUB_IP"
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

    @pay path /invoice /claim /snap /farms /farm /clan
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
for _ in $(seq 1 15); do
  if curl -fsS --max-time 6 "$API_URL/event" >/dev/null 2>&1; then HTTPS_OK=1; break; fi
  sleep 3
done
if [[ $HTTPS_OK -ne 1 ]]; then
  warn "Сертификат для $DOMAIN не выпустился (часто хостер режет проверку Let's Encrypt). Переключаюсь на запасной способ: DuckDNS + проверка по DNS."
  mkdir -p /root/.mf-all
  cat > /root/.mf-all/duck.sh <<'DUCKEOF'
#!/usr/bin/env bash
# duck.sh — HTTPS для «Мини-фермы» через бесплатный DuckDNS + проверку по DNS (входящий порт 80 не нужен).
# Работает, даже если сервер не может достучаться до DuckDNS: тогда скрипт покажет 2–3 ссылки,
# которые нужно один раз открыть в браузере на своём компьютере, и продолжит сам.
# Запуск:  bash duck.sh
set -uo pipefail
APP_DIR="${APP_DIR:-/root/farm-bot}"; CF=/etc/caddy/Caddyfile; ENVF="$APP_DIR/.env"
GAME_URL="${GAME_URL:-https://xnin228.github.io/everyday/}"; GAME_URL="${GAME_URL%/}/"
SUB="${DUCK_SUB:-fermafarms}"; TOK="${DUCK_TOKEN:-20b84b13-73e5-4942-a9f6-5e57cf4cae1c}"; MAIL="${EMAIL:-rayxnin@gmail.com}"
DOM="$SUB.duckdns.org"
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
say(){ echo -e "${G}[+]${N} $*"; }; warn(){ echo -e "${Y}[!]${N} $*"; }; err(){ echo -e "${R}[x]${N} $*" >&2; }
[[ $EUID -eq 0 ]] || { err "Запусти от root"; exit 1; }
[[ -f "$CF" && -f "$ENVF" ]] || { err "Нет $CF или $ENVF — сначала bash all.sh"; exit 1; }

IP="$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || curl -fsS --max-time 8 https://ifconfig.me 2>/dev/null)"
[[ -n "$IP" ]] || { err "Не определил внешний IP сервера"; exit 1; }
say "Внешний IP сервера: $IP"
waitkey(){ if [[ -r /dev/tty ]]; then read -rp "   → сделай это и нажми Enter… " _ </dev/tty; else sleep 60; fi; }

# ---------- 1. DNS: поддомен -> IP сервера ----------
resolves(){ getent ahostsv4 "$DOM" 2>/dev/null | awk '{print $1}' | grep -qx "$IP"; }
if resolves; then say "DNS уже верный: $DOM → $IP"
else
  R1="$(curl -fsS --max-time 12 "https://www.duckdns.org/update?domains=$SUB&token=$TOK&ip=$IP" 2>/dev/null)"
  if [[ "$R1" == OK* ]]; then say "DuckDNS обновлён автоматически: $DOM → $IP"
  else
    warn "Сервер не достаёт DuckDNS. Открой эту ссылку В БРАУЗЕРЕ на своём компьютере (должно написать OK):"
    echo; echo "   https://www.duckdns.org/update?domains=$SUB&token=$TOK&ip=$IP"; echo
    waitkey
  fi
  for i in $(seq 1 20); do resolves && break; sleep 5; done
  resolves && say "DNS работает: $DOM → $IP" || warn "Сервер пока не видит новый DNS (кэш). Продолжаю — для выпуска сертификата это не обязательно."
fi

# ---------- 2. certbot + хук для DNS-проверки ----------
if ! command -v certbot >/dev/null 2>&1; then
  say "Ставлю certbot…"; export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1; apt-get install -y certbot >/dev/null 2>&1
fi
command -v certbot >/dev/null 2>&1 || { err "certbot не установился (apt недоступен?)"; exit 1; }
mkdir -p /root/.mf-all
cat > /root/.mf-all/duck-hook.sh <<HOOK
#!/usr/bin/env bash
# вызывается certbot: кладёт TXT-запись в DuckDNS
U="https://www.duckdns.org/update?domains=$SUB&token=$TOK&txt=\${CERTBOT_VALIDATION}&verbose=true"
if curl -fsS --max-time 12 "\$U" 2>/dev/null | head -1 | grep -q '^OK'; then echo "TXT записан автоматически"
else
  echo; echo "[!] Открой эту ссылку В БРАУЗЕРЕ на своём компьютере (должно написать OK):"; echo; echo "   \$U"; echo
  if [[ -r /dev/tty ]]; then read -rp "   → открыл? нажми Enter… " _ </dev/tty; else sleep 90; fi
fi
sleep 45
HOOK
cat > /root/.mf-all/duck-clean.sh <<HOOK
#!/usr/bin/env bash
curl -fsS --max-time 10 "https://www.duckdns.org/update?domains=$SUB&token=$TOK&txt=removed&clear=true" >/dev/null 2>&1 || true
HOOK
cat > /root/.mf-all/duck-deploy.sh <<'HOOK'
#!/usr/bin/env bash
# после выпуска/продления: копирует сертификат туда, где его читает Caddy
D="$RENEWED_LINEAGE"; [[ -d "$D" ]] || exit 0
mkdir -p /etc/caddy; cp -L "$D/fullchain.pem" /etc/caddy/duck.crt; cp -L "$D/privkey.pem" /etc/caddy/duck.key
chown caddy:caddy /etc/caddy/duck.* 2>/dev/null || true; chmod 640 /etc/caddy/duck.key
systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null || true
HOOK
chmod +x /root/.mf-all/duck-*.sh

say "Выпускаю сертификат Let's Encrypt через DNS (около минуты)…"
certbot certonly --manual --preferred-challenges dns --manual-auth-hook /root/.mf-all/duck-hook.sh \
  --manual-cleanup-hook /root/.mf-all/duck-clean.sh --deploy-hook /root/.mf-all/duck-deploy.sh \
  -d "$DOM" -m "$MAIL" --agree-tos --no-eff-email --non-interactive --keep-until-expiring 2>&1 | tail -15
if [[ ! -s /etc/caddy/duck.crt ]]; then
  # --deploy-hook срабатывает только при новом выпуске; если сертификат уже был — копируем вручную
  [[ -d /etc/letsencrypt/live/$DOM ]] && RENEWED_LINEAGE=/etc/letsencrypt/live/$DOM bash /root/.mf-all/duck-deploy.sh
fi
[[ -s /etc/caddy/duck.crt && -s /etc/caddy/duck.key ]] || { err "Сертификат не выпущен. Смотри вывод certbot выше (обычно: ссылка не была открыта в браузере или не дождались записи DNS — просто запусти скрипт ещё раз)."; exit 1; }
say "Сертификат готов."

# ---------- 3. Caddy ----------
cp -a "$CF" "$CF.bak.$(date +%s)"
python3 - "$CF" "$DOM" <<'PY'
import re,sys
p,dom=sys.argv[1:3]; s=open(p,encoding="utf-8").read()
s=re.sub(r"# >>> zerossl-global >>>.*?# <<< zerossl-global <<<\n","",s,flags=re.S)
s=re.sub(r"\n[ \t]*tls /etc/caddy/duck\.crt /etc/caddy/duck\.key","",s)
m=re.search(r"# >>> minifarm >>>\n([^\n{]+)\{\n",s)
if not m: sys.exit("нет блока minifarm")
s=s[:m.start(1)]+dom+" {\n    tls /etc/caddy/duck.crt /etc/caddy/duck.key\n"+s[m.end():]
open(p,"w",encoding="utf-8").write(s)
PY
if ! caddy validate --config "$CF" --adapter caddyfile >/dev/null 2>&1; then
  err "Caddyfile не прошёл проверку, возвращаю прежний:"; caddy validate --config "$CF" --adapter caddyfile 2>&1 | tail -4
  cp -a "$(ls -t $CF.bak.* | head -1)" "$CF"; exit 1
fi
systemctl restart caddy; sleep 3

# ---------- 4. .env: ссылка на игру с новым адресом ----------
cp -a "$ENVF" "$ENVF.bak.$(date +%s)"
NEWURL="${GAME_URL}?api=https://$DOM"
if grep -q '^WEBAPP_URL=' "$ENVF"; then sed -i "s#^WEBAPP_URL=.*#WEBAPP_URL=$NEWURL#" "$ENVF"; else echo "WEBAPP_URL=$NEWURL" >> "$ENVF"; fi
systemctl restart minifarm minifarm-pay 2>/dev/null
say "WEBAPP_URL = $NEWURL"

# ---------- 5. проверка ----------
OK=0
for i in $(seq 1 12); do
  curl -fsS --max-time 8 --resolve "$DOM:443:127.0.0.1" "https://$DOM/event" >/dev/null 2>&1 && { OK=1; break; }; sleep 3
done
if [[ $OK == 1 ]]; then
  say "HTTPS на сервере работает ✅"
  curl -s --resolve "$DOM:443:127.0.0.1" "https://$DOM/event"; echo
  curl -fsS -D - -o /dev/null --resolve "$DOM:443:127.0.0.1" -H "Origin: ${GAME_URL%/}" "https://$DOM/event" 2>/dev/null | tr -d '\r' | grep -i '^access-control-allow-origin' | sed 's/^/   CORS: /'
  resolves && say "И снаружи тоже: https://$DOM" || warn "DNS для $DOM у сервера ещё не обновился — у игроков обновится в течение минут."
  echo; say "ГОТОВО. Адрес сервера: https://$DOM . Напиши боту /start — кнопка «Играть» уже с новым адресом."
  warn "Продление сертификата (раз в ~60 дней): если сервер не достаёт DuckDNS, просто запусти bash duck.sh ещё раз."
else
  err "HTTPS не отвечает. Лог: journalctl -u caddy -n 30 --no-pager"; exit 1
fi
DUCKEOF
  if APP_DIR="$APP_DIR" GAME_URL="$GAME_URL" bash /root/.mf-all/duck.sh; then
    DUCK_DOM="${DUCK_SUB:-fermafarms}.duckdns.org"
    API_URL="https://$DUCK_DOM"; FULL_URL="${GAME_URL}?api=$API_URL"; BACKUP_URL="$API_URL/game/"
    HTTPS_OK=1
    say "Адрес сервера теперь $API_URL"
  else
    warn "Запасной способ тоже не сработал. Бот работает, HTTPS можно доделать позже: bash /root/.mf-all/duck.sh"
  fi
fi
if [[ $HTTPS_OK -eq 1 ]]; then
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
say "Ответ /event сейчас:"; curl -fsS --max-time 8 "$API_URL/event" || true; echo
fi

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
