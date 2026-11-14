### Docs — the Full child app gets a way to reach families (ADR-0039, roadmap 5.10)
- ADR-0039 designs what the two-build plan never had: Full becomes `com.osratech.child.full` with its own
  `full-release` signing key (so it can never clash with the Play install), a third Firebase app, Android
  developer verification, an `/android/` download page on osratech.com, a manual `full-release.yml`
  workflow, and a Full-only self-update that trusts only an Ed25519-signed `latest.json` and refuses
  downgrades, off-site URLs and APKs signed with another key.
- Search capture (YouTube search box, Chrome/Google queries) ships Full-first; the Play build gains no
  permission and no data type.
- Roadmap row 5.10 added with acceptance R1–R8; build order PR A–E for Kimi, review and pen test for Ahmed.
