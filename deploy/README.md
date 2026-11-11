# Deployment (Time-Machine-Lab fork)

This fork adds static Bearer API tokens to the console and runs it inside the Higress all-in-one image on our K3s cluster.

## Console API token

`higress-console.admin.api-tokens` (env `HIGRESS_CONSOLE_ADMIN_API_TOKENS`) accepts a comma-separated list of
plaintext tokens or `sha256:<hex>` digests. Requests with `Authorization: Bearer <token>` are authenticated as the
admin user. Failures are rate limited per client IP (same limits as form/basic login). Empty = disabled.

On the server the plaintext token is `/opt/higress/secrets/console-api-token`; the container only gets its digest
through `/opt/higress/console.env`.

## Where it runs

Since 2026-11-11 Higress runs on the K3s cluster (`k3s.seasonschange.cn`), namespace `higress`.
The manifest is `k3s/higress.yaml`: one pod with the all-in-one container plus a Redis sidecar
(Higress MCP expects Redis on `127.0.0.1:6379`).

| Object | Purpose |
|---|---|
| PVC `higress-data` | `/data` of the all-in-one: routes, plugins, MCP servers, consumers (node `agent-1`) |
| Secret `higress-console-env` | `HIGRESS_CONSOLE_ADMIN_API_TOKENS` (sha256 digest of the console API token) |
| Secret `higress-redis` | Redis password (also referenced by the MCP redis config inside `/data`) |
| Service `higress` | `8080` gateway, `8001` console (cluster-internal only) |
| Ingress `mcp` | `mcp.tmlab.top` → gateway |

The plaintext console token and the `ops-admin` / `claude-ops` consumer keys are still kept in
`/opt/higress/secrets/` on 207.57.124.102. To reach the console: `kubectl -n higress port-forward svc/higress 8001`.

## Flow

1. Push to `main` → `.github/workflows/deploy.yaml` builds the jar, builds `Dockerfile` (the jar on top of the
   all-in-one base pinned by digest) and pushes `docker.io/<DOCKER_USERNAME>/higress-console:<version>`.
2. The deploy job pre-pulls the image on the node with a throw-away pod (the Deployment is `Recreate`, so the old
   pod is only stopped once the new image is known to be pullable), applies `k3s/higress.yaml` with the new image,
   waits for the console readiness probe, and runs `kubectl rollout undo` if it fails. It then checks that
   `https://mcp.tmlab.top/mcp-servers/higress-admin` rejects an unauthenticated call with 401.
   Manual rollback: `kubectl -n higress rollout undo deployment/higress`.
3. `mcp/setup_higress_admin.py` registers the console itself as the `higress-admin` MCP server
   (`https://<domain>/mcp-servers/higress-admin`, consumer `ops-admin`). Re-run after editing
   `mcp/higress-admin-openapi.yaml`.

Required secrets: repository secret `KUBE_CONFIG` (kubeconfig of the namespace-scoped ServiceAccount
`higress/ci-deployer`) and the organization secrets `DOCKER_USERNAME` / `DOCKER_PASSWORD`.
To move to a newer Higress all-in-one, update the digest in `Dockerfile` and push.

`deploy.sh`, `setup-server.sh` and `nginx/` describe the previous single-host Docker setup and are kept for reference.
