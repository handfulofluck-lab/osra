# What the Play Data Safety form has to be told, and where each answer comes from

Play asks, per data type: **collected? shared? optional? encrypted in transit? deletable on request?** and what it
is used for. This page answers each one **from the code**, with the file and line the claim rests on, so the
person filling the form does not have to take anyone's word for it — and so a reviewer can check a row by opening
a file.

It is **input to the form, not the form**, and nobody has signed it. Where the code does not settle a question, the
row says so instead of guessing.

## 1. What the child agent sends

| Data type (Play's category) | Collected? | Where | Purpose | Encrypted in transit | Retention |
|---|---|---|---|---|---|
| **Precise location** | **Yes**, when the parent grants it | `ACCESS_FINE_LOCATION` + `ACCESS_BACKGROUND_LOCATION` (`app/src/main/AndroidManifest.xml:29-30`); stored as `LocationPing` (`prisma/schema.prisma:468`) | Safety: where the child is, geofence alerts | Yes — release build is HTTPS-only, cleartext refused (`app/src/main/res/xml/network_security_config.xml`, asserted in CI at `child-android.yml:104-106`) | **30 days** default (`LOCATION_RETENTION_DAYS`, `lib/usageModel.ts:15-16,35-40`) |
| **App activity** (app usage) | **Yes** | `PACKAGE_USAGE_STATS` (`:37`); `AppUsageDaily` (`schema.prisma:381`), `DeviceApp` (`:295`) | Screen-time limits and the parent dashboard | Yes | Rollups **365 days** (`ROLLUP_RETENTION_DAYS`) |
| **Web browsing** | **Yes** | `WebVisit` — one row per URL event (`schema.prisma:395`) | Blocking, filtering, the parent's history view | Yes | Raw **90 days** default (`RETENTION_DAYS`, `usageModel.ts:14-15,33-36`) |
| **Messages / in-app content** | **Yes, encrypted at rest** | `SocialEvent.previewCipher` (`schema.prisma:407`) written through `lib/snippetVault.ts` — AES-256-GCM, `enc1:` prefix, `VAULT_KEY` required in production (`snippetVault.ts:4-9`, `server.ts:48-49`) | Concern detection; the parent can decrypt a snippet in the vault only | Yes | Raw **90 days** |
| **Device or other IDs** | **Yes** | `Device` (`schema.prisma:242`): push token, model, OS version | Pairing, push wake, dashboard | Yes | Until the device is removed |
| **App info and performance** (crash/diagnostics) | **Not collected to our servers** as far as this code shows | no crash reporter in the tree | — | — | — |
| **Health, photos, contacts, calendar, files** | **No** | no permission or code path reads them | — | — | — |

## 2. The two permissions Play scrutinises, and why the Play build is different

- **SMS and call log are FULL-flavour only.** `app/src/full/AndroidManifest.xml:12-17` declares `READ_CALL_LOG` and
  `READ_SMS`, with the reason written beside them: Play's SMS/Call-Log policy has **no exception** for monitoring
  apps, so the store build (`play` flavour) must not request them. The Data Safety answer for the Play build is
  therefore **no SMS, no call log** — and the `full` build is distributed outside Play, which is its own answer.
- **Notification access is FULL-flavour too** (`full/AndroidManifest.xml:10`, `BIND_NOTIFICATION_LISTENER_SERVICE`),
  so the Play build does not read notifications.
- **Accessibility service is in the store build** (`main/AndroidManifest.xml:61-64`,
  `BIND_ACCESSIBILITY_SERVICE`). Play requires a prominent in-app disclosure and, for monitoring apps, a
  justification video; the disclosure copy exists in the app's strings, the video is not made.

## 3. Deletion, consent and the legal side

| Question Play asks | Answer | Evidence |
|---|---|---|
| Can a user request deletion? | **Yes**, without installing anything: a public page issues a token by email, the link asks for the password, and the erase runs | `services/api/src/routes/account.ts:29-36`; `AccountDeletionToken` (`schema.prisma:122`) |
| Does deletion actually remove the child's data? | It runs one function that lists **every** child-scoped table and Redis key, so no rows or keys survive | `eraseChildData()` (`lib/usageModel.ts:348`) |
| Is consent recorded? | Yes: method, jurisdiction, grant/expiry/revocation, and a third-party-sharing flag | `ConsentRecord` (`schema.prisma:516`) |
| Is data shared with third parties? | The code sends nothing to an analytics or ad SDK. It does use infrastructure processors — email (Resend), push (FCM/APNs), hosting — which is "shared with service providers" in Play's wording and must be declared | `lib/email`, `lib/push` call sites; no analytics dependency in any `package.json` |
| Children's data (COPPA/GDPR-K)? | The product is a parental-control tool: the **parent** consents, the child's device reports. The form has to say the data is collected from a child's device under parental consent, and the consent record above is the evidence | `ConsentRecord`, `docs/` consent flow |

## 4. What this page does not settle

- **Whether our processors are listed exactly as Play wants.** That is a legal wording question, and the privacy
  policy is where it belongs.
- **The `full` build's own answers.** It reads SMS and notifications, so it needs a separate declaration wherever
  it is distributed; this page covers the Play build.
- **Anything the code cannot show**: whether Play's reviewers will accept the accessibility justification, the
  IARC answers, and the store listing's claims. Those are console decisions.

**Nobody has verified this page.** It was written from `main` at `fdf92c19` on 2026-11-16 by the release owner, and
it should be struck through by whoever fills the form before the form is submitted.
