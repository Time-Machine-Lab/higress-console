# Deployment (Time-Machine-Lab fork)

This fork adds static Bearer API tokens to the console and deploys it onto our single Higress all-in-one host.

## Console API token

`higress-console.admin.api-tokens` (env `HIGRESS_CONSOLE_ADMIN_API_TOKENS`) accepts a comma-separated list of
plaintext tokens or `sha256:<hex>` digests. Requests with `Authorization: Bearer <token>` are authenticated as the
admin user. Failures are rate limited per client IP (same limits as form/basic login). Empty = disabled.

On the server the plaintext token is `/opt/higress/secrets/console-api-token`; the container only gets its digest
through `/opt/higress/console.env`.

## Layout on the server (`/opt/higress`)

| Path | Purpose |
|---|---|
| `data/` | Higress all-in-one data volume |
| `releases/<version>/` | Uploaded jar + Dockerfile + deploy.sh (last 3 kept) |
| `console.env` | Env file for the container (token digest) |
| `ports.env` | Loopback host ports (`CONSOLE_PORT`, `GATEWAY_PORT`, `GATEWAY_TLS_PORT`; default 8001/8080/8443) |
| `secrets/` | console API token, `ops-admin` / `claude-ops` consumer keys |
| `redis.pass` | Password of the `higress-redis` container used by Higress MCP |
| `setup/` | Copy of this directory used for one-time setup |

## Flow

1. `setup-server.sh` (one time, idempotent): pins the running all-in-one image as `higress-aio-base:pinned`,
   generates the console token, installs nginx + certbot and issues the certificate for `$DOMAIN`.
   nginx terminates HTTPS and proxies to the gateway on `127.0.0.1:$GATEWAY_PORT`; certbot renews via `certbot.timer`
   and reloads nginx through a deploy hook.
2. Push to `main` → `.github/workflows/deploy.yaml` builds the jar, uploads it with `deploy.sh`, which builds
   `higress-aio-tml:<version>`, swaps the container, checks console readiness + token auth + gateway, and rolls back
   on failure. Manual rollback: `bash /opt/higress/releases/<older-version>/deploy.sh <older-version>`.
3. `mcp/setup_higress_admin.py` registers the console itself as the `higress-admin` MCP server
   (`https://<domain>/mcp-servers/higress-admin`, consumer `ops-admin`). Re-run after editing
   `mcp/higress-admin-openapi.yaml`:
   `python3 setup_higress_admin.py higress-admin-openapi.yaml` on the server.

Required repository secrets: `DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_SSH_KEY`, `DEPLOY_KNOWN_HOSTS`.
To move to a newer Higress all-in-one, pull it on the server and re-tag it as `higress-aio-base:pinned`, then redeploy.
