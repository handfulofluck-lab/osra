# Parent-action reauthentication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax. K31 executes inline because the requested K3.1 Pro subagent is unavailable; no substitute model or subagent is used.

**Goal:** Require the phone owner's strong biometric before protected parent actions, with a fixed memory-only two-minute grace and a non-destructive password/MFA fallback that ends the session after five failures.

**Architecture:** A Riverpod `ParentActionGuard` owns grace and always-ask policy. A small native Android `BiometricPrompt` gateway enforces `BIOMETRIC_STRONG` alone; iOS uses `local_auth` with `deviceOwnerAuthenticationWithBiometrics`. Protected writes call the guard at their existing boundary. A separate 204 endpoint validates the fallback without creating a session or changing login state, and revokes the current session on its fifth failed proof.

**Tech Stack:** Flutter/Dart/Riverpod, AndroidX Biometric 1.1.0 + Kotlin/JUnit, `local_auth` 3.0.2 for iOS, Fastify/Zod/Prisma/Argon2/Redis, Vitest, Flutter test, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-11-14-parent-action-reauth-design.md`, originally approved at #742 comment 6880228677 and revised for Ahmed's newer biometric-only/per-session rulings at 6881463125. This revised spec and plan require fresh approval before product code.

## Global Constraints

- Android uses exactly `BIOMETRIC_STRONG` on every API level; never `DEVICE_CREDENTIAL` or weak biometrics. iOS uses `deviceOwnerAuthenticationWithBiometrics`, never the passcode-inclusive policy. Any unavailable/not-enrolled strong method goes to the OSRA password/MFA fallback. Only `onAuthenticationSucceeded` is success.
- No prompt on app open, reading, ring, locate, SOS acknowledgement or pairing-code generation. Rules and controls use grace; removal, consent withdrawal and account/member changes always ask.
- Grace starts only on the first successful ordinary check, is fixed at two minutes, never slides, and is cleared on background, lock, logout, parent change, kill/relaunch or unreadable state. It is never persisted.
- No password, TOTP, recovery code, session token, grace timestamp, IP or device name is logged or persisted. TOTP success updates only its last-used step; a second use is rejected. No login-and-discard, recovery-route reuse, custom PIN pad or plugin fork.
- Arabic and English copy is limited to the sixteen approved #650 lines. Arabic is copied byte for byte; no new user-visible string bypasses the Bureaus.
- No real biometric, device credential, account, signing key, AWS/production action or store action in tests. A physical handset requires a lease and the assigned verifier's slot.
- One PR for #742, `risk:R3`, endpoint isolated in its own commit for Ahmed. Never merge directly, push `main`, force-push or rewrite history. Keep draft/WIP until independent verification and required Bureaus/security verdicts.

## Review Focus

- Weak face unlock, any `DEVICE_CREDENTIAL` on any API level, passcode-inclusive iOS policy, or a plain `FlutterActivity`: Task 3's per-API policy and host smoke tests must fail if these regress.
- Five wrong fallback proofs must end only the current session and prevent its refresh token from creating another: Task 1 pins the counter, single-`jti` revocation and refresh refusal.
- A cancelled/failed check, backgrounded prompt or relaunched app must not send a protected request or reuse grace: Tasks 2, 4 and 5 exercise them.
- A missing/wrong/replayed TOTP or a rate-limited request must never pass or reveal which proof failed: Task 1 pins uniform 401 and the fixed audit reason codes.
- Ring, locate, SOS acknowledgement and pairing-code generation must never prompt: Task 5 pins the negative cases alongside every gated write class.
- A no-lock phone, wrong password, killed app or unreadable grace must fail closed with the approved fallback, not silently bypass: Tasks 2, 4 and 5 cover them.

---

### Task 1: Non-destructive 204 reauthentication endpoint

**Files:**
- Modify: `services/api/src/lib/mfaVerify.ts`
- Modify: `services/api/src/lib/accountDeletion.ts`
- Create: `services/api/src/lib/reauthProof.ts`
- Create: `services/api/src/lib/reauthAudit.ts`
- Modify: `services/api/src/routes/auth.ts`
- Create: `services/api/test/reauth.test.ts`

**Interfaces:**
- Consumes: existing `checkReauth`, `verifyTotpFresh`, `requireParent`, `AUTH_RATE_LIMIT`, `ReauthSchema`, `revokeTokenOnce`, refresh-record helpers and test `buildApp`/`prismaMock` helpers, plus #771's shared normalization of ASCII, U+0660–U+0669 and U+06F0–U+06F9 before validation.
- Produces: `verifyTotpDetailed(...) -> Promise<"valid" | "invalid" | "replay">`; `verifyReauthProof(parent, body) -> Promise<"bad_password" | "bad_totp" | "totp_replay" | "mfa_reenroll_required" | null>`; `logParentReauth(log, parentId, success, reason?)` with reason only `bad_password`, `bad_totp`, `totp_replay`, `rate_limited`; `POST /v1/auth/reauth` returning 204 or uniform 401. A session-`jti`-scoped counter ends only the current session on failure 5 by calling `revokeTokenOnce` and deleting the associated live refresh record.

- [ ] **Step 1: Write the failing API tests.** Prove valid password (and valid TOTP when enabled) returns 204; wrong password, missing/wrong TOTP, replay, malformed proof and lockout are indistinguishable 401; the same TOTP fails on its second call; recovery codes are not accepted; revoked/expired sessions fail before Argon2 is called. Read the parent row before/after and show only the TOTP step changes, never `lastLoginAt` or unrelated sessions. Capture the structured log and prove fixed reason codes and no password, TOTP, recovery code, IP or device name. Include a failing audit-log call: no success is returned. Add a per-session sequence: failures 1–4 preserve the current session and other sessions, failure 5 revokes only the current `jti`, subsequent proof checks are refused before Argon2, and the associated refresh token cannot create a replacement session.
- [ ] **Step 2: Run `pnpm --filter @familyshield/api exec vitest run test/reauth.test.ts --maxWorkers=1 --minWorkers=1`; confirm RED on the missing route/helper.** Do not weaken the uniform-401, replay, per-session termination or redaction assertions to make a first implementation pass.
- [ ] **Step 3: Commit the failing tests as `test: pin non-destructive parent reauthentication (#742)` with the K31 testing trailer.**
- [ ] **Step 4: Implement the shared proof, per-session limit and route.** `verifyTotpDetailed` preserves all existing `verifyTotpFresh` behavior and the last-used-step store. `verifyReauthProof` centralizes `checkReauth`'s current semantics; `checkReauth` maps its results back to the legacy errors without changing other callers. The route uses `requireParent` before proof, the existing auth bucket and a uniform-401 error builder. A session-`jti` Redis counter is independent of the account login bucket. On failure 5, use `revokeTokenOnce` and remove the current refresh record; do not bump the parent's session version or revoke other sessions. Rate-limit logging uses only the session parent id when available; no lookup by password. No migration, new token, `lastLoginAt`, `Alert` or `ActivityEvent` is created.
- [ ] **Step 5: Re-run the focused suite and the full API suite plus `pnpm --filter @familyshield/api build`; confirm all pass, including the fifth-failure revocation/refresh-refusal rows. Commit implementation as `feat: add non-destructive parent reauthentication (#742)` with the K31 testing trailer for Ahmed's isolated review.**

### Task 2: Pure guard and fixed memory-only grace

**Files:**
- Create: `apps/parent-app/lib/features/auth/parent_action_guard.dart`
- Create: `apps/parent-app/test/parent_action_guard_test.dart`

**Interfaces:**
- Produces: `enum ParentActionKind { rules, controls, removal, account, consent }`; `enum ParentActionResult { passed, cancelled, unavailable }`; `abstract interface class ParentActionVerifier { Future<ParentActionResult> verify(ParentActionKind kind); }`; `ParentActionGuard(verifier, {DateTime Function()? now})` with `Future<ParentActionResult> authorize(ParentActionKind kind)` and `void invalidate()`.

- [ ] **Step 1: Write failing pure-Dart tests.** Use a fake verifier and hand-controlled clock. Assert first success, ordinary grace reuse, no extension at 119.999 seconds, reauthentication at 120 seconds, removal/account/consent always-ask even during grace, no grace after cancellation/unavailable, and no extension by always-ask actions. A fresh guard after simulated kill/relaunch must ask. Cover a verifier exception as failure, not success.
- [ ] **Step 2: Run `flutter test test/parent_action_guard_test.dart`; confirm RED on the missing guard.**
- [ ] **Step 3: Commit the tests as `test: pin parent action grace (#742)` with the K31 testing trailer.**
- [ ] **Step 4: Implement only the pure guard.** `removal`, `account` and `consent` always call the verifier. Ordinary actions reuse a live grace; every successful verification sets the timestamp only when no live grace exists. `invalidate` clears all proof/timestamp state and is safe to call repeatedly. Do not add storage, native calls, UI or an app-open prompt.
- [ ] **Step 5: Re-run the test; confirm all pass. Commit implementation as `feat: add fixed parent action grace (#742)` with the K31 testing trailer.**

### Task 3: Strong Android gateway and iOS authenticator

**Files:**
- Modify: `apps/parent-app/pubspec.yaml` and `pubspec.lock` (tool-resolved `local_auth` for iOS)
- Modify: `apps/parent-app/android/app/build.gradle.kts`
- Modify: `apps/parent-app/android/app/src/main/kotlin/dev/familyshield/familyshield_parent/MainActivity.kt`
- Create: `apps/parent-app/android/app/src/main/kotlin/dev/familyshield/familyshield_parent/ParentAuthPlugin.kt`
- Create: `apps/parent-app/android/app/src/main/kotlin/dev/familyshield/familyshield_parent/ParentAuthPolicy.kt`
- Create: `apps/parent-app/android/app/src/test/kotlin/dev/familyshield/familyshield_parent/ParentAuthPolicyTest.kt`
- Modify: `apps/parent-app/android/app/src/main/AndroidManifest.xml` only if the selected Biometric API requires its documented permission
- Modify: `apps/parent-app/ios/Runner/Info.plist` and `ios/Runner/ar.lproj/InfoPlist.strings`
- Create: `apps/parent-app/lib/features/auth/local_auth_owner_verifier.dart`
- Create: `apps/parent-app/test/local_auth_owner_verifier_test.dart`

**Interfaces:**
- Consumes: Task 2's `ParentActionVerifier` and `ParentActionResult`, plus the approved reason strings.
- Produces: `ParentAuthPolicy.allowedAuthenticators(sdkInt)` = `BIOMETRIC_STRONG` on every API level; never `DEVICE_CREDENTIAL` or `BIOMETRIC_WEAK`; a MethodChannel adapter for Android and `LocalAuthentication` adapter for iOS, both non-sticky and strong-biometric-only. iOS uses `deviceOwnerAuthenticationWithBiometrics`. `LocalAuthOwnerVerifier` implements Task 2's verifier interface and maps cancel/error/no-method to the Task 2 result enum; only Android `onAuthenticationSucceeded` is native success.

- [ ] **Step 1: Write failing policy/adapter tests.** Pin API 24, 28, 29, 30 and 31 combinations; assert every level returns exactly `BIOMETRIC_STRONG`, no level adds `DEVICE_CREDENTIAL` or `BIOMETRIC_WEAK`, the host is `FlutterFragmentActivity`, `stickyAuth`/`persistAcrossBackgrounding` is false, and iOS uses `deviceOwnerAuthenticationWithBiometrics` with `biometricOnly: true`. Assert only `onAuthenticationSucceeded` passes: error, cancel, lockout, `onAuthenticationFailed`, activity recreation and a missing result all fail. Assert `MainActivity` keeps its existing map/Firebase/plugin methods (currently it has no overrides or custom channels) with a launch smoke test, not a real biometric call.
- [ ] **Step 2: Run `./gradlew testDebugUnitTest` in `apps/parent-app/android` and `flutter test test/local_auth_owner_verifier_test.dart`; confirm RED on missing policy/gateway.** Do not accept the resolved plugin's weak-enabled `AuthenticationHelper` or any passcode fallback.
- [ ] **Step 3: Commit the failing tests as `test: pin strong platform authentication (#742)` with the K31 testing trailer.**
- [ ] **Step 4: Implement the native gateway and iOS adapter.** `MainActivity` becomes `FlutterFragmentActivity`; `ParentAuthPlugin` uses the system `BiometricPrompt` with `BIOMETRIC_STRONG` alone on every API level, approved title/cancel strings and no custom UI. `ParentAuthPolicy` is the only flag source. Add AndroidX Biometric 1.1.0 and only its documented manifest setup. iOS uses `LocalAuthentication` with `biometricOnly: true`, `deviceOwnerAuthenticationWithBiometrics`, `sensitiveTransaction: true`, `persistAcrossBackgrounding: false`, approved reason and every customizable message needed to avoid English defaults. Keep `local_auth` out of Android production authentication.
- [ ] **Step 5: Re-run both suites and `flutter analyze`; confirm pass. Commit implementation as `feat: enforce strong biometric authentication (#742)` with the K31 testing trailer. Keep the draft at WIP; no real prompt is launched locally.**

### Task 4: No-lock fallback, localization and lifecycle

**Files:**
- Create: `apps/parent-app/lib/api/reauth_api.dart`
- Create: `apps/parent-app/lib/features/auth/reauth_prompt.dart`
- Modify: `apps/parent-app/lib/features/auth/parent_action_guard.dart` only if lifecycle needs an explicit reset seam
- Modify: `apps/parent-app/lib/app.dart`
- Modify: `apps/parent-app/lib/features/dashboard/dashboard_screen.dart`
- Modify: `apps/parent-app/lib/features/settings/appearance_screen.dart` only if it owns the Settings row; otherwise use the existing settings screen
- Modify: `apps/parent-app/lib/l10n/app_en.arb`, `app_ar.arb`, `app_localizations.dart`, `app_localizations_en.dart`, `app_localizations_ar.dart`
- Create: `apps/parent-app/test/reauth_prompt_test.dart`

**Interfaces:**
- Consumes: Task 1's 204 route, Task 2's guard/verifier, Task 3's platform result, and the sixteen approved strings from #650 comment 6864555778.
- Produces: `ReauthApi(this._client).verify({required String password, String? mfaCode}) -> Future<bool>`; the approved no-lock sheet, password/TOTP step, Home needs-attention box and plain Settings row. `ReauthApi` returns true only on 204 and never logs/persists proof. The uniform 401 is not used to infer a fifth failure; the next authenticated request or refresh is refused, and existing auth handling clears credentials and returns to sign-in.

- [ ] **Step 1: Write failing fallback/widget tests.** Cover both platform settings destinations, cancel/failure sending no protected action, wrong password/TOTP showing the approved inline error, successful 204 passing, unavailable/network failing closed, disposed proof controllers, and no proof persisted. Verify the Home warning, informational (non-switch) Settings row, all sixteen English/Arabic strings, and `inactive`, `paused` and `detached` calling `invalidate` without prompting on resume. Prove a revoked session on the next authenticated request/refresh clears local credentials and returns to sign-in without treating the uniform 401 as a distinguishable fifth failure.
- [ ] **Step 2: Run `flutter test test/reauth_prompt_test.dart`; confirm RED on missing fallback/localization/lifecycle.** Include one fresh-guard-after-relaunch assertion so persistence cannot sneak back in.
- [ ] **Step 3: Commit the tests as `test: pin no-lock fallback and lifecycle (#742)` with the K31 testing trailer.**
- [ ] **Step 4: Implement the approved UI and client.** Show the no-lock bottom sheet with platform-specific Set screen lock/passcode action, password secondary action and Cancel. If MFA is enabled, require the current six-digit TOTP; never accept recovery codes. Call only Task 1's endpoint. Add Home's needs-attention box and a plain Settings row. Add only the sixteen approved English/Arabic lines and iOS permission text, preserving Arabic byte for byte. Invalidate grace on `inactive`, `paused` and `detached`. Keep the existing revoked-session handling to clear credentials and return to sign-in after a refused authenticated request or refresh; do not add a fifth-failure-specific error body.
- [ ] **Step 5: Re-run the fallback suite and `flutter analyze`; confirm pass. Commit implementation as `feat: add secure no-lock fallback (#742)` with the K31 testing trailer. No real account/password or settings destination is opened locally.**

### Task 5: Route every protected write through the guard

**Files:**
- Modify: `apps/parent-app/lib/features/rules/rules_editor_screen.dart`
- Modify: `apps/parent-app/lib/features/children/child_detail_screen.dart` and `app_groups_section.dart`
- Modify: `apps/parent-app/lib/features/children/consent_screen.dart`
- Modify: `apps/parent-app/lib/providers/controls_provider.dart`
- Modify: `apps/parent-app/lib/features/dashboard/dashboard_screen.dart`
- Modify: `apps/parent-app/lib/features/family/family_screen.dart`
- Modify: `apps/parent-app/lib/features/settings/mfa_enroll_screen.dart`, `mfa_settings_screen.dart`, `delete_account_screen.dart`
- Create: `apps/parent-app/test/parent_action_writes_test.dart`

**Interfaces:**
- Consumes: Task 2's `authorize`, Task 3's verifier and Task 4's fallback/API, with `ParentActionKind.rules` for rules saves, `controls` for bonus/wind-down/lock/unlock/pause/resume/internet changes, `removal` for device/child removal, `account` for account/member changes, and `consent` for consent withdrawal.
- Produces: protected writes occur only after `ParentActionResult.passed`. Ring, locate, SOS acknowledgement and pairing-code generation never call `authorize`.

- [ ] **Step 1: Write fail-first write-boundary tests.** Rules Save cancels with zero PUT and drafts retained; immediate pause/internet controls do not flip or POST before success; bonus/wind-down/removal/account/consent each have the required reason and grace behavior. Prove existing `ReauthDialog` server proof for destructive account changes remains. Explicitly prove ring, locate, SOS acknowledgement and pairing-code generation never prompt. Include every existing write site in those files, not only the happy-path rules editor.
- [ ] **Step 2: Run `flutter test test/parent_action_writes_test.dart`; confirm RED on unguarded writes.**
- [ ] **Step 3: Commit the tests as `test: pin protected parent writes (#742)` with the K31 testing trailer.**
- [ ] **Step 4: Wire the guard at each existing API boundary.** Do not create a second settings system or change the server command guards. After cancellation/failure, show the approved quiet unchanged line and keep drafts; immediate controls do not change visually. On success, preserve the existing confirmation, validation, server reauthentication and error behavior. Do not gate passive reading or the four explicitly ungated flows.
- [ ] **Step 5: Run the write-boundary suite and the complete Flutter suite; confirm all pass. Commit implementation as `feat: guard protected parent actions (#742)` with the K31 testing trailer. Open/update the draft PR with structure and the six evidence groups, but do not mark ready.**

### Task 6: Full verification, documentation and independent review

**Files:**
- Create: `docs/adr/0043-parent-action-reauthentication.md`
- Modify: `docs/TESTING.md`, `docs/ROADMAP.md`, `docs/README.md`, `README.md` and `CHANGELOG.d/`
- Modify: `docs/superpowers/specs/2026-11-14-parent-action-reauth-design.md` and this plan only if implementation differs from the approved design
- Modify: `.github/workflows/parent-app.yml` only if a new native test/gate needs it

- [ ] **Step 1: Run the complete gate on the exact candidate:**
  - `flutter analyze` and `flutter test` in `apps/parent-app`
  - `pnpm --filter @familyshield/api build` and `pnpm --filter @familyshield/api test`
  - `./gradlew testDebugUnitTest` in `apps/parent-app/android`
  - `node scripts/check-workflows.mjs --strict`, `node scripts/check-ci-paths.mjs --selftest`, `node scripts/check-ci-paths.mjs`, `node scripts/check-no-pins.mjs`, `node scripts/check-no-service-account-keys.mjs`, `node scripts/check-docs-links.mjs` and `git diff --check`
  Expected: all pass with exact counts, no real credentials and no generated files tracked.
- [ ] **Step 2: Run targeted planted faults.** `DEVICE_CREDENTIAL` or weak Android flag added, iOS passcode policy substituted, grace made persistent/sliding, TOTP accepted twice, a protected write moved before `authorize`, the fifth failure left unrevoked, and refresh allowed to recreate the ended session. Each must turn the owning test red; restore production code and prove it green. No fault remains in the product branch.
- [ ] **Step 3: Document and commit the ADR, testing procedure, parent security-gate roadmap row and changelog.** Record exact results and what was not verified: no real biometric on the development laptop, no production apply/signing, no clean-family claim. Keep the endpoint and native host changes visible for Ahmed.
- [ ] **Step 4: Obtain native evidence and update the draft PR.** Ask the leased Android/Flip4 slot for the six design pictures in light/dark and English/Arabic, the strong-prompt and host-launch smoke rows. Ask K31-Mac for the iOS/Face ID rows and Arabic permission string. Attach actual images/results; never fabricate a system prompt from a widget.
- [ ] **Step 5: Perform the inline whole-branch self-review and request independent review.** No subagent substitution for K3.1 Pro. Ask Claude for cross-family verification, Ahmed for the endpoint/security verdict, Fable for the R3 key, and both Bureaus for whole-screen approval. Keep draft/WIP and auto-merge off until all required verdicts, native evidence and CI checks are green. Never merge directly.

## Self-review notes

- Tasks 1–5 each have an independently testable deliverable and tests committed before implementation. Task 6 gates the assembled behavior and documentation rather than hiding integration until review.
- The API's `verifyTotpDetailed` wraps the existing replay store rather than adding a second TOTP counter; the 204 route reuses the live parent session and shared auth bucket. A separate session-`jti` failure count ends only that session on failure 5, using the durable access-token revocation plus refresh-record removal so a refresh cannot resurrect it.
- The native policy never accepts a device credential/passcode: Android is `BIOMETRIC_STRONG` only on every API level and iOS is `deviceOwnerAuthenticationWithBiometrics`; only `onAuthenticationSucceeded` passes.
- `ParentActionGuard` is the only grace owner. No widget, plugin or native gateway owns a second grace store.
- The plan intentionally leaves real native prompts, native iOS builds, production credentials and release signing to authorized CI/verifier slots. It does not claim them from local unit tests.
