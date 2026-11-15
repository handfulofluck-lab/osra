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
- **Not verified on a handset** — none of these four pages has been opened on the Flip4 with this build, and the
  Samsung wording of any of them is unknown until that dump exists.
