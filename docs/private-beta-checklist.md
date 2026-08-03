# Private Beta Checklist

- Confirm the Railway backend service and managed Postgres backups
- Put the OAuth consent screen in Production
- Verify the domain used by the hosted backend
- Publish a privacy policy URL
- Publish a support contact URL or email
- Configure Developer ID signing and notarization secrets
- Set `APP_RELEASE_SHA` to the exact deployed Git commit
- Optionally configure an external scheduler identity for `/internal/cron/sync`
- Verify `/healthz`, OAuth, bootstrap, mutation, SSE replay, and background sync after deployment
- Test a clean install on a separate Mac
- Test two different Google accounts for tenant isolation
