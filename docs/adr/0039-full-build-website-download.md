# ADR-0039 — The Full child app is a separate app, downloaded from osratech.com, that updates itself

- **Status:** accepted (architecture); implementation not started
- **Date:** 2026-11-12
- **Deciders:** Claude (architecture + testing), under the maintainer's grant of 2026-11-12 07:38Z ("you are the
  chief architect, do what you think is best … use Kimi to code it and Ahmed to check cybersec … FULL AUTHORITY
  GRANTED"). Implemented by Kimi Code; security review and pen test by Ahmed; QA and the customer-experience
  pass by Claude.
- **Related:** ADR-0016 (Play and Full flavors, notification capture), ADR-0021 (Play policy review of the child
  agent; its fallback names "its own signed download page"), ADR-0034 (`X-OSRA-Client` and the capability
  report), roadmap 1.x "Two builds (decision 1)" and the new row **5.10**.

## Context

Since 2026-10-16 the plan has been two Android child apps: the **Play** build in the store, and a **Full** build
from our own website that carries what Google Play does not allow a parental-control app to do. The code half
exists. `apps/child-android` has the `play` and `full` flavors; Full alone declares the notification listener,
`READ_CALL_LOG` and `READ_SMS` (`src/full/AndroidManifest.xml`); the merged-manifest gate and
`scripts/check-merged-manifest-gate.mjs` keep those out of Play; only `bundlePlayRelease` becomes an AAB, and
`play-upload.yml` sends only that.

The **distribution half was never designed**. Checked on `main@9f03e90`:

1. **Both flavors are `com.osratech.child`, signed with the same upload key.** Play re-signs the store app
   with the Play app-signing key, so a Full APK signed with the upload key cannot install over a Play install
   (signature mismatch) and the two cannot sit side by side. Play also sees two different certificates on
   the same package id.
2. **No update path.** A sideloaded APK gets no updates from Play. Today a Full family would stay on the
   version they first installed, with no way for us to ship a security fix.
3. **No download page, no hosting, no release workflow, no roadmap row.**
4. **Firebase:** `google-services.json` only holds `com.osratech.child` and `com.osratech.parent`; a new
   package id needs its own Firebase Android app or the release build fails.
5. **Android developer verification.** Google now requires apps installed outside Play on certified devices
   to come from a verified developer with a registered package name. Enforcement started 2026-09-30 in four
   countries and widens through 2027. An unregistered Full build will eventually stop installing.
6. **Search monitoring is half-built.** `POST /v1/content/search-event` and `/youtube-watch` exist on the
   server and the parent app has the Search safety screen, but no client sends either. The child app reads
   the screen text in YouTube as a chat app (`MonitoredApps`), not the search box.

Competitors work the same way. Qustodio offers a separate "Android with Calls & SMS" download on its own
site. Bark moved its Android monitoring to a download from bark.us after Google's 2019 SMS and call-log
policy.

## Decision

### D1 — Full is its own app id

`full` gets `applicationIdSuffix = ".full"`, so it is **`com.osratech.child.full`**, and
`versionNameSuffix = "-full"`. `namespace` and the Kotlin packages stay `com.familyshield.agent`.
`EssentialPackages.OWN_PACKAGE` already derives from `BuildConfig.APPLICATION_ID`, so the agent keeps
recognising itself. Every test that hard-codes `com.osratech.child` as "self" reads `BuildConfig.APPLICATION_ID`
or is parameterised per flavor.

**One child phone runs one OSRA child app.** If Full starts on a phone that also has `com.osratech.child`
installed, onboarding says so. After Full is paired, the parent removes the old device in the parent app.
That lifts the uninstall guard, and the child app then guides the uninstall. A Full phone that still has the
Play app sends one `duplicate_agent` capability note (ADR-0034), so the parent sees it.

Why not keep one id: the two builds would need one signing key, which means giving up Play App Signing or
exporting Play's key. Both are worse than a second id.

### D2 — Full has its own signing key, kept apart from Play

- A new key, **`full-release`** (PKCS12, RSA 4096, 30-year validity), made on the maintainer's PC under
  `C:\karim\osra-secrets\full-release\`. It is never the Play upload key and never sent to Google.
- **Losing it strands every Full family**: they would have to uninstall and reinstall. So it has two offline
  copies (the maintainer's encrypted USB stick and his password manager), recorded in the release runbook. The
  APK is signed with v2 + v3, so a future key rotation can use a v3 lineage instead of a reinstall.
- CI reads it from four Actions secrets, `OSRA_FULL_KEYSTORE_B64`, `OSRA_FULL_KEYSTORE_PASSWORD`,
  `OSRA_FULL_KEY_ALIAS` and `OSRA_FULL_KEY_PASSWORD`. Those secrets are scoped to the `full-release` GitHub
  environment, which only the release workflow (D4) uses. `child-android.yml` keeps building Full debug-signed
  on every PR, so pull requests never see the key.

### D3 — Firebase and developer verification

- Register `com.osratech.child.full` as a third Android app in Firebase project `osra-3665a`, and update the
  `CHILD_GOOGLE_SERVICES_JSON_B64` secret with a file that lists all three clients.
- Register `com.osratech.child.full` and the `full-release` certificate under the maintainer's verified
  developer identity (Android developer verification, Play Console). This is an account step, so it is the
  maintainer's (or Claude's in his Chrome, under the 2026-11-12 grant), and it comes **before the first
  public Full download**.

### D4 — Hosting and the release workflow

- Files live on the existing `site` stack (S3 + CloudFront, `infra/terraform/site`) under `/android/`:
  - `/android/` — the download page, in English and Arabic (D6).
  - `/android/osra-kids-full-<versionName>-<versionCode>.apk` — immutable, cached for a year.
  - `/android/latest.json` — the update manifest, with `Cache-Control: max-age=300`.
- The APK is **not** committed to the repository. A new manual workflow, **`full-release.yml`**
  (`workflow_dispatch`, environment `full-release` with a required reviewer), builds `assembleFullRelease` and
  checks that the signer is the `full-release` certificate and that the merged manifest has the Full
  permissions. It then writes and signs `latest.json` (D5) and uploads both through a new OIDC role,
  `osra-full-release-publisher`. That role may only `s3:PutObject` on `android/*` and invalidate
  `/android/latest.json`, and is defined in the `site` stack.
- The `site` Terraform must keep managing only the files under `site/`. A test (`terraform plan` after a
  release shows no change) proves an apply cannot delete `android/*.apk`.

### D5 — Full updates itself, and refuses anything that is not ours

Full only (`src/full/`):

1. **Check.** `FullUpdateWorker` (WorkManager, every 12 h, plus once at boot and after pairing) fetches
   `https://osratech.com/android/latest.json` over the app's existing HTTPS-only network config:

   ```json
   { "schema": 1, "packageName": "com.osratech.child.full", "versionCode": 7, "versionName": "0.4.0-full",
     "url": "https://osratech.com/android/osra-kids-full-0.4.0-7.apk", "sha256": "<hex>", "size": 9123456,
     "minSdk": 26, "releasedAt": "2026-12-01T10:00:00Z", "minSupportedVersionCode": 5,
     "signature": "<base64 Ed25519 over the canonical JSON without this field>" }
   ```

2. **Trust.** The manifest is signed with a separate **Ed25519 manifest key**. The private half is an Actions
   secret in the `full-release` environment, with an offline copy next to D2's. The public half is compiled
   into the app. The app refuses the manifest (and logs `update_refused:<reason>`) unless all of these hold:
   the signature verifies, `packageName` is its own, `versionCode` is **higher** than the installed one (no
   downgrade, no replay of an old manifest), and `url` is on `https://osratech.com/android/`. This means a
   hijacked bucket or CDN cannot steer phones to an older vulnerable build or an off-site file.
3. **Download.** The APK goes to app-private storage. The app checks `size` and `sha256`, then reads the
   archive's signing certificate (`getPackageArchiveInfo(…, GET_SIGNING_CERTIFICATES)`) and requires it to
   equal the installed app's. Android enforces the same rule at install, and checking first means a bad file
   never reaches the installer and is reported.
4. **Install.** `PackageInstaller` session with `setRequireUserAction(USER_ACTION_NOT_REQUIRED)` on Android 12+.
   Where Android still asks, the child sees one notification, **"OSRA needs to update — tap to install"**,
   and the agent re-raises it at most every 6 h until done. The existing `MY_PACKAGE_REPLACED` receiver
   restarts every service, and the update must not leave a protection gap longer than the restart itself
   (acceptance row R5).
5. **Permission.** Full declares `REQUEST_INSTALL_PACKAGES`, and onboarding adds one Full-only row, "Allow OSRA
   to install its updates". Play must never declare it, and the merged-manifest gate gains that assertion.
6. **Parent visibility.** The version is already in `X-OSRA-Client` (ADR-0034). The parent app shows "Child app
   update pending" when a device is below `latestVersionCode` for over 48 h, and "Update required" below
   `minSupportedVersionCode`. The server reads both from `latest.json` on a timer, so no new admin route is
   needed.

### D6 — How a family gets Full

- **Download page** `osratech.com/android` (EN/AR, RTL). It explains in plain words what Full adds (WhatsApp and
  other message notifications, calls, SMS, searches) and why it is not on Google Play. It walks through the
  install with screenshots: "allow your browser to install apps", the Play Protect warning, and opening OSRA.
  It also shows the APK's SHA-256 and certificate fingerprint for anyone who wants to check.
- **The Play apps never link to the APK.** Google's Device and Network Abuse policy forbids a store app from
  installing or downloading code from outside Play. The Play parent app may name the website in plain text
  ("The Full version is available at osratech.com") and nothing more. We revisit after the first Play
  approval, not before.
- **Play Protect.** Full keeps `isMonitoringTool=child_monitoring` (ADR-0021). The page and onboarding say
  plainly that Android may warn, and why.

### D7 — Which features are Full-only

| Capability | Play | Full |
|---|---|---|
| Location, lock, ring, app blocking, schedules, web filter, YouTube restricted mode (DNS) | ✅ | ✅ |
| On-screen chat text in 12 apps via Accessibility (WhatsApp, Instagram, TikTok, Snapchat, YouTube, …) | ✅ (declared) | ✅ |
| Message notifications (WhatsApp etc., even with the app closed) | — | ✅ |
| Call log, SMS (from the grant onward, #229) | — | ✅ |
| **Search capture:** YouTube search box, Chrome / Google search queries → `/v1/content/search-event` | — (first release) | ✅ |
| Self-update (D5) | — (Play updates it) | ✅ |

Search capture ships **Full-first**. The Play data-safety form is already filled and saved, and a new
collected data type would reopen it before the first review. Once Play approves the store build, a separate
ADR amendment decides whether search capture moves to Play. Its design: the Accessibility service reads the
submitted text of YouTube's search field and Chrome's address bar (by view id, falling back to a field that
has focus when the results window opens). It sends the query only, never page content, through the existing
durable `pending_scans` queue, signed like every device call. It runs only when the parent turns on a new
`searchMonitoring` rule flag, offered in setup with the other monitoring choices and pre-ticked like them (decision 14 A).

## Falsifiable claims (what the verifiers test)

- **R1** `aapt2 dump badging` on the Full release APK shows `package: name='com.osratech.child.full'`; on the
  Play AAB/APK it shows `com.osratech.child`. Both install side by side on the Flip4.
- **R2** The Full release APK's signer SHA-256 is the `full-release` certificate, not the upload key. A
  `pull_request` run has no access to the `full-release` secrets.
- **R3** The Play merged manifest has none of `REQUEST_INSTALL_PACKAGES`, `READ_SMS`, `READ_CALL_LOG` or
  `BIND_NOTIFICATION_LISTENER_SERVICE`. Removing the guard makes CI fail by name.
- **R4** The updater refuses: a bad signature, a lower or equal `versionCode`, another package name, an
  off-site `url`, a `sha256` mismatch, and an APK signed with another key. Each has a JVM test, and Ahmed
  reproduces each against a doctored manifest on a real phone.
- **R5** On the Flip4: install version N from the page, publish N+1, and the phone updates within one check.
  A lock set before the update is still in force afterwards, and the gap without enforcement is measured
  and recorded.
- **R6** A YouTube search for a seeded test phrase on the Flip4 (Full) appears on the parent's Search safety
  screen. The same search on the Play build sends nothing.
- **R7** A non-engineer follows `osratech.com/android` on a clean phone, in English and in Arabic, and reaches
  "This device is paired" without help (Claude times it; this is the customer-experience gate).
- **R8** `terraform plan` on `site` after a release shows no change to `android/*`.

## Build order (one PR each)

1. **Claude**: this ADR + roadmap row 5.10. **Claude (on the maintainer's PC)**: the `full-release` key, the
   manifest key, the Firebase app and the secrets.
2. **Kimi — PR A**: D1 + D2 + the D3 Firebase file. Covers R1, R2, R3 and the duplicate-app onboarding.
3. **Kimi — PR B**: D5, the updater (R4), with Ahmed's review before merge.
4. **Kimi — PR C**: `full-release.yml` + the `site` OIDC role (R8); Claude applies the Terraform.
5. **Kimi — PR D**: search capture, Full-only (R6).
6. **Claude — PR E**: the download page EN/AR and the onboarding copy (Arabic to the maintainer for approval),
   then R5 and R7 on the Flip4.
7. **Ahmed**: threat-model review of this ADR now; a security review of A–C; and a pen test of the updater and
   manifest on a phone before the first public Full download.

## Consequences

- Good: Full stops being a build nobody can install or update, and the Play submission is unchanged. Nothing
  in D1–D7 adds a permission or a data type to the Play build.
- Cost: two signing keys and one manifest key to guard, a third Firebase app, and a release step per Full
  version. The download page is a new support surface, and families will see Android's warnings.
- Risk: Google widens developer verification or Play Protect blocks monitoring apps outright. Then D3's
  registration is what keeps Full installable, which is why it comes before the first public download.
