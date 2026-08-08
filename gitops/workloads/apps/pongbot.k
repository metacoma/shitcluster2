import k8s.api.core.v1 as k8s
import k8s.api.apps.v1 as apps
import config as cfg

_config = cfg.config
_pb = _config.pongbot

# pongbot.py — Mattermost mention responder ("pong" on @mention).
# Runs in the container; BOT_TOKEN comes from the pongbot-token Secret
# (resolved by vals from Vault at render time).
_script = """#!/usr/bin/env python3
import json
import os
import sys
import time
import urllib.request
import websocket

MM_URL = os.environ.get("MM_URL", "https://mattermost.mansion.metacoma.org")
MM_WS = MM_URL.replace("https://", "wss://").replace("http://", "ws://") + "/api/v4/websocket"
BOT_TOKEN = os.environ.get("BOT_TOKEN", "")
BOT_USERNAME = os.environ.get("BOT_USERNAME", "pongbot")
BOT_ID = os.environ.get("BOT_ID", "")

def api(method, path, body=None, token=BOT_TOKEN):
    req = urllib.request.Request(MM_URL + path, method=method)
    req.add_header("Authorization", "Bearer " + token)
    if body is not None:
        req.add_header("Content-Type", "application/json")
        req.data = json.dumps(body).encode()
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        print("[api] {} {} -> {}: {}".format(method, path, e.code, e.read().decode()[:300]), flush=True)
        return None

def get_me():
    return api("GET", "/api/v4/users/me")

def post_message(channel_id, message, root_id=None):
    body = {"channel_id": channel_id, "message": message}
    if root_id:
        body["root_id"] = root_id
    return api("POST", "/api/v4/posts", body)

def on_message(ws, raw):
    try:
        evt = json.loads(raw)
    except Exception:
        return
    if evt.get("event") != "posted":
        return
    data = evt.get("data", {})
    broadcast = evt.get("broadcast", {})
    channel_id = broadcast.get("channel_id") or data.get("channel_id")
    if not channel_id:
        return
    post_str = data.get("post")
    if not post_str:
        return
    post = json.loads(post_str) if isinstance(post_str, str) else post_str
    if post.get("user_id") == BOT_ID:
        return
    msg = (post.get("message") or "").lower()
    mentioned = ("@" + BOT_USERNAME.lower()) in msg
    mentions = data.get("mentions") or []
    if isinstance(mentions, str):
        mentions = mentions.split(",")
    if isinstance(mentions, list) and BOT_ID in mentions:
        mentioned = True
    if mentioned:
        print("[mention] channel={} msg={!r}".format(channel_id, post.get("message")[:60]), flush=True)
        res = post_message(channel_id, "pong", root_id=post.get("root_id") or post.get("id"))
        print("[reply] -> {}".format("ok" if res else "FAILED"), flush=True)

def on_error(ws, error):
    print("[ws error] {!r}".format(error), flush=True)

def on_close(ws, code, msg):
    print("[ws closed] code={} msg={} — reconnecting in 5s".format(code, msg), flush=True)
    time.sleep(5)

def main():
    global BOT_ID
    me = get_me()
    if not me:
        print("ERROR: cannot authenticate, check BOT_TOKEN", flush=True)
        sys.exit(1)
    BOT_ID = me["id"]
    print("Connected as {} ({})".format(me["username"], BOT_ID), flush=True)

    while True:
        ws = websocket.WebSocketApp(
            MM_WS,
            header=["Authorization: Bearer " + BOT_TOKEN],
            on_message=on_message,
            on_error=on_error,
            on_close=on_close,
        )
        try:
            ws.run_forever(ping_interval=30, ping_timeout=10)
        except Exception as e:
            print("[run_forever error] {!r}".format(e), flush=True)
        print("disconnected, reconnecting in 5s", flush=True)
        time.sleep(5)

if __name__ == "__main__":
    main()
"""

manifests = [
    # ------------------------------------------------------------------
    # ConfigMap: pongbot.py script
    # ------------------------------------------------------------------
    k8s.ConfigMap {
        metadata = {
            name = _pb.name + "-script"
            namespace = _pb.namespace
        }
        data = {
            "pongbot.py": _script
        }
    },

    # ------------------------------------------------------------------
    # Secret: bot token (vals resolves ref+vault:// at render time)
    # ------------------------------------------------------------------
    k8s.Secret {
        metadata = {
            name = _pb.name + "-token"
            namespace = _pb.namespace
        }
        type = "Opaque"
        stringData = {
            token = _pb.token
        }
    },

    # ------------------------------------------------------------------
    # Deployment: runs pongbot.py against Mattermost
    # ------------------------------------------------------------------
    apps.Deployment {
        metadata = {
            name = _pb.name
            namespace = _pb.namespace
            labels = {
                app = _pb.name
            }
        }
        spec = {
            replicas = 1
            selector = {
                matchLabels = {
                    app = _pb.name
                }
            }
            template = {
                metadata = {
                    labels = {
                        app = _pb.name
                    }
                }
                spec = {
                    containers = [{
                        name = _pb.name
                        image = _pb.image
                        command = ["/bin/sh", "-c"]
                        args = ["pip install --no-cache-dir -q websocket-client requests && python /bot/pongbot.py"]
                        env = [
                            {
                                name = "MM_URL"
                                value = _pb.mm_url
                            }
                            {
                                name = "BOT_USERNAME"
                                value = _pb.username
                            }
                            {
                                name = "BOT_TOKEN"
                                valueFrom = {
                                    secretKeyRef = {
                                        name = _pb.name + "-token"
                                        key = "token"
                                    }
                                }
                            }
                        ]
                        volumeMounts = [{
                            name = "script"
                            mountPath = "/bot"
                            readOnly = True
                        }]
                        resources = _pb.resources
                    }]
                    volumes = [{
                        name = "script"
                        configMap = {
                            name = _pb.name + "-script"
                            defaultMode = 292  # 0444
                        }
                    }]
                    nodeSelector = _config.nodeSelector.worker
                }
            }
        }
    },
]
