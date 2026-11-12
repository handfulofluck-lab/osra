# ADR-0041 — One family plan on every platform, and the Windows and Mac clients downloaded from osratech.com

- **Status:** proposed (2026-11-12). Architecture is Claude's call; the items marked **M1–M4** are the
  maintainer's (money, legal, pricing) and are put to him as decision cards.
- **Date:** 2026-11-12
- **Deciders:** Claude (architecture, QA); Karim (money, legal, pricing, launch scope). Built by Kimi and
  K31 (billing, Windows, parent app), Ahmed (Mac, security review).
- **Related:** ADR-0002 (consent gate), ADR-0012 (command queue), ADR-0013 (retention and erasure),
  ADR-0014 (family roles), ADR-0034 (capability report, `X-OSRA-Client`), ADR-0036 (macOS agent),
  ADR-0039 (Full Android download and signed update manifest). Roadmap rows **5.4** (amended), **5.9**
  (amended), new **5.12** and **5.13**.
- **Amends:** ADR-0036 decision "the Mac never enters the Phase 5 gate" (see D7). Nothing else in
  ADR-0036 changes.

## Context

The maintainer, 2026-11-12 12:15Z: *"If I subscribe and buy, let's say via my Android app, but I want to
manage my kid's Windows, I need to be able to install the Windows client from the OSRA website."* Then:
*"Also the Mac desktop app"* and *"All need to be ready, as this is our core capability."*

So the product promise is: **a family buys once, on whichever phone the parent uses, and that plan covers
every child and every device the family pairs: Android, iPhone, Windows and Mac.** The computer clients are
not in any store; the parent downloads them from osratech.com and pairs them from the parent app.

What exists today (checked on `main@4d3a291`):

1. **No billing at all.** No purchase code in the parent app, no subscription or entitlement table on the
   server, no store products. (`customer-guide` launch gaps, 2026-11-07, said the same.)
2. **Windows agent** (`apps/agent-desktop`, .NET 8, ~4,500 lines, 171 xunit cases, CI on
   `windows-latest`): pairing with parent approval, rule sync, app blocking by process, screen time,
   routines, lock overlay, SOS hotkey, pause, tamper and VPN heuristics, URL telemetry. It is **not
   shippable**:
   - It runs as **one interactive user process**. There is no Windows service, no watchdog, no installer.
   - Web filtering is a **WinINET proxy on 127.0.0.1:8877** written into **HKCU**. A Standard user can
     switch that proxy off in Settings, and HTTPS `CONNECT` is not filtered; the only HTTPS answer is an
     optional MITM root CA (`FS_HTTPS_INSPECT=1`) that we will not ship to families.
   - Release builds still read `API_BASE`, `DEVICE_JWT`, `DEVICE_ID`, `CHILD_ID`,
     `INTERNAL_HMAC_SECRET` and the PIN from environment variables (`AgentConfig.Load`).
   - The pairing window asks the child's computer for a **server URL**, which no parent will know.
   - It is still named FamilyShield in 40 places in `Services/` (namespace, data folder, root-cert name).
   - It does not send `X-OSRA-Client` or a capability report (ADR-0034).
   - Roadmap 5.4 says "MSIX installer". MSIX cannot register a LocalSystem service without a restricted
     capability, and cannot write machine-wide browser policies, so it does not fit this agent.
3. **Mac agent**: designed in ADR-0036 (Swift daemon + content-filter system extension + menu-bar agent,
   Developer ID, outside the Mac App Store); M2 spike rows (a) and (b) passed 2026-11-11; build step (i)
   not started; beta was planned for Q2 2027, outside the launch gate.
4. **Website**: `site/` has home, privacy and delete-account (3.19, merged in #592, not published). The
   Full Android page (`/android/`, ADR-0039, #589) sets the pattern this ADR reuses: the `site` S3 +
   CloudFront stack, an offline-signed update manifest, no page online before the build it links to.

### Store rules that shape the design (checked 2026-11-12)

- **Google Play.** Digital subscriptions bought *inside* an app on Play must use Play Billing. An app may
  let a user *use* something bought elsewhere ("Google Play allows any app to be consumption-only, even if
  it is part of a paid service"). An app that sells through Play may **not** link to a web page "that
  could lead to an alternate payment method"; links to account, help and privacy pages are fine as long as
  they never lead to one. Outside the app we may talk to users about other ways to pay. (Play Console
  Help, *Understanding Google Play's Payments policy*, answer 10281818.) US, EEA, India and Korea have
  programs that relax this; we do not need them.
- **Apple.** Guideline 3.1.1: a feature unlocked inside an iOS app is sold with In-App Purchase.
  Guideline **3.1.3(b) Multiplatform Services**: an app that works across platforms may let users use a
  subscription bought on another platform or on our website, **provided the same subscription is also
  offered as In-App Purchase in the app**, and without steering users to buy elsewhere.
- **Windows and Mac clients** are not distributed by a store and sell nothing, so no store payment rule
  applies to them. They only *use* the family plan.
- **Code signing.** Microsoft's Azure Artifact Signing (formerly Trusted Signing, $9.99/month) issues
  certificates to **individuals in the USA and Canada only** and to organisations in the USA, Canada, EU
  and UK. The maintainer's Apple team is an **individual** account, so the Windows route is a public CA
  certificate (M1). Apple's **Developer ID** certificates and notarisation come with the paid Apple
  Developer Program the maintainer already has, so the Mac costs nothing extra.

## Decision

### D1 — The plan belongs to the family, and only the server decides it

- New table **`family_purchases`**: `family_id`, `source` (`google_play` | `app_store` | `web` | `grant`),
  `product_id`, a store reference (Play purchase token, or Apple `originalTransactionId`), `status`
  (`active` | `grace` | `on_hold` | `expired` | `revoked` | `refunded`), `expires_at`, `auto_renews`,
  `last_verified_at`. One row per purchase; a family can have more than one row over time.
- **`entitlement(family)`** is computed by the server from those rows: the best active row wins. It
  answers `{ plan, until, source, manage_on }`. Nothing on a client is trusted for this.
- The plan covers **every child and every device of the family** on all four platforms. There is no
  per-device or per-platform purchase. A fair-use cap on paired devices per family stops resale of one
  plan (number: **M3**).
- **Who buys:** the family **owner** only (ADR-0014 roles). Every guardian sees the plan's state. This
  matches the "export is owner-only" ruling of 2026-10-26.
- **Beta families** get a `grant` row (source `grant`, an expiry date, the reason). Grants are created by
  an admin script that runs with the maintainer's AWS profile, never by a public route.
- **Feature gating is server-side.** The server leaves premium rules out of the rule set it sends and
  refuses premium routes with a typed `402 plan_required`. A child agent never decides whether the family
  has paid; it enforces what it is sent.

### D2 — How a purchase reaches the server

- **Android parent app → Google Play Billing.** The purchase carries `obfuscatedAccountId` = an opaque
  per-family id (never an email or name). The app sends the purchase token to
  `POST /v1/billing/google/verify`; the server checks it with the Play Developer API
  (`purchases.subscriptionsv2`), acknowledges it, and writes the row. **Real-time developer notifications**
  (Pub/Sub push to `POST /v1/billing/google/rtdn`, authenticated by the Pub/Sub OIDC token) keep renewals,
  grace, account hold, cancellations and refunds current.
- **iOS parent app → StoreKit 2.** The purchase carries `appAccountToken` = a per-family UUID. The app
  sends the signed transaction to `POST /v1/billing/apple/verify`; the server verifies the JWS chain to
  Apple's root and writes the row. **App Store Server Notifications V2** to
  `POST /v1/billing/apple/notifications` keep it current.
- The same product shape on both stores: one family plan, monthly and yearly (prices: **M3**).
- **Web checkout** (a card payment on osratech.com) is **M2**. **Decided 2026-11-12 12:58Z: in the apps only at launch** (the maintainer chose Claude's recommendation on the decision card). The reasons: both
  stores already sell the plan, each takes 15% on subscriptions (Apple after we join its Small Business Program), they handle
  VAT and refunds in every country, and a website with no buy button keeps every download link from the
  apps safe under both stores' anti-steering rules. If the maintainer later wants web sales, it is a third
  `source` behind the same `entitlement()`, sold through a merchant of record so we do not register for
  VAT country by country, and D4's rule about download pages still holds.
- **We do not use a billing middleman** (RevenueCat or similar). We need subscriptions only, on two
  stores, the verification APIs are documented, and purchase data then stays in our Frankfurt stack
  (ADR-0030) instead of going to another US processor.

### D3 — What each parent app shows

- **No plan:** the store's own purchase sheet (Play on Android, In-App Purchase on iOS). This is what
  3.1.3(b) needs on iOS.
- **Plan active, bought on the same store:** status, renewal date, and the store's own "Manage
  subscription" page.
- **Plan active, bought on the other store:** "Your family's plan is active. It was bought on Google Play
  (or App Store) and is managed there." No buy button (that would bill the family twice), no link to any
  payment page.
- **Lapse:** the stores' own grace and account-hold periods count as active. After the plan ends, the
  family keeps its children, devices, rules and history; nothing is unpaired or deleted, and a child is
  never left suddenly unprotected at night: the change takes effect at the next family-local 10:00.
  What a family without a plan keeps is the free tier (**M3**).
- Restore: "Restore purchases" on both apps re-sends the store's current transactions to the server.

### D4 — The computer clients come from osratech.com

- **Pages:** `osratech.com/windows/` and `osratech.com/mac/`, English and Arabic, same design language
  and stylesheet as 3.19 and `/android/`. Each page says what the client does, the system it needs, how
  to install it in three steps, and how to pair it. Like `/android/`: **no page goes online before the
  build it links to works**, no "coming soon", no SHA-256 on the page. Arabic goes through the Arabic
  Language Bureau before the maintainer sees it.
- **No payment path on these pages or anywhere they link to**, so the parent apps may link to them on
  both stores. A CI check fails if `site/windows/` or `site/mac/` contains a price, "buy", "subscribe" or
  a link to a checkout.
- **Files** live on the existing `site` stack (S3 + CloudFront, `infra/terraform/site`) under
  `/windows/` and `/mac/`, uploaded by OIDC roles that may write only those prefixes (the ADR-0039 D4
  pattern).
- **One installer for everyone.** The download is not personalised: no family id, token or secret is
  baked into it. The production API address is compiled in; the pairing window never asks for a server.
- **Updates:** each client updates itself from an Ed25519-signed `latest.json` + `latest.json.sig`,
  signed **offline** with the same rules as ADR-0039's amendment (exact-bytes signature, strict URLs,
  downgrade refused, two public keys for rotation). Windows also checks that the downloaded MSI carries
  one of our Authenticode signers before running it (a list of up to two, so a move from a personal
  certificate to a company certificate ships first as an update that trusts both); the Mac uses Sparkle 2 with an EdDSA-signed appcast, which
  also checks the Developer ID signature.

### D5 — Pairing a computer from the parent app

1. Parent app → child → **Add a computer** → picks Windows or Mac. The app shows the 6-digit pairing code
   (existing `POST /v1/devices/pair`, 600 s) and the address `osratech.com/windows` or `/mac`, with a
   "Send the link" share sheet so the parent can send it to themselves or open it on the computer.
2. On the computer, a Mac or Windows **administrator** (the parent) installs the client. The first run
   shows: pairing code, then a parent PIN typed twice. No server field.
3. The parent taps **Allow** on the phone (the existing approval flow, osra-security#3 PR 2).
4. The client sends `X-OSRA-Client` and its capability report (ADR-0034), so the parent app shows only
   what that computer can enforce.
5. If the child's own Windows or Mac account is an **administrator**, pairing warns the parent in the
   app: "Protection is weak on this computer because your child's account is an administrator." The
   model on both systems is: the parent is the admin, the child is a Standard user.
6. The parent PIN stays on the computer, hashed, as on Android and iOS (ADR-0010, ADR-0037). It is never
   sent to the server. Roadmap 5.4's "PIN synced from the parent account" is dropped for that reason;
   a forgotten PIN is reset by a signed command from the parent app (ADR-0012).

### D6 — The Windows client that ships

- **Two processes**, the same split as the Mac (ADR-0036 D3):
  - **`OSRA Service`** (Windows service, LocalSystem, automatic start, recovery set to restart after
    every failure = the watchdog): rule sync, command queue, telemetry, heartbeat for tamper alerts
    (ADR-0027), web filtering, killing blocked processes in every session, and keeping the tray agent
    alive.
  - **`OSRA` tray agent** (per user, started for every user at sign-in by the service): lock and bedtime
    overlay, block page, "ask for more time", SOS hotkey, pairing window, Arabic and English.
  - They talk over a named pipe whose ACL admits only SYSTEM and the signed tray binary's session.
- **Web filtering is system-wide, not a user proxy.** The service runs a local DNS resolver with the same
  rules as the Android DNS filter (ADR-0015): block list, categories, SafeSearch and YouTube Restricted
  by DNS answer, pause-internet. It sets every adapter's DNS to that resolver and adds Windows Firewall
  rules that block outbound 53 and 853 to anything else. Machine-wide browser policies (HKLM, the
  documented Chrome, Edge and Firefox policies) turn off DNS-over-HTTPS in the browser and force
  SafeSearch. A Standard user can change none of these.
- The **WinINET proxy, the MITM root CA and `reset-proxy.bat` are removed** from release builds.
  `HttpsInterception.cs` stays out of any build a family gets.
- **Release builds ignore every environment variable** that names the server, an identity, a secret or
  the PIN; only debug builds read them.
- **Installer: MSI (WiX), per-machine, x64 and ARM64**, Windows 10 22H2 and Windows 11. Uninstall needs
  an administrator (the parent); a Standard user cannot stop the service or remove it. Uninstall or a
  stopped heartbeat raises the existing tamper alert.
- **Signed** with the code-signing certificate (M1); the private key stays in the CA's cloud HSM or token,
  never in the repo or in a GitHub secret as a file. CI builds unsigned MSIs on every PR; signing is a
  release step.
- Every visible "FamilyShield" goes (with #608).

### D7 — Launch scope: all four platforms, in two waves

The maintainer made the computer clients **core capability**. ADR-0036's rule that the Mac stays out of
the Phase 5 gate is replaced by this:

| Wave | When (estimate, not a promise) | Platforms | Plan sold on |
|---|---|---|---|
| Closed beta | Android mid to late December 2026; **Windows joins by 8 January 2027** | Android phones, Windows computers | free `grant` for beta families; Play Billing on the internal and closed tracks with licence testers |
| Public 1 | February 2027 | Android, **Windows** | Google Play |
| Public 2 | set by the iOS lane now that Apple granted Family Controls (Distribution) on 2026-11-12; the Mac aims for the same wave and **no later than March 2027** | iPhone, **Mac** | Google Play and App Store |

What has to move for this:

- **Mac moves from Q2 2027 to March 2027 at the latest.** Ahmed takes the Mac build (ADR-0036 steps i–vi,
  plus D4's updater and page) as soon as the OSRA Kids build is in TestFlight. Apple granted Family
  Controls (Distribution) on 2026-11-12, so that wait is gone; the iPhone may now launch before the Mac,
  and the Mac follows as soon as it passes claims 6, 7 and 9.
- **Windows (5.4) moves from Antigravity's lane to Kimi and K31.** K31 writes the code and tests in
  GitHub; Kimi reviews and merges; Claude tests on a Windows test machine (not the maintainer's own PC,
  because the agent rewrites DNS and firewall rules).
- **Billing (5.12) is new launch-blocking work** in Kimi's and K31's lane, started now, ahead of the
  Play launch items that do not depend on it.

## Alternatives considered

- **Per-platform purchases** (buy the Windows client separately). Rejected: it is exactly what the
  maintainer said a family must not have to do, and it would need a web shop for Windows.
- **Sell only on the website.** Rejected: both parent apps would then be consumption-only, which Apple
  allows only if the app also offers In-App Purchase (3.1.3(b)), and it puts VAT and refunds on us.
- **Keep the WinINET proxy and ship the MITM root CA.** Rejected: a Standard user can turn the proxy
  off, and installing our own root in a child's trust store is a security liability we will not carry.
- **MSIX** (the old 5.4 wording). Rejected for the service and machine-policy reasons in Context 2.
- **Microsoft Store** for the Windows client. Rejected: Store apps cannot run a LocalSystem service or
  set firewall and machine policy, so it would be a weaker agent with a store payment rule on top.
- **Mac App Store** for the Mac client. Rejected in ADR-0036 (no root daemon, no system extension).
- **RevenueCat.** Rejected in D2.

## Maintainer decisions (cards in the project thread)

- **M1 — Windows code-signing certificate.** Spend was approved earlier for 5.4; the route is open:
  an OV certificate in the maintainer's own name (fastest; the publisher shown is his name), an OV
  certificate in a company's name (needs company registration documents), or EV (costs more and no
  longer buys instant SmartScreen trust).
- **M2 — Where families can pay.** **Decided 2026-11-12: in the apps only at launch** (Google Play and
  the App Store); osratech.com offers downloads only.
- **M3 — Prices and what a family without a plan keeps** (monthly and yearly price per store region,
  the free tier, the device cap).
- **M4 — Store paperwork** the maintainer does in the consoles: the subscription products on Play and
  App Store Connect, the Play service account for the Developer API, the RTDN Pub/Sub topic, the App
  Store Server Notifications URL, and the Data safety / App Privacy "Purchases" answers. Claude prepares
  each step; the Mac does the Apple side where it can.

Also: the Apple team name still reads "Karin Abdelaziz" (Membership Information Update filed
2026-11-12). The Developer ID certificate, and so the Mac installer's "identified developer" line,
carry that name until Apple fixes it. The first notarised Mac build waits for the fix.

## Falsifiable claims (what the verifiers test)

1. A family that subscribes on the Android parent app sees the plan active within 60 s on the iPhone
   parent app and on a paired Windows computer's status window; no second purchase is offered anywhere.
2. Refunding the Play purchase in the Play Console turns the family's plan off through RTDN within
   10 minutes, with no client involved.
3. A forged or replayed purchase token, a token for another family's `obfuscatedAccountId`, and an
   Apple JWS not chained to Apple's root are each refused with no row written.
4. A child agent sent a rule set without premium rules does not enforce premium rules from its cache.
5. On Windows, a Standard user cannot: stop or disable `OSRA Service`, change an adapter's DNS, reach
   a blocked domain through Chrome, Edge or Firefox (with DoH on in the browser's own settings), or use
   an outside DNS server on 53 or 853. Each attempt either fails or raises a tamper alert within 2 min.
6. The Windows MSI and the Mac package install without a SmartScreen "unknown publisher" or Gatekeeper
   "unidentified developer" block on a clean machine.
7. A tampered `latest.json`, an older version, and an MSI not signed by us are each refused by the
   updater (the ADR-0039 rows, re-run on Windows and Mac).
8. No page under `site/windows/` or `site/mac/` contains a price or a path to a payment (CI).
9. A non-engineer parent installs and pairs the Windows client from the page and the parent app without
   help (the R7 test of ADR-0039, for Windows; then for the Mac).

## Build order (one PR each; issues filed 2026-11-12)

Billing (5.12): B1 entitlement model, `GET /v1/family/entitlement`, `402 plan_required`, grants (K31) →
B2 Play verification + RTDN (Kimi) → B3 Apple verification + notifications (Kimi) → B4 parent app plan
screen on Android and iOS (Kimi).

Windows (5.4): W1 service + tray split, release config without env overrides, production API compiled in
(K31) → W2 DNS resolver, firewall and browser policies; proxy and MITM removed (K31) → W3 MSI x64/ARM64,
service recovery, unsigned CI artifact, signing step (K31; the certificate is M1) → W4 signed self-update
(K31) → W5 parent app "Add a computer" (Kimi).

Mac (5.9): ADR-0036 steps (i)–(vi) (Ahmed), plus Sparkle updater and notarised package.

Website (5.13): `/windows/` and `/mac/` pages, the no-payment CI check, the upload roles (Claude), merged
only with the first release of each client.

## Consequences

- Good: one purchase, every device; the computers become first-class OSRA clients; both computer clients
  share one tamper model (parent admin, child Standard user) and one update model with Android Full.
- Good: purchase data stays in our EU stack; no new processor.
- Cost: two store integrations and two notification endpoints to run and monitor; refunds and
  cancellations must be tested on both stores before launch.
- Cost: the Windows web filter is rebuilt (DNS + firewall + policies). The process-blocking, screen-time,
  routine and lock code carries over; the proxy code does not.
- Cost: a Windows code-signing certificate every year, and SmartScreen reputation that builds with
  downloads, so the first public weeks may still show a "not commonly downloaded" note.
- Risk: a child who is an administrator on the computer can remove the client. We say so to the parent
  at pairing; we do not pretend otherwise.
- Risk: the Mac date depends on Ahmed's time after the iPhone kids build ships to TestFlight.
