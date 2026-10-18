# ADR-0021 — Google Play policy review of the child agent: what the Play build may declare

**Status:** accepted
**Date:** 2026-10-18
**Deciders:** Claude (architecture), on work order C2 in #92 (Kimi, development lead); roadmap 2.6 / Phase 5 release

## Context

ADR-0016 split the child agent into a `play` and a sideloaded `full` flavor, and put the notification listener
in `full` only (`apps/child-android/app/src/full/AndroidManifest.xml:10`). Work order C2 asks whether
`BIND_NOTIFICATION_LISTENER_SERVICE` is defensible on Play, what declaration it needs, and what the fallback is
if Google refuses. Answering that meant reading the whole `main` manifest, which both flavors inherit. That
turned up a bigger problem than the listener.

Policy text checked on 2026-10-18 (Play Console Help):

- **SMS and Call Log permissions** ([9047303](https://support.google.com/googleplay/android-developer/answer/9047303)).
  `READ_SMS` and `READ_CALL_LOG` are allowed only for the default SMS/Phone handler or a listed exception. Parental
  control and child safety are **not** listed. "Family or device locator" is named as an invalid use, and the
  enterprise exception is limited to "device management for corporate entities for their employees".
- **Stalkerware and Monitoring Applications** ([9888380](https://support.google.com/googleplay/android-developer/answer/9888380)).
  Monitoring is allowed for apps "exclusively designed and marketed for parents to monitor their children". Such
  an app must meet all of these:
  - show "a persistent notification at all times when the app is running" with "a unique icon that clearly
    identifies the app";
  - disclose monitoring in the store description;
  - not hide or cloak the tracking;
  - declare the `isMonitoringTool` manifest flag
    ([12955211](https://support.google.com/googleplay/android-developer/answer/12955211): value `child_monitoring`).
- **Accessibility API** ([10964491](https://support.google.com/googleplay/android-developer/answer/10964491)).
  A monitoring app is not an accessibility tool, so it can't set `isAccessibilityTool`. It needs:
  - a Play Console declaration;
  - an in-app prominent disclosure with affirmative consent, separate from other disclosures;
  - a video of that flow.

  Deterministic, rule-based actions are allowed; autonomous agent-style actions are not.
- **Broad package visibility** ([10158779](https://support.google.com/googleplay/android-developer/answer/10158779)).
  `QUERY_ALL_PACKAGES` is permitted for "device search, antivirus apps, file managers, and browsers". Parental
  control isn't named, so it would have to be argued as core functionality on the declaration form.
- **Notification listener.** No Play page lists it as a restricted permission with its own form (this is an
  inference from the absence of one, not a quoted clause). It falls under the User Data policy (prominent
  disclosure and consent) and the stalkerware rules above.

What `apps/child-android/app/src/main/AndroidManifest.xml` declares today, inherited by `play`:
- `READ_CALL_LOG` (line 17) and `READ_SMS` (line 18);
- `QUERY_ALL_PACKAGES` (11), `PACKAGE_USAGE_STATS` (12) and `SYSTEM_ALERT_WINDOW` (13);
- `ACCESS_BACKGROUND_LOCATION` (4);
- an `AccessibilityService` (24), a `VpnService` (38) and a device admin receiver (59).

No manifest in the repository declares `isMonitoringTool`.

## Decision

1. **The notification listener stays Full-only** (ADR-0016 holds). It would probably be defensible on Play as
   disclosed parental monitoring. However, reading other apps' message content is the capability most likely
   to get a monitoring app removed on review, and the Full build already delivers it. This answers C2's first
   question: defensible in principle, not worth the review risk now.
2. **`READ_CALL_LOG` and `READ_SMS` move to the `full` flavor**, together with `CommsLogger` and its harvest
   path. This works the same way as the listener: shared decision logic in `main`, with the Android binding
   and the permissions in `src/full/`. On Play these permissions have no qualifying exception, so declaring
   them gets the build rejected whatever the declaration says. This is the blocking finding of this review.
3. **`isMonitoringTool = child_monitoring`** is added to `src/main/AndroidManifest.xml` as
   `<meta-data android:name="isMonitoringTool" android:value="child_monitoring" />`, so both flavors carry
   it. The Full build carries it too, because Play Protect uses it on sideloaded installs as well.
4. **Persistent notification.** The agent's foreground service notification must be shown whenever any
   monitoring component runs, with OSRA's own icon. It must not be a silent or hidden channel. This becomes
   a test row (below), because the policy says "at all times when the app is running".
5. **`QUERY_ALL_PACKAGES` is replaced in `play`** by a `<queries>` element with the launcher intent
   (`MAIN` / `LAUNCHER`). That gives the user-visible apps, which is what app limits and the app list need.
   `full` keeps the broad permission. If a feature turns out to need non-launcher packages on Play, it goes
   on the declaration form with that feature named; the permission isn't declared by default.
6. **Accessibility** stays in both builds, with the Play Console declaration, an in-app disclosure screen
   (separate from the general privacy screen, affirmative tap, explains why) and the required video. Its
   actions stay deterministic and rule-based (block screen, back-out of a blocked app), which the policy
   permits.

## Fallback if Google refuses

- **A refusal of a single capability:** that capability moves to `full` the same way (decision logic shared,
  binding and permission in `src/full/`), and the Play listing stops naming it.
- **A refusal of the monitoring category as a whole:** OSRA ships `full` only, from its own signed download
  page. Play Protect will warn on install because of the `isMonitoringTool` flag, and onboarding has to say
  so. That is the cost of honesty under this policy.

## Consequences

- Good: the Play build declares nothing that has no route to approval, so the first submission isn't spent
  learning that.
- Cost: on Play, call and SMS logs are gone. The parent app has to show "available in the Full build" rather
  than an empty list. This belongs to the plan 2.6 part 3 onboarding row.
- Cost: #94 (`fix/91-commslogger-guard`) touches `CommsLogger`, which this ADR moves. #94 can land first,
  and the move follows as its own PR.
- Tests that must exist before the next Play build:
  - **Merged-manifest test (extends ADR-0016's):** the `play` merged manifest contains none of
    `READ_CALL_LOG`, `READ_SMS`, `QUERY_ALL_PACKAGES` or `BIND_NOTIFICATION_LISTENER_SERVICE`, and both
    flavors contain `isMonitoringTool=child_monitoring`. It fails on `main` today.
  - **Hardware row:** with the agent running, `adb shell dumpsys notification --noredact` lists OSRA's
    ongoing notification with its own small icon, and the notification is still there after the agent
    restarts.

## Not decided here

- The store listing text and the data safety form; they come with the Phase 5 release.
- `ACCESS_BACKGROUND_LOCATION` has its own Play location policy and declaration. It's in scope for the
  Phase 5 release review, not this ADR.
