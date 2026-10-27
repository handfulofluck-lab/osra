### Parent app — the remaining gated reads name the owner too (ADR-0014 decision 7, #406)
- `readErrorText(l10n, error, fallback)` is now the one place a screen decides between decision 7's sentence and
  its own message. It reuses `ReadPermissionRequired.from`, so "which errors count as a refusal" stays decided once.
- Wired into every `AsyncValue.when(error:)` that renders a gated read: the map (family), reports
  (`/v1/reports/web`), social (`/v1/social/events` and `/v1/reports/activity`, four call sites) and search safety
  (`/v1/content/searches`).
- The fallback is a callback, so a screen that formats the error into its message does not build it on the refusal
  path.
- **Not covered, and named in the issue rather than papered over:** the map reads the latest ping and the geofences
  through `.valueOrNull`, so a refusal there shows **no pin and no text** rather than a generic error. Decision 7 has
  nothing to replace until that UI grows an error state; it is the remaining piece of #406.
- Tests: three rows on the helper — a refusal wins over the screen's message, a 500/timeout/non-Dio error falls
  through, and the fallback is not built on the refusal path. The screen wiring itself has no widget row yet, which is
  the weakest part and is called out in the PR.
