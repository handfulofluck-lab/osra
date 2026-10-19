# ADR-0026 — Multi-window coverage for the lock and block overlays

- **Status:** accepted
- **Date:** 2026-10-19
- **Deciders:** Kimi Code (development lead), implementing #175 from Claude's review of #171
- **Related:** #171 (active-window-only decision), #165 (the window is authority over the event
  package), ADR-0010 (the lock overlay), `AccessibilityMonitorService`,
  `LockEnforcementPolicy`, `EssentialPackages`

## Context

#171 fixed the block decision to use `rootInActiveWindow` instead of the accessibility event's
package. That was the right authority, but it made the decision depend on **one** window. A blocked
app can be visible without being active:

- **Picture-in-picture.** The child starts a video in a blocked app and presses Home. The active
  window is the launcher, which is essential, so the decision is ALLOW. The video keeps floating
  and playing; nothing ever evaluates the video app.
- **Split screen.** The blocked app sits beside the launcher or the dialer. Tapping the essential
  half makes the essential app active, ALLOW follows, and the blocked app stays on screen.

Before #171 the blocked app's own content-change events named it, so it was covered by accident.
#171 removed that accident, which is why this is a gate regression rather than a new feature gap.

Two platform facts constrain the fix:

1. `AccessibilityWindowInfo` exposes every visible window (the service already configures
   `flagRetrieveInteractiveWindows`) and `isInPictureInPictureMode` (API 26, the app's `minSdk`).
   It exposes no way to **close another application's** PiP window.
2. `Activity.setPictureInPictureParams` is a method on the target activity. `ActivityOptions` has no
   public windowing-mode setter (`setLaunchWindowingMode` is hidden), so this app cannot force its
   own overlay out of a split-screen task through launch options.

## Decision

1. **Judge every visible application window.** Once per accessibility event the service takes a
   `WindowSnapshot`: the active package plus every `TYPE_APPLICATION` window, including its PiP
   flag. `EssentialPackages.blockCandidates(active, visible)` returns the active app first and then
   the rest, skipping the framework package, our own package and the statically essential names;
   the OS-assigned HOME/dialer roles are still applied by `RuleRepository.decide`. Every candidate
   is evaluated with the same rules, and the first non-ALLOW answer gets the overlay.
2. **The lock treats a visible non-exempt window as "not covered".** `LockEnforcementPolicy` now
   answers from the snapshot: an active call surface still wins (never cover the dialer), any other
   visible non-own non-exempt window means the overlay comes back, and our own overlay **in PiP** is
   explicitly not coverage — it may be replaced.
3. **The overlays are full-screen activities, not multi-window participants.** `BlockActivity` and
   `LockActivity` declare `android:resizeableActivity="false"` and
   `android:supportsPictureInPicture="false"`. The system launches a non-resizable activity
   full-screen, which is the only public mechanism available to leave split screen; neither activity
   can become a PiP window of its own.
4. **Re-raising is bounded.** `OverlayRetryBudget` allows three raises per
   `WindowSnapshot.signature` and then logs once and stops. A changed signature (PiP closed, split
   left, another app opened) resets the budget. A state the platform refuses to change therefore
   cannot start an activity on every accessibility event forever.
5. **Every node and window is recycled.** `rootInActiveWindow`, each window's `root` and the
   windows themselves are obtained per event; on API 26–32 an unrecycled `AccessibilityNodeInfo` is
   a native leak, and the service can walk this path ten times a second.
6. **No audio-focus pause yet.** Pausing media through `AudioManager` is a possible next step if
   measurement shows a PiP window staying above the overlay, but it depends on each app honouring
   focus loss and changes device audio behaviour. The #175 hardware row decides that, not a guess.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| Ask the target app to leave PiP (`Activity.setPictureInPictureParams`) | The method belongs to the target activity; an accessibility service cannot call it. |
| Close PiP by clicking its accessibility close button | Package- and OEM-specific view hierarchy; a wrong node clicks arbitrary app UI. Not a gate. |
| `AudioManager` transient focus request while the overlay is up | Plausible, but unverified without the #175 hardware row, and it pauses other audio only when the app honours focus loss. Deferred, not silently added. |
| Suspend or force-stop the package with device-owner powers | Requires the DPC tier (the project deliberately supports the accessibility tier), kills the app's state, and is a much larger product decision. |
| `GLOBAL_ACTION_TOGGLE_SPLIT_SCREEN` to leave split | A toggle is not an exit: its behaviour when already split varies by OEM/SystemUI, and it can open the split flow instead. The non-resizable launch is deterministic where it is honoured. |
| Issue a real keyguard lock (`lockNow`) | Needs device admin (blocked on the test phone's stale row, #181) and changes the product: bedtime means an overlay, not the device lock. |

## Consequences

- A split-screen sibling and a PiP window are now named by the block decision and by the lock's
  re-raise trigger. The one-gesture bedtime/school-hours bypass in #175 is closed at the decision
  level.
- Split screen is left because the overlay is launched full-screen. On **large screens running
  Android 12+** the system may ignore `resizeableActivity="false"`; there the bounded re-raise is
  the fallback, and if the system also refuses to move the overlay, the measurement (not the code)
  says so.
- **PiP is not dismissed by this change.** Android keeps a PiP window above a fullscreen activity;
  if the measurement shows the video still playing over the overlay, the block is correct but the
  visual gate is incomplete until a media-pause mechanism is decided. That row is blocked on the
  Flip4 by its stale Knox admin record (#181), so this ADR claims no hardware result.
- Re-raising is deliberately finite: after three attempts for one unchanged window state the
  service stops and logs. A child who does nothing sees no further activity starts; a child who
  changes the state gets a fresh budget.
- Every event now walks the window list in addition to the active root: one extra binder read per
  window per event, at the existing 100 ms event throttle.

## Evidence

- JVM: `MultiWindowCoverageTest` (split, PiP, normal, the #171 background case, own overlay in PiP,
  exempt call surface, retry bound and signature stability). On the pre-fix tree the split, PiP,
  own-PiP and visible-window assertions fail; the raw run is in the #175 pull request.
- Merged-manifest gate: both flavours keep the same permission set; the new activity attributes are
  asserted by the existing `PlayMergedManifestTest`/`FullMergedManifestTest` merge, not by a source
  text check.
- Hardware: **not measured**. `R5CW116Y6GF` carries a stale Knox admin row (#181), so anything that
  needs device admin cannot be measured, and the #175 row (YouTube in PiP over Home, then split
  beside the dialer) needs a working run on a clean phone.
