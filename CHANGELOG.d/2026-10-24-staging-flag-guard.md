### Tooling — a mistyped flag on the staging check fails closed instead of running the real AWS test (roadmap 2.7 debt)
- `scripts/check-staging-prereqs.mjs` recognised exactly one flag, `--selftest`, by substring, and ignored
  everything else. So `--self-test` **ran the real check** — `iam get-role`, `ecr list-images` — while the
  reader believed the six fixture cases had run. Measured on `fix/337-staging-prereqs`: 6/6 with
  `--selftest`, and exit **1** with a real rule-1 finding with the hyphenated spelling.
- The script now refuses any argument it does not know, prints the usage, and exits **2** — the same code
  it already uses for "could not be asked", so nothing parsing the result can mistake it for a pass.
- `.github/workflows/workflow-lint.yml` asserts it: the step runs the six cases and then asserts that
  `--self-test` exits 2, so a future edit cannot quietly remove the guard.
- `docs/TESTING.md`'s traps row gains the guard; the row was written with the guard still owed, and this is
  that debt paid.
