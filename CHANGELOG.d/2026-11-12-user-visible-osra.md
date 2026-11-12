### User-visible OSRA — remaining FamilyShield-named surfaces now say OSRA (#608)
- The GDPR export filename is `osra-export-<familyId>.json` (was the old familyshield-namespace name).
- The demo parent signs in as `demo@osratech.com`. Locally the password is the public non-production
  default in `services/api/scripts/seed-password.ts` (never printed); against staging it is read from
  the `osra-staging/demo-password` secret.
- Windows and macOS user-visible data folders are `OSRA`, with a one-time migration from `FamilyShield`
  that preserves pairing.
- Windows test certificate: only newly generated roots use the `OSRA Test Root` subject; existing PFX
  files and trust entries are deliberately unchanged.
- Internal package/namespace/header/target names stay unchanged, so already-paired devices keep working.
- Adds `scripts/check-user-visible-brand.mjs` and a `workflow-lint.yml` step (`--selftest` then the real
  scan) that fail any tracked or untracked repo file still carrying a pre-OSRA user-visible form.
- Verification evidence (suite runs): API 57 files / 836 tests; Windows desktop 242 tests; macOS
  migration 6 tests; Android Play 987/987 and Full 987/987; Flutter 623 tests with `flutter analyze`
  clean; brand guard self-test 55/55 and real scan green; workflow lint 18 files clean; docs-links
  self-test 17/17 and 133 links in 332 Markdown files clean.
- Still unverified: the `net8.0-macos` app build and iOS/macOS device behaviour (not verified on a Mac).
  Not merged, and no independent Claude verification is claimed.
