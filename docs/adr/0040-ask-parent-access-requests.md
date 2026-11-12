# 0040 — "Ask parent": an access request the parent answers, and the answer reaches the phone

- **Status:** proposed (2026-11-12)
- **Issue:** #600 (roadmap 5.11), from finding 3 of the iPhone 13 full pass on `main@bba8c86f`. First slice: #599.
- **Deciders:** Claude (architecture); built by Kimi (API, parent app, Android) and Ahmed (iOS)
- **Relates to:** ADR-0011 (one alert path), ADR-0012 (command queue), ADR-0014 amendment (guardian permissions),
  ADR-0019 (safe-direction commands), ADR-0034 (capability report), ADR-0037 (iOS app groups), ADR-0038 (design language)

## Context

Both child apps have a request button on the block screen: "Request access" on Android (`BlockActivity`), "Ask
parent" on the iPhone shield (`FamilyShieldShieldActionDelegate`). Both only POST an `app_blocked` alert to
`/v1/alerts/internal`. On the iPhone (12 Nov) the alert arrived (201), and then nothing could happen:

- the parent app titles alerts by category (#344), so the request reads "App blocked" like any other block (#599);
- there is no approve, deny or "allow for N minutes" action anywhere;
- the child never hears back, so the button teaches a child that asking is pointless.

What we already have, and reuse:

- **Rules are the authority, delivered by version.** A rule write bumps `RuleSet.rulesVersion`, coalesces a
  `rules_updated` command (ADR-0012) and sends a data-only wake (`{ "w": "1" }`). The parent app already shows
  "hasn't picked this up yet" for a version the phone has not fetched (#475).
- **A today-only bonus** (`POST /children/:id/bonus`, `bonusMinutesToday`) raises the *global* daily limit. It
  cannot open one app, and it cannot open anything during bedtime, a routine or a per-app block.
- **Wakes.** Android has FCM. The iPhone agent has the APNs wake code (#382), but the server cannot send it until
  an APNs key exists, which is Karim's call. Measured on the iPhone: a wake lands in about 3 s when the app was
  recently in front and 5 to 7 min in the background.
- **iOS cannot name apps.** Shields and grants work on opaque tokens, which never leave the phone (ADR-0037). The
  server knows an iPhone group by id and label only.

The forces: the answer must survive a phone that is offline, asleep or out of battery; a child must not be able to
stretch a grant by changing the clock or flood the parent; a guardian must not loosen a rule they may not edit; and
none of it may weaken a lock, a pause or the essential-apps rule.

## Decision

### 1. The request is a record, not only an alert

A new table `AccessRequest`:

| Field | Meaning |
|---|---|
| `id` | UUID made by the server |
| `childId`, `deviceId` | from the signing device (never from the body when they disagree, as in `/alerts/internal`) |
| `target` | what was asked for, one of: `{ kind: "app", packageId, label }` (Android), `{ kind: "token", scope: "app" \| "category" \| "site", groupId?, phoneRef }` (iPhone) |
| `blockedBy` | why it was blocked: `app_rule`, `time_limit`, `daily_limit`, `bedtime`, `school`, `routine`, `category_protection`, `group` |
| `status` | `pending → approved \| denied \| expired \| withdrawn` |
| `requestedAt`, `expiresAt` | a request waits **30 minutes**, then becomes `expired` |
| `answeredAt`, `answeredBy` | the parent who answered |
| `grantMinutes`, `grantEndsAt` | set on approval |
| `alertId` | the `access_request` alert raised with it |

- **iPhone:** `phoneRef` is a random id the phone makes and keeps, next to the token, in the app group. The server
  stores and echoes it and never learns the token, the app name or the bundle id (ADR-0037 decision 5). `groupId`
  is set when a group's shield was tapped, so the parent reads "an app in Games"; with no group (a bedtime shield)
  the parent reads "an app". `label` exists only for Android, where the agent already reads the app's name.
- **Android:** apps only. The DNS filter has no screen to ask from, so blocked websites are out of scope here.
- Creating a request is collection, so it is refused with 428 once consent is withdrawn (ADR-0008), like any alert.
- Rows are erased with the child (ADR-0013 cascade) and kept 30 days, then deleted by the nightly rollup.

**Route:** `POST /v1/access-requests` (device HMAC, same signing as `/alerts/internal`). It creates the row **and**
raises the alert through `raiseAlertOnce` in one transaction, with category **`access_request`** (#599) and
`metadata.requestId`. The parent push stays data-only (ADR-0011); the parent app builds the notification text
from the category, never from the English title.

### 2. The parent's answers

Three answers, nothing else in v1:

| Answer | Effect |
|---|---|
| **Allow for 15 min / 30 min / 1 hour** (custom 5–240 min) | `approved`, `grantEndsAt = answer time + minutes` |
| **Not now** | `denied` |
| *(no answer)* | `expired` after 30 min; the child may ask again |

- **Route:** `POST /v1/access-requests/:id/answer` `{ "answer": "allow", "minutes": 30 }` or `{ "answer": "deny" }`.
  The first answer wins: one `UPDATE … WHERE status = 'pending' RETURNING`. A second answer gets **409** with the
  answer that stands, and every parent's card updates through the existing live event.
- **End early:** `POST /v1/access-requests/:id/end` ends an active grant now (it bumps the rules version).
- **"Approve once" is rejected.** Neither platform can tell us reliably when a "session" of an app ends (iOS gives
  no app-close event to an agent), so "once" would mean a hidden timer anyway. A time box the parent chooses is
  honest and the same on both phones.
- **"Always allow" is not an answer.** It changes a rule, so the request card links to the rules editor for that app
  (Android) or group (iPhone). That keeps one place where permanent rules are made.

**Guardian permissions (ADR-0014 amendment, gate by permission).** Seeing a request is reading an alert, so the
list follows `alerts`. Answering loosens a rule, so `answer` and `end` need **`rules`**, exactly as `/bonus` does
(owner always passes). A guardian with `alerts` but not `rules` sees the request with "Only a parent can answer
this" and no buttons; the API sends `canAnswer` so the app does not guess.

### 3. How the answer reaches the phone

**An approval is part of the ruleset.** The served `RuleSet` gains

```
accessGrants?: Array<{ id: UUID; target: { packageId: string } | { phoneRef: string }; endsAt: ISODate }>
```

listing approved requests whose `endsAt` is still in the future (at most 10 per child). Approving and ending early
bump `rulesVersion`, coalesce `rules_updated` and send the wake. Expiry does **not** bump the version: the phone
ends a grant on its own clock (section 5), and the next served ruleset simply leaves it out.

Why the ruleset and not a one-off command:

- it is durable and idempotent: a phone that was off for an hour fetches the rules and gets the grant with the time
  that is left, or nothing if it has ended; a command lost or replayed would grant too much or too little;
- the parent app's "hasn't picked this up yet" (#475) works unchanged;
- enforcement has one source on the phone, as today.

**Every answer is also a command** `access_answer` `{ requestId, answer, endsAt? }` (TTL 1 hour, ADR-0012), only
so the child is *told* (section 4). Enforcement never reads it. It is **not** safe-direction under ADR-0019 rule 1:
a "Not now" closes a request inside a restriction, so it needs active consent like the answer route itself.

**Where a grant sits in the order of rules (both platforms):**

1. the lock (`lock` command) and pause-the-internet still win; a grant never opens a locked or paused phone;
2. always-allowed and essential apps are unchanged;
3. **then the grant**: the granted app (Android) or token (iPhone) is allowed until `endsAt`, above routines,
   per-app rules, category protection, the daily and per-app limits, bedtime and school hours;
4. then every other rule as today.

A grant for an app with a time limit does **not** count against that limit while it runs, and is not added to the
global bonus: they are different promises.

### 4. What the child sees

| Moment | Android (`BlockActivity`) | iPhone (shield) |
|---|---|---|
| Tapped the button | The button becomes "Asked. Waiting for your parent…" and stays so while `pending` | The shield action answers `.defer`; the shield redraws with the same "Asked" line, read from the app group |
| Asked again while waiting | Nothing new is sent | Same |
| Parent allowed | A notification: "You can use {app} for {N} minutes." The block screen closes if it is open | A local notification: "You can use it for {N} minutes." The shield lifts |
| 1 minute left | A notification: "1 minute left on {app}." | Not on iOS v1 (see consequences) |
| Grant ended | The block screen comes back with "Your time on {app} is up." | The shield comes back |
| Parent said no | "Your parent said not now." on the block screen and as a notification | Shield line and local notification |
| No answer in 30 min | "No answer yet. You can ask again." | Same, on the shield |
| Too many requests | "You've asked a lot today. Talk to your parent." (section 6) | Same |
| Phone offline | "Can't reach your parent right now. Try again when you're online." Nothing is queued: an old request is not worth sending | Same |

The parent's name is never shown (a guardian may have answered); the child reads "your parent". On the iPhone the
app name is drawn by Apple in the shield itself, so our strings never need it.

### 5. Expiry on the phone, and the clock

A grant ends on the phone, offline or not, and a child must not lengthen it by moving the clock.

- At the fetch, the phone computes **remaining = `endsAt` − server time** (the response's `Date` header, the same
  receipt clock ADR-0034 trusts), then holds the end as a **monotonic** deadline (`SystemClock.elapsedRealtime()`
  on Android, `ProcessInfo.systemUptime` on iOS). Changing the wall clock moves nothing.
- **After a reboot** the monotonic clock restarts, so the phone falls back to the wall clock and **fails closed**:
  a grant is kept only if the wall clock is after the time the grant was received and before `endsAt`; otherwise it
  is dropped and the block returns. A rules fetch then restores any time genuinely left.
- **Android:** `RuleEngine` checks the grant before the rules it outranks; an exact alarm (or the existing
  re-evaluation loop) re-raises the block screen at the deadline if the app is still in front.
- **iPhone:** the phone lifts the shield by removing that one token from the store that shields it (the group store
  or the bedtime/routine store; shields from several stores add up, so the token must leave each). It schedules a
  `DeviceActivity` interval ending at the deadline; the monitor extension's `intervalDidEnd` puts the shield back,
  and every app launch and rules sync re-applies the stores without expired grants. **iOS refuses a schedule
  shorter than 15 minutes**, so a shorter grant is scheduled with its start in the past and its end at the deadline.
  That trick is unproven on our phone and is spike row S1.

### 6. Abuse limits

All checked on the server (the phone mirrors them to show the right line, but the server is the authority):

- **one pending request per target**: asking again while waiting returns the same request (200), no new push;
- **after "Not now", 10 minutes** before the same target can be asked again (429 `cooldown`);
- **per child: 6 requests an hour and 20 a day** (429 `too_many_requests`, with `retryAfter`);
- **a parent gets at most one push per request**; repeats inside the pending window update the same alert;
- **at most 10 active grants per child**, and a grant is at most 240 minutes.

No free text from the child in v1. A message box is new content to moderate, store and translate, and a
child-written note can carry what our content rules exist to catch. A short list of preset reasons is a candidate
for v2.

### 7. Push, and what changes without an APNs key

- **Android:** the FCM wake exists; the answer lands in seconds.
- **iPhone, with an APNs key:** the same, once the server sends the existing child wake to Apple.
- **iPhone, without one (today):** the answer is stored and waits for the next fetch: the next app open, a
  background refresh, or a shield tap (the shield action extension fetches the request's status when tapped). So
  the shield's waiting line on iOS adds "Open OSRA Kids to check." until the key exists. **This is a product
  decision for Karim**: the APNs key costs nothing more (the developer account is paid), and without it "Ask
  parent" on the iPhone works but feels slow.

### 8. The parent app

- The alerts list shows an `access_request` as a **request card**, not a plain alert: the child, what was asked
  ("YouTube", "an app in Games", "an app"), why it was blocked ("during Bedtime"), the time asked, and the three
  buttons. After an answer, the card shows the answer, who gave it and, for a grant, the time left with **End now**.
- The child's page gets a **Requests** row (pending first, then today's answers).
- Tapping the push opens the request card. Answer buttons on the notification itself are a follow-up (they need
  an authenticated background action).
- The card follows ADR-0038 (Calm light, Control room dark), and its strings are in section 9.

### 9. Strings

New strings, English below. **Every Arabic string goes through the Arabic Language Bureau thread and then to
Karim before it ships**; nothing in Arabic is invented in a PR.

Child (Android `strings.xml`, iPhone `Localizable.strings`):

| Key | English |
|---|---|
| `request_waiting` | Asked. Waiting for your parent… |
| `request_waiting_open_app` (iPhone, no APNs) | Asked. Open OSRA Kids to check for an answer. |
| `request_allowed` | You can use {app} for {minutes} minutes. |
| `request_allowed_no_name` (iPhone) | You can use it for {minutes} minutes. |
| `request_one_minute_left` | 1 minute left on {app}. |
| `request_time_up` | Your time on {app} is up. |
| `request_denied` | Your parent said not now. |
| `request_expired` | No answer yet. You can ask again. |
| `request_too_many` | You've asked a lot today. Talk to your parent. |
| `request_offline` | Can't reach your parent right now. Try again when you're online. |

Parent (`app_en.arb` / `app_ar.arb`):

| Key | English |
|---|---|
| `alertCategoryAccessRequest` / `alertTitleAccessRequest` | Access request / {child} is asking for access |
| `accessRequestTargetApp` | {app} |
| `accessRequestTargetGroup` | an app in {group} |
| `accessRequestTargetUnknown` | an app |
| `accessRequestBlockedBy` | Blocked by {reason} |
| `accessRequestAllow15` / `Allow30` / `Allow60` | Allow 15 min / Allow 30 min / Allow 1 hour |
| `accessRequestAllowCustom` | Other time… |
| `accessRequestDeny` | Not now |
| `accessRequestAllowedBy` | Allowed for {minutes} min by {parent} |
| `accessRequestTimeLeft` | {minutes} min left |
| `accessRequestEndNow` | End now |
| `accessRequestDeniedBy` | {parent} said not now |
| `accessRequestExpired` | No one answered in time |
| `accessRequestNeedsRulesPermission` | Only a parent who can change rules can answer this. |
| `accessRequestAlreadyAnswered` | {parent} already answered. |
| `accessRequestNotPickedUp` | Sent. {child}'s phone hasn't picked it up yet. |

## Alternatives considered

- **Keep it an alert and add an "unblock" button that edits the rule.** Rejected: it turns a short "yes" into a
  permanent change the parent must remember to undo, and on the iPhone the server cannot even name the app.
- **Deliver the grant only as a command.** Rejected: a command is delivered once, so a phone that restarts, misses
  the ack or comes back after the TTL loses or keeps the grant with nothing to correct it. The ruleset is
  re-fetched and self-healing.
- **Reuse the bonus.** Rejected: `bonusMinutesToday` raises the global daily limit for every app, cannot open one
  app, and does nothing during bedtime, a routine or an app block, which are most of the requests.
- **Let the child's phone hold the grant timer from the parent's wall-clock time alone.** Rejected: a child who
  sets the clock back gets more time. Server receipt time plus a monotonic deadline closes that.
- **Queue a request made offline and send it later.** Rejected: a request from an hour ago is noise to the parent and
  a surprise to the child.
- **A free-text message from the child.** Deferred (section 6).

## Order (one PR each, after this ADR is accepted)

1. **#599 (first slice):** `access_request` in the alert enum, the parent title EN (AR after the Bureau), the iPhone
   sends it; the shield's "Exit" stops alerting (#602 item 1).
2. **API:** `AccessRequest` (migration), `POST /v1/access-requests`, `answer`, `end`, `accessGrants` in the served
   ruleset, the `access_answer` command, the limits, the guardian gate, retention and erasure. Shared types first.
3. **Parent app:** the request card, the child's Requests row, the push route. (Kimi)
4. **Android agent:** request through the new route, the waiting/answer states on `BlockActivity`, the grant in
   `RuleEngine` with the monotonic deadline, the notifications. (Kimi)
5. **iPhone agent:** S1 spike first, then `phoneRef`, `.defer` and the shield states, per-token grant and re-shield,
   the local notifications. (Ahmed)
6. **Arabic:** the Bureau's strings, approved by Karim, land with (3)–(5) or right after.

## Falsifiable claims for the verifier

| Row | Claim |
|---|---|
| R1 | A request makes one `AccessRequest` and one `access_request` alert; asking again while pending makes neither and sends no push |
| R2 | Two parents answer at once: exactly one answer stands, the other gets 409 with it |
| R3 | A guardian with `alerts` but not `rules` sees the request and gets 403 on `answer` and `end`; with `rules`, both work |
| R4 | An approval appears in the served ruleset with the version bumped, and vanishes after `endsAt` without a bump |
| R5 | Android, phone offline when the parent approves 30 min; online 20 min later: the app opens for about 10 min, not 30 |
| R6 | Android and iPhone: moving the wall clock back during a grant does not lengthen it; rebooting during a grant never lengthens it |
| R7 | A grant does not open a locked or internet-paused phone, and an always-allowed app is unaffected |
| R8 | The 7th request in an hour gets 429 and the child sees "You've asked a lot today"; the parent gets no push for it |
| R9 | "Not now" reaches the child's screen; a second request for the same app within 10 minutes is refused |
| R10 | After consent is withdrawn, a request and an answer are both 428 |
| R11 | iPhone: the server never receives a bundle id, app name or token in any request field |
| S1 | iPhone spike: a `DeviceActivity` interval starting in the past and ending in 5 minutes fires `intervalDidEnd` on time on the team's test iPhone, with the app in the background and after it is killed |

## Consequences

- **Good.** One record and one ordering rule on both phones; the answer is durable through offline phones; the
  clock cannot stretch a grant; guardians stay inside their permissions; nothing new reaches the server from an
  iPhone beyond a group id it already knows.
- **A new table, two routes and a ruleset field** for Kimi, plus a command type. The served ruleset grows by at
  most 10 small entries.
- **On the iPhone without an APNs key, the answer is slow** until the child opens the app (section 7).
- **On the iPhone there is no "1 minute left"** in v1: a `DeviceActivity` warning needs a second schedule per grant,
  which adds to iOS's limit of schedules per app; we add it if S1 shows headroom.
- **If S1 fails**, grants under 15 minutes on the iPhone are rounded up to 15, and the parent card says so for an
  iPhone. Android is unaffected.
- **A reboot during a grant may cut it short** until the next fetch (fail closed, section 5). That is the side we
  choose to err on.
- **The existing `app_blocked` "Access requested" path** keeps working for old agents until they update; the server
  accepts it and the parent app shows it as today, without buttons.
