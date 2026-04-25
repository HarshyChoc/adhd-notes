#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DIR="$ROOT_DIR/backend"
EDITOR_DIR="$ROOT_DIR/editor-web"
ENV_FILE="$BACKEND_DIR/.env"
DB_NAME="md_sticky_notes"
DB_USER="$(id -un)"

if [[ ! -f "$ENV_FILE" ]]; then
  APP_ENCRYPTION_KEY="$(openssl rand -base64 32)"
  cat > "$ENV_FILE" <<EOF
SYNC_PROVIDER=mock
BIND_HOST=127.0.0.1
PORT=8787
DATABASE_URL=postgresql://${DB_USER}@127.0.0.1:5432/${DB_NAME}
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
GOOGLE_REDIRECT_URI=http://127.0.0.1:8787/auth/google/callback
APP_DESKTOP_REDIRECT_URI=mdstickynotes://auth/callback
APP_ENCRYPTION_KEY=${APP_ENCRYPTION_KEY}
SESSION_TTL_DAYS=30
GOOGLE_SYNC_INTERVAL_MS=15000
MOCK_USER_EMAIL=local-dev@mdstickynotes.dev
ALLOWED_GOOGLE_EMAILS=
EOF
  echo "Created mock local-dev env at $ENV_FILE"
else
  echo "Using existing backend env at $ENV_FILE"
fi

if ! psql -Atqc "select 1" postgres >/dev/null 2>&1; then
  echo "Local Postgres is not reachable. Start Postgres and rerun this script." >&2
  exit 1
fi

createdb "$DB_NAME" >/dev/null 2>&1 || true

cd "$BACKEND_DIR"
npm install
npx prisma generate
npx prisma db push

cd "$EDITOR_DIR"
npm install

echo
echo "Local dev setup complete."
echo "Backend env: $ENV_FILE"
echo "Database: $DB_NAME"
