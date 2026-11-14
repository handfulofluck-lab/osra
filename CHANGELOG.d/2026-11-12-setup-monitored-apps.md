### Parent app — the parent picks the monitored apps during setup (Play decision 14 A)
- **Before:** message monitoring was on for every supported app unless a parent found the rules screen later and
  turned one off. The data-safety answer could not call that "optional", and the consent card could not honestly
  say the parent opted in.
- **After:** a **Which apps should OSRA watch for you?** step between pairing and the hand-over. All eight
  supported apps are listed and **all ticked**, which keeps the product default; unticking one writes it off
  through the same `socialMonitoring` map the rules and social screens already edit — no new model.
- **The consent numbers are on the screen**, not only in a policy: a flagged excerpt is kept 90 days, an alert
  12 months, and nothing is read from an app the parent leaves unticked.
- **It is one route and one file** (`/setup/monitoring`, `setup_monitoring_screen.dart`), so the onboarding
  redesign (#557) can move it without touching the welcome or done screens.
- Skipping pairing still goes straight to the hand-over: with no phone there is nothing to monitor yet, so the
  step would write to nothing.
- Rows: `setup_monitoring_test.dart` (6) — all eight ticked, the list is `kSocialApps` itself rather than a copy,
  the retention numbers are on screen, unticking one leaves the rest, Arabic renders, and a missing `childId`
  does not dead-end onboarding. Parent suite **603/603**.
- **Arabic is a draft pending Karim**, as every new Arabic string is.
