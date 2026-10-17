# ADR-0016 — Play vs Full flavor split, and why notification capture lives only in Full

**Status:** accepted and implemented 2026-10-17 (plan item 2.6, second half; supersedes nothing)
**Date:** 2026-10-17
**Deciders:** maintainer decision of 2026-10-16 ("two Android builds: Play + sideloaded Full"), implemented here

## Context

The maintainer decided on 2026-10-16 that OSRA ships **two Android builds**: a Play build for the
store and a sideloaded "Full" build for families who want the stronger features. Plan 2.6's second half
needs `NotificationListenerService` to read WhatsApp notifications when the app is backgrounded —
which is the only way to see a message the child never opens.

Three facts constrain the decision:

1. **`BIND_NOTIFICATION_LISTENER_SERVICE` is a policy-sensitive permission.** Google Play restricts
   notification access for apps whose core purpose is not accessibility or device management; an
   unapproved declaration gets the app rejected or the permission revoked post-review. It is not a
   runtime prompt a parent can be talked through — it is a manifest declaration the store reviews.
2. **The permission is trivially abusable if shipped silently.** A parental-control app with
   notification access can read every notification on the phone, including banking OTPs and a
   co-parent's messages. Whatever we ship has to be visible in the build description and in onboarding,
   not discovered.
3. **The scan pipeline already abstracts the source.** `ScanQueuePolicy.SOURCE_SCREEN` and
   `SOURCE_NOTIFICATION` exist, `SocialScanQueue.enqueue(..., source)` takes the value, and the API's
   `ScanSchema` accepts it. So the listener is a *producer* into an existing queue, not a new pipeline.

## Decision

1. **Create the two flavors now** (`play`, `full`) rather than shipping one build with a runtime flag.
   The split is a build-time fact, so the store artefact physically cannot contain the declaration —
   a runtime flag would still ship the permission and be reviewable as such.
2. **`NotificationCaptureService` and its `<service>` + `BIND_NOTIFICATION_LISTENER_SERVICE`
   declaration live in `app/src/full/AndroidManifest.xml` only.** `main` declares neither. The Play
   build therefore has no listener, no permission, and no code path that could request one.
3. **One shared implementation, no forked logic.** The decision-making is the pure
   `NotificationCapturePolicy` in `main` (so both CI and the Play build still compile and test it),
   and only the manifest declaration and the service registration are flavor-specific. Nothing in the
   Play build can enqueue a notification capture because nothing in the Play build can receive one.
4. **The Play build says what it does instead.** On Play the app captures from the accessibility
   **screen** path (`SOURCE_SCREEN`, already shipped) and the onboarding row states that richer
   capture requires the Full build — a documented difference rather than a silently missing feature.
5. **A test asserts the manifest difference** (`FlavorManifestTest`), because a flavor split is exactly
   the kind of thing that silently regresses when someone "simplifies" the manifest later.

## Alternatives considered

- **One build, permission declared, gated at runtime.** Rejected: the store still sees the declaration,
  and a revoked permission would break every family at once. Also leaves the "can read every
  notification" capability on every install.
- **One build with the service in `main` but disabled by a remote flag.** Rejected: same review surface
  as above, plus a remote flag that turns on notification reading is a privacy story we cannot defend.
- **Rely on the accessibility service alone (no listener).** Rejected for 2.6's acceptance: the
  accessibility path cannot see a WhatsApp message the child never opens, which is precisely the case a
  parent needs. It stays as the Play fallback.
- **Separate APKs from separate source sets, no flavors.** Rejected: flavors are the supported Gradle
  mechanism, and hand-maintained duplicate apps drift.

## Consequences

**Good.** The Play artefact cannot read notifications even if a future change tries to; the capability
is visible in the build a family sideloads; the pipeline, queue and policy stay single-copy; the
manifest difference is tested.

**Bad, and accepted.** Two build variants to keep green (CI now builds `playRelease` and `fullDebug`),
and the Full build is the one most families will actually run — so the flavor that carries the
restricted permission is also the one with the least store oversight. Onboarding must therefore name it
plainly, and the 1.6 grant screen must show the notification-listener row only in Full.

**Neutral.** `BATCH_SIZE`, dedupe and rate limits are unchanged: the listener adds a producer, and the
queue's existing bounds apply to it exactly as they do to screen captures.

## Not decided here

Whether the Play build can ever apply for notification access under a declared accessibility use — that
is a maintainer/store decision (5.x), not an implementation one.
