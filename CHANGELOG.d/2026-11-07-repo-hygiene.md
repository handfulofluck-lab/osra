### Repository — hygiene pass (2026-11-07)
- Removed the empty `infra/docker/` and `infra/k8s/` placeholders: ADR-0028 chose AWS Fargate built from
  `infra/terraform`, and each service keeps its own Dockerfile. `README.md` and `docs/SPEC.md` now say so.
- Removed `docs/QA/tools/file-issues.py`, the one-off script that filed the 2026-10-11 QA findings as
  issues; it has run, nothing references it, and the issues it filed are the record.
- `.gitignore` now also refuses Apple signing material (`*.p8` APNs keys, `*.p12`, `*.mobileprovision`),
  `*.jks` keystores, Xcode user data (`xcuserdata/`, `*.xcuserstate`, `DerivedData/`) and `coverage/`.
  No tracked file matches the new patterns.
- Branches: the stale `ahmed/444-call-probe` and `ahmed/444-media-pause` (superseded by #457) are listed
  for deletion with their tips recorded in the PR.
