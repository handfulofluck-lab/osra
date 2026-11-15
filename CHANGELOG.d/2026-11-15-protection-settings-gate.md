### Switching OSRA's own permissions off is behind the parent PIN (#29, #30)
- Found on the Flip4 (AS02, 14 Nov): Settings → Accessibility → Installed apps → OSRA turned the agent's
  accessibility service off **with no PIN**, and app blocking stopped at once. Permission manager → Location →
  OSRA does the same to the location grant (osra-security#30).
- Those pages are now protection screens (`TamperScreen.PROTECTION_SETTINGS`), classified by window class —
  the accessibility detail pages (AOSP, Google, Samsung) and the PermissionController pages
  (`ManagePermissionsActivity`, `AppPermissionsActivity`, `PermissionDetailsActivity`). The PermissionController
  package joins the system packages the classifier recognises, because Android 11+ keeps those pages there.
- The guard still fires only when the screen **names the agent**: the same two pages exist for every app on the
  phone, and a row asserts Chrome's and the camera's stay `NONE`.
- **Half of #29.** The unbind itself is not prevented — a route this classifier has not seen still switches the
  service off, and when it is unbound the guard is gone with it. The immediate-unbind alert is a separate change.
- Verified by JVM tests only (`TamperScreenPolicyTest`'s three new rows). **Not verified on a handset**: both
  pages on the Flip4 under the lease.
- **Two signals, not one (Fable's review).** The accessibility page is guarded when the screen carries our own
  `accessibility_description`, in whatever language the phone is in — that survives OEM renames and the fragment
  hosts current Settings builds use — and the PermissionController pages are guarded on the package plus our name
  alone. The class list stays as a second opinion, not as the gate.
- **The list pages are guarded too, deliberately.** Accessibility → Installed apps and Permission manager →
  Location both list several apps; a screen there that names OSRA opens the gate even when the parent is
  managing another app. That is fail-safe and it is a cost: it is recorded here so it is a decision, not a
  surprise.
- **Other doors, tracked on osra-security#29 rather than here:** usage access, display over other apps,
  notification access and the VPN entry are the same class of screen and are not covered by this change.
- **The parent hears about an unbind at once (second half of #29).** `onUnbind` raises its own alert
  (`accessibility_off`, deduped by the moment it happened) instead of leaving it to the 60-second poll — and on a
  phone where the location grant is off, that poll never runs, so this was the only report of a protection that
  had been switched off. The state the poll reads is written with it, so the poll does not repeat the same event.
