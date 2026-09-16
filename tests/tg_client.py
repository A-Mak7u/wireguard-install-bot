#!/usr/bin/env python3
"""Управление поддельным Telegram API из тестов.

Как модуль — функции для test_bot.py. Из командной строки — для expect-сценариев:
  tg_client.py clear
  tg_client.py start <id> <имя> <username>   — пользователь нажал «Старт»
"""

import json
import sys
import time
import urllib.request

API = "http://127.0.0.1:8081"


def api(path, data=None):
    body = json.dumps(data).encode() if data is not None else b""
    request = urllib.request.Request(API + path, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.load(response)


def user(user_id, first_name="Test", username=None):
    sender = {"id": user_id, "is_bot": False, "first_name": first_name}
    if username:
        sender["username"] = username
    return sender


def send_text(sender, text):
    message = {
        "message_id": int(time.time() * 1000) % 1_000_000,
        "date": int(time.time()),
        "chat": {"id": sender["id"], "type": "private"},
        "from": sender,
        "text": text,
    }
    if text.startswith("/"):
        message["entities"] = [{"type": "bot_command", "offset": 0, "length": len(text.split()[0])}]
    api("/test/update", {"message": message})


def press(sender, data):
    message = {"message_id": 1, "date": int(time.time()), "chat": {"id": sender["id"], "type": "private"}, "text": "…"}
    api(
        "/test/update",
        {"callback_query": {"id": str(time.time()), "from": sender, "chat_instance": "1", "data": data, "message": message}},
    )


def calls():
    return api("/test/calls")


def clear():
    api("/test/clear", {})


if __name__ == "__main__":
    if sys.argv[1] == "clear":
        clear()
    elif sys.argv[1] == "start":
        send_text(user(int(sys.argv[2]), sys.argv[3], sys.argv[4]), "/start")
