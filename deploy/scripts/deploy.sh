#!/usr/bin/env bash
# Build and (re)start every Zuvigo app on the VPS.
#
#   bash deploy/scripts/deploy.sh                 # pull, build, reload everything
#   RUN_MIGRATIONS=1 bash deploy/scripts/deploy.sh  # also run Backend migrations first
#   SKIP_PULL=1 bash deploy/scripts/deploy.sh       # use the files already on disk
#
# Each folder (root, Backend, readyiosite, readyiosite-blog, admin-panel) is its
# own git repo; every one that is a checkout gets `git pull --ff-only`.
#
# Order matters: the API must be up before the Next.js builds, because they
# pre-render blog pages by fetching http://127.0.0.1:4000/api.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ECOSYSTEM="$ROOT/deploy/ecosystem.config.cjs"
cd "$ROOT"

step() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

step "Preflight"
command -v node >/dev/null || fail "node is not installed"
command -v pm2 >/dev/null || fail "pm2 is not installed (npm i -g pm2)"
# Vite 7 (admin panel) needs ^20.19 or >=22.12; Next.js 16 needs >=20.9.
node -e 'const [maj,min]=process.versions.node.split(".").map(Number); process.exit((maj===20&&min>=19)||(maj===22&&min>=12)||maj>22?0:1)' \
  || fail "Node $(node -v) is too old; need Node 20.19+ or 22.12+"
[ -f Backend/.env ] || fail "Backend/.env is missing (copy Backend/.env.example)"
[ -f readyiosite/.env.local ] || fail "readyiosite/.env.local is missing (needs REVALIDATE_SECRET)"
[ -f readyiosite-blog/.env.local ] || fail "readyiosite-blog/.env.local is missing (needs REVALIDATE_SECRET)"
if grep -q 'rds.amazonaws.com' Backend/.env && [ ! -f Backend/global-bundle.pem ]; then
  fail "Backend/global-bundle.pem is missing (RDS SSL certificate bundle)"
fi

if [ -z "${SKIP_PULL:-}" ]; then
  step "Pulling latest code"
  for repo in . Backend readyiosite readyiosite-blog admin-panel; do
    if [ -d "$repo/.git" ]; then
      echo "-- $repo"
      git -C "$repo" pull --ff-only
    fi
  done
fi

step "API: install"
(cd Backend && npm ci --omit=dev)

if [ -n "${RUN_MIGRATIONS:-}" ]; then
  step "API: migrate (also resets the admin password to ADMIN_PASSWORD)"
  (cd Backend && npm run migrate)
fi

step "API: start/reload"
pm2 startOrReload "$ECOSYSTEM" --only readyio-api --update-env

step "API: waiting for /health"
for i in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:4000/health >/dev/null 2>&1; then
    echo "API is up"
    break
  fi
  [ "$i" -eq 30 ] && fail "API did not become healthy; check: pm2 logs readyio-api"
  sleep 1
done

step "zuvigo.com: install + build"
(cd readyiosite && npm ci && npm run build)

step "blog.zuvigo.com: install + build"
(cd readyiosite-blog && npm ci && npm run build)

step "blogpanel.zuvigo.com: install + build"
(cd admin-panel && npm ci && npm run build)

step "Start/reload Next.js apps"
pm2 startOrReload "$ECOSYSTEM" --only readyio-site,readyio-blog --update-env
pm2 save

step "Smoke test"
check() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' "$1" || true)
  printf '  %-45s %s\n' "$1" "$code"
}
sleep 2
check http://127.0.0.1:4000/health
check http://127.0.0.1:4000/api/articles
check http://127.0.0.1:8080/
check http://127.0.0.1:8080/blog
check http://127.0.0.1:8081/
check http://127.0.0.1:8081/sitemap.xml
[ -f admin-panel/dist/index.html ] && echo "  admin-panel/dist/index.html                   present"

step "Done"
pm2 status
