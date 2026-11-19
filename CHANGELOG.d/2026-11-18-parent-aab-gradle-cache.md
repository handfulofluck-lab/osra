### CI — the parent app's AAB step caches Gradle, so a Maven rate limit no longer costs a run (#911)
- The `Parent app` workflow's **Release build (AAB)** step failed on a PR with
  `Could not resolve org.jetbrains.kotlin:kotlin-stdlib:2.2.21`, and the cause was not a version or a missing
  repository line: Gradle logged `Could not GET 'https://repo.maven.apache.org/maven2/…/kotlin-gradle-plugins-bom-2.2.20.pom'.
  Received status code 429 from server: Too Many Requests` and then disabled the Gradle Plugin Portal for the
  rest of the build, so the next artifact it needed failed too. A rate limit on a shared runner IP, not our tree.
- `gradle/actions/setup-gradle` (pinned by full commit SHA, the same copy the Android suite uses) now caches the
  Gradle user home before the build. Every request served from that cache is a request that cannot be
  rate-limited, which is what makes the observed "passed, then failed four times" pattern stop repeating.
- **Not fixed here, and it is the half that keeps `main` red:** every push run of this workflow on `main` since
  at least 16 Nov fails *before* Gradle, at the `OSRA_API_BASE` guard — the repository variable is not set, and
  a signed store bundle is refused without it by design (osra-security#8 F3). That is a repository setting, not
  code, and it is reported on #911 for whoever owns it.
- Verified: `node scripts/check-workflows.mjs --strict` → 0/0 across 19 workflows;
  `node scripts/check-ci-cost-guardrails.mjs` → 0 problems and its self-test 20/20 (the setup-gradle pin rule
  still passes); `node scripts/check-ci-paths.mjs` → 0 problems.
