### CI — every PR and push to main is scanned for secrets (osra-security#26, #609)
- `workflow-lint` now runs gitleaks v8.30.1 over the whole git history and the working tree, with the repo's
  `.gitleaks.toml` (default rules plus two reviewed test fixtures, matched by file and variable name) and a
  `.gitleaksignore` holding one reviewed historical fingerprint. A new key-shaped value fails the job.
- A value pasted into `docs/QA/DISCUSSION-LOG.md` is redacted.
