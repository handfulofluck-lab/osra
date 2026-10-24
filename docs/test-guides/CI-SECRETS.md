# CI and deployment secrets

Every secret below is read from the environment (locally: `android/local.properties`, `services/api/.env`,
`services/ai-engine/.env`) or from GitHub Actions repository secrets. **None is ever committed.** A value
that appears in a commit is considered leaked and must be rotated.

| Secret | Used by | Purpose |
|---|---|---|
| `MAPS_API_KEY` | parent-app (Android manifest placeholder) | Google Maps SDK key; restrict it to the app's package + SHA-1 in Google Cloud Console |
| `OSRA_UPLOAD_KEYSTORE_B64` | parent-app, child-android CI | Base64 of the Play upload keystore (`upload.jks`) |
| `OSRA_UPLOAD_KEYSTORE_PASSWORD`, `OSRA_UPLOAD_KEY_ALIAS`, `OSRA_UPLOAD_KEY_PASSWORD` | same | Keystore credentials |
| `GOOGLE_SERVICES_JSON_B64` | child-android, parent-app | Firebase config for FCM (Phase 1-C / 2) |
| `FCM_SERVICE_ACCOUNT_JSON` | services/api | FCM HTTP v1 sender credentials (push to parents) |
| `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID` | services/api | APNs token auth (iOS parent app) |
| `RESEND_API_KEY` (or SMTP_*) | services/api | Transactional email: password reset, invites, digests |
| `DEEPSEEK_API_KEY` | services/ai-engine | Hosted multilingual classifier, **synthetic evaluation messages only** (ADR-0033); the regex fallback runs without it |
| `AWS_BEDROCK_EVAL_ROLE_ARN` (a repository **variable**, not a secret) | `ai-eval-bedrock.yml` | The role the Bedrock evaluation assumes over OIDC; no AWS key exists. Set from `terraform -chdir=infra/terraform/base output -raw bedrock_eval_role_arn` |
| `JWT_SECRET`, `INTERNAL_HMAC_SECRET`, `VAULT_KEY` | services/api | Already documented in `services/api/.env.example`; rotate the dev values in `start-backend.bat` before any external tester build |
| `WINDOWS_CODESIGN_PFX_B64`, `WINDOWS_CODESIGN_PASSWORD` | agent-desktop | Authenticode signing of the MSIX/exe (Phase 5) |
| `APPLE_TEAM_ID`, `APP_STORE_CONNECT_KEY_*` | child-ios, parent-app iOS | Signing and TestFlight upload (Phase 5) |

How CI treats a missing secret: builds still run (debug key, blank Maps key, no push) so the *compile*
gate stays meaningful; only the publish steps require the real values.
