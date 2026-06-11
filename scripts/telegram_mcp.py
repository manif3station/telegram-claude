#!/usr/bin/env python3
import json
import mimetypes
import os
import pathlib
import sys

import requests


PLUGIN_ROOT = pathlib.Path(__file__).resolve().parent.parent
ENV_FILE = PLUGIN_ROOT / ".env"
DOWNLOAD_ROOT = PLUGIN_ROOT / "downloads"
SERVER_NAME = "telegram-claude-bot"
SERVER_VERSION = "0.2.0"
PROTOCOL_VERSION = "2024-11-05"


def load_env_file(path):
    env = {}
    if not path.exists():
        return env
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key.strip()] = value.strip()
    return env


FILE_ENV = load_env_file(ENV_FILE)


def env_value(name):
    value = os.environ.get(name)
    if value:
        return value
    return FILE_ENV.get(name)


def bot_token():
    token = env_value("TELEGRAM_BOT_TOKEN")
    if not token:
        raise RuntimeError("Missing TELEGRAM_BOT_TOKEN in plugin .env or process environment")
    return token


def bot_api(method):
    return f"https://api.telegram.org/bot{bot_token()}/{method}"


def bot_file_url(file_path):
    return f"https://api.telegram.org/file/bot{bot_token()}/{file_path}"


def telegram_request(method, *, params=None, files=None):
    response = requests.post(bot_api(method), data=params, files=files, timeout=60)
    response.raise_for_status()
    payload = response.json()
    if not payload.get("ok"):
        raise RuntimeError(f"Telegram API error for {method}: {payload}")
    return payload


def telegram_get(method, *, params=None):
    response = requests.get(bot_api(method), params=params, timeout=60)
    response.raise_for_status()
    payload = response.json()
    if not payload.get("ok"):
        raise RuntimeError(f"Telegram API error for {method}: {payload}")
    return payload


def summarise_update(update):
    message = update.get("message") or update.get("edited_message") or {}
    chat = message.get("chat") or {}
    photos = message.get("photo") or []
    best_photo = photos[-1] if photos else None
    return {
        "update_id": update.get("update_id"),
        "message_id": message.get("message_id"),
        "date": message.get("date"),
        "chat": {
            "id": chat.get("id"),
            "type": chat.get("type"),
            "title": chat.get("title"),
            "username": chat.get("username"),
            "first_name": chat.get("first_name"),
            "last_name": chat.get("last_name"),
        },
        "from": message.get("from"),
        "text": message.get("text"),
        "caption": message.get("caption"),
        "photo": best_photo,
        "document": message.get("document"),
        "audio": message.get("audio"),
        "video": message.get("video"),
        "voice": message.get("voice"),
    }


def tool_get_me(_arguments):
    return telegram_get("getMe")["result"]


def tool_get_updates(arguments):
    params = {}
    for key in ("offset", "limit", "timeout"):
        if arguments.get(key) is not None:
            params[key] = arguments[key]
    if arguments.get("allowed_updates") is not None:
        params["allowed_updates"] = json.dumps(arguments["allowed_updates"])
    payload = telegram_get("getUpdates", params=params)
    updates = payload["result"]
    return {
        "count": len(updates),
        "updates": [summarise_update(item) for item in updates],
        "next_offset": (updates[-1]["update_id"] + 1) if updates else arguments.get("offset"),
    }


def tool_download_file(arguments):
    file_id = arguments["file_id"]
    target_dir = pathlib.Path(arguments.get("target_dir") or DOWNLOAD_ROOT)
    target_dir.mkdir(parents=True, exist_ok=True)
    file_info = telegram_get("getFile", params={"file_id": file_id})["result"]
    file_path = file_info["file_path"]
    response = requests.get(bot_file_url(file_path), timeout=120)
    response.raise_for_status()
    filename = arguments.get("filename") or pathlib.Path(file_path).name
    destination = target_dir / filename
    destination.write_bytes(response.content)
    return {
        "file_id": file_id,
        "telegram_file_path": file_path,
        "saved_to": str(destination),
        "bytes": destination.stat().st_size,
    }


def tool_send_message(arguments):
    result = telegram_request("sendMessage", params={
        "chat_id": arguments["chat_id"],
        "text": arguments["text"],
    })["result"]
    return {
        "chat_id": result["chat"]["id"],
        "message_id": result["message_id"],
        "text": result.get("text"),
    }


def tool_send_photo(arguments):
    photo_path = pathlib.Path(arguments["photo_path"]).expanduser().resolve()
    with photo_path.open("rb") as photo_fh:
        result = telegram_request(
            "sendPhoto",
            params={"chat_id": arguments["chat_id"], "caption": arguments.get("caption", "")},
            files={"photo": (photo_path.name, photo_fh, "application/octet-stream")},
        )["result"]
    return {
        "chat_id": result["chat"]["id"],
        "message_id": result["message_id"],
        "caption": result.get("caption"),
    }


def tool_send_document(arguments):
    document_path = pathlib.Path(arguments["document_path"]).expanduser().resolve()
    mime_type = mimetypes.guess_type(document_path.name)[0] or "application/octet-stream"
    with document_path.open("rb") as document_fh:
        result = telegram_request(
            "sendDocument",
            params={"chat_id": arguments["chat_id"], "caption": arguments.get("caption", "")},
            files={"document": (document_path.name, document_fh, mime_type)},
        )["result"]
    return {
        "chat_id": result["chat"]["id"],
        "message_id": result["message_id"],
        "caption": result.get("caption"),
    }


def tool_auto_reply_start(arguments):
    payload = telegram_get("getUpdates", params={"limit": arguments.get("limit", 20), "timeout": arguments.get("timeout", 0)})
    updates = payload["result"]
    reply_text = arguments.get("reply_text") or "Talbot Telegram bridge is live. Send text, photos, or files here and ask Claude to poll and reply."
    replied = []
    for update in updates:
        message = update.get("message") or update.get("edited_message") or {}
        text = (message.get("text") or "").strip()
        chat = message.get("chat") or {}
        if text != "/start" or not chat.get("id"):
            continue
        sent = telegram_request("sendMessage", params={
            "chat_id": chat["id"],
            "text": reply_text,
            "reply_to_message_id": message.get("message_id"),
        })["result"]
        replied.append({
            "update_id": update.get("update_id"),
            "chat_id": chat.get("id"),
            "message_id": sent.get("message_id"),
        })
    next_offset = (updates[-1]["update_id"] + 1) if updates else arguments.get("offset")
    if updates:
        telegram_get("getUpdates", params={"offset": next_offset})
    return {
        "checked": len(updates),
        "replied": replied,
        "next_offset": next_offset,
    }


TOOLS = [
    {
        "name": "telegram_get_me",
        "description": "Return the configured Telegram bot identity and capabilities.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "telegram_get_updates",
        "description": "Poll Telegram updates for new text, photos, and files.",
        "inputSchema": {"type": "object", "properties": {"offset": {"type": "integer"}, "limit": {"type": "integer"}, "timeout": {"type": "integer"}, "allowed_updates": {"type": "array", "items": {"type": "string"}}}, "additionalProperties": False},
    },
    {
        "name": "telegram_download_file",
        "description": "Download a Telegram file locally by file_id.",
        "inputSchema": {"type": "object", "properties": {"file_id": {"type": "string"}, "target_dir": {"type": "string"}, "filename": {"type": "string"}}, "required": ["file_id"], "additionalProperties": False},
    },
    {
        "name": "telegram_send_message",
        "description": "Send a text reply to a Telegram chat.",
        "inputSchema": {"type": "object", "properties": {"chat_id": {"type": ["integer", "string"]}, "text": {"type": "string"}}, "required": ["chat_id", "text"], "additionalProperties": False},
    },
    {
        "name": "telegram_send_photo",
        "description": "Send a local image file to a Telegram chat.",
        "inputSchema": {"type": "object", "properties": {"chat_id": {"type": ["integer", "string"]}, "photo_path": {"type": "string"}, "caption": {"type": "string"}}, "required": ["chat_id", "photo_path"], "additionalProperties": False},
    },
    {
        "name": "telegram_send_document",
        "description": "Send a local file to a Telegram chat as a document.",
        "inputSchema": {"type": "object", "properties": {"chat_id": {"type": ["integer", "string"]}, "document_path": {"type": "string"}, "caption": {"type": "string"}}, "required": ["chat_id", "document_path"], "additionalProperties": False},
    },
    {
        "name": "telegram_auto_reply_start",
        "description": "Poll recent updates and automatically reply to any /start messages.",
        "inputSchema": {"type": "object", "properties": {"limit": {"type": "integer"}, "timeout": {"type": "integer"}, "reply_text": {"type": "string"}}, "additionalProperties": False},
    },
]


def tool_by_name(name):
    if name == "telegram_get_me":
        return tool_get_me
    if name == "telegram_get_updates":
        return tool_get_updates
    if name == "telegram_download_file":
        return tool_download_file
    if name == "telegram_send_message":
        return tool_send_message
    if name == "telegram_send_photo":
        return tool_send_photo
    if name == "telegram_send_document":
        return tool_send_document
    if name == "telegram_auto_reply_start":
        return tool_auto_reply_start
    raise KeyError(name)


def encode_message(payload):
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    header = f"Content-Length: {len(body)}\r\n\r\n".encode("utf-8")
    return header + body


def read_message():
    header_bytes = b""
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        header_bytes += line
        if header_bytes.endswith(b"\r\n\r\n"):
            break
    headers = header_bytes.decode("utf-8").split("\r\n")
    content_length = None
    for header in headers:
        if header.lower().startswith("content-length:"):
            content_length = int(header.split(":", 1)[1].strip())
            break
    if content_length is None:
        raise RuntimeError("Missing Content-Length header")
    body = sys.stdin.buffer.read(content_length)
    return json.loads(body.decode("utf-8"))


def write_response(payload):
    sys.stdout.buffer.write(encode_message(payload))
    sys.stdout.buffer.flush()


def result_text(data):
    return {"content": [{"type": "text", "text": json.dumps(data, indent=2, ensure_ascii=False)}]}


def handle_request(request):
    method = request.get("method")
    request_id = request.get("id")
    params = request.get("params") or {}
    if method == "initialize":
        return {"jsonrpc": "2.0", "id": request_id, "result": {"protocolVersion": PROTOCOL_VERSION, "capabilities": {"tools": {}}, "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION}}}
    if method == "notifications/initialized":
        return None
    if method == "ping":
        return {"jsonrpc": "2.0", "id": request_id, "result": {}}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": request_id, "result": {"tools": TOOLS}}
    if method == "tools/call":
        try:
            data = tool_by_name(params.get("name"))(params.get("arguments") or {})
            return {"jsonrpc": "2.0", "id": request_id, "result": result_text(data)}
        except Exception as exc:
            return {"jsonrpc": "2.0", "id": request_id, "result": {"content": [{"type": "text", "text": f"{type(exc).__name__}: {exc}"}], "isError": True}}
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": f"Method not found: {method}"}}


def run_stdio_server():
    while True:
        request = read_message()
        if request is None:
            return 0
        response = handle_request(request)
        if response is not None:
            write_response(response)


def main(argv):
    if "--self-test" in argv:
        print(json.dumps(tool_get_me({}), indent=2))
        return 0
    if "--get-updates" in argv:
        print(json.dumps(tool_get_updates({"limit": 5, "timeout": 0}), indent=2, ensure_ascii=False))
        return 0
    if "--auto-reply-start" in argv:
        print(json.dumps(tool_auto_reply_start({"limit": 20, "timeout": 0}), indent=2, ensure_ascii=False))
        return 0
    return run_stdio_server()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
