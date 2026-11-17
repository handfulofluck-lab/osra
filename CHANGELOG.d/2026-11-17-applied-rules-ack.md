### Android child — the applied rules version reaches the server when it moves (#865 second half)
- The phone told the server which rules version it had applied only inside telemetry uploads, and the periodic
  upload returns early when there is no usage to send. The Mac test bed measured the consequence: rules at v15
  at 10:25:35, the command acked at 10:26:24, and `/v1/family/me` still said 14 six minutes later — so the
  parent's "hasn't picked this change up yet" line was telling the truth about a stale number.
- `RuleRepository` now hands the stored version to a listener the moment it is written (and only when the write
  succeeded), and `UsageReporter.reportAppliedRulesIfChanged()` posts it as a one-number telemetry body.
- The version the server **accepted** is kept in its own preference, written only after a 2xx, so a failed
  POST is retried on the next tick instead of being remembered as done. Nothing is sent while consent is paused.
- Tests: `AppliedRulesReporterTest` covers change, no-change, never-applied and the failed-upload retry;
  `AppliedRulesReportWiringTest` pins the save-then-fire order, the consent guard and the two separate keys.
- Verified: no Android SDK on the authoring host, so `./gradlew testDebugUnitTest` and the debug APK are CI
  evidence on the PR.
