#!/bin/bash

set -euo pipefail

: "${GCP_PROJECT_ID:?Set GCP_PROJECT_ID}"
: "${GCP_REGION:=us-central1}"
: "${SCHEDULER_JOB:=md-sticky-notes-sync}"
: "${PUBLIC_API_BASE_URL:?Set PUBLIC_API_BASE_URL}"
: "${INTERNAL_CRON_SERVICE_ACCOUNT_EMAIL:?Set INTERNAL_CRON_SERVICE_ACCOUNT_EMAIL}"

gcloud scheduler jobs create http "$SCHEDULER_JOB" \
  --project "$GCP_PROJECT_ID" \
  --location "$GCP_REGION" \
  --schedule "*/1 * * * *" \
  --http-method POST \
  --uri "${PUBLIC_API_BASE_URL}/internal/cron/sync" \
  --oidc-service-account-email "$INTERNAL_CRON_SERVICE_ACCOUNT_EMAIL" \
  --oidc-token-audience "${PUBLIC_API_BASE_URL}/internal/cron/sync" \
  --attempt-deadline 30s \
  --quiet \
|| gcloud scheduler jobs update http "$SCHEDULER_JOB" \
  --project "$GCP_PROJECT_ID" \
  --location "$GCP_REGION" \
  --schedule "*/1 * * * *" \
  --http-method POST \
  --uri "${PUBLIC_API_BASE_URL}/internal/cron/sync" \
  --oidc-service-account-email "$INTERNAL_CRON_SERVICE_ACCOUNT_EMAIL" \
  --oidc-token-audience "${PUBLIC_API_BASE_URL}/internal/cron/sync" \
  --attempt-deadline 30s \
  --quiet
