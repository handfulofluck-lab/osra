# OSRA UX Contest — Option D ("One Child, Full Screen") Captions

**Model D thesis:** *One child, full screen — calm single-page canvas + horizontal child swipe + bottom sheets & gestures, **ZERO bottom tab bar**.*

## Why Option D Shines

1. **Zero tab-bar clutter, maximum calm:** Parents never hunt across 4–5 bottom tabs to remember where screen time, alerts, or web rules live. Every child is a full-screen living status card (`P-07-D`) with a single glanceable hero, a floating 4-action dock (`Pause`, `+30 min`, `Locate`, `More`), and draggable bottom sheets (`P-08-D`..`P-23-D`) that keep the child's live identity visible in the dimmed backdrop.
2. **One-thumb multi-child switching:** A horizontal swipe (signaled by pager dots `(● ○)` and the opposite-edge peek pill `Sam ›`) switches between children instantly without navigating up and down a hierarchy.
3. **Calm, transparent child experience:** The Child app (`C-01-D`..`C-05-D`) mirrors the exact same zero-tab single-canvas + bottom-sheet architecture. Instead of punitive locks or hidden surveillance, the child sees one clear remaining-time ring, upcoming routines, active protection stated plainly, and one-tap sheets to request extra time (`C-03-D`) or inspect the same activity totals their parents see (`C-04-D`).
4. **Shared OSRA visual language:** Built strictly on OSRA's light palette (`#0B5D57` primary teal, `#F4F7F6` warm mist canvas, `#FFFFFF` cards, `#13211E` ink, `#4D5E5A` muted ink, `#FFF1D6`/`#8A4B00` amber attention, `#FDECEE`/`#A3242B` danger, `18px` card radius, `26px` bottom-sheet radius), rendered at crisp `780×1688` (`390×844 @2x`).

> **Fictional data note:** All names (`Alex`, `Sam`, `Maya`), devices (`Galaxy S23`), screen-time totals, pairing codes (`482 916`), location pins, and safety-alert excerpts shown across all 30 frames are **100% synthetic demo data**. No real family or production user data appears anywhere in this set.

> **Arabic RTL note:** Both hero screens include full Arabic RTL counterparts (`P-07-D-ar.png` and `C-01-D-ar.png`) rendered with `dir="rtl"` and `lang="ar"`, mirrored layout geometry and logical spacing (`inset-inline-*`), authentic OSRA Arabic terminology, and Western tabular numerals (`1:42`, `3:00`, `1:18`, `16:00`) isolated with `dir="ltr"` for zero clipping or bidi reversal.

---

## All 30 Frames

### Parent App — Onboarding & Hero (`P-01-D`..`P-09-D` + `P-07-D-ar`)

| File | Screen | Surface | What it shows | First action |
|---|---|---|---|---|
| `P-01-D.png` | Welcome to OSRA | Full screen | Calm OSRA brand hero, 3 plain-language promises, EN/AR language pill, primary Get started + Sign in | Tap **Get started** (or switch language via **EN / العربية**) |
| `P-02-D.png` | Sign in | Full screen | Parent credentials + 2-step authenticator 6-digit boxes + calm recovery sheet link | Enter 6-digit authenticator code and tap **Sign in** |
| `P-03-D.png` | Create an account | Full screen | Name, family name, email, password strength bar, UAE region selector, plain-language privacy card | Complete details and tap **Create account** |
| `P-04-D.png` | Add a child + parental consent | Full screen | Alex (12) profile, Teen starter rules preview card, explicit parental consent checkbox | Review starter rules, tick consent, tap **Continue** |
| `P-05-D.png` | Pair a device | Full screen | Crisp QR pairing card + 6-digit code `482 916` + live waiting pill + manual pairing sheet trigger | Scan QR or enter `482 916` on Alex's phone |
| `P-06-D.png` | Finish setting up on Alex's phone | Full screen | 4 of 5 protection checklist with clear progress bar + Send reminder CTA | Tap **Send reminder** to complete remaining step |
| `P-07-D.png` | **Hero: One child, full screen (EN)** | Full screen (0 tabs) | Alex (12) teal hero with pager dots `(● ○)`, right-edge `Sam ›` swipe peek, live status (`Protected · Galaxy S23 · Home`), tabular `1h 42m / 3h 00m`, alert card (`1 message to review · WhatsApp · Maya`), Location strip, swipe-up handle, and floating 4-button dock (`Pause`, `+30 min`, `Locate`, `More`) | Swipe left for **Sam**, tap a quick dock action, or swipe up for control sheets |
| `P-07-D-ar.png` | **Hero: One child, full screen (AR RTL)** | Full screen (0 tabs, RTL) | Full Arabic RTL mirror of `P-07-D` (`أسرة`, `محمي`, `الوقت المتبقي`, `رسالة واحدة تستدعي المراجعة`, `إيقاف مؤقت`, `+30 دقيقة`, `تحديد الموقع`, `اسحب للأعلى للتحكم والتطبيقات`, `أليكس`/`سام`, Western numerals `1:42`, `3:00`) | Swipe right for **سام**, tap a dock action, or swipe up for controls |
| `P-08-D.png` | Device controls | Bottom sheet | Pulled over `P-07` backdrop: **This device** controls (`Lock`, `Pause device`, `Ring`, `Record delivery`) + **All paired devices** (`Pause internet`), honoring OSRA's scope-label contract | Tap **Lock**, **Pause device**, **Ring**, or **Pause internet** |
| `P-09-D.png` | Apps | Bottom sheet | Search bar, App groups (`Games · Blocked`, `Social · 1h limit`), per-app rows (`YouTube`, `Roblox`, `Minecraft`, `WhatsApp`) with badges/toggles, `+ Add app rule` | Toggle an app rule or tap **+ Add app rule** |

### Parent App — Control, Safety & Family Sheets (`P-10-D`..`P-23-D`)

| File | Screen | Surface | What it shows | First action |
|---|---|---|---|---|
| `P-10-D.png` | Screen time | Bottom sheet | Weekday 2h / Weekend 3h sliders, daily progress `1h 42m used`, `+30 min bonus today` quick pill, category breakdown bars | Tap **+30 min bonus today** or adjust Weekday/Weekend sliders |
| `P-11-D.png` | Routines | Bottom sheet | 24h visual day strip with Bedtime (`#C7D0E2`) and School (`#DCE4CC`) bands, active toggle cards (`Bedtime 21:00–07:00`, `School 07:30–14:30`, `Homework 16:00–18:00`), `+ Add routine` | Toggle a routine card or tap **+ Add routine** |
| `P-12-D.png` | Web protection | Bottom sheet | Recommended 13-category shield switch ON, SafeSearch + YouTube Strict pills, Allowed/Blocked website chips + `+ Add website rule` | Toggle shield/SafeSearch or tap **+ Add website rule** |
| `P-13-D.png` | Location | Bottom sheet | Stylized SVG vector map with Alex's teal pin, `Home` geofence ring, saved places pills (`Home`/`School`), `Updated 4m ago · Refresh location` primary CTA | Tap **Refresh location** or jump to a saved place |
| `P-14-D.png` | Alerts | Bottom sheet | Grouped by `Today` / `Earlier`, severity dot chips (`critical`/`warning`/`info`), per-contact count (`+3 new · WhatsApp · Maya`), swipe-to-ack hint | Tap an alert row to open its detail sheet |
| `P-15-D.png` | Safety alert detail | Bottom sheet | Severity badge, `Encrypted on device` trust strip, concern chips (`grooming_risk`, `secrecy`), synthetic demo excerpt, Parent Coaching Card (`How to talk calmly with Alex`), `Mark reviewed` + `Open social activity` | Read the coaching card and tap **Mark reviewed** |
| `P-16-D.png` | Child's Day summary | Bottom sheet | `Tuesday, November 24` timeline pills for screen time, routine switches, 1 blocked site, 1 location arrival at Home, calm end-of-day summary | Scan the day timeline or tap an entry for detail |
| `P-17-D.png` | Social safety | Bottom sheet | All 12 child-monitored apps: Installed A–Z with switches, collapsed `Not on Alex's phone (8)` row, privacy promise (`"OSRA only flags concerning messages. It never shows you every chat."`), YouTube `"Comments and chats"` subtitle | Toggle per-app safety switches or expand **Not on Alex's phone (8)** |
| `P-18-D.png` | Weekly insights | Bottom sheet | 7-day stacked bar chart Mon–Sun (today highlighted in `#0B5D57`, limit line in `#8A4B00`), top 3 apps, `+12% calmer evenings` insight card, `View history` | Inspect the weekly chart or tap **View history** |
| `P-19-D.png` | Usage history | Bottom sheet | Segmented toggle (`Apps` / `Websites`), chronological usage rows with category color dots & durations, `Export CSV` action | Switch **Apps / Websites** or tap **Export CSV** |
| `P-20-D.png` | Requests | Bottom sheet | Pending card (`Alex asked for +30 min on Minecraft`) with `Approve +30m` / `Decline` buttons + Past requests list | Tap **Approve +30m** or **Decline** |
| `P-21-D.png` | Family | Bottom sheet | Owner card, Co-parent card, Children list (`Alex` & `Sam` with color dots), `+ Invite a caregiver` & `+ Add a child` | Tap **+ Invite a caregiver** or **+ Add a child** |
| `P-22-D.png` | Settings | Bottom sheet | Language (`EN` / `العربية`) switcher, Appearance (`Light` / `Dark`), Notifications & Quiet Hours, Parent PIN & 2-Step Security, App version | Change language, theme, or security preferences |
| `P-23-D.png` | Privacy and data | Bottom sheet | Plain-language retention (`90 days for flagged excerpts · 12 months for alerts`), `Download my family data`, `Pause monitoring`, `Withdraw consent / Delete child data` in calm danger styling | Tap **Download my family data**, **Pause monitoring**, or **Withdraw consent** |

### Child App — Calm, Transparent Single-Canvas Experience (`C-01-D`..`C-05-D` + `C-01-D-ar`)

| File | Screen | Surface | What it shows | First action |
|---|---|---|---|---|
| `C-01-D.png` | **Child "My day" (EN)** | Full screen (0 tabs) | Friendly, non-punitive home with OSRA shield mark, big calm remaining-time ring (`1h 18m left today`), next routine pill (`Homework starts at 16:00`), transparent active protection strip (`Web filter on · Location shared with Mom & Dad`), pending request peek, primary **Ask for more time** button, and swipe-up **My activity** pill | Tap **Ask for more time** or swipe up on **My activity** |
| `C-01-D-ar.png` | **Child "My day" (AR RTL)** | Full screen (0 tabs, RTL) | Full Arabic RTL mirror of `C-01-D` (`يومي`, `متبقي اليوم`, `1:18`, `الروتين القادم: الواجبات 16:00`, `فلتر الويب مفعّل`, `طلب وقت إضافي`, `طلب الوصول`, `نشاطي`) with isolated Western tabular numerals and zero clipping | Tap **طلب وقت إضافي** / **طلب الوصول** or swipe up on **نشاطي** |
| `C-02-D.png` | Child "Time's up" shield | Full screen | Calm deep-teal surface (never punitive red), OSRA brand mark, Minecraft daily-limit badge, friendly subtitle (`"Your daily time for Minecraft is up for today. It resets tomorrow at 07:00."`), primary **Request access** CTA (#882 copy), `Back to My day`, and always-available **Emergency call** safe link | Tap **Request access** (or **Emergency call** if needed) |
| `C-03-D.png` | Child "Ask for more time" | Bottom sheet | Pulled over `C-01` backdrop: target chips (`Minecraft` / `All screen time`), quick duration pills (`+15 min`, `+30 min`, `+1 hour`), optional friendly note (`"Finishing my build with Sam"`), clear approval note, primary **Send request** CTA | Choose a duration (`+30 min`), optionally add a note, tap **Send request** |
| `C-04-D.png` | Child "My activity" | Bottom sheet | Pulled over `C-01` backdrop: calm encouragement banner, transparent today's app usage bars (`Minecraft`, `YouTube`, `WhatsApp`, `Duolingo`), 2 recent requests with `Pending` / `Approved` pills, parity note (`"You see the same screen-time totals that Mom & Dad see."`) | Review today's usage and request statuses (swipe down to close) |
| `C-05-D.png` | Child "Set up this device" | Full screen | Guided `Step 1 of 3` pairing flow with OSRA shield mark, `"Enter the 6-digit code from your parent's phone"`, 6 crisp digit boxes (`482–916`), `Continue` + `Scan QR code`, and transparent **What OSRA checks** card so nothing feels hidden | Enter the 6-digit code and tap **Continue** (or **Scan QR code**) |
