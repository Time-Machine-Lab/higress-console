#!/usr/bin/env python3
"""Run on the Higress host: registers the console itself as the `higress-admin` MCP server.

Uses the console Bearer API token (/opt/higress/secrets/console-api-token), creates the
`ops-admin` consumer (key kept in /opt/higress/secrets/ops-admin.key) and allows only it.
Idempotent: re-running updates the MCP server and keeps the existing consumer/key.
"""
import json
import os
import secrets
import subprocess
import sys

import yaml

def _console_port():
    try:
        for line in open("/opt/higress/ports.env"):
            if line.startswith("CONSOLE_PORT="):
                return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return "8001"


CONSOLE = f"http://127.0.0.1:{_console_port()}"
SECRETS = "/opt/higress/secrets"
SPEC = sys.argv[1] if len(sys.argv) > 1 else "/tmp/higress-admin-openapi.yaml"
MCP_NAME = "higress-admin"
CONSUMER = "ops-admin"

token = open(f"{SECRETS}/console-api-token").read().strip()


def api(method, path, body=None):
    cmd = ["curl", "-s", "-X", method, CONSOLE + path,
           "-H", f"Authorization: Bearer {token}", "-H", "Content-Type: application/json"]
    if body is not None:
        cmd += ["--data-binary", json.dumps(body, ensure_ascii=False)]
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    return json.loads(out) if out.strip() else {}


def redact(text):
    return text.replace(token, "***")


# consumer
key_file = f"{SECRETS}/{CONSUMER}.key"
existing = {c["name"] for c in api("GET", "/v1/consumers").get("data", [])}
if CONSUMER not in existing:
    old_umask = os.umask(0o077)
    key = secrets.token_hex(24)
    with open(key_file, "w") as f:
        f.write(key + "\n")
    os.umask(old_umask)
    r = api("POST", "/v1/consumers", {"name": CONSUMER, "credentials": [
        {"type": "key-auth", "source": "BEARER", "values": [key]}]})
    print("consumer created:", r.get("success", r.get("name") == CONSUMER))
else:
    print("consumer exists")

# convert + patch
conv = api("POST", "/v1/mcpServer/swaggerToMcpConfig", {"content": open(SPEC, encoding="utf-8").read()})
cfg = yaml.safe_load(conv["data"])
cfg["server"]["name"] = MCP_NAME
cfg["server"]["securitySchemes"] = [{
    "id": "ConsoleToken", "type": "apiKey", "in": "header", "name": "Authorization",
    "defaultCredential": f"Bearer {token}"}]
for tool in cfg["tools"]:
    tool["requestTemplate"]["security"] = {"id": "ConsoleToken"}
    tool.pop("responseTemplate", None)
    tool.pop("security", None)

server = {
    "name": MCP_NAME,
    "description": "Higress 控制台管理（接入新产品用，仅查询/新建/更新）",
    "type": "OPEN_API",
    "domains": [],
    "services": [{"name": "higress-console.static", "port": 80, "weight": 100}],
    "consumerAuthInfo": {"type": "key-auth", "enable": True, "allowedConsumers": [CONSUMER]},
    "rawConfigurations": yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False),
}
r = api("PUT", "/v1/mcpServer", server)
print("mcp server:", r.get("name"), "tools:", len(cfg["tools"]),
      "auth:", json.dumps(r.get("consumerAuthInfo")))
print(redact(json.dumps([t["name"] for t in cfg["tools"]])))
