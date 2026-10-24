# ADR-0034 — Each device reports what it can enforce, and every client says which build it is

- **Status:** accepted (architecture); implementation not started
- **Date:** 2026-10-24
- **Deciders:** Claude (architecture + testing); to be implemented by Kimi Code (development lead)
- **Related:** ADR-0028 decision 4 (the capability list and the version gate, named but not designed),
  ADR-0027 (edge-triggered tamper alerts), ADR-0016 §4 (the Play and Full builds), issue #221 (the
  location grant report this generalises), issue #368 (a lock acknowledged while no lock screen could
  show), roadmap 5.8 open items (1) and (2)

## Context

ADR-0028 decided, in one sentence, that each device reports a capability list and every client sends
its app version, so that the server can say "update required" and families with mixed phones get
honest screens. Neither half exists. Roadmap 5.8 lists both as open engineering items before launch.

**What the server knows about a child's phone today** is its platform, model, OS version, battery,
last-seen time and one grant: `locationGrant` (`background`, `while_in_use` or `none`), added for issue
#221. That one field already shows the pattern working. The agent reports what its own
`LocationStartPolicy` decided, the server stores it with a timestamp (`locationGrantReportedAt`), and
`POST /v1/devices/:id/command` records a `locate_now` as failed at once, with the agent's own reason and
without waking the phone, when a report younger than 20 minutes says it cannot work
(`services/api/src/lib/locationGrant.ts`).

**Everything else the agent needs is invisible to the server and to the parent:**

- The agent checks nine grants on the phone (`OnboardingPolicy.Grant`, checked by `GrantChecks`):
  accessibility, usage access, overlay, device admin, web filter (VPN consent), location, Private DNS,
  battery, and notification access (Full build only).
- When one is missing, the parent finds out only from a failed acknowledgement, after a command was
  sent. Issue #368 was measured on the Flip4 today: the overlay grant had never been given, a lock
  reached the dozing phone in under 2 seconds, `LockActivity` was blocked from opening, and the agent
  acknowledged the lock anyway. The parent app said "locked". The phone was not.
- The build is invisible too. The Play and Full builds can do different things (ADR-0016 §4). Nothing
  tells the server which one a phone runs.

**What the server knows about client versions:** the parent app sends `appVersion` only when it
registers a push token (`routes/me.ts`). The child agent sends nothing. The installed-apps report
carries a contract number (`Device.appsVersion`), which is the one place a request shape is versioned.
So a stale APK whose requests no longer match is either silently half-understood (`TelemetrySchema` is
`.passthrough()`) or refused with a 400 that nobody sees. And there is no way to tell a parent "update
the app" before a change that needs it.

Two constraints shape the design:

- **The idle budget.** Roadmap 5.8 caps an idle child phone at 3 requests per 10 minutes (#353, #367).
  Neither half may add a request on a schedule.
- **A child may prefer an old agent.** Refusing an out-of-date child agent would stop rule updates and
  commands from reaching the phone. That is exactly what a child avoiding an update would want, so a
  version gate on the child side can only ever warn, never cut off.

## Decision

### 1. One capability report, computed on the device, in one shared vocabulary

The agent sends a `capabilities` object, defined once in `packages/shared-types` as
`DeviceCapabilitiesV1`. It has three parts:

| Part | Content | Who reads it |
|---|---|---|
| `client` | `app` (`child-android`, `child-ios`, `agent-desktop`, `agent-macos`), `version` (`0.2.0`), `build` (an integer: `versionCode` on Android), `flavour` (`play`, `full`, or the platform's equivalent) | the version gate (decision 4), support |
| `grants` | one entry per grant the platform needs, each `granted`, `missing` or `not_applicable`. Android's keys are the wire names of `OnboardingPolicy.Grant`, plus `full_screen_intent` once #368 adds it | the parent's "Phone setup" list |
| `features` | a fixed list, each `ready`, `degraded`, `unavailable` or `not_supported`: `lock_screen`, `pause_screen`, `app_blocking`, `screen_time`, `web_filter`, `pause_internet`, `location`, `uninstall_guard`, `notification_scan`, `call_sms_log` | the command route (decision 3), the parent's feature list |

**`features` is computed by the same code that decides the agent's acknowledgements:**
`EnforceabilityPolicy` for `lock_screen`, `pause_screen` and `pause_internet`, `LocationStartPolicy` for
`location`, and the build's `BuildConfig` flags for `notification_scan` and `call_sms_log`.

- **The server never works a feature out from the grants.** Issue #221 set the rule that the server and
  the agent must not grow two vocabularies for one condition. A server that decided "overlay missing
  means the lock screen is unavailable" would be wrong on a phone where the accessibility service can
  still show it (`EnforceabilityPolicy`'s third path), and would drift every time the agent's policy
  changed.
- **`degraded`** means the feature works by a weaker path. Example: `lock_screen` with only the
  keyguard path, so the screen locks but OSRA's lock screen and its message do not show.
- **`not_supported`** means the build or the platform cannot do it at all. Examples: `call_sms_log` on
  the Play build, `uninstall_guard` on iOS. The parent app greys these out. It does not report them as a
  fault.

### 2. It rides on requests the phone already makes

- The report goes in the body of the telemetry upload that already runs every 15 minutes
  (`POST /v1/devices/:id/telemetry`), and in `pair/claim`, so a new phone is described from its first
  minute.
- When a grant changes between ticks, the agent sends one telemetry upload early. That costs one
  request per change, not per period, so the idle budget is untouched.
- The agent re-checks its grants on every tick, the same way `GrantChecks` re-runs on every resume.

On the server, the report is stored on the `Device` row as `capabilities` (JSONB) with
`capabilitiesReportedAt`. The rules are the ones #221 already uses for `locationGrant`:

- the latest report wins;
- a request that omits the field leaves the stored value alone, so an old agent cannot erase what a
  newer one said;
- a report older than one telemetry period plus its flex (20 minutes) is **unknown**. It is shown with
  its age and is never used to refuse anything.

`locationGrant` stays as it is for two releases. The agent sends both. After that, `features.location`
replaces it in a separate change.

### 3. What the server does with it

- **`GET /v1/devices` and `GET /v1/devices/:id`** return a `setup` object: `reportedAt`, `features`, and
  `missing`, the grants that are `missing`. The parent app shows this as "Phone setup", one line per
  feature, in the parent's language, with the grant that fixes it. The fix itself happens on the child's
  phone; the parent app says so rather than offering a button that cannot work remotely.
- **`POST /v1/devices/:id/command` records a command as failed at once**, without waking the phone,
  the way a refused `locate_now` is recorded today (`enqueueFailedDeviceCommand`, answering
  `{"published": false, "status": "failed", "reason": …}`). It does so only when **all three** of these
  hold:
  - a fresh report exists;
  - the report says the feature the command needs is `unavailable` or `not_supported`;
  - the reason string is the one the agent's own acknowledgement would carry (for example
    `lock_screen_unavailable` from `EnforceabilityPolicy`).

  In every other case the command is queued and the phone answers it, as today. `degraded` is never a
  refusal: a keyguard-only lock still locks the screen. This is `locateNowRefusal` (#221) generalised
  from one command to all of them, with the same freshness guard.
- **No new alert kind.** A drop from `ready` to anything worse shows on the setup list. The drops that
  already page the parent keep paging, through the agent's edge-triggered path (ADR-0027): device admin
  removed, accessibility service turned off. Whether an overlay drop pages is #368's call. Its fix
  already makes the lock acknowledgement fail honestly, which reaches the parent at the moment it
  matters.

### 4. Every client names its build in a header

Every request from every client carries `X-OSRA-Client`:

    X-OSRA-Client: child-android/0.2.0+2 (play)
    X-OSRA-Client: parent-app/0.1.0+1 (android)

The format is `<app>/<version>+<build> (<flavour or platform>)`, and `build` is the integer that
orders releases.

- An `onRequest` hook parses the header, puts the result on the request, and stores the build on the
  `Device` row (child) or the push-token row (parent) when it changes. A malformed header is treated
  like a missing one; it is never an error.
- A request without the header is **legacy**. Every client released before this change is legacy, so
  legacy requests are served exactly as today. The gate (decision 5) can only act on a header it
  could read.

### 5. The version gate: required for the parent app, advisory for the child agent

The server reads a client policy, one JSON value per environment, kept in the task's environment:

    CLIENT_POLICY={"parent-app":{"min":3,"recommended":4},"child-android":{"min":5,"recommended":6}}

- **Every response** carries `X-OSRA-Update: none`, `recommended` or `required`, computed from the
  request's own header. An app that reads it can show a gentle "update available" once, or the blocking
  screen below. An app that does not read it loses nothing.
- **The parent app below `min`:** every route answers `426 Upgrade Required` with
  `{"error": "update_required", "app": "parent-app", "minBuild": 3}`. The exceptions are `/health` and
  `POST /v1/auth/logout`, so a parent can always sign out. The app shows one screen: "Update OSRA to
  continue", with the store link.
- **The child agent below `min` is never refused.** The server keeps accepting its requests and
  commands. It sets the device's setup state to `update_required`, which the parent sees as "This phone
  runs an old version of OSRA. Update it on the phone." A request shape the server can no longer parse
  still gets the 400 it gets today. The gate's job is to make that rare and visible, not to replace it.
- **An empty or absent policy means no gate.** This is the default, and it is how the change ships: the
  code goes out with the gate off, and the first `min` is set in a later, separate change.

### 6. Old request shapes keep working for two releases, and CI proves it

- The server must accept every request shape sent by the last two released builds of each client.
- For each released build, the requests it sends are recorded once as fixtures, under
  `services/api/test/contract/<app>/<build>/`. CI replays them against the current API and fails on any
  400 or any field the server ignores that it used to read.
- Raising a `min` is a pull request that names the release. It may never go above a build that has been
  live in its store for 14 days, so an iPhone update stuck in App Store review cannot lock a parent out.

## Reasoning

- **Computed on the device, not the server.** The agent is the only thing that knows whether the lock
  screen can show *on this phone*. Three paths can show it, and the right one depends on grants, on
  whether the service is bound, and on the OEM. The server can only repeat the agent's verdict, so it
  should repeat it rather than re-derive it.
- **Inside telemetry, not a new route.** A new route on a timer would spend the idle budget that #367 is
  measuring. A field on an existing upload costs about 400 bytes every 15 minutes.
- **Refuse only on a fresh, explicit `unavailable`.** Issue #221's follow-up measured a Locate failed
  four seconds after "Allow all the time" was granted, because the report was stale. A refusal is worse
  than a queued command that the phone answers itself. So the server refuses only when it is as sure as
  the phone would be.
- **The child-side gate warns, never cuts off.** A refused agent is an unmonitored phone. The pressure
  to update goes to the parent, who can act on it, not to the agent, whose user might prefer it never
  updated.
- **A header, not a body field.** The gate has to work on every route, including GETs. A header can be
  read before the body is parsed, so a 426 never depends on a request shape the server might not
  understand.

## Alternatives rejected

- **The server works capabilities out from raw grants.** Rejected for the drift described above. Raw
  grants are still sent, but only for the parent's "what to fix" list.
- **A dedicated `POST /capabilities` on a timer.** Rejected: it spends the idle budget.
- **Refuse old child agents with 426, like the parent app.** Rejected: it trades a mismatch that can be
  seen for a phone nobody monitors.
- **Use the `User-Agent` header.** Rejected: OkHttp, Dio and the iOS stack each set their own, and
  rewriting it per platform is more fragile than one header we own.
- **Hard-code the minimum builds in the API.** Rejected: raising a minimum would then need an API
  release, which is the wrong coupling when the reason is a store release.

## Costs and consequences

- **New contract surface** to keep in `packages/shared-types`, with a Kotlin mirror on the agent. That
  is two copies of one vocabulary, held together by a test that compares the agent's wire names with the
  shared enum (the same check `LocationGrantState` already relies on).
- **Two migrations on `Device`** (`capabilities`, `capabilitiesReportedAt`, plus the client build) and
  one on the push-token row.
- **Fixtures per release.** Every release adds one folder of recorded requests. That is a release step,
  so `docs/RELEASING.md` gains a line.
- **A wrongly set `min` locks parents out.** The 14-day rule, `recommended` coming before `min`, and the
  logout exemption limit the damage. Fixing a wrong value is a configuration change, not an app release.
- **The parent app gains two screens:** "Phone setup" and "Update OSRA". Both need Arabic, so both go
  through the 3.1 review that the other screens get.

## How it is built (one roadmap item per pull request)

1. **API and shared types:** `DeviceCapabilitiesV1`, the two columns, `setup` on the device routes, the
   generalised refusal, the `X-OSRA-Client` hook, `X-OSRA-Update`, and the 426 gate. `CLIENT_POLICY`
   ships empty, so the gate is off.
2. **Android agent:** the header on every request; `capabilities` in telemetry and in `pair/claim`; the
   early upload when a grant changes; `features` from the existing policies. If #368 has not added the
   `full_screen_intent` grant by then, this PR adds it.
3. **Parent app:** the header, "Phone setup" on the child's device screen, the update screen, and the
   `X-OSRA-Update` notice.
4. **Release step:** the contract fixtures for the current builds, and the `RELEASING.md` line.

**Relation to #368:** #368's item 3 ("setup and the device health check report a missing overlay or
full-screen-intent permission to the parent") is this ADR's PR 2 and PR 3. #368 can ship its items 1,
2 and 4 without waiting for them, and should: the honest acknowledgement is the urgent part.

## Falsifiable claims a verifier can test

1. With the overlay grant revoked on the Flip4 and the accessibility service off, the next telemetry
   upload stores `features.lock_screen = "unavailable"`, and `GET /v1/devices/:id` shows it within one
   telemetry period.
2. A `lock` sent right after that is recorded `failed` with `lock_screen_unavailable` and the phone is
   not woken. The same `lock` sent when the report is older than 20 minutes is queued.
3. With device admin active and the overlay revoked, `lock_screen` is `degraded` and a `lock` is
   queued, never refused.
4. An idle Flip4 makes no more requests per 10 minutes with this change than without it: compare #346's
   counter over the same window.
5. With `CLIENT_POLICY` empty, every response carries `X-OSRA-Update: none` and no request is refused.
   With the parent app's `min` above its build, every route except `/health` and logout answers 426.
6. With `child-android`'s `min` above the Flip4's build, the phone still receives and acknowledges a
   command, and the parent sees "update required" on its setup list.
7. The APK already on the Flip4 (`b1c7906`, which sends no header) keeps working against the new API,
   unchanged.

## Evidence

- `services/api/src/lib/locationGrant.ts` (the freshness guard and the refusal this generalises),
  `services/api/src/routes/devices.ts` (`TelemetrySchema`, the telemetry route), `services/api/prisma/schema.prisma`
  (`Device`).
- `apps/child-android/app/src/main/java/com/familyshield/agent/setup/OnboardingPolicy.kt` and
  `GrantChecks.kt` (the nine grants), `security/EnforceabilityPolicy.kt` (the three lock paths and
  `lock_screen_unavailable`).
- `services/api/src/routes/me.ts` (the only version a client reports today).
- Issue #368 (the Flip4 measurement of a lock acknowledged with no lock screen), issue #353 and PR #367
  (the idle budget).
