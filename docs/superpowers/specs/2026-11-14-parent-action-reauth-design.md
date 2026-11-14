# Parent-action reauthentication design (#742)

## Status and authorities

- **Status:** design for review, not an implementation or readiness claim.
- **Issue:** #742, beta-A blocker, risk R3; parent app on Android and iPhone.
- **Product/UI/UX:** #650 comments 6864489687 and 6864555778. The sixteen English and Arabic strings are final there and are copied byte for byte; this document does not create alternate wording.
- **Security/API:** #742 comment 6879252992 approves `POST /v1/auth/reauth` with the existing `checkReauth` semantics. Password is required, plus current TOTP when MFA is enabled. Recovery codes are not accepted. The endpoint is a separate, independently reviewed commit in the same PR so Ahmed can read it alone.
- **Ahmed's security rulings:** #742 comments 6879750562 and 6881463125. A successful TOTP consumes its time step exactly as login does, so a second use is refused. The newer biometric-only ruling supersedes the earlier device-credential allowance: Android permits only `BIOMETRIC_STRONG`, iOS only `deviceOwnerAuthenticationWithBiometrics`, never a device credential/passcode or weak biometric. The fallback is the OSRA password plus TOTP when MFA is enabled. Consent withdrawal always asks; pairing-code generation does not. Grace exists only in memory and never survives kill/relaunch, background, lock or unreadable state.
- **Per-session fallback limit:** #742 comment 6881463125. In addition to the account-wide login lockout, five failed `/reauth` proofs in one session end that session and require a fresh sign-in. The endpoint keeps its uniform 401 failure response.
- **Execution:** inline by K31 with fail-first tests. No subagent is substituted for the requested K3.1 Pro review. Claude verifies cross-family; Ahmed reviews security and may tighten the MFA decision; Fable or Ahmed supplies the R3 key as applicable.

## Outcome

A child holding the parent's unlocked phone must not loosen rules, remove a device or pause protection merely because the app session is open. A parent can read and edit drafts freely, but a protected change requires the phone owner's strong biometric at the moment of action; knowing the phone's unlock code is not enough. A successful check permits ordinary protected changes for a fixed two minutes, not on app open and not by sliding the window forward. When no strong biometric is available or enrolled, the fallback is the OSRA password plus current TOTP when MFA is enabled, never the device credential or passcode.

The server-side command and family authorization rules remain in force. This is a local proof on top of them, not a replacement.

## Scope and action matrix

| Action | Authentication behavior |
|---|---|
| Full rules save: limits, bedtime, school hours, app rules, web filter, routines, contact allowlist and app-group rules | Prompt unless a live grace exists |
| Bonus time and wind-down | Prompt unless a live grace exists |
| Lock, unlock, pause, resume, pause internet and resume internet | Prompt unless a live grace exists; immediate controls do not change visually before success |
| Remove/unlink a device or child | Always prompt, even during grace |
| Consent withdrawal | Always prompt, even during grace, because it switches protection off |
| Account and family-member changes, including invitations/revocation, MFA enrollment/recovery-code regeneration and account/family deletion | Always prompt, even during grace; existing server reauthentication still applies |
| Open app, read map, alerts, reports, history, pairing-code generation/setup or Settings | Never prompt merely to read or create a pairing code |
| Ring, locate and SOS acknowledgement | Never prompt; these are urgent/read-only actions |

The PR guards existing write paths, not a new removal workflow or a second account settings system. Every write listed above must route through the guard before its API call. UI state for immediate actions must remain unchanged after cancellation/failure; editor drafts remain intact for another attempt.

Non-security preference writes are not silently reclassified. If their inclusion is ambiguous at implementation time, Claude rules before they change. They do not justify bypassing the listed actions.

## Architecture

### One guard, with platform adapters

A Riverpod `ParentActionGuard` exposes a single result: passed, cancelled/failed, or no strong biometric method. An enum selects the approved reason for rules, pause/lock/continue, removal, or account change. No screen calls `local_auth` directly.

The production adapter does not accept the resolved `local_auth_android 2.3.0` default: its `AuthenticationHelper` enables `BIOMETRIC_WEAK` as well as `BIOMETRIC_STRONG`, and this app's `MainActivity` is a plain `FlutterActivity`, not the required fragment activity. The direct Android `MethodChannel` gateway approved in #742 comment 6880228677 uses AndroidX `BiometricPrompt` and `FlutterFragmentActivity`; **the newer biometric-only ruling at 6881463125 narrows its flags to exactly `BIOMETRIC_STRONG` on every API level**. Never add `DEVICE_CREDENTIAL` or weak biometrics. iOS uses `local_auth` with `deviceOwnerAuthenticationWithBiometrics`, never the passcode-inclusive `deviceOwnerAuthentication` policy. Where strong biometric authentication is unavailable or not enrolled, go directly to the OSRA password/MFA fallback. Pure Kotlin policy tests pin `BIOMETRIC_STRONG` alone and the absence of device credentials at every API level. Only `onAuthenticationSucceeded` counts as native success; error, cancel, lockout, `onAuthenticationFailed`, activity recreation and a missing result are not success. Do not ship the weak-enabled plugin default or a dependency fork.

The adapter passes the localized reason and every customizable title/hint/cancel string exposed by the selected native path, so no English plugin default leaks into Arabic. Android uses the approved title only, with no subtitle/description. iOS uses the approved reason text and Arabic `NSFaceIDUsageDescription` in `InfoPlist.strings`. Platform setup is limited to what the selected native path documents; no custom PIN pad or biometric artwork is built.

Test adapters never invoke a real biometric, passcode, system lock, account or device. Tests cover both success and failure/cancel, plugin exceptions and the no-method result. The current `MainActivity` is an empty `FlutterActivity` with no overrides or custom channels. Changing it to `FlutterFragmentActivity` must preserve the existing map/Firebase/plugin methods with a launch smoke test and a leased Flip4 launch after Karim's test slot.

### Fixed grace and lifecycle

- A successful ordinary check records its timestamp only if no live grace exists. A live grace is never extended by another action.
- An always-ask action does not reuse an existing grace and does not extend it. A successful always-ask action can establish a grace only when none is live.
- The grace ends at the earlier of two minutes from the initial check, app background/lock, logout, or a different parent session. Background does not preserve the proof. Platform prompts are not sticky across backgrounding.
- No password, TOTP, biometric result, token or grace timestamp is persisted. No such value is logged. Password controllers are disposed/cleared and the API receives the proof only for the intended verification.

The app root adds a lifecycle listener which invalidates the grace on inactive/paused/detached states. The listener does not prompt on resume or app open.

### No strong biometric method

The no-strong-biometric path is closed, not bypassed, and keeps the already approved wording and destinations:

1. Show the approved bottom sheet: no-lock title/explanation, platform-specific Set screen lock/passcode button, OSRA password secondary action and Cancel. Offering to enroll a strong biometric is not authentication; the device credential/passcode itself is never accepted.
2. Android opens device security settings; iPhone opens the app's Settings page (the OS does not expose a passcode-specific destination).
3. The password step shows one obscured password field and Confirm. If MFA is enabled, the approved reauthentication proof also requires the current authenticator code; recovery codes are not accepted.
4. Wrong proof shows the approved inline error. Cancellation/failure leaves the action unsent and shows the quiet `Nothing was changed.` line with editor drafts preserved. Network failure cannot pass the guard. On the fifth failed proof, the server ends that session without changing the uniform failure body. The next authenticated request or refresh is refused, and the existing client auth handling clears local credentials and returns to sign-in rather than allowing another attempt.
5. A passed password proof starts the same fixed grace as a passed system check. Home shows the approved needs-attention box while no strong biometric method exists; its Fix action opens the same settings destination. Settings contains a plain informational row, never a disable switch.

### Non-destructive 204 endpoint with per-session termination

`POST /v1/auth/reauth` is a separate server commit in this PR:

- Requires a live parent session. Expired/revoked/invalid sessions are refused before proof is checked.
- Reuses `checkReauth` exactly: password plus current TOTP when MFA is enabled; recovery codes are not accepted.
- Shares login's rate limit and lockout counter. A wrong proof counts as a failed login.
- Also maintains a failure counter scoped to the current session `jti`, separate from the account-wide login bucket. Failures 1–4 return uniform 401 and leave the session usable. Failure 5 revokes that access token with the existing `revokeTokenOnce` and deletes its live refresh record, so neither the old access token nor refresh can recreate the session. Other sessions of the same parent are untouched. The failed response remains uniform 401 and the parent must sign in again.
- Returns one uniform `401` for wrong password, missing/wrong TOTP, lockout and fifth-failure session termination, without naming the failed factor.
- On success returns only **204**, with no new session, access token, refresh token or `lastLoginAt` change. A successful TOTP updates only its last-used step, exactly as login does, so it cannot be replayed within its window.
- Writes one info-level structured `parent_reauth` application-log entry with the session parent id, success/failure, timestamp and only the approved failure reason codes (`bad_password`, `bad_totp`, `totp_replay`, `rate_limited`). No password, TOTP, recovery code, IP, device name, migration or reuse of `Alert`/`ActivityEvent`. A success is not returned without the log entry; a durable queryable auth audit is a separate ADR decision.
- Does not change command authorization, family isolation, consent gates, refresh rotation or existing MFA/recovery behavior. The only session-state exceptions are the required fifth-failure revocation of the current token and its refresh record.

API tests use only synthetic identities and test-time password hashes. They prove valid proof returns 204; invalid proof and lockout are indistinguishable; revoked/expired sessions are refused before password verification; `lastLoginAt`, sessions and other account fields are unchanged apart from the explicitly allowed TOTP last-used step and fifth-failure session termination; the same TOTP is refused on the second call; captured audit entries contain no proof material; recovery codes are not accepted; and failures 1–4 preserve the session while failure 5 ends it, rejects subsequent proof checks and prevents refresh from recreating it.

## Component boundaries

- `features/auth/parent_action_guard.dart`: action kinds, result, grace policy and lifecycle invalidation.
- `features/auth/local_auth_owner_verifier.dart`: the `local_auth` adapter and plugin error mapping.
- `features/auth/reauth_prompt.dart`: the no-method sheet and password/TOTP step using the approved strings and current design tokens.
- `api/reauth_api.dart`: thin parent reauthentication client, mapping success/failure without logging proof.
- Existing rules editor, child commands/bonus/wind-down, family invitations, MFA/account screens and server-backed settings actions call the guard at their existing write boundary. Existing draft and confirmation behavior remains.
- `services/api/src/routes/auth.ts` and the existing reauthentication/auth-failure helpers implement the 204 endpoint without a second password or lockout implementation.
- `app_en.arb`, `app_ar.arb`, generated localization files and iOS `InfoPlist.strings` carry only the approved strings. Arabic is never authored by K31.

## Testing and evidence

### Fail-first local gates

- Guard unit tests: first success, grace reuse, fixed expiry, no extension, background/lock/logout invalidation, kill/relaunch with no persisted grace, removal/account/consent always-ask, strong-authenticator flags, plugin failure/cancel and no-method result.
- Widget tests: cancelled/failed actions send no request and do not flip immediate controls; drafts survive; ungated read/ring/locate/SOS acknowledgement never prompts; every listed write category is exercised through the guard.
- No-method tests: both platform settings destinations, wrong password/TOTP, success, no proof stored, Home warning and informational Settings row.
- API tests: all 204 endpoint invariants, including uniform failure, shared lockout, per-session fifth-failure termination, refresh refusal and audit redaction.
- Regression checks for the real `local_auth` dependency on both native targets and localization parity. No test asserts a real system prompt on a development laptop.

### Required review/device evidence

The draft PR includes the six design pictures: system sheet over rules, quiet unchanged line, no-method sheet, password error, Home needs-attention and Settings row, in light/dark and English/Arabic on both phone families. The real system sheet and native plugin behavior require authorized Android/iOS runs, not a widget mock. Any physical handset is leased; no real credential, account, signing key or production service is used.

K31-Mac is asked to run the iPhone plugin/Face ID rows. Claude runs cross-family verification. Ahmed reviews the endpoint, fallback and gate #632 implications. Required Bureaus review the whole screens and final Arabic. Independent verification and R3 security approval are not inferred from author tests.

### Documentation and compatibility

The PR includes an ADR entry for this security boundary, the implementation plan, testing guide, roadmap/parent security-gate row and changelog fragment. It documents that the endpoint is non-destructive, the grace is local-only and non-persistent, and that a no-method device needs the account proof. No new production apply, store action or signing step is introduced.

## Explicit non-goals

- No prompt on app open or passive reading.
- No custom biometric/PIN UI and no password/TOTP persistence.
- No alternate account recovery path and no password-only bypass of MFA.
- No new session or token issuance, login-and-discard flow, destructive recovery-route reuse, AWS plan/apply, production changes, signing or store actions.
- No claim that the local guard replaces server authorization or proves the human parent's identity beyond the platform's device-owner check.
