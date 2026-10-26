#!/usr/bin/env bash
# update.sh — БЕЗОПАСНОЕ обновление «Мини-фермы» (акции, погода, /buys, надёжная выдача доната).
# НЕ трогает: .env, data.json, grants.json, players.json и всё остальное, где лежат данные игроков/покупки.
# Меняет только код бота (*.py), перед этим делает копию всех данных в папку backup-<дата>.
# Запуск: bash update.sh     (повторный запуск безопасен)
set -euo pipefail
APP_DIR="${APP_DIR:-/root/farm-bot}"
PY="$APP_DIR/venv/bin/python3"
[[ -x "$PY" ]] || PY="$(command -v python3)"
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
say(){ echo -e "${G}[+]${N} $*"; }; warn(){ echo -e "${Y}[!]${N} $*"; }; err(){ echo -e "${R}[x]${N} $*" >&2; }
[[ -d "$APP_DIR" && -f "$APP_DIR/.env" ]] || { err "Не найден $APP_DIR/.env — бот не установлен. Сначала bash nano.sh"; exit 1; }
cd "$APP_DIR"

BK="$APP_DIR/backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK"
cp -a .env *.json *.json.lock *.log *.py "$BK/" 2>/dev/null || true
say "Копия данных и кода: $BK (если что-то пойдёт не так — просто скопируй файлы оттуда обратно)"

cat > "$APP_DIR/server.py.new" <<'UPDEOF'
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
UPDEOF
cat > "$APP_DIR/payments.py.new" <<'UPDEOF'
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
        if sku == "vip": return 150
        if sku == "bp": return 100
    except (IndexError, ValueError):
        pass
    return None

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
        if rb and inv:
            try: bot.send_message(int(inv), "🤝 Ваш друг сделал покупку: вам +%d 🪙 (партнёрская программа). Заберите в игре!" % rb)
            except Exception: pass

    # платёжные обработчики — раньше общих «ловушек» из server.py
    bot.pre_checkout_query_handlers.insert(0, bot.pre_checkout_query_handlers.pop())
    bot.message_handlers.insert(0, bot.message_handlers.pop())
UPDEOF
cat > "$APP_DIR/payments_http.py.new" <<'UPDEOF'
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
                ok = admin.record_snapshot(uid, body.get("name"), body.get("lvl"), body.get("xp"), body.get("coins"), body.get("snap"))
                return self._send(200, {"ok": bool(ok)})
        except Exception as e:
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
ThreadingHTTPServer(("127.0.0.1", 3001), H).serve_forever()
UPDEOF
cat > "$APP_DIR/admin.py.new" <<'UPDEOF'
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


def record_snapshot(uid, name, lvl, xp, coins, snap):
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
        wk = week_id(now)
        rec = {
            "name": _clean(name) or "Фермер",
            "lvl": max(1, min(999, int(lvl or 1))),
            "xp": nxp,
            "coins": max(0, min(10 ** 12, int(coins or 0))),
            "seen": int(now),
            "snap": snap,
        }
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
    rows = [(u, _week_gain(v, w), v) for u, v in d.items()]
    rows = [r for r in rows if r[1] > 0]
    rows.sort(key=lambda r: r[1], reverse=True)
    out = [{"id": hid(u), "name": v.get("name", "Фермер"), "lvl": v.get("lvl", 1), "gain": g,
            "me": 1 if u == str(uid) else 0} for u, g, v in rows[:20]]
    me = next((i + 1 for i, r in enumerate(rows) if r[0] == str(uid)), 0)
    mg = next((r[1] for r in rows if r[0] == str(uid)), 0)
    left = int((w + 1) * 604800 + 4 * 86400 - time.time())
    return {"ok": True, "rows": out, "me": me, "mg": mg, "left": left, "prizes": [p[0] for p in WEEK_PRIZES]}


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
        rows = sorted([(u, _week_gain(v, last)) for u, v in pl.items()], key=lambda r: r[1], reverse=True)
        rows = [r for r in rows if r[1] > 0][:3]
        for i, (u, g) in enumerate(rows):
            c, egg, et = WEEK_PRIZES[i]
            gl = dd["grants"].setdefault(u, [])
            gl.append({"id": uuid.uuid4().hex[:12], "sku": "adm_coins_%d" % c})
            if egg:
                gl.append({"id": uuid.uuid4().hex[:12], "sku": egg})
            wins.append((u, i + 1, c, et))
        dd["wkaward"] = w; P._save(dd)
    if bot:
        for u, place, c, et in wins:
            try:
                bot.send_message(int(u), "🏆 Итоги недели: вы заняли %d место в рейтинге ферм!\nНаграда: %d 🪙%s. Откройте игру — награда уже ждёт." % (place, c, (" + " + et) if et else ""))
            except Exception:
                pass


def farms_list(limit=50):
    d = _pload()
    cutoff = time.time() - 60 * 86400
    rows = [(u, v) for u, v in d.items() if v.get("seen", 0) > cutoff]
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
        rbox = box.get(rid, [])
        if len(rbox) >= MAIL_BOX_MAX: return {"ok": False, "err": "У получателя переполнен ящик"}
        pd = _pload()
        fn = _mclean(body.get("fn"), 16) or _mclean((pd.get(uid) or {}).get("name"), 16) or "Друг"
        g = {"id": uuid.uuid4().hex[:12], "fn": fn, "kind": kind, "k": k, "n": n, "msg": _mclean(body.get("msg"), 40), "t": int(time.time())}
        rbox.append(g); box[rid] = rbox
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
    with P._Lock():
        d = P._load()
        d["grants"].setdefault(str(uid), []).append({"id": uuid.uuid4().hex[:12], "sku": grant})
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
    if grant.startswith("egg_"): return "🥚 кейс с яйцом %s" % grant[4:].replace("_", " / ")
    if grant.startswith("skin_"): return "🎨 скин %s" % grant[5:].replace("_", " / ")
    if grant.startswith("bx_"):
        _, m, dd = grant.split("_"); return "⚡ множитель ×%s на %s дн." % (m, dd)
    return grant


# ---------- бот ----------
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
            v.update({"xp": 0, "lvl": 1, "coins": 0, "wb": 0})
            v.pop("pwk", None); v.pop("pg", None)
            _psave(pl)
    log(admin_id, uid, "RESET: " + reason)
    return gid


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
                    [("📢 Объявление", "adm:an"), ("ℹ️ Команды", "adm:h")]]))

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
            [("🗑 Обнулить прогресс", "adm:rs:%s" % u)],
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
    first("message_handlers", 13)
    first("callback_query_handlers", 1)
UPDEOF
cat > "$APP_DIR/broadcast.py.new" <<'UPDEOF'
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
UPDEOF

for f in server.py payments.py payments_http.py admin.py broadcast.py; do
  "$PY" -m py_compile "$APP_DIR/$f.new" || { err "$f не компилируется — ничего не заменено."; rm -f "$APP_DIR"/*.py.new; exit 1; }
done
for f in server.py payments.py payments_http.py admin.py broadcast.py; do mv "$APP_DIR/$f.new" "$APP_DIR/$f"; done
rm -rf "$APP_DIR/__pycache__"
say "Код бота обновлён."

# подключение оплаты и админки в новый server.py (как в nano.sh)
for MOD in payments admin; do
"$PY" - "$APP_DIR/server.py" "$MOD" <<'PATCHPY'
import re, sys
p, mod = sys.argv[1], sys.argv[2]; s = open(p, encoding="utf-8").read()
if mod + ".install" in s: sys.exit(0)
m = re.search(r"^([ \t]*)(\w+)\.(infinity_polling|polling)\(", s, re.M)
if not m: print("NOPOLL"); sys.exit(1)
call = "payments.install(%s, %s.token)" % (m.group(2), m.group(2)) if mod == "payments" else "admin.install(%s)" % m.group(2)
open(p, "w", encoding="utf-8").write(s[:m.start()] + "%simport %s; %s\n" % (m.group(1), mod, call) + s[m.start():])
PATCHPY
done
"$PY" -m py_compile "$APP_DIR/server.py" || { cp -a "$BK/server.py" "$APP_DIR/server.py"; err "server.py не компилируется — вернул старый."; exit 1; }

# свежая копия игры для запасного адреса на сервере (основная — GitHub Pages — обновляется сама)
RAW_URL="${RAW_URL:-https://raw.githubusercontent.com/xnin228/everyday/main/index.html}"
if [[ -d /var/www/minifarm ]] && curl -fsS --max-time 30 "$RAW_URL" -o /tmp/mf-index.html && grep -q "wxType" /tmp/mf-index.html; then
  cp /tmp/mf-index.html /var/www/minifarm/index.html; say "Запасная копия игры на сервере обновлена."
else warn "Копию игры на сервере не обновлял (не страшно: основная игра на GitHub Pages)."; fi

systemctl restart minifarm minifarm-pay
sleep 3
systemctl is-active --quiet minifarm && systemctl is-active --quiet minifarm-pay && say "Сервисы работают ✅" || { err "Сервис не поднялся: journalctl -u minifarm -n 40 --no-pager"; exit 1; }
PORT_VAL="$(grep -E '^PORT=' .env | cut -d= -f2 || true)"; PORT_VAL="${PORT_VAL:-3000}"
curl -fsS --max-time 5 "http://127.0.0.1:$PORT_VAL/event" | grep -q weather && say "API акций и погоды отвечает ✅" || warn "API /event не ответил — смотри journalctl -u minifarm -n 40"
echo
echo "Готово. Игроки и их данные не затронуты. Новые команды в боте (только админу): /event, /weather, /buys"
