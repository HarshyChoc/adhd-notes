# Backend Sync Service

This service is the Google Tasks sync boundary for ADHD Notes. It owns Google OAuth, stores encrypted refresh tokens, keeps Postgres as the canonical note/task state, projects desktop mutations to Google Tasks, polls for remote changes, and streams events back to the macOS app over SSE.

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
npx prisma db push
npm run dev
```

For local Google OAuth, the redirect URI should be:

- `http://127.0.0.1:8787/auth/google/callback`

The desktop callback remains:

- `mdstickynotes://auth/callback`

## Production Hosting

The repo now includes:

- [Dockerfile](Dockerfile)
- baseline Prisma migration in [backend/prisma/migrations](prisma/migrations)
- Cloud Run deploy script at [scripts/deploy-backend-gcp.sh](../scripts/deploy-backend-gcp.sh)
- Cloud Scheduler deploy script at [scripts/deploy-scheduler-gcp.sh](../scripts/deploy-scheduler-gcp.sh)

Expected production shape:

- Cloud Run hosts the public API
- Cloud SQL Postgres stores canonical state
- Secret Manager stores `DATABASE_URL`, Google OAuth credentials, and the encryption key
- Cloud Scheduler hits `POST /internal/cron/sync` every minute with an OIDC token
- Manual and scheduled sync share a per-user Postgres lease, so overlapping jobs return `status: "already_running"` instead of projecting the same task twice

The internal cron endpoint verifies the Google-issued identity token against:

- `INTERNAL_CRON_AUDIENCE`
- `INTERNAL_CRON_SERVICE_ACCOUNT_EMAIL`

## Build And Run

```bash
cd backend
npm install
npm run build
npm run start
```

The production container command runs:

```bash
npm run prisma:migrate && npm run start
```
