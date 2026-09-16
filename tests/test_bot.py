#!/usr/bin/env python3
"""Сквозная проверка установленного бота через поддельный Telegram API.

Запускается на тестовом сервере после установки (см. run.sh): бот уже работает
как служба wg-bot и ходит в fake_telegram.py вместо api.telegram.org.
"""

import json
import os
import subprocess
import sys
import time

from tg_client import calls, press, send_text, user

WG_SCRIPT = "/opt/wg-bot/wireguard-install.sh"
EXPECTED_PORT = os.environ.get("EXPECTED_PORT", "51820")
ADMIN = user(555, "Admin")
STRANGER = user(777, "Stranger")

BTN_ADD = "➕ Добавить ключ"
BTN_DEL = "🗑 Удалить ключ"
BTN_LIST = "📜 Список ключей"
BTN_CLIENTS = "👥 Клиенты WG"
BTN_STATUS = "📊 Статус сервера"

failures = []


def check(name, condition):
    print(("OK   " if condition else "FAIL ") + name, flush=True)
    if not condition:
        failures.append(name)


def text_of(call):
    params = call["params"]
    return params.get("text") or params.get("caption") or ""


def markup(call):
    raw = call["params"].get("reply_markup") or "{}"
    return json.loads(raw) if isinstance(raw, str) else raw


def wait_for(start, method=None, contains=None, timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        for call in calls()[start:]:
            if (method is None or call["method"] == method) and (contains is None or contains in text_of(call)):
                return call
        time.sleep(0.3)
    return None


def say(sender, text, contains=None, method=None, timeout=60):
    start = len(calls())
    send_text(sender, text)
    return wait_for(start, method, contains, timeout)


def tap(sender, data, contains=None, method="editMessageText", timeout=60):
    start = len(calls())
    press(sender, data)
    return wait_for(start, method, contains, timeout)


def silence_for(sender, action, seconds=3):
    start = len(calls())
    action()
    time.sleep(seconds)
    return not any(str(c["params"].get("chat_id")) == str(sender["id"]) for c in calls()[start:])


def wg_clients():
    return subprocess.run([WG_SCRIPT, "list"], capture_output=True, text=True).stdout.split()


# Ждём, пока бот начнёт отвечать
call = None
for _ in range(20):
    call = say(ADMIN, "/start", contains="Панель управления", timeout=3)
    if call:
        break
check("админ получает меню на /start", call is not None and BTN_ADD in json.dumps(markup(call), ensure_ascii=False))

call = say(STRANGER, "/start", contains="Доступ только для админа")
check("посторонний получает отказ и свой ID", call is not None and "777" in text_of(call))
check("кнопки постороннего игнорируются", silence_for(STRANGER, lambda: send_text(STRANGER, BTN_LIST)))

say(ADMIN, BTN_ADD, contains="Введи имя")
start = len(calls())
call = say(ADMIN, "mama", contains="создан и отправлен", timeout=90)
check("ключ создаётся", call is not None)
documents = [c for c in calls()[start:] if c["method"] == "sendDocument"]
document = documents[0]["params"]["document"] if documents else {}
check(
    "приходит файл mama.conf с конфигом",
    document.get("filename") == "mama.conf" and "[Interface]" in (document.get("content") or ""),
)
check("приходит QR-код", any(c["method"] == "sendPhoto" for c in calls()[start:]))
check("клиент появился в WireGuard", "mama" in wg_clients())

say(ADMIN, BTN_ADD, contains="Введи имя")
started = time.time()
call = say(ADMIN, "a.b", contains="Некорректное имя", timeout=10)
check("имя с точкой отклоняется сразу", call is not None and time.time() - started < 5)
say(ADMIN, BTN_ADD, contains="Введи имя")
check("слишком длинное имя отклоняется", say(ADMIN, "averyverylongname", contains="Некорректное имя", timeout=10))

say(ADMIN, BTN_ADD, contains="Введи имя")
call = say(ADMIN, BTN_LIST, contains="Список клиентов")
check("кнопка вместо имени открывает свой раздел", call is not None and "mama" in text_of(call))

say(ADMIN, BTN_ADD, contains="Введи имя")
call = say(ADMIN, "mama", contains="Не удалось создать")
check("повторное имя — понятная ошибка", call is not None and "уже существует" in text_of(call))

call = say(ADMIN, BTN_DEL, contains="Какой ключ удалить")
buttons = [b["callback_data"] for row in markup(call).get("inline_keyboard", []) for b in row] if call else []
check("в списке на удаление есть mama", "del:mama" in buttons)
check("удаление просит подтверждения", tap(ADMIN, "del:mama", contains="Удалить ключ mama?"))
check("«Отмена» ничего не удаляет", tap(ADMIN, "delno:", contains="отменено") and "mama" in wg_clients())
silence_for(STRANGER, lambda: press(STRANGER, "delok:mama"))
check("посторонний не может удалить ключ", "mama" in wg_clients())
call = tap(ADMIN, "delok:mama", contains="удалён")
check("подтверждённое удаление работает", call is not None and "mama" not in wg_clients())
check("файл конфига удалён с сервера", not os.path.exists("/root/wg0-client-mama.conf"))

call = say(ADMIN, "/removeuser ghost", contains="Не удалось удалить ghost")
check("/removeuser несуществующего — понятная ошибка", call is not None and "не найден" in text_of(call))
say(ADMIN, BTN_ADD, contains="Введи имя")
say(ADMIN, "tmpuser", contains="создан и отправлен", timeout=90)
call = say(ADMIN, "/removeuser tmpuser", contains="Ключ tmpuser удалён")
check("/removeuser удаляет", call is not None and "tmpuser" not in wg_clients())

call = say(ADMIN, BTN_STATUS, contains="Статус сервера")
check(
    "статус сервера",
    call is not None and "WireGuard: активен" in text_of(call) and f"Порт WG: {EXPECTED_PORT}/udp" in text_of(call),
)
call = say(ADMIN, BTN_CLIENTS, contains="Клиенты WireGuard")
check("отчёт по клиентам", call is not None and "phone" in text_of(call))

sys.exit(1 if failures else 0)
