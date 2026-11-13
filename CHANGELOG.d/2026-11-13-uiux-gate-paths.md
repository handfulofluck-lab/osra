### Process — every screen needs the UI/UX Bureau before merge; gate fails closed without main's policy
- The maintainer's rule of 2026-11-13 18:44Z ("any screen should have the UI/UX Bureau OK before it goes") is now
  enforced by `verified-gate`: the UI/UX path list in `scripts/verified-gate-policy.mjs` covers the whole parent
  app (with its Android `MainActivity` and iOS `Runner/`), every Android resource and manifest (all source sets),
  Android screen, overlay, composable, `ui/`, copy and tile code, the six Android files that build notifications or
  covers in code, the iOS app shell, extensions, resources, shield text and SwiftUI views, the desktop lock overlay,
  dialogs, SOS prompt, block page, `Resources/` and `.xaml`, asset catalogs and string files, the API email templates
  and push alert choice (`notify.ts`), the website and its build script, and `docs/store/` + `docs/design/`.
  Test files alone never trigger it.
- The Bureau's only waiver, `UIUX-Bureau: not user-visible <head sha>`, counts when the comment is signed as the
  Bureau and answers a path match only; a `needs:uiux` label still needs a real review.
- The gate no longer falls back to the PR's own copy of the policy: if `origin/main`'s copy cannot be read, it fails
  closed.
- The policy self-test grows to 155 cases. AGENTS.md §6.6 records the rule, the standards (ADR-0038, Material 3,
  Apple HIG, WCAG), that the review is of the whole screen on a device picture in light and dark, English and
  Arabic, and the waiver.
