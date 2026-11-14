### Docs — ADR-0039 amended after Ahmed's threat-model review
- The Full update manifest is signed offline on the maintainer's PC, never in CI, so a CI compromise cannot
  point a phone at a malicious APK. Its Actions secret is to be removed.
- The updater now has nine requirements: exact-byte signatures; `expiresAt` plus a highest-seen guard
  against freeze attacks; two keys with a `keyId`; strict URLs with no redirects; install-only-itself; hashing
  while streaming into the install session; `hasSigningCertificate` so key rotation still works; the install
  grant in the capability report; and `minSupportedVersionCode` as information only.
- Hosting gains an exact OIDC `sub`, bucket versioning, no deletes, `If-None-Match` on APKs, and HSTS.
  `OSRA_VERSION_CODE` is now required for Full builds.
