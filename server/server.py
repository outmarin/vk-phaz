#!/usr/bin/env python3
"""
TK notifier server — приложение САМО регистрирует свой VK-токен и TG-конфиг здесь
(POST /register), а сервер держит VK Long Poll и шлёт входящие в Telegram.
Так уведомления приходят даже при закрытом приложении, а токен я вручную никуда не вписываю —
его присылает апка. Токены хранятся в state.json (chmod 600), это неизбежная плата за фон.

Только стандартная библиотека Python 3.
API:
  GET  /              -> {"ok": true, "workers": N}
  POST /register      {"vk_token","tg_bot_token","tg_chat_id"}  -> запускает воркер
  POST /unregister    {"vk_token"}                              -> останавливает
"""
import json
import os
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from cryptography.fernet import Fernet

PORT = int(os.environ.get("PORT", "8787"))
BASE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(BASE, "state.enc")   # encrypted at rest
KEYFILE = os.path.join(BASE, "key")
VK_V = "5.199"


def _fernet():
    if not os.path.exists(KEYFILE):
        with open(KEYFILE, "wb") as f:
            f.write(Fernet.generate_key())
        os.chmod(KEYFILE, 0o600)
    with open(KEYFILE, "rb") as f:
        return Fernet(f.read())


FERNET = _fernet()

workers = {}   # vk_token -> threading.Event (stop flag)
lock = threading.Lock()


def http_json(url, data=None, timeout=40):
    body = urllib.parse.urlencode(data).encode() if data else None
    with urllib.request.urlopen(urllib.request.Request(url, data=body), timeout=timeout) as r:
        return json.load(r)


def vk(method, token, **params):
    params.update(access_token=token, v=VK_V)
    return http_json("https://api.vk.com/method/" + method, params)


def tg_send(bot, chat, text):
    try:
        http_json("https://api.telegram.org/bot%s/sendMessage" % bot,
                  {"chat_id": chat, "text": text})
    except Exception as e:
        print("tg error:", e)


def name_for(token, peer, cache):
    if peer in cache:
        return cache[peer]
    title = "id%s" % peer
    try:
        if peer >= 2000000000:
            r = vk("messages.getConversationsById", token, peer_ids=peer)
            items = r.get("response", {}).get("items", [])
            if items:
                title = items[0].get("chat_settings", {}).get("title", title)
        elif peer < 0:
            g = vk("groups.getById", token, group_id=-peer).get("response", [])
            if g:
                title = g[0].get("name", title)
        else:
            u = vk("users.get", token, user_ids=peer).get("response", [])
            if u:
                title = "%s %s" % (u[0].get("first_name", ""), u[0].get("last_name", ""))
    except Exception as e:
        print("name error:", e)
    cache[peer] = title
    return title


def worker(token, cfg, stop):
    cache = {}
    print("worker start", token[:6])
    while not stop.is_set():
        try:
            s = vk("messages.getLongPollServer", token, lp_version=3, need_pts=0)["response"]
            server, key, ts = s["server"], s["key"], s["ts"]
            while not stop.is_set():
                q = urllib.parse.urlencode(dict(act="a_check", key=key, ts=ts, wait=25, mode=2, version=3))
                data = http_json("https://%s?%s" % (server, q))
                if "failed" in data:
                    break
                ts = data.get("ts", ts)
                for u in data.get("updates", []):
                    if not u or u[0] != 4:
                        continue
                    flags = u[2] if len(u) > 2 else 0
                    peer = u[3] if len(u) > 3 else 0
                    text = u[5] if len(u) > 5 else ""
                    if flags & 2:
                        continue
                    tg_send(cfg["tg_bot"], cfg["tg_chat"],
                            "%s: %s" % (name_for(token, peer, cache), text or "Вложение"))
        except Exception as e:
            print("worker error:", e)
            time.sleep(5)
    print("worker stop", token[:6])


def load_state():
    try:
        with open(STATE, "rb") as f:
            return json.loads(FERNET.decrypt(f.read()))
    except Exception:
        return {}


def save_state(state):
    with open(STATE, "wb") as f:
        f.write(FERNET.encrypt(json.dumps(state).encode()))
    try:
        os.chmod(STATE, 0o600)
    except Exception:
        pass


def start_worker(token, cfg):
    old = workers.get(token)
    if old:
        old.set()
    stop = threading.Event()
    workers[token] = stop
    threading.Thread(target=worker, args=(token, cfg, stop), daemon=True).start()


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path == "/":
            self._send(200, {"ok": True, "workers": len(workers)})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            return self._send(400, {"error": "bad json"})
        if self.path == "/register":
            token = body.get("vk_token")
            cfg = {"tg_bot": body.get("tg_bot_token"), "tg_chat": body.get("tg_chat_id")}
            if not (token and cfg["tg_bot"] and cfg["tg_chat"]):
                return self._send(400, {"error": "missing fields"})
            with lock:
                state = load_state()
                state[token] = cfg
                save_state(state)
                start_worker(token, cfg)
            return self._send(200, {"ok": True})
        if self.path == "/unregister":
            token = body.get("vk_token")
            with lock:
                state = load_state()
                state.pop(token, None)
                save_state(state)
                if token in workers:
                    workers[token].set()
                    workers.pop(token, None)
            return self._send(200, {"ok": True})
        self._send(404, {"error": "not found"})


def main():
    for token, cfg in load_state().items():
        start_worker(token, cfg)
    print("TK notifier server on :%d, resumed %d workers" % (PORT, len(workers)))
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()


if __name__ == "__main__":
    main()
