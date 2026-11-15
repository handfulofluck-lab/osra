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
