### Release carriers — a Windows version, a Play build number, and a readiness page that stops lying (release prep)

- **The Windows agent has a version.** `FamilyShield.Agent.csproj` carried none, so every build reported the SDK
  default and two builds of different trees were indistinguishable in a release record or a bug report
  (`RELEASING.md` §3 said so; it now records the value and its line).
- **The parent app has a `+<build>` suffix.** `pubspec.yaml` was `0.1.0`, and Android takes `versionCode` from
  that suffix — so a second upload to Play would have reused code 1 and been refused. It is `0.1.0+1` now, and the
  runbook says to raise `n` for every uploaded build, rebuilds included.
- **The privacy row is what is measured, not what was assumed.** The policy exists and is deployed
  (`site/privacy/index.html`, `site-pages.yml`); `http://osratech.com/privacy/` serves it, and
  `https://osratech.com/privacy/` fails the TLS handshake because the GitHub Pages domain-challenge TXT record
  does not exist, so no certificate is issued. The row carries the record to add and the reason not to hand Play an
  `http://` policy URL.
- **The readiness page no longer quotes test counts.** It listed 178/178 API, 146/146 Android, 161/161 Windows,
  89/89 parent, 44/44 E2E; the same suites are 205+, 1117, 185, 103 and 56 today. A table nobody re-runs gets
  quoted as current, so it now points at the CI run for the commit and leaves the numbers to the release record.
