### Infra — Terraform can express staging's APNs sandbox and the QA push flag (#1083)
- New `apns_env` (production/sandbox), `apns_secret_json` and `social_alert_push_every_message` variables, so a staging apply keeps what API rev 17 runs (APNs key, key id and team id from the JSON secret, sandbox endpoint, push on every flagged message).
- Production is unchanged: `APNS_ENV` stays pinned to `production`, every new variable defaults off, and a precondition refuses the push flag in production. No apply in this change.
