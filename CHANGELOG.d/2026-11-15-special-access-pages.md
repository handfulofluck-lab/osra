### The sibling special-access pages are behind the parent PIN (osra-security#29, part 2)
- Display over other apps, usage access, notification access and the VPN entry are protection screens
  when the page names the agent **and we already hold that access** — the same shape as the admin and
  location gates, because onboarding opens those very pages to grant them.
- The class names are fragment hosts on current builds, so the page's own words are the signal, as they had
  to be for the accessibility page. The branch is scoped to Settings, and the VPN words name the
  management actions (`always-on vpn`, `forget vpn`, `vpn profile`) rather than the letters.
- **The visit is judged by what we held when it began**: those pages carry an inline toggle, so without the
  latch a grant made during onboarding would trip the gate on the content change that follows it.
- **The Arabic phrases are published, sourced ones**: the overlay title and switch, the usage title (12–15) and
  switch (16), the notification-access switch, and the VPN management phrases (always-on, forget, profile, stay
  connected, per version), each taken from Google's `values-ar` for Android 12 to 16 and folded by `normalize()`.
  The VPN phrases are Google's too: the Bureau quoted them verbatim from the same files, in its note on
  osra-security#29 of 2026-11-15, which corrects what an earlier draft of this fragment said. One English phrase
  the policy used to carry, `permit access to app usage data`, is **not** listed separately: `app usage data` is a
  substring of it, so the longer entry could be deleted without any row noticing. The test feeds the longer label
  and shows the shorter phrase matches it.
- **Direction marks and the Arabic letter mark are formatting, not text.** `normalize()` drops U+061C, U+200E,
  U+200F, U+202A–U+202E and U+2066–U+2069, because Google's Arabic lines that name a Latin word begin with U+200F
  and a mark inside a phrase would otherwise defeat `contains`. Two rows put a mark **inside** the phrase, where
  removing the strip turns them red; a mark only at the start would match anyway.
- **The lists are identified by their activity class, not only their words** (Antigravity's Flip4 pass on One UI
  8.0, 15 Nov). The overlay and usage lists carry a **Search apps** bar, and opening it replaces the page title with
  "Search apps" — so the phrase that named the page was gone and the child could toggle us off with no PIN, in
  English and Arabic alike. Notification access and the VPN list have no search control on One UI 8.0, so there the
  title still works; the class identifies all five either way. `SPECIAL_ACCESS_CLASSES` covers `OverlaySettingsActivity`,
  `UsageAccessSettingsActivity`, `AppUsageAccessSettingsActivity`, `NotificationAccessSettingsActivity` and
  `NotificationAccessDetailsActivity`, and the words still carry the VPN gear page (`SubSettings`) and split-screen
  (a null class).
- **The words from the Flip4 dump are in**: One UI 8.0's own Arabic titles («الظهور في الأعلى», «وصول بيانات
  الاستخدام»), the Arabic and English function descriptions the Search results show, and the VPN gear page in
  ar-AE (`تشغيل vpn دائما`, `حظر الاتصالات من دون vpn`, `حذف ملف تعريف vpn`, written here in the folded form the
  list stores, which is what the comparison uses) — the last of which deletes our profile with no PIN before this
  change.
- **A keyboard state change can no longer clear the latch.** The soft keyboard emits a state change with the IME's
  package, and the service read the latch package from the event — so typing in Search cleared
  `specialAccessLatch` and the location latch, turning a grant we hold into "the parent is granting it".
  `AccessibilityOffPolicy.latchPackage` prefers the foreground application package, and `windowClass` is read from
  the per-package class map (`#802 V5`'s `lastClassByPkg`) rather than the single global pair.
- **Device state**: Antigravity opened all four pages on the Flip4 (SM-F721B, One UI 8.0, ar-AE and en-GB) at
  `e131c080`, found the bypasses this change closes, and **re-ran the whole matrix at `526d513c`**: the bypasses and
  the keyboard-latch bug are closed in both languages, and the negative controls (browsing a list with OSRA
  off-screen, an unheld access's setup visit, the top-level VPN list) still do not raise the gate. The raw dumps
  live in the private report in `osra-security#29`. This author has still not driven the four pages himself.
