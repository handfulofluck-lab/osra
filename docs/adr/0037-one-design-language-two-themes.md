# ADR-0037 — One design language on every platform, with a Calm light theme and a Control room dark theme

- **Status:** accepted (2026-11-11); implementation not started
- **Deciders:** Karim (product, chose the two themes); Claude (architecture, wrote the language); implemented by
  Kimi (parent app, Android, API), Ahmed (iPhone) and the desktop lane
- **Related:** roadmap 3.8 (the token layer this builds on), ADR-0034 (the capability report the protection line
  reads), ADR-0019 (safe-direction commands), ADR-0036 (macOS), roadmap 3.10 to 3.18 (the work)

## Context

The maintainer reviewed the parent app and OSRA Kids on 2026-11-11 and asked for a redesign: *"we need a UI that
projects confidence and clarity to the parents with clear readable dashboard that is easy to understand … the top 20
features should all be very easy to make, then other more demanding features should be less visible … the UI should
give options to turn on and off some capabilities like bed time, i can have daily time but maybe not a bed time …
the days assigned to a rule should be per option and not per page."*

What the screens on `main@a5e321d` show:

- The parent picks a child in several places. The child page has tabs Overview, Apps, Social, Location, and a
  separate Edit rules screen has tabs Screen time, Web filter, Apps, Routines, with one Save for all of them.
- Home shows coordinates, an unexplained "Wellbeing 100/100", and nothing about whether protection is working.
- The device card has seven command buttons (Delivery status, Ring, Lock, Unlock, Pause, Resume, Pause net).
- Bedtime has no switch and no days. The daily limit is a slider in minutes with one weekday and one weekend value,
  and the Android agent treats Saturday and Sunday as the weekend. The first market has many families with a Friday
  and Saturday weekend.
- Alerts read "App blocked · Blocked app" with no child or app name, and the detail shows a geofence id.
- OSRA Kids shows ids, a server address and unstyled buttons.

Three looks were drawn on the same structure. The maintainer chose two of them as the two themes and asked for the
same language on iOS and Android, and as far as possible on Windows and macOS.

## Decision

1. **`docs/design/DESIGN-LANGUAGE.md` is the contract** for every screen of the parent app and OSRA Kids on every
   platform, and `docs/design/tokens.json` is the one source of colour, radius, spacing and type. A platform
   theme that differs from `tokens.json` is a bug.
2. **Light is Calm, dark is Control room.** The app follows the system setting by default; the parent can choose.
3. **One layout, two themes.** A theme changes colour, corner radius and the numeric typeface. It does not move,
   add or remove a control. Control room's map-and-rows first screen becomes the Map tab in both themes, and its
   week chart joins the child page in both themes, so nothing the maintainer approved in either drawing is lost.
4. **The parent app is organised by child.** Home has one card per child. One child page shows and changes
   everything for that child. The separate rules editor, its tabs and the global Save are removed.
5. **Three actions**: Pause, Ring, More time. Pause asks what (whole phone or internet only) and for how long. The
   wire commands stay as they are.
6. **Every rule is a card with its own switch and its own days**, edited in a sheet with one Done. Bedtime, School
   time and routines are presented as one family, Schedules.
7. **Protection is stated on every child card** from the ADR-0034 report, and every rule set states whether it has
   reached the phone.
8. **OSRA Kids is a product surface**: time left, what is next, a way to ask, and what parents can see. Technical
   detail moves to a hidden diagnostics page.
9. **A screen is accepted against its reference image in both themes, in English and Arabic**, and the redesign is
   accepted by the task test in section 8 of the design language.

## Why not the alternatives

- **Keep the structure and restyle it.** Rejected: the cost to the parent is the structure (re-picking the child,
  two places for one rule, one Save for four tabs). New colours on it change nothing a parent feels.
- **Let each theme keep its own layout, as first drawn.** Rejected: a parent who switches theme, or whose phone
  switches at sunset, would find the buttons moved. It also doubles every screen's tests and every Arabic review.
- **A separate design per platform.** Rejected: the maintainer asked for one language, and a family often has an
  Android parent and an iPhone child. The words and the order of actions must match across the two.
- **Seven day chips on every closed rule card.** Rejected: eight rules would show fifty-six chips. Days live inside
  the open sheet; the closed card shows a sentence.
- **Keep the Wellbeing score on Home.** Rejected until each point traces to a finding the parent can read.

## Costs

- Most parent-app screens are rewritten, with their widget tests and Arabic strings. The Arabic needs the
  maintainer's review again.
- Section 7 of the design language adds fields to the rule set (`enabled` and `days` on bedtime, `enabled` on
  school hours and routines, a limit per weekday, an end time on pause). Each needs an API change, a migration and
  an agent release on four platforms, with old agents kept working.
- Two bundled font families add to the app size (IBM Plex Sans and IBM Plex Sans Arabic, Plex Mono for dark).
- On iPhone the design is limited by what Apple's Screen Time framework lets the parent's phone see and choose.
  Those cards say so instead of matching Android.
- This work competes with the Play launch items for the same developer. It is sequenced after them (roadmap note).

## Evidence

- The maintainer's request and choice: project thread of 2026-11-11 (15:37Z and 15:59Z).
- Code facts: `packages/shared-types/src/index.ts` (`ScreenTimeRule`, `Routine`),
  `apps/child-android/.../data/RuleEngine.kt` (`isWeekend`, "Bedtime (every day)"),
  `services/api/src/routes/devices.ts` (`CommandSchema`), all at `main@a5e321d`.
- Contrast of every text pair in `tokens.json` was computed; the lowest is 6.19:1 (warning text on the light page).

## Claims a verifier should test

1. Every colour in a platform theme equals its value in `tokens.json`.
2. Switching theme changes no widget's position or presence on any reference screen.
3. With bedtime off and a daily limit on, the child phone enforces the limit and no bedtime.
4. A daily limit of 5 h on Friday and Saturday and 4 h on other days is enforced on those days on a phone whose
   locale has a Friday and Saturday weekend.
5. With app blocking revoked on the child phone, the parent's Home shows "Needs attention" within one report cycle.
6. No parent screen shows a coordinate pair, a package name, a UUID or the word "Severity".
