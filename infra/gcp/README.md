# Optional Google Cloud Reference

Railway is the canonical production host. These scripts are retained only as
reference material for a possible manual Cloud Run migration; pushing `main`
does not invoke them.

This repo now includes the production deployment scaffolding for the hosted backend:

- `backend/Dockerfile`
- `scripts/deploy-backend-gcp.sh`
- `scripts/deploy-scheduler-gcp.sh`

Required Google Cloud pieces:

- Cloud Run service
- Cloud SQL Postgres instance
- Secret Manager secrets for:
  - `DATABASE_URL`
  - `GOOGLE_CLIENT_ID`
  - `GOOGLE_CLIENT_SECRET`
  - `APP_ENCRYPTION_KEY`
- Cloud Scheduler service account allowed to invoke the Cloud Run service
- Custom domain such as `https://api.mdstickynotes.com`

Expected environment inputs for the deploy scripts:

- `GCP_PROJECT_ID`
- `GCP_REGION`
- `PUBLIC_API_BASE_URL`
- `INTERNAL_CRON_SERVICE_ACCOUNT_EMAIL`

The backend deploy script configures the public routes for the desktop app and injects the scheduler OIDC audience for `POST /internal/cron/sync`.
