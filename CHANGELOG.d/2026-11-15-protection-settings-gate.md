### Switching OSRA's own permissions off is behind the parent PIN (osra-security#29, osra-security#30)
- Found on the Flip4 (AS02, 14 Nov) and tracked privately as osra-security#29, osra-security#30: two system surfaces that
  change the agent's own permissions opened **without the parent PIN**.
- Those pages are now protection screens (`TamperScreen.PROTECTION_SETTINGS`), classified by window class —
  the accessibility detail pages (AOSP, Google, Samsung) and the PermissionController pages
  (`ManagePermissionsActivity`, `AppPermissionsActivity`, `PermissionDetailsActivity`). The PermissionController
  package joins the system packages the classifier recognises, because Android 11+ keeps those pages there.
- The guard still fires only when the screen **names the agent**: the same two pages exist for every app on the
  phone, and a row asserts Chrome's and the camera's stay `NONE`.
- **The unbind is not prevented, only reported** — at once, by `onUnbind` (`accessibility_off`), rather than by
  the 60-second poll, which on a phone without the location grant never runs at all. The alert retries without a
  cap, because the state the poll reads is written before the POST.
- Verified by JVM tests only (`TamperScreenPolicyTest` and `TamperAlertWorkNameTest`). **Not verified on a handset**: both
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
- **Part 2 (osra-security#29): the sibling special-access pages.** Display over other apps, usage access, notification
  access and the VPN entry are protection screens when the page names the agent **and we already hold that access** —
  the same shape as the admin and location gates, because onboarding opens those very pages to grant them. The
  class names are fragment hosts on current builds, so the page's own words are the signal, as they had to be for
  the accessibility page. Not wired to a device yet; the Flip4 rows are owed.
