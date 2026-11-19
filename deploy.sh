#!/usr/bin/env bash
# Deploy the fork (origin/master by default) to monitor.alephhouse.com.
# Usage: ./deploy.sh [git-ref]      (default: master)
# Env:   DEPLOY_HOST (default ubuntu@aleph-14)
set -euo pipefail

HOST="${DEPLOY_HOST:-ubuntu@aleph-14}"
REF="${1:-master}"
FORK_URL="$(git remote get-url origin)"

# Refuse to deploy commits the server can't fetch.
git fetch -q origin
SHA="$(git rev-parse "origin/${REF}" 2>/dev/null || git rev-parse "${REF}")"
if ! git branch -r --contains "$SHA" | grep -q origin/; then
    echo "Commit $SHA is not pushed to origin. Push first." >&2
    exit 1
fi
echo "Deploying $SHA to $HOST"

ssh "$HOST" bash -s -- "$FORK_URL" "$SHA" <<'REMOTE'
set -euo pipefail
FORK_URL="$1"; SHA="$2"
cd ~/workspace/uptime

git remote get-url fork >/dev/null 2>&1 || git remote add fork "$FORK_URL"
git fetch -q fork
PREV="$(git rev-parse HEAD)"

sudo systemctl stop uptime-kuma
BACKUP=~/backups/uptime-kuma/pre-deploy-$(date +%Y%m%d-%H%M%S).tar.gz
tar czf "$BACKUP" data
echo "Backup: $BACKUP (previous commit: $PREV)"

git checkout -q --detach "$SHA"
npm ci --omit dev --no-audit --no-fund
npm run download-dist

sudo systemctl start uptime-kuma
for i in $(seq 1 30); do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3001/dashboard)" = "200" ]; then
        echo "Healthy after ${i}x2s"
        exit 0
    fi
    sleep 2
done

echo "Health check FAILED. Check: journalctl -u uptime-kuma -n 50" >&2
echo "Rollback: stop service, restore $BACKUP into data/, git checkout $PREV, npm ci, npm run download-dist" >&2
exit 1
REMOTE

curl -s -o /dev/null -w "public: %{http_code}\n" https://monitor.alephhouse.com/dashboard
