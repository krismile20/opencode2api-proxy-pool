#!/bin/sh
# Runtime entrypoint: generate configs from environment variables, then exec supervisord.
# Secrets are only read here and written to /run/app (ephemeral tmpfs-like path).
# They are never echoed to stdout/stderr and never baked into the image.
set -eu

APP_DIR=/run/app
mkdir -p "$APP_DIR"

export OC2A_LISTEN="${OC2A_LISTEN:-127.0.0.1:8080}"
export EP_POOL_ADDR="${EP_POOL_ADDR:-127.0.0.1:2323}"
export EP_MGMT_ADDR="${EP_MGMT_ADDR:-127.0.0.1:9091}"
export OC2A_WEB_LISTEN="${OC2A_WEB_LISTEN:-127.0.0.1:8081}"
export PREFER="${PREFER:-go}"
export SUB_REFRESH_INTERVAL="${SUB_REFRESH_INTERVAL:-30m}"

python3 <<'PYEOF'
import json
import os
import pathlib
import secrets

app = pathlib.Path("/run/app")
env = os.environ


def split_csv(value):
    return [item.strip() for item in (value or "").split(",") if item.strip()]


server_keys = split_csv(env.get("SERVER_KEYS"))
subscriptions = split_csv(env.get("PROXY_SUBSCRIPTIONS"))
mgmt_password = env.get("MGMT_PASSWORD") or secrets.token_urlsafe(18)
webui_username = env.get("OC2A_WEBUI_USERNAME") or "admin"
webui_password = env.get("OC2A_WEBUI_PASSWORD") or secrets.token_urlsafe(18)
pool_user = "pool"
pool_pass = env.get("POOL_PASS") or secrets.token_urlsafe(12)

proxy_host, _, proxy_port = env.get("EP_POOL_ADDR", "127.0.0.1:2323").rpartition(":")
oc2a_config = {
    "listen": env.get("OC2A_LISTEN", "127.0.0.1:8080"),
    "server_keys": server_keys,
    "zen_keys": [],
    "go_keys": [],
    "anonymous": True,
    "prefer": env.get("PREFER", "go"),
    "proxies": ["http://%s:%s@%s:%s" % (pool_user, pool_pass, proxy_host, proxy_port)],
    "upstream": {
        "zen": "https://opencode.ai/zen",
        "go": "https://opencode.ai/zen/go",
    },
    "retry": {"max_attempts": 3, "timeout_seconds": 300},
    "models": {"refresh_seconds": 300, "protocols": {}},
    "performance": {
        "max_idle_conns": 2048,
        "max_idle_conns_per_host": 256,
        "max_conns_per_host": 0,
        "idle_conn_timeout_seconds": 120,
        "connect_timeout_seconds": 5,
        "failure_cooldown_seconds": 15,
    },
    "logging": {"level": "info", "ring_size": 2000},
    "webui": {
        "enabled": True,
        "listen": env.get("OC2A_WEB_LISTEN", "127.0.0.1:8081"),
        "username": webui_username,
        "password": webui_password,
        "session_ttl_minutes": 720,
    },
}
(app / "config.json").write_text(json.dumps(oc2a_config, indent=2))


def yq(text):
    return json.dumps(text)


lines = [
    "# Generated at container start by start.sh - do not edit",
    "mode: pool",
    "log_level: %s" % yq(env.get("LOG_LEVEL", "info")),
    "log:",
    "  output: stdout",
    "",
    "listener:",
    "  address: %s" % yq(proxy_host),
    "  port: %s" % proxy_port,
    "  username: %s" % yq(pool_user),
    "  password: %s" % yq(pool_pass),
    "",
    "pool:",
    "  mode: random",
    "  failure_threshold: 3",
    "  blacklist_duration: 1h",
    "  retry_enabled: true",
    "  retry_attempts: 3",
    "",
    "sticky:",
    "  enabled: false",
    "",
    "management:",
    "  enabled: true",
    "  listen: %s" % yq(env.get("EP_MGMT_ADDR", "127.0.0.1:9091")),
    "  probe_target: http://cp.cloudflare.com/generate_204",
    "  password: %s" % yq(mgmt_password),
    "",
    "dns:",
    "  server: 1.1.1.1",
    "  fallback_servers:",
    "    - 8.8.8.8",
    "  port: 53",
    "  strategy: prefer_ipv4",
    "",
    "geoip:",
    "  enabled: false",
    "",
    "subscription_refresh:",
    "  enabled: true",
    "  interval: %s" % yq(env.get("SUB_REFRESH_INTERVAL", "30m")),
]

if subscriptions:
    lines += ["", "subscriptions:"]
    lines += ["  - %s" % yq(url) for url in subscriptions]
else:
    lines += [
        "",
        "subscriptions: []",
        "nodes:",
        "  - uri: %s" % yq(
            "http://127.0.0.1:9#placeholder-add-your-subscription-in-the-webui-at-/pool/"
        ),
    ]

lines.append("")
(app / "easy_proxies.yaml").write_text("\n".join(lines))
PYEOF

unset SERVER_KEYS PROXY_SUBSCRIPTIONS MGMT_PASSWORD OC2A_WEBUI_PASSWORD POOL_PASS || true

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
