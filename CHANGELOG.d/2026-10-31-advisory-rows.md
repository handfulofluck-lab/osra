### Tests — two review advisories become rows (#507, #509)
- Android: `TamperWindowClassWiringTest` pins that `AccessibilityMonitorService` keeps the window class from
  window-state changes only and passes it to `TamperScreenPolicy.classify` only while the same package is in
  front (#507 review).
- iOS: `RuleSyncTests.testClearRemovesTheAppliedVersionWithTheRules` checks directly that `RuleStore.clear()`
  drops the applied rules version (#509 review), instead of relying on a value left over from an earlier row.
