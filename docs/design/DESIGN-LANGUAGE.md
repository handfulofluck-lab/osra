# OSRA design language

**Decision:** ADR-0037. **Chosen by the maintainer on 2026-11-11:** *"I want A Calm for the light theme and I want B
Control room to be our dark theme option … please adopt same design language in iOS and Android and as much as
possible in Windows and macOS."*

This file is the contract for every screen of the parent app and of OSRA Kids on every platform. It says what a
screen holds, how a control behaves and what the words are. `tokens.json` beside it holds every colour, radius and
type size. `reference/` holds the same six screens drawn in both themes.

| Reference | Light (Calm) | Dark (Control room) |
|---|---|---|
| Parent home | `reference/light-home.png` | `reference/dark-home.png` |
| Map | `reference/light-map.png` | `reference/dark-map.png` |
| Child page | `reference/light-child.png` | `reference/dark-child.png` |
| Rule sheet (daily limit by day) | `reference/light-limit.png` | `reference/dark-limit.png` |
| OSRA Kids home | `reference/light-kids.png` | `reference/dark-kids.png` |
| OSRA Kids block screen | `reference/light-block.png` | `reference/dark-block.png` |

`reference/screens.html` is the source of those images. Open it in a browser (`?theme=dark` for dark) to read exact
sizes. All names and figures in it are invented demo data.

## 1. Principles

1. **The child is the unit.** A parent picks a child once. One page shows that child and changes that child's rules.
   There is no separate editor, no global Save, and no second place that lists the same thing.
2. **Say the truth about protection.** Every child shows whether protection is working, from the device's own
   capability report (ADR-0034). It is quiet when fine and loud when not.
3. **Three states of use.** Checking takes five seconds and no taps. Acting takes one tap. Deciding rules may take
   two minutes. Screens are weighted in that order.
4. **Every rule stands alone.** Each rule has its own switch and its own days. Any rule can be off while the others
   are on.
5. **Never hide a limit, never fake a capability.** A card is drawn from what that device reports it can do. A
   control that cannot work on this device says so in one line and offers the next step.
6. **One layout, two themes.** A theme changes colour, corner radius and the numeric typeface. It never moves,
   adds or removes a control.
7. **Sentences, not data.** Places have names, durations read as hours, every alert names the child and the app.

## 2. Themes

Light is **Calm**, dark is **Control room**. The app follows the phone's setting by default and offers Light, Dark
and System in Family > App settings. Values are in `tokens.json`; the table is the summary.

| Role | Calm (light) | Control room (dark) |
|---|---|---|
| Page / card | `#F1F5F4` / `#FFFFFF` | `#0E1417` / `#172026` with a 1 px `#2B3840` outline |
| Text / secondary text | `#12211F` / `#4D5E5A` | `#E9EFF1` / `#A7B6BD` |
| Primary | `#0B5D57` | `#7DB4FF` |
| OK / warning | `#0B5D57` / `#8A4B00` | `#86D4BE` / `#FFB454` |
| Card / control / sheet radius | 18 / 12 / 26 | 12 / 8 / 16 |
| Stand-alone numbers | IBM Plex Sans, tabular | IBM Plex Mono 600 |

Rules that hold in both themes:

- Text is at least 4.5:1 on its background; graphics that carry meaning are at least 3:1. The pairs in
  `tokens.json` were measured; a new pair is measured before it ships.
- Status is never colour alone. "Protected" and "Needs attention" are words; the limit on a chart is a line with a
  legend.
- One type family: IBM Plex Sans with IBM Plex Sans Arabic. Both are bundled with the app, not fetched.
- Touch targets are at least 44 by 44. Primary buttons are 52 high.
- A child's colour marks the avatar and the map pin only.

## 3. Parent app

### 3.1 Bottom bar

Four places: **Home**, **Map**, **Inbox**, **Family**. The Inbox tab shows the count of items that need the parent.

### 3.2 Home

One card per child, in the order the parent set. Each card, top to bottom:

1. Avatar, name, and the **protection line**. "Protected" in the OK colour when every feature in the capability
   report is `ready`. "Needs attention" in the warning colour otherwise, followed by a box that names the problem in
   one sentence ("App blocking is off on Omar's phone.") and a **Fix** button that opens the guided repair for that
   grant.
2. The **status sentence**: place, time used of the limit, and what comes next. "At **Home**. 1 h 52 m used of 4 h.
   Bedtime at 21:00." The place is a saved place name first, otherwise the nearest street or area. Coordinates never
   appear. If the location is older than 15 minutes the sentence says so: "Last seen near Al Wasl Road, 40 minutes ago."
3. A bar of today's time against today's limit.
4. The three action buttons (3.4). They are hidden while the card shows a Fix box, because the fix comes first.

"Add child" sits in the header.

### 3.3 Child page

One scrolling page. No tab row. Top to bottom:

1. Back, the child's name, **Search settings**. Search finds any rule or setting by plain words ("bedtime",
   "block tiktok", "ring") and opens it.
2. The status sentence and the protection line with "phone seen N minutes ago".
3. The three action buttons.
4. **Today** (3.6).
5. **This week** (3.6).
6. **Rules**: the schedule and limit cards (3.5), ending with "Add a schedule". The header carries one delivery
   line for the whole set: "All active on Alex's phone", or "Waiting for Alex's phone, offline since 16:40".
7. **Apps**, **Websites**, **Places**, **More protection**. Each row shows its state on the right.

**More protection** holds everything outside the twenty everyday tasks: social monitoring, search safety, contact
rules, wind down, uninstall protection, devices, diagnostics. Every row inside shows its state ("Social monitoring:
on, 2 apps") so the list can be read without opening anything.

### 3.4 The three actions

| Button | Behaviour |
|---|---|
| **Pause** | Opens a sheet. First choice: "The whole phone" or "Internet only". Second: 15 minutes, 1 hour, "Until I resume". The sheet states: "Calls to you and emergency numbers still work." While a pause runs, the button reads **Resume** and shows the time left. |
| **Ring** | Rings at full volume even when the phone is silent. The button reads **Stop** while it rings. If the phone has not confirmed within 10 seconds the card says "Waiting for Alex's phone" rather than "Ringing". |
| **More time** | +15, +30, +60 minutes for today only. The home bar and OSRA Kids update. |

The separate Lock, Unlock, Resume, Pause net and Delivery status buttons are removed from the screens. The commands
behind them are unchanged. A command is never shown as done before the device acknowledges it (roadmap 3.6).

### 3.5 The rule card

Every rule has the same anatomy.

- **Closed:** name, a one-line summary, and a switch. The switch acts at once and shows **Undo** for 5 seconds.
- **Open:** tapping the card opens a sheet with that rule's values, **its own days**, its delivery line, and one
  **Done** button. Leaving the sheet any other way discards the edit. There is no global Save.
- **Days** are seven chips inside the sheet, starting on the region's first day of the week (from the phone's
  locale). Shortcuts above them: "Every day", "School days", "Weekend". School days and weekend come from the
  family's region setting, never from a fixed Saturday and Sunday.

| Rule | Closed summary | In the sheet |
|---|---|---|
| Daily limit | "4 h, Fri and Sat 5 h" | One stepper in 15-minute steps. "Different on some days" shows seven columns; tapping a day gives that day its own stepper. |
| Bedtime | "21:00 to 07:00, every night" | Start, end, days, "Always allowed" apps. |
| School time | "08:00 to 14:00, Sun to Thu" | Start, end, days, "Always allowed" apps. |
| A schedule the parent adds | "Homework, 16:00 to 17:30, Mon to Thu" | Name, start, end, days, blocked or allowed apps. Templates: Homework, Dinner, Prayer time, Custom. |
| App | "YouTube, 1 h a day" | Allow, Block, or a daily time. Icon and name only; a package name never appears. |
| Websites | "Safe search on, 6 categories blocked" | Categories, blocked sites, allowed sites. |
| Place | "School, tells you on arrive and leave" | Pin and radius on a map, an arrive switch, a leave switch. |

Bedtime, School time and added schedules are one family, **Schedules**: a named block of time on chosen days.
Durations are never a slider.

### 3.6 Usage

- **Today:** one strip from 0 to 24. Usage is drawn as blocks coloured by category. Bedtime and each schedule are
  shaded bands behind the blocks, labelled where they fit, so use inside a band is visible at once. A thin line marks
  now. Below it: the category totals.
- **This week:** seven bars, today's in the primary colour, with each day's limit drawn as a line over its column
  (so a day with a different limit shows a different line).
- **Top apps:** five rows with icon, name, time and a bar.
- **Weekly report:** three plain findings, each with an action beside it. "YouTube is up 40% on last week" with
  "Set a limit". The Wellbeing score is removed from Home; it may return only when every point traces to a finding.

In Arabic the strip and the week run right to left.

### 3.7 Map

All children on one map with their colour pins and the family's saved places as dashed circles. Below the map: one
row per child (place, when they arrived or left, when the phone was last seen, a Ring button), then the saved places.
"Add a place" sits on the map.

### 3.8 Inbox

- **Needs you** on top: requests from a child, safety concerns, protection that stopped working. These notify.
- **Activity** below: arrived at school, app blocked, limit reached. A quiet log, silent by default.
- Every item is a sentence with the child's name and the app or place name: "Alex tried to open 9GAG. It's blocked."
  The sentence is built on the device from the alert's category and metadata, never by matching English text.
- A request carries its answer: "Alex asks for 15 more minutes of Chess" with **Allow** and **Not now**, in the list
  and in the notification.
- Ids, "Severity", raw coordinates and package names never appear. "How to talk about this" appears only on safety
  concerns.

### 3.9 Family

Children and their devices, guardians and their permissions, account, plan, app settings (theme, language), sign
out. Sign out leaves the top bar.

### 3.10 The twenty everyday tasks

Taps are counted from Home. A PR that changes one of these paths states the new count.

| # | Task | Path | Taps |
|---|---|---|---|
| 1 | See where each child is | Home sentence | 0 |
| 2 | See today's screen time | Home bar | 0 |
| 3 | See that protection is working | Home protection line | 0 |
| 4 | Ring a silent phone | Ring | 1 |
| 5 | Answer a request | Allow in the notification | 1 |
| 6 | Pause the phone | Pause, duration | 2 |
| 7 | Give more time | More time, +15 | 2 |
| 8 | Turn bedtime on or off | Child, switch | 2 |
| 9 | See what a child did today | Child | 1 |
| 10 | Read the weekly report | Inbox, report | 2 |
| 11 | Pause the internet only | Pause, Internet only, duration | 3 |
| 12 | Change the daily limit | Child, Daily limit, step, Done | 4 |
| 13 | Change bedtime hours or days | Child, Bedtime, edit, Done | 4 |
| 14 | Set school time | Child, School time, edit, Done | 4 |
| 15 | Add a schedule | Child, Add a schedule, template, Done | 4 |
| 16 | Block an app | Child, Apps, app, Block | 4 |
| 17 | Limit an app's time | Child, Apps, app, time, Done | 5 |
| 18 | Block a website | Child, Websites, type, Add | 4 |
| 19 | Add a place alert | Map, Add a place, pin, Done | 4 |
| 20 | Add a child or a device | Family, Add, guided pairing | 2 to start |

## 4. OSRA Kids

| Screen | Content |
|---|---|
| Home | Greeting, time left today as a ring, "Next: Bedtime at 21:00", the child's limited apps with time left, **Ask for more time**, **What my parents can see**. |
| Block screen | What happened, when it ends, what the child can do. "Chess time is up for today. You used your 45 minutes. More tomorrow at 7:00." Buttons: "Ask for 15 more minutes", "Ask for something else", "Go to the home screen". Footer: "You can always call Mum and Dad." |
| Ask | 15, 30 or 60 minutes, an optional short reason, then "Sent to Mum and Dad" and the answer when it comes. |
| What my parents can see | A plain list, generated from the family's actual settings. |
| Pairing | Scan the QR code or type six digits. Nothing else on the screen. No server address (#553). |
| Setup | One permission per screen, a picture of where to tap, a progress count. |
| Diagnostics | Hidden page (long-press the version) for ids, server and build details. Nothing technical on Home. |

Tone follows the child's age from the birth year: friendly under 9, plain from 9 to 12, plain and brief from 13.
The block screen never shames and never shows a countdown of failed attempts.

Each window type has its own sentence (bedtime, school time, a schedule, daily limit, an app's limit, a blocked app,
a pause from a parent), following #473.

## 5. Words

- Durations: "4 h", "1 h 52 m", "45 minutes". Never "240 min". Compact tiles and chart axes may use "1:52".
- Clock times follow the phone's 12 or 24-hour setting.
- Buttons name the action: Pause, Ring, More time, Fix, Done, Allow, Not now.
- Arabic sentences are written whole by a person and reviewed by the maintainer. A sentence is never assembled
  from translated fragments. The layout mirrors in Arabic.
- An error says what happened and what to do next.

## 6. Platforms

The same tokens, the same anatomy, the same words. Each platform uses its native controls for system behaviour
(back gesture, sheets, pickers, notifications) and the tokens for everything visible.

| Surface | Code | What adopts the language |
|---|---|---|
| Parent app, Android and iPhone | `apps/parent-app` (Flutter) | All of section 3. `lib/theme/app_tokens.dart` takes its values from `tokens.json`; `test/design_system_test.dart` keeps the contrast checks. |
| OSRA Kids, Android | `apps/child-android` (Kotlin, Compose) | All of section 4. A Compose theme reads the same values. |
| OSRA Kids, iPhone | `apps/child-ios` (SwiftUI) | Section 4. The shield that Apple draws takes its colours and text from the tokens through `ShieldConfiguration`; its layout is Apple's. App choice happens in Apple's picker on the iPhone, so the parent's Apps card for an iPhone child says "Apps on Alex's iPhone are chosen on the iPhone" and starts that step. |
| Windows child | `apps/agent-desktop` (.NET) | Pairing dialog, lock overlay, time-left window, Ask. Same colours, type, words and button order. |
| macOS child | `apps/agent-macos` (.NET) | The same four surfaces as Windows. |
| Parent on a wide screen | `apps/parent-app` | Children on the left, the child page on the right, at 840 px and wider. |

A card for a feature that a device reports as `not_supported` is shown with one line that says so, never hidden and
never drawn as if it worked.

## 7. Data the design needs

Additions only. None changes the architecture. Each lands with the screen that needs it.

| The design needs | On `main` at `a5e321d` | Change |
|---|---|---|
| Bedtime with a switch and its own days | `ScreenTimeRule.bedtimeStart/End` only; the Android agent applies it every day (`RuleEngine.kt`, "Bedtime (every day)") | `bedtime: { enabled, start, end, days }` |
| School time and routines with a switch | `schoolHours.days` and `Routine.days` exist; no on/off | `enabled` on both |
| A daily limit per day of the week | `dailyLimitMinutes` and `weekendLimitMinutes`; `RuleEngine.isWeekend` is Saturday or Sunday | `dailyLimitByDay: number[7]`, with the two old fields read as a fallback during migration |
| A pause that ends by itself | Pause and resume are separate commands with no end time | Optional `untilIso` on pause; the agent lifts it locally |
| Place names on Home | `LocationPing` is latitude and longitude | Saved-place match on the server, then the parent phone's own geocoder. No third-party call with a child's location. |
| The protection line | ADR-0034 capability report; `X-OSRA-Client` ships off | Turn on and read |
| The delivery line | `rules_freshness.dart`, `rules_behind_banner.dart` | Show it on the Rules header and in each sheet |
| Category colours on the day strip | Usage is per app | An app-to-category map; "Other" when unknown |

Each schema change needs an old agent to keep working: a field an agent does not know must leave its behaviour as
it is today.

## 8. Acceptance

A screen is done when:

1. It matches its reference image in both themes at 360, 390 and 430 px wide, in English and Arabic.
2. Its colours come from the token layer; no screen names a colour.
3. The tap counts in 3.10 hold for the paths it touches.
4. A golden or screenshot test pins it in both themes.

The redesign is done when five parents, at least two using Arabic, each finish 18 of the 20 tasks without help
inside the tap budget; when each can say, after five seconds on Home, where every child is and whether protection
is working; and when five children of different ages can each say how much time is left and how to ask for more.
