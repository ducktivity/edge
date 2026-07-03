#!/usr/bin/env bash
# Runs on YOUR machine (WSL), NOT the box. One command to (re)deploy the shared edge stack: copies docker-compose.yml, the vector/ config dir, and your local .env.prod (landed on the box as .env, which compose auto-loads) to the box over Cloudflare Access SSH, then pulls + brings the stack up — the box-side steps are streamed inline over SSH, so there is no second script to maintain. No secrets live in git or GitHub; your secrets stay in edge/.env.prod on your disk only.
#
# Unlike an app deploy there is no image tag / rollback: cloudflared tracks latest and vector is pinned in the compose file. Bringing this stack up also creates the shared `ducktivity_edge` network the app stacks attach to, so deploy it before any app.
#
# Prereqs on your machine: cloudflared installed + the Cloudflare Access service token sourced (TUNNEL_SERVICE_TOKEN_ID / TUNNEL_SERVICE_TOKEN_SECRET), and a filled edge/.env.prod (copy from .env.example).
#
# Usage:  ./deploy/remote-deploy.sh
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root (edge/)

# Overridable config (sane suite defaults).
SSH_HOST="${SSH_HOST:-ducktivity-ssh.ducktvt.com}"
SSH_USER="${SSH_USER:-deploy}"
APP_DIR="${APP_DIR:-/opt/ducktivity/edge}"
SECRETS="${SECRETS:-.env.prod}"   # local, git-ignored

[ -f "$SECRETS" ] || { echo "error: $SECRETS not found — copy .env.example to .env.prod and fill it." >&2; exit 1; }

# SSH rides Cloudflare Access (no open port on the box). ProxyCommand needs cloudflared + a sourced service token; see the prereqs above.
SSH_OPTS=(-o "ProxyCommand=cloudflared access ssh --hostname %h" -o StrictHostKeyChecking=accept-new)
DEST="$SSH_USER@$SSH_HOST"

echo "==> staging runtime files on $DEST:$APP_DIR"
ssh "${SSH_OPTS[@]}" "$DEST" "mkdir -p '$APP_DIR'"
scp "${SSH_OPTS[@]}" docker-compose.yml "$DEST:$APP_DIR/docker-compose.yml"
scp "${SSH_OPTS[@]}" -r vector          "$DEST:$APP_DIR/vector"
scp "${SSH_OPTS[@]}" "$SECRETS"         "$DEST:$APP_DIR/.env"

echo "==> bringing the edge stack up"
# Runs ON THE BOX: pull the shared images and (re)create only what changed. Vector hot-reloads its mounted config, so a vector.yaml-only change needs no restart, but `up -d` is harmless and keeps this one command sufficient. APP_DIR is passed as a positional arg; the quoted heredoc keeps the body literal so nothing expands locally.
ssh "${SSH_OPTS[@]}" "$DEST" "bash -s -- '$APP_DIR'" <<'REMOTE'
set -euo pipefail
cd "$1"
chmod 600 .env
docker compose pull
docker compose up -d --remove-orphans
docker image prune -f
echo "edge stack status:"
docker compose ps
REMOTE
