### OSRA Kids iPhone: reachable Continue button on the ring screen (#760)

- `apps/child-ios/Sources/FamilyShieldAgent/RingView.swift`: move the PIN Continue button into `.safeAreaInset(edge: .bottom)` so it stays above the keyboard on the SE 3 and at large text sizes. Disable it until the PIN reaches the minimum length.
- `apps/child-ios/Sources/FamilyShieldAgent/ParentPinViews.swift`: let `PinGateView` optionally bind its PIN/message state and hide its own Continue button, so `RingView` owns the single bottom button.
- `apps/child-ios/Tests/FamilyShieldAgentTests/RingCommandTests.swift`: add source tests that assert the bottom Continue uses `safeAreaInset`, is disabled until the PIN is long enough, and `RingView`'s `PinGateView` has `showsButtons: false`.
- `apps/parent-app/lib/l10n/app_en.arb` and `apps/parent-app/lib/l10n/app_ar.arb`: format the `count` placeholder of `alertBodyRingChildDismissed` with `decimalPattern` so the dismissal count uses the locale's number format and never mixes digit sets within a row.
- `apps/parent-app/test/localization_test.dart`: assert the ring dismissal count placeholder uses `decimalPattern` in both locales.
