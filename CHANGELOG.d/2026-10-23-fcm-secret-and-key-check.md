### Staging — the FCM service account has a Terraform home, and a gate against committing key material
- **`base/secrets.tf`** gains the `osra-staging/fcm-service-account` container and an output for its ARN. The
  container is Terraform's; **the JSON value is not** — it is a Google-issued credential, so it is written with
  `aws secretsmanager put-secret-value --secret-string file://<path outside every checkout>` and never enters state.
- **`env/ecs.tf`** maps it into the API task as `FCM_SERVICE_ACCOUNT_JSON` (`services/api/src/lib/push/fcm.ts` reads
  that name) **only when `push_enabled = true`**. A secret with no version cannot be resolved by ECS, so mapping it
  before the value exists would fail the task at start; the flag keeps `up.sh` working until push is actually turned on.
- **`scripts/check-no-service-account-keys.mjs`** (new, `workflow-lint`) fails a tracked file containing a Google
  service-account marker or a PEM private-key header. Name rules in `.gitignore` miss a renamed file —
  `backup/service.json` matches no glob — and a credential in a public repository stays in every clone and fork.
  The self-test proves both directions (4/4): a service-account JSON and a PEM key fail, an ordinary `package.json`
  and prose about service accounts pass.
- **Not built here:** the Android side of roadmap 1.5 (the gms plugin, `google-services.json` for
  `com.familyshield.agent`, and data messages for commands). It waits on the two app registrations in the Firebase
  project; the acceptance line is a lock landing in under 5 s with the app backgrounded.
