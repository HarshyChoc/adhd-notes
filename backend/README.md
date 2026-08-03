# Backend Sync Service

This service is the Google Tasks sync boundary for MD Sticky Notes. It owns Google OAuth, stores encrypted refresh tokens, keeps Postgres as the canonical synchronized state, projects desktop mutations to Google Tasks, polls for remote changes, and streams events back to the macOS app over SSE.

## Stack

- Fastify
- Prisma
- Postgres
- Google Tasks API

## API Surface

- `GET /auth/google/start`
- `GET /auth/google/callback`
- `POST /auth/app/exchange`
- `GET /v1/bootstrap`
- `GET /v1/events/stream`
- `POST /v1/mutations`
- `POST /v1/sync/now`
- `GET /v1/task-lists`
- `PATCH /v1/preferences/sync`
- `POST /internal/cron/sync`
- `GET /healthz`

## Environment

Copy `.env.example` to `.env` and fill in real values:

```bash
cd backend
cp .env.example .env
```

Important values:

- `DATABASE_URL`
- `SYNC_PROVIDER`
- `GOOGLE_CLIENT_ID`
- `GOOGLE_CLIENT_SECRET`
- `GOOGLE_REDIRECT_URI`
- `APP_ENCRYPTION_KEY`
- `INTERNAL_CRON_AUDIENCE`
- `INTERNAL_CRON_SERVICE_ACCOUNT_EMAIL`
- `APP_RELEASE_SHA`
- `SCHEDULED_SYNC_CONCURRENCY`

Generate a local encryption key with:

```bash
openssl rand -base64 32
```

## Local Development

### Mock provider

```bash
./scripts/dev-run-backend.sh
```

### Real Google provider

```bash
cd backend
npm install
npx prisma generate
npx prisma migrate deploy
npm run dev
```

For local Google OAuth, the redirect URI should be:

- `http://127.0.0.1:8787/auth/google/callback`

The desktop callback remains:

- `mdstickynotes://auth/callback`

## Production Hosting

Railway is the canonical production host. The linked project uses a service rooted at `backend/`, [railway.json](railway.json), this Dockerfile, and managed Postgres. The public API is:

- `https://backend-production-15d8.up.railway.app`

Expected production shape:

- Railway hosts the Fastify API and runs additive Prisma migrations before startup
- Railway managed Postgres stores users, sessions, notes, OAuth state, event replay, projection jobs, and leases
- Railway encrypted variables store `DATABASE_URL`, Google OAuth credentials, and the encryption key
- the in-process completion-based loop runs background sync; `POST /internal/cron/sync` remains available for an optional external scheduler
- manual and scheduled sync share a renewable per-user Postgres lease, so overlapping jobs return `status: "already_running"`
- `/healthz` verifies database readiness and returns `APP_RELEASE_SHA` so a deployment can be tied to an exact Git commit

The GCP files under `../infra/gcp/` are optional migration references only. The GitHub workflow runs CI and does not deploy either GCP or Railway.

The internal cron endpoint verifies the Google-issued identity token against:

- `INTERNAL_CRON_AUDIENCE`
- `INTERNAL_CRON_SERVICE_ACCOUNT_EMAIL`

## Build And Run

```bash
cd backend
npm install
npm run build
npm test
npm run start
```

The production container command runs:

```bash
npm run prisma:migrate && npm run start
```
