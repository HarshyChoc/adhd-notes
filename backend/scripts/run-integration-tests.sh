#!/usr/bin/env bash
set -euo pipefail

test_db="mdsticky_test_${$}_$(date +%s)"
test_host="${PGHOST:-127.0.0.1}"
test_port="${PGPORT:-5432}"
test_user="${PGUSER:-$(id -un)}"
base_database_url="${DATABASE_URL:-postgresql://${test_user}@${test_host}:${test_port}/postgres}"

cleanup() {
  dropdb --if-exists --force -h "$test_host" -p "$test_port" -U "$test_user" "$test_db" >/dev/null 2>&1 || true
}
trap cleanup EXIT

createdb -h "$test_host" -p "$test_port" -U "$test_user" "$test_db"
export DATABASE_URL="$(
  node --input-type=module -e '
    const url = new URL(process.argv[1]);
    url.pathname = `/${process.argv[2]}`;
    process.stdout.write(url.toString());
  ' "$base_database_url" "$test_db"
)"
export SYNC_PROVIDER="mock"
export APP_ENCRYPTION_KEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
export APP_RELEASE_SHA="integration-test"
export GOOGLE_SYNC_INTERVAL_MS="3600000"

npx prisma migrate deploy >/dev/null
npx tsx --test --test-concurrency=1 test/*.test.ts
