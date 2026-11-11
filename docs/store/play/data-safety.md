# Google Play Data safety answers

**What this is for.** These are the answers for Google Play's **Data safety** form, for both Play apps:

- the **child agent**, `play` flavour (`apps/child-android`). The sideloaded `full` build is not on Play and is
  not covered here;
- the **parent app** (`apps/parent-app`).

Each answer points at the code that makes it true, so a reviewer can check it. It is not legal text. Karim's
decisions, and the work they still need, are listed at the end (§6).

**Checked against:** `origin/main` at `5d3e49c` (2026-11-11). Every `file:line` below was re-read at that
commit. It started as §2 of the 29 October Play submission draft (made at `e6e532b`), with the evidence moved
to the current lines, the account-deletion row filled in, the capability report added, and the retention
numbers confirmed from the code.

**Updated 2026-11-11** with Karim's Play decisions 5 to 17 and his two data-safety answers (location and
diagnostics). §6 lists every decision and the work each one still needs. Where an answer depends on code
that is not on main yet, the row names the issue that adds it (#562).

---

## 1. How to read the answers

Google treats a transfer to a service provider that processes data on our behalf (AWS hosting, Google FCM
delivery, the email sender: AWS SES once #562 C lands, decision 11) as **not "sharing"**. Every "Shared = No" below relies on that rule.

"Encrypted in transit" rests on the release network-security configs. Both are HTTPS-only:

- child: `apps/child-android/app/src/main/res/xml/network_security_config.xml:5`;
- parent: `apps/parent-app/android/app/src/main/res/xml/network_security_config.xml:5`.

The debug builds override these files for LAN testing. The debug builds are never uploaded.

## 2. Form-level answers, both apps

| Question | Answer |
|---|---|
| Collects or shares required data types? | Yes |
| All user data encrypted in transit? | Yes (configs above) |
| Way to request deletion? | **Yes: in the app and on the web.** Details in §2.1. |
| Independent security review? | No |
| Is delivering the child's data to the parent's account "sharing"? | **No** (Karim, decision 8). The parent is the account holder who set it up, and it is the app's core function. |

### 2.1 How a user deletes their account and data

Only the parent app creates accounts. The child agent has no account of its own: a child's data belongs to
the parent's family and is deleted with it.

| Path | What the user does | Evidence |
|---|---|---|
| **In the parent app** | Dashboard, then the menu (⋮, top right), then **Delete account**. The parent types their own email, then their password, and their authenticator code if MFA is on. | Menu entry `apps/parent-app/lib/features/dashboard/dashboard_screen.dart:57,65`; route `apps/parent-app/lib/app.dart:118`; the call `apps/parent-app/lib/features/settings/delete_account_screen.dart:80-86` |
| **On the web (the URL for the Play Console)** | **`https://osratech.com/delete-account`** (decision 5). It forwards to the page the API serves at `/v1/account/delete`; the forward is owed (#562 B). The page explains the in-app steps and asks for the account's email. A known address gets a link that works once, for 30 minutes. The link asks for the password (and MFA code) before anything is deleted. English and Arabic. | Page `services/api/src/routes/account.ts:280`; request `:288`; confirm `:305,323`; mounted at `services/api/src/server.ts:130` |

What each deletion removes:

- **The owner** deletes the whole family: every child's data, every linked phone, every other parent and
  guardian, and the family (`DELETE /v1/family`, `services/api/src/routes/family.ts:380-394`;
  `services/api/src/lib/accountDeletion.ts:152`).
- **A co-parent or guardian** deletes only their own account. The family and the children stay
  (`DELETE /v1/me`, `services/api/src/routes/me.ts:65-78`; `services/api/src/lib/accountDeletion.ts:189`).
- Each child goes through the same erasure the server already had: every child-scoped table, and each phone's
  token is revoked (`services/api/src/lib/usageModel.ts:257-276,293`).
- **Kept:** the ids of signed-out tokens until those tokens would have expired, at most 8 days
  (`services/api/src/lib/accountDeletion.ts:92-95`), and database backups until they rotate out.

Deleting one child's data without deleting the account exists on the server only
(`DELETE /v1/family/children/:id`, `services/api/src/routes/family.ts:239-242`). No screen calls it, so do
not offer the optional "delete some data" URL on the form.

## 3. Child agent (Play flavour)

| Data type | Collected | Shared | Purpose | Optional? | Evidence |
|---|---|---|---|---|---|
| **Precise location** | Yes | No | App functionality (locate, geofence alerts) | Required. Onboarding marks it required (`apps/child-android/app/src/main/java/com/familyshield/agent/setup/OnboardingPolicy.kt:26`). | `apps/child-android/app/src/main/AndroidManifest.xml:29-30` (fine and background); `apps/child-android/app/src/main/java/com/familyshield/agent/network/dto/PayloadDtos.kt:6-11` (lat, lng, accuracy, time); upload `apps/child-android/app/src/main/java/com/familyshield/agent/services/LocationService.kt:305`; high-accuracy locate `:199`. Kept 30 days (§5). |
| **Approximate location** | Yes | No | App functionality | Required | Routine fixes use `PRIORITY_BALANCED_POWER_ACCURACY` (`apps/child-android/app/src/main/java/com/familyshield/agent/services/LocationService.kt:62,266`) |
| **Personal info** (name, email, phone, address, IDs, other) | No for the device user | — | — | — | The child's name and birth year are entered in the parent app, not by the agent (`services/api/src/routes/family.ts:24-28`). Third-party names and numbers are under Contacts below. |
| **Messages: Other in-app messages** | Yes | No | App functionality (safety alerts) | Optional: the parent can switch it off per app (`apps/child-android/app/src/main/java/com/familyshield/agent/social/SocialCapture.kt:33`, `apps/child-android/app/src/main/java/com/familyshield/agent/network/dto/RulesDtos.kt:27`). The parent chooses the apps during setup, all ticked by default (decision 14; the setup step is #562 D). Today the key's absence means on. | Capture of visible text in 12 mapped apps (`apps/child-android/app/src/main/java/com/familyshield/agent/social/MonitoredApps.kt:10-23`; `apps/child-android/app/src/main/java/com/familyshield/agent/social/SocialCapture.kt:29-49`, at most 4000 characters per event `:70`). Masked on the phone (`apps/child-android/app/src/main/java/com/familyshield/agent/social/TextRedaction.kt:19-23`). Sent in batches (`apps/child-android/app/src/main/java/com/familyshield/agent/social/SocialScanQueue.kt:91-97`; `apps/child-android/app/src/main/java/com/familyshield/agent/network/dto/SocialDtos.kt:6-14,20`). The server keeps only a flagged excerpt of at most 240 characters, encrypted (`services/api/src/routes/social.ts:39,131-139`), deleted after 90 days (§5). |
| **Messages: SMS/MMS** | **No** (Play) | — | — | — | Forbidden in the Play artefact (`apps/child-android/app/src/test/java/com/familyshield/agent/manifest/PlayManifestPolicy.kt:48-49,53-54`); `CAPTURE_CALL_SMS=false` (`apps/child-android/app/build.gradle.kts:140`); no-op capture (`apps/child-android/app/src/play/java/com/familyshield/agent/di/CommsBindingModule.kt:20`). WhatsApp call rows come only from the Full build's notification listener (`apps/child-android/app/src/full/java/com/familyshield/agent/services/NotificationCaptureService.kt:50`). |
| **Messages: Emails** | No | — | — | — | No email access in the manifest (`apps/child-android/app/src/main/AndroidManifest.xml:28-48`) |
| **Photos and videos** | No | — | — | — | The camera is used only for the QR preview. Nothing is stored or sent (`apps/child-android/app/src/main/AndroidManifest.xml:41-48`; `apps/child-android/app/src/test/java/com/familyshield/agent/manifest/PlayManifestPolicy.kt:38`). |
| **Audio** | No | — | — | — | No `RECORD_AUDIO` (allow list `apps/child-android/app/src/test/java/com/familyshield/agent/manifest/PlayManifestPolicy.kt:25-44`) |
| **Files and docs** | No | — | — | — | No storage permission (same allow list) |
| **Calendar** | No | — | — | — | Same |
| **Contacts** | Yes | No | App functionality (safety alerts, unknown-contact alert) | Optional, with message capture | A chat partner's displayed name or number goes with each scan (`apps/child-android/app/src/main/java/com/familyshield/agent/network/dto/SocialDtos.kt:12`; `apps/child-android/app/src/main/java/com/familyshield/agent/social/SocialCapture.kt:47-49`). When the parent has set a contact allow list (`apps/child-android/app/src/main/java/com/familyshield/agent/network/dto/RulesDtos.kt:28-32`), a numeric contact not on it raises an alert carrying its digits (`apps/child-android/app/src/main/java/com/familyshield/agent/social/SocialScanQueue.kt:115-135`). No `READ_CONTACTS`. |
| **App activity: App interactions** | Yes | No | App functionality (limits, reports) | Required. Usage access is required (`apps/child-android/app/src/main/java/com/familyshield/agent/setup/OnboardingPolicy.kt:22`). | Per-app minutes, total, unlocks (`apps/child-android/app/src/main/java/com/familyshield/agent/network/dto/PayloadDtos.kt:19-22`; upload `apps/child-android/app/src/main/java/com/familyshield/agent/telemetry/UsageReporter.kt:161-171`). The foreground app every 60 s or less while the screen is on (`apps/child-android/app/src/main/java/com/familyshield/agent/telemetry/LiveActivity.kt:10-13`; `apps/child-android/app/src/main/java/com/familyshield/agent/telemetry/UsageReporter.kt:204-211`). |
| **App activity: Installed apps** | Yes | No | App functionality (app rules, install alerts) | Required | Package, label, system flag, and whether Android treats it as essential (`apps/child-android/app/src/main/java/com/familyshield/agent/network/dto/PayloadDtos.kt:65-82`; upload `apps/child-android/app/src/main/java/com/familyshield/agent/apps/InstalledAppsReporter.kt:56`). Install alert (`apps/child-android/app/src/main/java/com/familyshield/agent/receivers/PackageAddedReceiver.kt:62-70`). |
| **App activity: Other actions** | Yes | No | App functionality | Required | SOS (`apps/child-android/app/src/main/java/com/familyshield/agent/sos/SosActivity.kt:98-106`); access request from the block screen (`apps/child-android/app/src/main/java/com/familyshield/agent/enforcement/BlockActivity.kt:198-206`) |
| **App activity: In-app search history** | No | — | — | — | — |
| **Web browsing history** | **No** | — | — | — | DNS is filtered on the phone and forwarded to the network's resolver (`apps/child-android/app/src/main/java/com/familyshield/agent/vpn/FilterVpnService.kt:236-256,270-279`). No upload call exists in `vpn/`. The agent's only activity upload is `app_usage` (`apps/child-android/app/src/main/java/com/familyshield/agent/network/ApiService.kt:114-116`; `apps/child-android/app/src/main/java/com/familyshield/agent/telemetry/LiveActivity.kt:13`). When the network's resolver is unknown, queries go to Cloudflare's and Google's public resolvers (`apps/child-android/app/src/main/java/com/familyshield/agent/vpn/FilterVpnService.kt:237,326`). OSRA never receives them; both resolvers are named in the privacy policy (decision 12 B). |
| **App info and performance: Diagnostics** | Yes | No | App functionality; fraud prevention, security and compliance (tamper detection, update prompts) | Required | See §3.1. |
| **App info and performance: Crash logs** | No | — | — | — | No crash SDK in `apps/child-android/app/build.gradle.kts:182-222`. Still to check: what the Google SDKs (Firebase Messaging, ML Kit barcode, Play services location) self-report, against Google's SDK data-safety guidance (§6, Claude). |
| **Device or other IDs** | Yes | No | App functionality (push, device authentication), security | Required | FCM token (`apps/child-android/app/src/main/java/com/familyshield/agent/services/FirebaseMessagingSvc.kt:72`; `apps/child-android/app/src/main/java/com/familyshield/agent/network/dto/PayloadDtos.kt:56-58`). The device name typed at pairing, which defaults to the model (`apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:929`), is stored as the phone's label (`services/api/src/routes/devices.ts:497`). |
| **Financial info** | No | — | — | — | No payment code or permission |
| **Health and fitness** | No | — | — | — | — |

### 3.1 What "Diagnostics" covers

| What | Evidence |
|---|---|
| Battery %, location-permission state, the rules version the phone has applied | `apps/child-android/app/src/main/java/com/familyshield/agent/network/dto/PayloadDtos.kt:23,30,36` |
| **Device model and OS version**, sent once at pairing | `apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:927-928`; checked at `services/api/src/routes/devices.ts:97-98`; stored at `:497-498` (`services/api/prisma/schema.prisma:220-221`). The SOS alert title names the model (`apps/child-android/app/src/main/java/com/familyshield/agent/sos/SosActivity.kt:104`). |
| **The ADR-0034 capability report**: the app's build (app, version, build number, flavour), the state of each setup permission, the state of each protection feature, and how many other user profiles or spaces the phone has, by kind. Counts and kinds only: no user names, ids or app lists. | Built on the phone (`apps/child-android/app/src/main/java/com/familyshield/agent/capabilities/CapabilitiesPolicy.kt:83-101`; `apps/child-android/app/src/main/java/com/familyshield/agent/capabilities/CapabilityReporter.kt:51-56`). Shape `packages/shared-types/src/capabilities.ts:78-124`. Sent with every telemetry upload and when a permission changes (`apps/child-android/app/src/main/java/com/familyshield/agent/network/dto/PayloadDtos.kt:37-44`; `apps/child-android/app/src/main/java/com/familyshield/agent/telemetry/UsageReporter.kt:160-170,254-273`), and at pairing (`apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:923,934`). The server keeps the latest report and its receipt time (`services/api/src/routes/devices.ts:505-507,880-882`; `services/api/prisma/schema.prisma:247-251`). The parent sees it on the Phone setup screen. |
| The app's build on every request (`X-OSRA-Client` header) | `apps/child-android/app/src/main/java/com/familyshield/agent/network/ClientHeader.kt:18-34`; added at `apps/child-android/app/src/main/java/com/familyshield/agent/di/NetworkModule.kt:46-54`; stored when it changes (`services/api/src/middleware/clientHeader.ts:97-105`; `services/api/prisma/schema.prisma:252-257`) |
| Tamper alerts (Accessibility switched off, overlay revoked, VPN in use, and similar) | `apps/child-android/app/src/main/java/com/familyshield/agent/receivers/AccessibilityOffReceiver.kt:48-56`; `apps/child-android/app/src/main/java/com/familyshield/agent/services/LocationService.kt:480-554` |
| A flag that OSRA's data was cleared on the phone, sent at pairing | `apps/child-android/app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt:930` |

Model and OS version were under "Device or other IDs" in the 29 October draft. They are not identifiers, so
they move here with the capability report. Karim confirmed Diagnostics on 2026-11-11.

### 3.2 Ephemeral processing

- **Unflagged** chat text is processed and dropped without storage (`services/api/src/routes/social.ts:131-133`).
- **Flagged** text is stored, so the type cannot be declared "ephemeral" as a whole.

## 4. Parent app

The parent app *reads* the child's data from the server. Google counts only what an app sends off the device,
so the child's data types are declared on the child agent's form.

| Data type | Collected | Shared | Purpose | Optional? | Evidence |
|---|---|---|---|---|---|
| **Location (approximate/precise)** | **Yes** (Karim, 2026-11-11) | No | App functionality (geofence alerts) | Optional: only when the parent adds a place | The app uploads the **geofence points the parent places**, such as home or school (`services/api/src/routes/location.ts:364`). It never reads the parent's own device location: no location permission (`apps/parent-app/android/app/src/main/AndroidManifest.xml:4-7`). Declared anyway, so a reviewer sees nothing left unsaid. |
| **Personal info: Name** | Yes | No | Account management, app functionality | Required | Parent display name and family name (`services/api/src/routes/auth.ts:43-50`); child display name (`services/api/src/routes/family.ts:26`) |
| **Personal info: Email address** | Yes | No | Account management, developer communications (digest, reset) | Required | `services/api/src/routes/auth.ts:44`; invitee emails (`services/api/src/routes/invites.ts:50-59`); extra digest recipients (`services/api/src/routes/digests.ts:24-25`) |
| **Personal info: User IDs** | Yes | No | Account management | Required | Server account ids and tokens (`services/api/src/routes/auth.ts:191-192`) |
| **Personal info: Other** | Yes | No | App functionality (age-aware rules), legal (consent record) | Required | Child birth year (`services/api/src/routes/family.ts:27`); consent method, jurisdiction and dates (`services/api/src/routes/family.ts:17-22`); family region and time zone (`services/api/src/routes/auth.ts:50-52`) |
| **Personal info: Phone, address, race, religion, sexual orientation, politics** | No | — | — | — | — |
| **Financial info** | No | — | — | — | The consent method "credit card" is a label the parent picks. No card data is collected and no route checks it (`services/api/src/routes/family.ts:18`). |
| **Messages, Photos, Audio, Files, Calendar, Contacts** | No | — | — | — | No such permission (`apps/parent-app/android/app/src/main/AndroidManifest.xml:4-7`). The optional `avatarUrl` field is not sent by any parent screen (`apps/parent-app/lib/api/models.dart:90`). |
| **App activity: Other user-generated content** | Yes | No | App functionality | Required | Rules, place names, commands, consent declarations (parent-app calls to `/v1/rules`, `/v1/location/geofences`, `/v1/devices/:id/command`) |
| **App activity: App interactions / search** | No | — | — | — | No analytics SDK (`apps/parent-app/pubspec.yaml:7-21`) |
| **Web browsing** | No | — | — | — | — |
| **App info and performance** | No | — | — | — | No crash or analytics SDK. The parent app sends no `X-OSRA-Client` header and no app version today. Still to check: what Firebase Messaging and the Google Maps SDK self-report (§6, Claude). |
| **Device or other IDs** | Yes | No | App functionality (push) | Optional (notification permission) | FCM token to `POST /v1/me/push-token` (`apps/parent-app/lib/api/push_api.dart:67-77`; `services/api/src/routes/me.ts:24`) |
| **Health** | No | — | — | — | — |

## 5. Retention the code enforces

A nightly job deletes old rows (`services/api/src/jobs/usageRollup.ts:31-34`; `services/api/src/lib/usageModel.ts:242-254`).
The numbers are the code's defaults. The repository sets no override for production, so check the deployed
environment before quoting them.

| Data | Kept | Evidence |
|---|---|---|
| Location history | **30 days.** An override may lower it to 7 days, and it can never exceed the general window. | `services/api/src/lib/usageModel.ts:38-43,244,250`; `services/api/.env.example:29-30,38` |
| Flagged chat excerpts, activity events | 90 days | `services/api/src/lib/usageModel.ts:26-29,243,247,249` |
| Daily app-usage totals | 365 days | `services/api/src/lib/usageModel.ts:45-48,245,251` |
| Installed-app list, capability report | Replaced by each new report; deleted when the phone is unpaired or the child is erased | `services/api/src/routes/devices.ts:880-882,954-956`; `services/api/prisma/schema.prisma:281`; `services/api/src/lib/usageModel.ts:261` |
| Alerts | **12 months** (decision 10 B), once #562 A lands. Until then, no expiry until the child is erased. | Not in `applyRetention` today (`services/api/src/lib/usageModel.ts:246-252`); erased at `:300` |
| Everything of a family | Until the account is deleted (§2.1) | — |

## 6. Decisions, and what is still owed

Karim's answers (2026-11-11) to the eight open items of the first version:

| # | Item | Answer | Still owed |
|---|---|---|---|
| 1 | Is delivering the child's data to the parent "sharing"? | **No** (decision 8) | — |
| 2 | The web deletion URL | **`https://osratech.com/delete-account`** (decision 5), behind the password (decision 9) | The forward from `osratech.com` to the API page (Claude, with the hosting stack). The web page says "Settings, then Delete account" (`services/api/src/routes/account.ts:143`), but the app's entry is the dashboard's ⋮ menu: fixed in #562 B. The page's Arabic copy waits for Karim's review. |
| 3 | Parent app location | **Declare it** (card, 2026-11-11), §4 | — |
| 4 | Google SDK self-reporting | Not a decision | Claude checks Firebase Messaging, ML Kit, Play services location and Google Maps against Google's SDK data-safety guidance before the upload |
| 5 | Fallback DNS resolvers | **Keep Cloudflare and Google, name both in the privacy policy** (decision 12 B) | The privacy policy text |
| 6 | Message monitoring on by default | **The parent picks the apps during setup, all ticked** (decision 14) | The setup step and its consent text, #562 D |
| 7 | Alert retention | **12 months** (decision 10 B) | The retention window, #562 A |
| 8 | Model, OS version and the capability report under "Diagnostics" | **Diagnostics** (card, 2026-11-11), §3.1 | — |

Other decisions that touch this form: the support address is `support@osratech.com`, the privacy policy is at
`https://osratech.com/privacy` (decision 5), and email goes through AWS SES instead of Resend (decision 11,
#562 C). Until #562 C lands, the email sender is Resend, which is also a service provider under §1.
