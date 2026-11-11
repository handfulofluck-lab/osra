# 0036 — The macOS child agent: Apple's Screen Time is the floor, OSRA is the cross-platform layer above it

- **Status:** proposed (2026-11-11). The design is Claude's call (architecture); the **timing** is the
  maintainer's (product scope) and is put to him as one question.
- **Roadmap:** new row **5.9** (design recorded; build not started). Not part of the Phase 5 gate.
- **Deciders:** Claude (architecture); Karim (timing)
- **Supersedes:** the "Screen Time path (macOS 13+)" paragraph and next step 4 of
  `apps/agent-macos/README.md`, which assumed `FamilyControls` works on macOS. It does not (below).

## Context

macOS 27 shipped with redesigned parental controls, and the maintainer asked (2026-11-11) that the OSRA
MacBook client use the latest features and that we say how that gives OSRA an edge over the competition.
Before designing, every claim below was checked against Apple's own pages on 2026-11-11, not against
memory or third-party blogs. Where something could not be confirmed it is marked **unconfirmed**.

### What macOS 27 adds (Apple's own pages)

Apple's newsroom (June 2026 preview, September 2026 release) and the macOS 27 "What's new" page list, for
iOS 27, iPadOS 27 and macOS 27:

- simpler **child account** setup with age-based safeguards (required under 13, available to 18);
- **Ask to Browse**: a child asks before opening a new website **in Safari**; the parent approves in
  Messages. Apple names Mac explicitly for this one;
- **Time Allowances** by category (Entertainment, Games, Social Media) with age-based suggestions, and
  **Schedules** by time of day and weekday;
- a redesigned **Screen Time** with faster sync, weekly summaries, most-used apps, **pause** and
  temporary extensions. It needs **every device in the Family Sharing group on version 27**;
- **contact approval** in Messages, FaceTime and Phone; **Communication Safety** now also blocks
  violent imagery.

All of these are configured **by a parent on an Apple device through Family Sharing**. None of them is
described as something a third-party app can switch on, read or extend.

### What a third-party app can actually use on a native Mac (Apple developer documentation, 2026-11-11)

| Framework | Platforms Apple lists | Use for OSRA on a Mac |
|---|---|---|
| `FamilyControls` | iOS 15, iPadOS 15, Mac Catalyst 15 | **No.** `AuthorizationCenter.requestAuthorization(for:)` is listed for **iOS and iPadOS only**, so even a Catalyst build cannot get authorisation. |
| `ManagedSettings` / `ManagedSettingsUI` | iOS, iPadOS, Mac Catalyst (tvOS 26 for the store) | **No** without the authorisation above. |
| `DeviceActivity` | iOS, iPadOS, Mac Catalyst | **No** without the authorisation above. |
| `DeclaredAgeRange` | iOS 26, iPadOS 26, Mac Catalyst 26, **macOS 26** | **Yes.** Ask for the child's age band without the birthday. |
| `PermissionKit` (`AskCenter`) | iOS/iPadOS/macOS **26.2**, visionOS | **Narrow.** Built for parent approval of new contacts inside an app's own communication; OSRA has no chat. |
| `SensitiveContentAnalysis` | iOS 17, **macOS 14** | **Narrow.** Its policy tells an app whether Communication Safety is on for this user. |
| `NetworkExtension` content filter (`NEFilterManager`, data provider) | **macOS 10.11+** as a system extension | **Yes.** All-browser, all-app web filtering on a Mac. |
| `EndpointSecurity` | **macOS 10.15+** | **Yes, gated.** Deny an app's launch (`AUTH_EXEC`). Needs a separate entitlement that Apple grants on request. |
| `ServiceManagement` (`SMAppService`) | **macOS 13+** | **Yes.** Install the agent as a root daemon the child cannot unload. |
| Declarative device management (macOS 27): binary execution control (built on Endpoint Security), the consolidated privacy consent prompt, app configuration | macOS 27, **MDM only** (WWDC26 session 206) | **Not for v1.** Needs OSRA to be an MDM server with Apple's MDM push certificate; whether an Individual developer account can obtain one is **unconfirmed** (we believe it needs an Organization account). |

**Unconfirmed, to test on the M2 (spike below):** that Apple's documentation is complete for macOS 27
(i.e. that `FamilyControls` really is absent on a native macOS 27 app, not merely undocumented), and that
an iPhone app run on an Apple-silicon Mac ("Designed for iPad") cannot get Family Controls authorisation.

### What already exists in the repo

- `apps/agent-macos/` — a never-compiled `net8.0-macos` (.NET) scaffold that writes a status file. Its
  README plans a `FamilyControls` shield layer that the table above rules out.
- `apps/child-ios/` (5.5, Ahmed) — a Swift package. Eight of its fourteen source files import no
  iOS-only framework (`AgentIdentityStore`, `SecretStore`, `InternalSigner`, `RuleSync`, `DeviceCommands`,
  `RoutineWindow`, `PushRegistration`, `ShieldText` with its en/ar strings); `ScreenTimeController`,
  `DeviceActivityMonitor`, `ShieldConfiguration`, `PairingClient`, `PairingView` and `Location` are the
  iOS-bound part (UIKit, FamilyControls, ManagedSettings, DeviceActivity, CoreLocation).
- `apps/agent-desktop/` (Windows, 5.4) — the desktop reference for usage counting, lock overlay,
  pause-internet and SafeSearch.
- ADR-0034 already reserves `agent-macos` as a client name in `X-OSRA-Client` and the capability report.

## Decision

1. **OSRA does not try to drive Apple's Screen Time on the Mac.** It cannot (no authorisation on macOS).
   Apple's macOS 27 controls are the **floor**: OSRA's setup guides the parent to turn them on, reports
   which are on, and adds what Apple does not do. We complement Apple; we do not fight it.
2. **The macOS agent is Swift, not .NET.** The .NET scaffold is retired when the build starts. A Swift
   agent shares the iOS package's core (point 6), and Network Extension and Endpoint Security clients are
   Swift/Objective-C system extensions in any case.
3. **Shape of the agent** (Developer ID, outside the Mac App Store, so the root daemon and system
   extensions are allowed):
   - **Daemon** (`SMAppService.daemon`, root, approved once by the parent as Mac admin): rule sync,
     command queue (ADR-0012), usage counting, capability report (ADR-0034), heartbeat for tamper alerts.
   - **Content-filter system extension** (`NEFilterDataProvider`): web categories and block list, SafeSearch,
     pause-internet, across **every browser** — the same rules and semantics as the Android DNS filter
     (ADR-0015). Visits flow into the existing `WebVisit` model (ADR-0013) behind the consent gate (ADR-0002).
   - **Per-user agent** (LaunchAgent, menu-bar): pairing, lock and bedtime overlay (a screen-saver-level
     window, the Windows `LockOverlay` pattern), block page, "ask for more time", Arabic and English.
   - **App blocking, two tiers.** Tier 1 (no special entitlement): watch the frontmost app
     (`NSWorkspace` notifications), cover it with the block overlay and terminate it, like the Android
     overlay. Tier 2 (if Apple grants it): an Endpoint Security client that denies the launch outright.
     The capability report says which tier is live, so the parent app never over-promises (ADR-0034).
4. **Tamper model: the child is a Standard user.** A Standard user cannot unload a root daemon or remove
   a system extension. Pairing checks the child's account type and warns the parent, in the app, when the
   child is an administrator ("protection is weak on this Mac"). A missed heartbeat raises the existing
   edge-triggered tamper alert (ADR-0027).
5. **Use the new Apple pieces that are open to us:** `DeclaredAgeRange` to propose the age-band rule
   preset at pairing (and to confirm a child account exists); `SensitiveContentAnalysis`'s policy to show
   whether Communication Safety is on; a **"Safeguard check"** card in the parent app listing which Apple
   protections are on for this Mac (child account, Standard user, OSRA filter active, Communication
   Safety) with a guided fix for each. PermissionKit and the MDM route are recorded as later options,
   not v1.
6. **Share with iOS by making the Swift package multi-platform.** `apps/child-ios/Package.swift` gains
   `.macOS(.v14)`; the eight portable files compile for both; the enforcement layer moves behind one
   protocol (`EnforcementBackend`: `ScreenTimeBackend` on iOS, `FilterAndOverlayBackend` on macOS). One
   pairing flow, one HMAC signer (ADR-0003, ADR-0014), one rule interpreter, one en/ar string table.
   This refactor is done by the iOS owner after the iOS TestFlight build, never in the middle of 5.5.

## Why not the alternatives

- **Use `FamilyControls`/`ManagedSettings` on the Mac, as the old README planned.** Apple lists
  authorisation for iOS and iPadOS only; on a Mac it is not available to third parties.
- **Ship only a setup guide that turns on Apple's controls.** It costs nothing, but it fails exactly the
  families OSRA is for: Apple's new Screen Time needs every family device on version 27 and a parent on an
  Apple device, and Ask to Browse covers Safari only. A parent with an Android phone cannot manage the
  Mac at all. The guide is kept as part of the product (the Safeguard check), not as the whole of it.
- **Become an MDM now** (the macOS 27 binary execution control and consent prompt are attractive). It
  needs an MDM push certificate, likely an Organization developer account, an enrolment flow parents find
  intimidating, and it puts OSRA in the device-management business before the phone product ships. Kept
  as a later option.
- **Keep the .NET scaffold.** It shares nothing with the iOS agent, and the parts that matter on a Mac
  (filter, Endpoint Security) are native extensions .NET cannot be.
- **Run the iPhone agent on the Mac ("Designed for iPad").** Family Controls is not expected to authorise
  there (unconfirmed; tested in the spike) and it would enforce nothing at the Mac level.

## Competitive position

Sources are listed under Evidence; anything about a rival not shown there is marked unverified.

- **Apple's own controls** are free and now strong, but all-Apple: every family device on 27, parent on an
  Apple device, Ask to Browse in Safari only. **OSRA's edge:** a parent on Android or iPhone runs one
  rulebook for the child's Android phone, iPhone, Mac and Windows PC; bedtime and pause hit every device
  at once; filtering covers every browser; Arabic first.
- **Qustodio, Net Nanny, Norton Family, Mobicip** run their own filters and time limits on Mac (reviews,
  2026). They replace Apple's controls. **OSRA's edge:** we stack on top of Apple's free floor and show the
  parent which Apple safeguards are on (Safeguard check), plus the AI concern alerts on search terms
  (Phase 4), with bounded snippets rather than full surveillance (ADR-0006) and EU hosting (ADR-0030).
- **Bark** is monitoring-led (alerts across services) rather than enforcement-led on Mac (review, 2026).
  **OSRA's edge:** both enforcement and Arabic-aware alerts in one product.
- **Aura:** its Mac support is **unverified**; not claimed either way.

The honest limit: on a Mac, OSRA's app blocking is an overlay-and-terminate until Apple grants Endpoint
Security, and Apple's own Screen Time engine stays out of reach.

## Timing (the maintainer's call)

Claude recommends: **record the design now, run a one-day feasibility spike on the M2 now, and start the
build after the iOS TestFlight build (5.6)**, aiming at a Mac beta in Q2 2027. Reasons: 5.1 (the Family
Controls request) is not filed and gates the iOS date; the Mac agent reuses the iOS core, which should
settle first; the Android beta (mid-to-late December) and iOS are the launch path; the Windows agent (5.4)
is the desktop work already on the roadmap.

**Spike (no product code, results recorded on this ADR's PR or its follow-up):** on the M2 with
macOS 27, (a) a native macOS test target calling `AuthorizationCenter` does not compile or is
unavailable; (b) the iOS child agent installed as "Designed for iPad" cannot obtain authorisation;
(c) a Developer-ID-signed `NEFilterDataProvider` system extension activates on a Standard user and
blocks a test domain in Safari and Chrome; (d) `DeclaredAgeRange` returns a band for the test child
account.

## Costs

- A fourth native agent to maintain, and two system extensions that each need user approval in System
  Settings during setup (a parent-at-the-Mac step).
- Tier 1 app blocking is beatable by a fast child for a second or two; only Tier 2 closes it, and Tier 2
  depends on Apple granting Endpoint Security.
- The Network Extension capability for a content filter must be enabled on the developer account (a
  portal step, not expected to need a special request — **unconfirmed** until done).
- The shared Swift package adds a macOS build to iOS CI.

## Evidence

- Apple developer documentation platform lists, read 2026-11-11 from developer.apple.com:
  `familycontrols`, `familycontrols/authorizationcenter`, `.../requestauthorization(for:)`,
  `managedsettings`, `managedsettings/managedsettingsstore`, `deviceactivity`, `declaredagerange`,
  `permissionkit/askcenter`, `sensitivecontentanalysis`, `networkextension/nefiltermanager`,
  `endpointsecurity`, `servicemanagement/smappservice`.
- Apple Newsroom, "Apple previews new child safety features" (June 2026) and "Apple's new child safety
  features now available" (September 2026); Apple Support, "What's new in macOS 27".
- WWDC26 session 206, "What's new in managing Apple devices" (declarative binary execution control,
  consolidated privacy consent prompt, app configuration on macOS 27).
- Mac parental-control reviews (iGeeksBlog, 2026) for Qustodio, Net Nanny, Norton Family, Mobicip, Bark.
- Repo: `apps/agent-macos/README.md`, `apps/child-ios/Sources/FamilyShieldAgent/*.swift` imports,
  `apps/agent-desktop/Services/`, ADR-0002, 0003, 0006, 0012, 0013, 0014, 0015, 0027, 0030, 0034.
