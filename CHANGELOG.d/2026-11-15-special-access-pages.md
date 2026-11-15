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
  switch (16), and the notification-access switch, each taken from Google's `values-ar` for Android 12 to 16 and
  folded by `normalize()`. Arabic for the VPN management phrases is deliberately absent: the Bureau described those
  by meaning without quoting them, and they land with the Flip4 dump.
- **Not verified on a handset** — none of these four pages has been opened on the Flip4 with this build, and the
  Samsung wording of any of them is unknown until that dump exists.
