#!/usr/bin/env python3
"""
TK notifier — держит VK Long Poll и шлёт новые входящие сообщения в Telegram-бот.
Работает НЕЗАВИСИМО от телефона: пока крутится этот процесс, уведомления приходят,
даже когда приложение TK закрыто.

Запуск:
    VK_TOKEN=xxx TG_BOT_TOKEN=yyy TG_CHAT_ID=123456 python3 notify.py

Только стандартная библиотека Python 3 — никаких зависимостей.
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request

VK_TOKEN = os.environ.get("VK_TOKEN", "")
TG_BOT_TOKEN = os.environ.get("TG_BOT_TOKEN", "")
TG_CHAT_ID = os.environ.get("TG_CHAT_ID", "")
VK_V = "5.199"

if not (VK_TOKEN and TG_BOT_TOKEN and TG_CHAT_ID):
    sys.exit("Задай переменные окружения VK_TOKEN, TG_BOT_TOKEN, TG_CHAT_ID")

names = {}  # peer_id -> отображаемое имя (кэш)


def http_json(url, data=None):
    body = urllib.parse.urlencode(data).encode() if data else None
    with urllib.request.urlopen(urllib.request.Request(url, data=body), timeout=40) as r:
        return json.load(r)


def vk(method, **params):
    params.update(access_token=VK_TOKEN, v=VK_V)
    return http_json("https://api.vk.com/method/" + method, params)


def tg_send(text):
    url = "https://api.telegram.org/bot%s/sendMessage" % TG_BOT_TOKEN
    try:
        http_json(url, {"chat_id": TG_CHAT_ID, "text": text})
    except Exception as e:
        print("telegram error:", e)


def name_for(peer_id):
    if peer_id in names:
        return names[peer_id]
    title = "id%s" % peer_id
    try:
        if peer_id >= 2000000000:  # беседа
            r = vk("messages.getConversationsById", peer_ids=peer_id)
            items = r.get("response", {}).get("items", [])
            if items:
                title = items[0].get("chat_settings", {}).get("title", title)
        elif peer_id < 0:          # сообщество
            r = vk("groups.getById", group_id=-peer_id)
            g = r.get("response", [])
            if g:
                title = g[0].get("name", title)
        else:                      # пользователь
            r = vk("users.get", user_ids=peer_id)
            u = r.get("response", [])
            if u:
                title = "%s %s" % (u[0].get("first_name", ""), u[0].get("last_name", ""))
    except Exception as e:
        print("name error:", e)
    names[peer_id] = title
    return title


def main():
    print("TK notifier запущен. VK Long Poll → Telegram.")
    while True:
        try:
            r = vk("messages.getLongPollServer", lp_version=3, need_pts=0)
            s = r["response"]
            server, key, ts = s["server"], s["key"], s["ts"]
            while True:
                q = urllib.parse.urlencode(
                    dict(act="a_check", key=key, ts=ts, wait=25, mode=2, version=3))
                url = "https://%s?%s" % (server, q)
                data = http_json(url)
                if "failed" in data:
                    break  # переполучить сервер
                ts = data.get("ts", ts)
                for u in data.get("updates", []):
                    if not u or u[0] != 4:
                        continue
                    flags = u[2] if len(u) > 2 else 0
                    peer = u[3] if len(u) > 3 else 0
                    text = u[5] if len(u) > 5 else ""
                    if flags & 2:      # исходящее — пропускаем
                        continue
                    tg_send("%s: %s" % (name_for(peer), text or "Вложение"))
        except Exception as e:
            print("loop error:", e)
            time.sleep(5)


if __name__ == "__main__":
    main()
