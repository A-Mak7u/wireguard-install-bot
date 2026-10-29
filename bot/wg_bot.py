#!/usr/bin/env python3
"""Telegram-бот для управления клиентами AmneziaWG / WireGuard.

Ключи создаёт и удаляет wireguard-install.sh (команды add, list, revoke) —
бот только вызывает его, присылает конфиги с параметрами обфускации и показывает статус сервера.
Настройки берутся из переменных окружения; установщик пишет их в /etc/wg-bot/bot.env.
"""

from __future__ import annotations

import asyncio
import datetime
import io
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

import qrcode
from telegram import (
    InlineKeyboardButton,
    InlineKeyboardMarkup,
    Message,
    ReplyKeyboardMarkup,
    Update,
)
from telegram.error import InvalidToken, TelegramError
from telegram.ext import (
    Application,
    CallbackQueryHandler,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

# ========= Настройки =========

log_handlers: list[logging.Handler] = [logging.StreamHandler(sys.stdout)]
log_file = os.environ.get("LOG_FILE")
if log_file:
    log_handlers.append(
        RotatingFileHandler(log_file, maxBytes=10 * 1024 * 1024, backupCount=3)
    )

logging.basicConfig(
    level=logging.INFO,
    format="%(levelname)s %(name)s: %(message)s",
    handlers=log_handlers,
)
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)
log = logging.getLogger("wg-bot")

TELEGRAM_TOKEN = os.environ.get("TELEGRAM_TOKEN", "").strip()
ADMIN_IDS = {int(x) for x in re.findall(r"\d+", os.environ.get("ADMIN_IDS", ""))}
WG_SCRIPT = os.environ.get("WG_SCRIPT", "/opt/wg-bot/wireguard-install.sh")
TELEGRAM_API_URL = os.environ.get("TELEGRAM_API_URL", "https://api.telegram.org").rstrip("/")

CLIENT_NAME_RE = re.compile(r"[A-Za-z0-9_-]{1,15}")
ACTIVE_HANDSHAKE_SECONDS = 10 * 60
SCRIPT_TIMEOUT_SECONDS = 120
EXIT_BAD_CONFIG = 2  # с этим кодом systemd не перезапускает бота

BTN_ADD = "➕ Добавить ключ"
BTN_DEL = "🗑 Удалить ключ"
BTN_LIST = "📜 Список ключей"
BTN_CLIENTS = "👥 Клиенты WG"
BTN_STATUS = "📊 Статус сервера"

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


# ========= VPN Утилиты =========


class ScriptError(Exception):
    pass


_script_lock: asyncio.Lock | None = None


def run_script(*args: str) -> str:
    try:
        result = subprocess.run(
            [WG_SCRIPT, *args],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=SCRIPT_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        raise ScriptError("скрипт не ответил за 2 минуты") from None
    except OSError as exc:
        raise ScriptError(f"не удалось запустить {WG_SCRIPT}: {exc}") from None

    if result.returncode != 0:
        message = ANSI_RE.sub("", result.stderr or result.stdout).strip()
        raise ScriptError(message or f"скрипт завершился с кодом {result.returncode}")
    return result.stdout


async def call_script(*args: str) -> str:
    # Скрипт переписывает конфиг VPN — две команды одновременно пускать нельзя
    global _script_lock
    if _script_lock is None:
        _script_lock = asyncio.Lock()
    async with _script_lock:
        return await asyncio.to_thread(run_script, *args)


async def list_clients() -> list[str]:
    output = await call_script("list")
    return [line.strip() for line in output.splitlines() if line.strip()]


async def add_client(name: str) -> Path:
    lines = (await call_script("add", name)).strip().splitlines()
    path = Path(lines[-1]) if lines else None
    if path is None or not path.is_file():
        raise ScriptError("ключ создан, но скрипт не сообщил, где лежит конфиг")
    return path


async def revoke_client(name: str) -> None:
    await call_script("revoke", name)


def read_wg_params() -> dict[str, str]:
    params = {}
    for p in [Path("/etc/amnezia/amneziawg/params"), Path("/etc/wireguard/params")]:
        if p.exists():
            for line in p.read_text().splitlines():
                key, sep, value = line.partition("=")
                if sep:
                    params[key.strip()] = value.strip()
            break
    return params


def find_wg_config(interface: str) -> Path:
    for p in [
        Path(f"/etc/amnezia/amneziawg/{interface}.conf"),
        Path(f"/etc/wireguard/{interface}.conf"),
    ]:
        if p.exists():
            return p
    return Path(f"/etc/wireguard/{interface}.conf")


def format_bytes(num_bytes: int) -> str:
    if num_bytes <= 0:
        return "0 B"

    value = float(num_bytes)
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    unit_index = 0
    while value >= 1024 and unit_index < len(units) - 1:
        value /= 1024
        unit_index += 1

    if unit_index == 0:
        return f"{int(value)} {units[unit_index]}"
    return f"{value:.2f} {units[unit_index]}"


def format_age(timestamp: int) -> str:
    if timestamp <= 0:
        return "никогда"

    age = max(0, int(time.time()) - timestamp)
    days, rem = divmod(age, 86400)
    hours, rem = divmod(rem, 3600)
    minutes, seconds = divmod(rem, 60)

    parts = []
    if days:
        parts.append(f"{days}д")
    if hours:
        parts.append(f"{hours}ч")
    if minutes and len(parts) < 2:
        parts.append(f"{minutes}м")
    if not parts:
        parts.append(f"{seconds}с")
    elif len(parts) < 2 and seconds and age < 3600:
        parts.append(f"{seconds}с")

    return " ".join(parts) + " назад"


def format_uptime() -> str:
    try:
        uptime_seconds = int(float(Path("/proc/uptime").read_text().split()[0]))
        days, rem = divmod(uptime_seconds, 86400)
        hours, rem = divmod(rem, 3600)
        minutes, _ = divmod(rem, 60)

        parts = []
        if days:
            parts.append(f"{days}д")
        if hours:
            parts.append(f"{hours}ч")
        if minutes or not parts:
            parts.append(f"{minutes}м")
        return " ".join(parts)
    except Exception:
        return "неизвестно"


def get_memory_summary() -> tuple[str, str, int]:
    try:
        meminfo = {}
        for line in Path("/proc/meminfo").read_text().splitlines():
            key, value = line.split(":", 1)
            meminfo[key] = int(value.strip().split()[0]) * 1024

        total = meminfo["MemTotal"]
        used = total - meminfo["MemAvailable"]
        return format_bytes(used), format_bytes(total), round(used / total * 100)
    except Exception:
        return "0 B", "0 B", 0


def get_disk_summary() -> tuple[str, str, int]:
    try:
        usage = shutil.disk_usage("/")
        return format_bytes(usage.used), format_bytes(usage.total), round(usage.used / usage.total * 100)
    except Exception:
        return "0 B", "0 B", 0


def parse_peer_names(config: Path) -> dict[str, str]:
    peer_names = {}
    current_client = None
    if not config.exists():
        return peer_names

    for raw_line in config.read_text().splitlines():
        line = raw_line.strip()
        if line.startswith("### Client "):
            current_client = line[len("### Client "):].strip()
        elif line.startswith("PublicKey"):
            public_key = line.split("=", 1)[1].strip()
            peer_names[public_key] = current_client or public_key[:12]
            current_client = None
    return peer_names


def get_wg_peers(interface: str) -> list[dict]:
    config_path = find_wg_config(interface)
    peer_names = parse_peer_names(config_path)

    cmd = ["awg", "show", interface, "dump"] if shutil.which("awg") else ["wg", "show", interface, "dump"]
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return []

    peers = []
    # Первая строка — сам интерфейс (в AmneziaWG имеет 30 полей).
    # Пиры имеют 8 полей (awg show <iface> dump) или 9 полей (awg show all dump).
    for line in result.stdout.splitlines()[1:]:
        parts = line.split("\t")
        if len(parts) < 7:
            continue
        if len(parts) >= 8:
            if "/" not in parts[3] and "/" not in parts[4]:
                continue
            if len(parts) >= 9 and "/" in parts[4]:
                public_key, endpoint, allowed_ips, handshake, rx, tx = parts[1], parts[3], parts[4], parts[5], parts[6], parts[7]
            else:
                public_key, endpoint, allowed_ips, handshake, rx, tx = parts[0], parts[2], parts[3], parts[4], parts[5], parts[6]
        else:
            public_key, _, endpoint, allowed_ips, handshake, rx, tx = parts[:7]

        try:
            handshake_ts = int(handshake)
            rx_bytes = int(rx)
            tx_bytes = int(tx)
        except ValueError:
            continue

        peers.append(
            {
                "name": peer_names.get(public_key, public_key[:12]),
                "allowed_ip": allowed_ips.split(",", 1)[0],
                "endpoint": endpoint,
                "handshake_ts": handshake_ts,
                # rx — что сервер получил от клиента, tx — что отправил ему
                "rx_bytes": rx_bytes,
                "tx_bytes": tx_bytes,
                "is_active": handshake_ts > 0
                and time.time() - handshake_ts <= ACTIVE_HANDSHAKE_SECONDS,
            }
        )

    peers.sort(key=lambda p: (not p["is_active"], -p["handshake_ts"], p["name"].lower()))
    return peers


def build_status_report() -> str:
    params = read_wg_params()
    interface = params.get("SERVER_WG_NIC", "awg0" if shutil.which("awg") else "wg0")

    awg_active = (
        subprocess.run(
            ["systemctl", "is-active", "--quiet", f"awg-quick@{interface}"],
            check=False,
        ).returncode
        == 0
    )
    wg_active = (
        awg_active
        or subprocess.run(
            ["systemctl", "is-active", "--quiet", f"wg-quick@{interface}"],
            check=False,
        ).returncode
        == 0
    )
    is_awg = bool(shutil.which("awg")) or "awg" in interface or params.get("IS_AWG") == "1"
    vpn_label = "AmneziaWG" if is_awg else "WireGuard"

    peers = get_wg_peers(interface) if wg_active else []
    active_peers = [p for p in peers if p["is_active"]]
    try:
        load1, load5, load15 = os.getloadavg()
    except Exception:
        load1, load5, load15 = 0.0, 0.0, 0.0
    mem_used, mem_total, mem_percent = get_memory_summary()
    disk_used, disk_total, disk_percent = get_disk_summary()
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    return "\n".join(
        [
            f"📊 Статус сервера ({now})",
            f"{'🟢' if wg_active else '🔴'} {vpn_label}: {'активен' if wg_active else 'не активен'}",
            f"👥 Клиенты: {len(active_peers)} активны / {len(peers)} всего",
            f"📥 Клиенты скачали: {format_bytes(sum(p['tx_bytes'] for p in peers))}",
            f"📤 Клиенты отправили: {format_bytes(sum(p['rx_bytes'] for p in peers))}",
            f"⏱ Аптайм: {format_uptime()}",
            f"⚙ Load average: {load1:.2f} / {load5:.2f} / {load15:.2f}",
            f"🧠 RAM: {mem_used} / {mem_total} ({mem_percent}%)",
            f"💾 Диск /: {disk_used} / {disk_total} ({disk_percent}%)",
            f"🔌 Порт WG: {params.get('SERVER_PORT', '?')}/udp",
        ]
    )


def build_clients_report() -> str:
    params = read_wg_params()
    interface = params.get("SERVER_WG_NIC", "awg0" if shutil.which("awg") else "wg0")
    is_awg = bool(shutil.which("awg")) or "awg" in interface or params.get("IS_AWG") == "1"
    vpn_label = "AmneziaWG" if is_awg else "WireGuard"

    peers = get_wg_peers(interface)
    active_peers = [p for p in peers if p["is_active"]]
    lines = [
        f"👥 Клиенты {vpn_label}",
        f"🟢 Активны за последние 10 минут: {len(active_peers)} / {len(peers)}",
        f"ℹ️ Трафик считается с последнего запуска {vpn_label}.",
        "",
    ]
    if not peers:
        lines.append("Клиентов нет.")

    for peer in peers:
        lines.append(
            " | ".join(
                [
                    f"{'🟢' if peer['is_active'] else '⚪'} {peer['name']}",
                    peer["allowed_ip"],
                    f"последний handshake: {format_age(peer['handshake_ts'])}",
                    f"↓ {format_bytes(peer['tx_bytes'])}",
                    f"↑ {format_bytes(peer['rx_bytes'])}",
                ]
            )
        )
    return "\n".join(lines)


def make_qr_png(text: str) -> bytes:
    buffer = io.BytesIO()
    qrcode.make(text).save(buffer)
    return buffer.getvalue()


# ========= Telegram =========


def admin_keyboard() -> ReplyKeyboardMarkup:
    return ReplyKeyboardMarkup(
        [[BTN_ADD, BTN_DEL], [BTN_LIST, BTN_CLIENTS], [BTN_STATUS]],
        resize_keyboard=True,
    )


async def start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    user = update.effective_user
    if user.id not in ADMIN_IDS:
        log.warning("Бота открыл посторонний: id=%s username=%s", user.id, user.username)
        await update.message.reply_text(f"Доступ только для админа. Твой Telegram ID: {user.id}")
        return

    context.user_data.pop("mode", None)
    await update.message.reply_text("Панель управления AmneziaWG / WireGuard.", reply_markup=admin_keyboard())


async def send_client_config(message: Message, name: str, path: Path) -> None:
    config = path.read_bytes()
    await message.reply_document(
        document=config,
        filename=f"{name}.conf",
        caption="Файл для приложения AmneziaWG: «Добавить туннель» → «Импорт из файла».",
    )
    await message.reply_photo(
        photo=make_qr_png(config.decode(errors="ignore")),
        caption=f"QR-код для {name}: «Добавить туннель» → «Сканировать QR-код».",
    )


async def create_client(message: Message, name: str) -> None:
    if not CLIENT_NAME_RE.fullmatch(name):
        await message.reply_text(
            "Некорректное имя: только латиница, цифры, _ и -, не длиннее 15 символов.\n"
            f"Нажми «{BTN_ADD}», чтобы попробовать снова.",
            reply_markup=admin_keyboard(),
        )
        return

    await message.reply_text(f"Создаю ключ {name}…")
    try:
        path = await add_client(name)
    except ScriptError as exc:
        await message.reply_text(f"❌ Не удалось создать {name}: {exc}", reply_markup=admin_keyboard())
        return

    try:
        await send_client_config(message, name, path)
    except TelegramError as exc:
        log.exception("Не удалось отправить конфиг %s", name)
        await message.reply_text(
            f"⚠️ Ключ {name} создан, но отправить конфиг не получилось: {exc}\nОн лежит на сервере: {path}",
            reply_markup=admin_keyboard(),
        )
        return

    await message.reply_text(f"✅ Ключ {name} создан и отправлен.", reply_markup=admin_keyboard())


async def show_clients_list(message: Message) -> None:
    try:
        clients = await list_clients()
    except ScriptError as exc:
        await message.reply_text(f"❌ Не удалось получить список: {exc}", reply_markup=admin_keyboard())
        return

    if not clients:
        await message.reply_text("Клиентов нет.", reply_markup=admin_keyboard())
        return
    body = "\n".join(f"{i}) {name}" for i, name in enumerate(clients, 1))
    await message.reply_text("📜 Список клиентов:\n" + body, reply_markup=admin_keyboard())


async def ask_which_to_delete(message: Message) -> None:
    try:
        clients = await list_clients()
    except ScriptError as exc:
        await message.reply_text(f"❌ Не удалось получить список: {exc}", reply_markup=admin_keyboard())
        return

    if not clients:
        await message.reply_text("Клиентов нет, удалять нечего.", reply_markup=admin_keyboard())
        return
    keyboard = [[InlineKeyboardButton(f"🗑 {name}", callback_data=f"del:{name}")] for name in clients]
    await message.reply_text("Какой ключ удалить?", reply_markup=InlineKeyboardMarkup(keyboard))


async def send_report(message: Message, build_report) -> None:
    try:
        report = await asyncio.to_thread(build_report)
    except Exception as exc:
        log.exception("Не удалось собрать отчёт")
        report = f"❌ Ошибка: {exc}"
    await message.reply_text(report, reply_markup=admin_keyboard())


async def on_admin_text(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Кнопки меню и ввод имени клиента после «Добавить ключ»."""
    message = update.message
    text = (message.text or "").strip()
    waiting_for_name = context.user_data.pop("mode", None) == "await_client_name"

    if text == BTN_ADD:
        context.user_data["mode"] = "await_client_name"
        await message.reply_text("Введи имя нового клиента: латиница, цифры, _ и -, не длиннее 15 символов.")
    elif text == BTN_DEL:
        await ask_which_to_delete(message)
    elif text == BTN_LIST:
        await show_clients_list(message)
    elif text == BTN_CLIENTS:
        await send_report(message, build_clients_report)
    elif text == BTN_STATUS:
        await send_report(message, build_status_report)
    elif waiting_for_name:
        await create_client(message, text)
    else:
        await message.reply_text("Используй кнопки снизу или /start.", reply_markup=admin_keyboard())


async def on_delete_button(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()
    if query.from_user.id not in ADMIN_IDS:
        return

    action, _, name = query.data.partition(":")
    if action == "del":
        confirm = InlineKeyboardMarkup(
            [
                [
                    InlineKeyboardButton("Да, удалить", callback_data=f"delok:{name}"),
                    InlineKeyboardButton("Отмена", callback_data="delno:"),
                ]
            ]
        )
        await query.edit_message_text(
            f"Удалить ключ {name}? Устройство с этим ключом сразу потеряет VPN.",
            reply_markup=confirm,
        )
    elif action == "delno":
        await query.edit_message_text("Удаление отменено.")
    elif action == "delok":
        try:
            await revoke_client(name)
        except ScriptError as exc:
            await query.edit_message_text(f"❌ Не удалось удалить {name}: {exc}")
            return
        await query.edit_message_text(f"🗑 Ключ {name} удалён.")


async def remove_user_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    message = update.message
    if not context.args:
        await message.reply_text("Использование: /removeuser <имя_клиента>", reply_markup=admin_keyboard())
        return

    name = context.args[0].lstrip("@")
    try:
        await revoke_client(name)
    except ScriptError as exc:
        await message.reply_text(f"❌ Не удалось удалить {name}: {exc}", reply_markup=admin_keyboard())
        return
    await message.reply_text(f"✅ Ключ {name} удалён.", reply_markup=admin_keyboard())


async def on_error(update: object, context: ContextTypes.DEFAULT_TYPE) -> None:
    log.error("Ошибка при обработке сообщения", exc_info=context.error)


def main() -> None:
    if not TELEGRAM_TOKEN or not ADMIN_IDS:
        log.error("Не заданы TELEGRAM_TOKEN или ADMIN_IDS — проверь /etc/wg-bot/bot.env")
        sys.exit(EXIT_BAD_CONFIG)

    app = (
        Application.builder()
        .token(TELEGRAM_TOKEN)
        .base_url(f"{TELEGRAM_API_URL}/bot")
        .base_file_url(f"{TELEGRAM_API_URL}/file/bot")
        .build()
    )
    admins = filters.User(user_id=ADMIN_IDS)

    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler(["removeuser", "purgeuser"], remove_user_command, filters=admins))
    app.add_handler(CallbackQueryHandler(on_delete_button, pattern=r"^del(ok|no)?:"))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND & admins, on_admin_text))
    app.add_error_handler(on_error)

    log.info("Бот запущен, админы: %s", ", ".join(map(str, sorted(ADMIN_IDS))))
    try:
        app.run_polling()
    except InvalidToken:
        log.error("Telegram не принял токен — проверь TELEGRAM_TOKEN в /etc/wg-bot/bot.env")
        sys.exit(EXIT_BAD_CONFIG)


if __name__ == "__main__":
    main()
