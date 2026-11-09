#!/usr/bin/env bash
# Server-side release script. CI uploads the console jar plus this directory to
# /opt/higress/releases/<version>/ and runs: bash deploy.sh <version>
#
# It builds an image on top of the pinned all-in-one base, swaps the running container,
# waits for the console (including Bearer token auth) and the gateway to become ready,
# and rolls back to the previous container if anything fails.
set -euo pipefail

VERSION="${1:?usage: deploy.sh <version>}"
ROOT=/opt/higress
RELEASE_DIR="$ROOT/releases/$VERSION"
BASE_IMAGE="${BASE_IMAGE:-higress-aio-base:pinned}"
IMAGE="higress-aio-tml:$VERSION"
NAME=higress-ai
PREV="$NAME-prev"
ENV_FILE="$ROOT/console.env"
TOKEN_FILE="$ROOT/secrets/console-api-token"
KEEP_RELEASES=3

# Host-side ports (loopback only). Override in $ROOT/ports.env on hosts where the defaults are taken.
CONSOLE_PORT=8001
GATEWAY_PORT=8080
GATEWAY_TLS_PORT=8443
# shellcheck disable=SC1091
[ -f "$ROOT/ports.env" ] && . "$ROOT/ports.env"

log() { echo "[deploy $(date -u +%H:%M:%S)] $*"; }

for f in "$RELEASE_DIR/higress-console.jar" "$RELEASE_DIR/Dockerfile" "$ENV_FILE" "$TOKEN_FILE" "$ROOT/redis.pass"; do
  [ -f "$f" ] || { log "missing $f (run setup-server.sh first)"; exit 1; }
done
docker image inspect "$BASE_IMAGE" >/dev/null 2>&1 || { log "base image $BASE_IMAGE not found"; exit 1; }

log "building $IMAGE"
docker build -q --build-arg BASE_IMAGE="$BASE_IMAGE" -t "$IMAGE" "$RELEASE_DIR" >/dev/null

run_higress() {
  docker run -d --name "$NAME" --restart unless-stopped \
    --env-file "$ENV_FILE" \
    -v "$ROOT/data:/data" \
    -p "127.0.0.1:$CONSOLE_PORT:8001" -p "127.0.0.1:$GATEWAY_PORT:8080" -p "127.0.0.1:$GATEWAY_TLS_PORT:8443" \
    "$1" >/dev/null
}

# Redis shares the Higress container's network namespace (Higress MCP expects it on 127.0.0.1:6379),
# so it has to be recreated whenever the Higress container is replaced.
run_redis() {
  docker rm -f higress-redis >/dev/null 2>&1 || true
  docker run -d --name higress-redis --restart unless-stopped --network "container:$NAME" \
    redis:7-alpine redis-server --bind 127.0.0.1 --port 6379 --requirepass "$(cat "$ROOT/redis.pass")" \
    --maxmemory 64mb --maxmemory-policy allkeys-lru --save "" >/dev/null
}

wait_ready() {
  local token
  token="$(cat "$TOKEN_FILE")"
  for _ in $(seq 1 72); do
    if curl -fsS -o /dev/null "http://127.0.0.1:$CONSOLE_PORT/healthz/ready" \
      && curl -fsS -H "Authorization: Bearer $token" "http://127.0.0.1:$CONSOLE_PORT/v1/mcpServer" | grep -q '"success":true' \
      && curl -s -o /dev/null "http://127.0.0.1:$GATEWAY_PORT/"; then
      return 0
    fi
    sleep 5
  done
  return 1
}

docker rm -f "$PREV" >/dev/null 2>&1 || true
if docker inspect "$NAME" >/dev/null 2>&1; then
  log "stopping current container"
  docker stop "$NAME" >/dev/null
  docker rename "$NAME" "$PREV"
fi

log "starting $IMAGE"
run_higress "$IMAGE"
run_redis

if wait_ready; then
  log "release $VERSION is healthy"
  docker rm -f "$PREV" >/dev/null 2>&1 || true
else
  log "release $VERSION failed health checks; rolling back"
  docker logs --tail 80 "$NAME" 2>&1 | grep -iE "error|exception" | tail -20 || true
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  if docker inspect "$PREV" >/dev/null 2>&1; then
    docker rename "$PREV" "$NAME"
    docker start "$NAME" >/dev/null
    run_redis
    log "previous container restored"
  fi
  exit 1
fi

# Keep the newest releases (dirs + images) for manual rollback: bash deploy.sh <older-version>
ls -1dt "$ROOT"/releases/*/ 2>/dev/null | tail -n +$((KEEP_RELEASES + 1)) | while read -r dir; do
  v="$(basename "$dir")"
  docker rmi "higress-aio-tml:$v" >/dev/null 2>&1 || true
  rm -rf "$dir"
done
docker image prune -f >/dev/null 2>&1 || true
log "done"
