### API and CI — a production task definition is checked as a release configuration (gate #637)
- `scripts/check-production-taskdef.mjs` reads what `aws ecs describe-task-definition` prints and fails on a
  development, staging or test switch (any-origin CORS, the demo seed password, the legacy internal signature, the
  idle counter, a skipped schema check), a secret passed as a plain value, a moving image tag, a missing required
  setting, or a variable nobody classified. It names variables and never prints a value. `--pre-launch` reports the
  iPhone-push and Play-billing settings as pending instead of failing; nothing else can be waived.
- `--source` fails when the API starts reading an environment variable the script has no decision for, so a new
  switch cannot reach production unclassified. It follows `env[CONSTANT]` reads and fails on one it cannot
  resolve. CI runs it and the 68-check self-test in `workflow-lint`.
- After Fable's review of #778: a setting held as a `secrets` entry is a finding (its value cannot be read), as are
  `environmentFiles`, any volume or mount point, a task role, an image, secret or execution role in another AWS
  account (`--account` pins the account), added Linux capabilities, a non-essential container and `TRUST_PROXY`
  other than `1`. `DEVICE_SILENT_ALLOW_TIGHT` is forbidden in production. Who runs `--file` on the real task
  definition and where the output goes is in `docs/TESTING.md`.
- The API no longer writes a recipient's address or a subject line to the production log when no e-mail provider is
  configured: it says only that a message was not sent and how to fix it.
- `services/api/test/log-hygiene.test.ts` reads every log call in the API and fails when one names a field a family
  typed or owns (an address, message or search text, a title, a link or token, a place, a name). The two calls that
  do are development-only, and the test checks that each still sits under its production guard.
