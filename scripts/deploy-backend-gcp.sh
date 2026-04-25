#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DIR="$ROOT_DIR/backend"

: "${GCP_PROJECT_ID:?Set GCP_PROJECT_ID}"
: "${GCP_REGION:=us-central1}"
: "${CLOUD_RUN_SERVICE:=md-sticky-notes-backend}"
: "${PUBLIC_API_BASE_URL:?Set PUBLIC_API_BASE_URL}"
: "${DATABASE_URL_SECRET:=md-sticky-notes-database-url}"
: "${GOOGLE_CLIENT_ID_SECRET:=md-sticky-notes-google-client-id}"
: "${GOOGLE_CLIENT_SECRET_SECRET:=md-sticky-notes-google-client-secret}"
: "${APP_ENCRYPTION_KEY_SECRET:=md-sticky-notes-app-encryption-key}"
: "${INTERNAL_CRON_SERVICE_ACCOUNT_EMAIL:?Set INTERNAL_CRON_SERVICE_ACCOUNT_EMAIL}"

gcloud run deploy "$CLOUD_RUN_SERVICE" \
  --project "$GCP_PROJECT_ID" \
  --region "$GCP_REGION" \
  --source "$BACKEND_DIR" \
  --allow-unauthenticated \
  --port 8787 \
  --memory 512Mi \
  --set-env-vars "BIND_HOST=0.0.0.0,SYNC_PROVIDER=google,PORT=8787,GOOGLE_REDIRECT_URI=${PUBLIC_API_BASE_URL}/auth/google/callback,APP_DESKTOP_REDIRECT_URI=mdstickynotes://auth/callback,INTERNAL_CRON_AUDIENCE=${PUBLIC_API_BASE_URL}/internal/cron/sync,INTERNAL_CRON_SERVICE_ACCOUNT_EMAIL=${INTERNAL_CRON_SERVICE_ACCOUNT_EMAIL}" \
  --set-secrets "DATABASE_URL=${DATABASE_URL_SECRET}:latest,GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID_SECRET}:latest,GOOGLE_CLIENT_SECRET=${GOOGLE_CLIENT_SECRET_SECRET}:latest,APP_ENCRYPTION_KEY=${APP_ENCRYPTION_KEY_SECRET}:latest"
