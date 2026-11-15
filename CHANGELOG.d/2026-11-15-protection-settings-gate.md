### Switching OSRA's own permissions off is behind the parent PIN (osra-security#29, osra-security#30)
- Found on the Flip4 (AS02, 14 Nov) and tracked privately as osra-security#29, osra-security#30: two system surfaces that
  change the agent's own permissions opened **without the parent PIN**.
- Those pages are now protection screens (`TamperScreen.PROTECTION_SETTINGS`), classified by window class —
  the accessibility detail pages (AOSP, Google, Samsung) and the PermissionController pages
  (`ManagePermissionsActivity`, `AppPermissionsActivity`, `PermissionDetailsActivity`). The PermissionController
  package joins the system packages the classifier recognises, because Android 11+ keeps those pages there.
- The guard still fires only when the screen **names the agent**: the same two pages exist for every app on the
  phone, and a row asserts Chrome's and the camera's stay `NONE`.
- **The unbind is not prevented, only reported** — and now reported at once: `onUnbind` raises its own alert
  (`accessibility_off`) instead of leaving it to the 60-second poll, which on a phone without the location grant
  never runs at all.
- Verified by JVM tests only (`TamperScreenPolicyTest`'s three new rows). **Not verified on a handset**: both
  pages on the Flip4 under the lease.
- **Two signals, not one (review).** The accessibility page is guarded when the screen carries our own
  `accessibility_description`, in whatever language the phone is in — that survives OEM renames and the fragment
  hosts current Settings builds use — and the PermissionController pages are guarded on the package plus our name
  alone. The class list stays as a second opinion, not as the gate.
- **What is deliberately NOT guarded, after review.** The accessibility **list of every installed service** and
  the accessibility settings hub are never protection screens: gating them would block access to assistive
  tools (ADR-0021). The **runtime permission prompt** is never one either — the OS asks it while a parent is
  setting the phone up, and a gate there would block onboarding itself.
- **Other system surfaces of the same kind are not covered by this change**; they are tracked privately and are
  the Part 2 of that work.
- **The parent hears about an unbind at once (second half of #29).** `onUnbind` raises its own alert
  (`accessibility_off`, deduped by the moment it happened) instead of leaving it to the 60-second poll — and on a
  phone where the location grant is off, that poll never runs, so this was the only report of a protection that
  had been switched off. The state the poll reads is written with it, so the poll does not repeat the same event.
