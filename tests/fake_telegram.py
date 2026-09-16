#!/usr/bin/env python3
"""Поддельный Telegram Bot API для тестов: отвечает боту и записывает, что он отправил.

Служебные адреса:
  POST /test/update  — положить апдейт в очередь (update_id проставится сам)
  POST /test/clear   — очистить очередь апдейтов
  GET  /test/calls   — все вызовы бота: [{"method": ..., "params": {...}}, ...]

Настоящим считается только токен GOOD_TOKEN, на остальные — 401, как у Telegram.
"""

import email.parser
import email.policy
import json
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8081
GOOD_TOKEN = "123456:TESTtoken_aaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
BOT_USER = {
    "id": 123456,
    "is_bot": True,
    "first_name": "Test VPN",
    "username": "test_vpn_bot",
    "can_join_groups": True,
    "can_read_all_group_messages": False,
    "supports_inline_queries": False,
}

state = threading.Condition()
updates = []
calls = []
counters = {"update": 0, "message": 1000}


def new_message(params, **extra):
    counters["message"] += 1
    message = {
        "message_id": counters["message"],
        "date": int(time.time()),
        "chat": {"id": int(params.get("chat_id") or 0), "type": "private"},
    }
    if "text" in params:
        message["text"] = params["text"]
    message.update(extra)
    return message


def bot_method(method, params):
    if method == "getMe":
        return BOT_USER
    if method == "getUpdates":
        offset = int(params.get("offset") or 0)
        deadline = time.time() + min(float(params.get("timeout") or 0), 2)
        with state:
            while True:
                pending = [u for u in updates if u["update_id"] >= offset]
                if pending or time.time() >= deadline:
                    return pending
                state.wait(deadline - time.time())

    with state:
        calls.append({"method": method, "params": params})
    if method in ("sendMessage", "editMessageText"):
        return new_message(params)
    if method == "sendDocument":
        return new_message(params, document={"file_id": "doc", "file_unique_id": "doc"})
    if method == "sendPhoto":
        photo = [{"file_id": "photo", "file_unique_id": "photo", "width": 100, "height": 100}]
        return new_message(params, photo=photo)
    return True


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def read_params(self):
        params = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(self.path).query))
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        content_type = self.headers.get("Content-Type", "")

        if content_type.startswith("multipart/form-data"):
            raw = b"Content-Type: " + content_type.encode() + b"\r\n\r\n" + body
            form = email.parser.BytesParser(policy=email.policy.HTTP).parsebytes(raw)
            for part in form.iter_parts():
                name = part.get_param("name", header="content-disposition")
                payload = part.get_payload(decode=True) or b""
                filename = part.get_filename()
                if filename:
                    content = payload.decode() if filename.endswith(".conf") else None
                    params[name] = {"filename": filename, "size": len(payload), "content": content}
                else:
                    params[name] = payload.decode()
        elif content_type.startswith("application/json"):
            params.update(json.loads(body or b"{}"))
        elif body:
            params.update(urllib.parse.parse_qsl(body.decode()))
        return params

    def respond(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        params = self.read_params()

        if path == "/test/update":
            with state:
                counters["update"] += 1
                params["update_id"] = counters["update"]
                updates.append(params)
                state.notify_all()
            self.respond(200, {"ok": True})
        elif path == "/test/clear":
            with state:
                updates.clear()
            self.respond(200, {"ok": True})
        elif path == "/test/calls":
            with state:
                self.respond(200, list(calls))
        elif path.startswith("/bot"):
            token, _, method = path[len("/bot"):].partition("/")
            if token != GOOD_TOKEN:
                self.respond(401, {"ok": False, "error_code": 401, "description": "Unauthorized"})
            else:
                self.respond(200, {"ok": True, "result": bot_method(method, params)})
        else:
            self.respond(404, {"ok": False, "error_code": 404, "description": "Not Found"})

    do_POST = do_GET


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
