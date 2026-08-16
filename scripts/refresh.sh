#!/usr/bin/env bash
# =============================================================================
# refresh.sh — rebuild + redeploy the Decepticon stack from THIS checkout
# =============================================================================
# Layout: code lives in this repo; runtime state (.env, workspace/, volumes)
#         lives in the compose home ($HOME/.decepticon). See CLAUDE.md
#         § "Running it on this box" for the fork / compose-home split.
#
# Usage:
#   ./refresh.sh            pull fork + rebuild changed images + restart stack
#   ./refresh.sh --pull     (default) git pull first
#   ./refresh.sh --no-pull  skip git pull (build local uncommitted changes)
#   ./refresh.sh --force    rebuild everything from scratch (no cache)
#
# What it does NOT touch: ~/.decepticon/.env, workspace/, telemetry/, postgres
# and neo4j volumes — those live outside the images and survive a refresh.
#
# If containers were started with the GHCR :stable images (pre-fork install),
# the first run repoints them to the locally built :stable tags; run it twice
# if `docker compose up` reports an image mismatch on the first try.
# =============================================================================
set -euo pipefail

# Repo root derived from this script's real location (move-proof).
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
HOME_DIR="$HOME/.decepticon"
PULL=1
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --no-pull) PULL=0 ;;
    --force)   FORCE=1 ;;
    --pull)    PULL=1 ;;
    *) echo "unknown flag: $arg (use --pull | --no-pull | --force)"; exit 2 ;;
  esac
done

cd "$REPO"
BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "[1/5] repo: $REPO (branch $BRANCH, $(git rev-parse --short HEAD))"

if [ "$PULL" = 1 ]; then
  echo "[2/5] pulling origin/$BRANCH ..."
  git pull --ff-only
else
  echo "[2/5] skipping pull (--no-pull)"
fi

echo "[3/5] building images from local code ..."
if [ "$FORCE" = 1 ]; then
  docker compose --profile cli build --no-cache
else
  docker compose --profile cli build
fi

echo "[4/5] restarting stack from $HOME_DIR ..."
cd "$HOME_DIR"
docker compose --profile cli up -d --no-build --wait --wait-timeout 600

echo "[5/5] status:"
docker compose --profile cli ps --format 'table {{.Name}}\t{{.Status}}'

echo ""
echo "done. quick health check:"
echo "  curl -sS http://127.0.0.1:4000/v1/chat/completions \\"
echo "    -H 'Authorization: Bearer sk-decepticon-master' \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"custom/glm-5.3\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":200}'"
