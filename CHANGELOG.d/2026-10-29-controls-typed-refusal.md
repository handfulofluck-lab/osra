### Parent app — a refused pause says why, and the wizard names the region (#437 A2)
- `pauseInternet` / `resumeInternet` rethrew the `DioException` and every caller stringified it
  (`commandFailed('$e')`), so a consent `428` on a control arrived as an exception dump. The provider now throws
  **`ControlsRefusal`** carrying the original exception, and child detail maps it through `readErrorText` — the same
  sentence every other write uses. Anything unmapped keeps the old message.
- The onboarding wizard's create collapsed **every** `428` into "consent required", including a region mismatch the
  parent can actually fix. It now uses `consentRefusalRegionLabel`, the one place that decides a refusal's region, and
  the add-child dialog delegates to it too — so the decision lives once, not three times.
- Rows: a refused pause on the child's device card (asserts the POST happened, the sentence, and no exception or wire
  code), and the wizard's region sentence. Mutant: letting the provider stringify again reddens the pause row.
