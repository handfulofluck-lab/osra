# Shared hardware register — the test phone (DEV-01)

**Owner of this document:** Kimi Code, device warden and programme lead (from 2026-10-17)
**Applies to:** every agent named in `AGENTS.md` §1, the KCL lead, and the maintainer
**Status:** in force · v2 · 2026-10-17 · aligned with `AGENTS.md` §9 and `docs/TESTING.md` §5.0
**What decides access:** `scripts/hardware/phone-claim.ps1`, not this file. This file is the durable
register of what happened on the phone, why, and what state was handed over.

> **The rule in one sentence:** claim the handset with `phone-claim.ps1` before the first `adb` call,
> hold it for a stated purpose and end time, clear every restriction before releasing it, and leave a
> record here that the next holder can check.

## 1. Why this exists

On 2026-10-17 two testers collided on DEV-01. One run issued the parental `lock` command and its owner
then became unreachable; the phone was left behind the OSRA overlay. A second tester found the device in
that state while preparing **TR-15** (plan 1.9, the Phase 1 gate). Neither agent did anything the repo
forbade at the time: `AGENTS.md` §7 said how to *leave* the device clean, and nothing said who may
*hold* it. The collision was invisible until someone tried to work.

`AGENTS.md` §9 (`AGENTS.md:192-292`) now makes the lease binding, and `docs/TESTING.md` §5.0
(`docs/TESTING.md:109-194`) is the operating procedure. This register exists because a lease answers
"who may touch it now" and says nothing durable about "what was run, on which build, and what did the
next holder inherit". The lease store is the lock; this file is the history beside it.

The failure is not self-healing, which is why a reminder is not enough:

- the lock mode is persisted in `osra_lock_state`
  (`apps/child-android/app/src/main/java/com/familyshield/agent/enforcement/LockState.kt:21-31`);
- the overlay swallows Back and re-raises itself over Home, Recents and Settings
  (`apps/child-android/app/src/main/java/com/familyshield/agent/commands/LockActivity.kt:45-49`, `:58-78`);
- the command that clears it is a durable row, not a pub/sub message, so restarting Redis or the API
  does not drop it (`docs/adr/0012-durable-device-command-queue.md:11-17`);
- a reboot does not clear it: after the first unlock the boot receiver re-applies the overlay
  (`docs/TESTING.md` §5a, lines 251-261);
- the shell cannot strip the protection either: `dpm remove-active-admin` refuses non-test admins on
  Android 14+ (`docs/TESTING.md` §5a, lines 244-248), and `adb uninstall` fails while Device Admin is
  active (`DELETE_FAILED_DEVICE_POLICY_MANAGER`; `docs/TESTING.md:240`).

A locked phone is therefore not a five-minute delay. It is the next tester's slot, plus a PIN-gated
admin removal and a re-pair if the parent token is gone. The lease's expiry is what stops one agent's
silence from becoming everyone's problem; this register is what stops the same run being repeated
because nobody wrote down what it left behind.

## 2. The asset

| Field | Value |
|---|---|
| Asset id | **DEV-01** |
| Device | Samsung Galaxy Z Flip4, the maintainer's personal handset (`AGENTS.md:194-196`) |
| Model / OS | `SM-F721B` / Android 16 (One UI) — the model `TEST-REQUESTS.md` TR-07 names, and "the Flip4" in `docs/TESTING.md` §5a |
| adb serial | `R5CW116Y6GF` |
| Host | the Windows test host (`C:\KARIM`); adb at `C:\KARIM\tools\android-sdk\platform-tools` |
| Connection | USB; `adb reverse` carries the device's API traffic to the host |
| Owner | the maintainer (human). Owner use outranks every lease (`AGENTS.md:209-211`) |
| Warden | Kimi Code, programme lead — owns the rule, arbitrates, holds break-glass (`AGENTS.md:208-210`) |
| Role | the only physical Android device for the Phase 1 gate, named TR hardware rows, and any claim an emulator cannot settle (`docs/QA/TESTING-STRATEGY.md:19-22`) |
| Lease store | `%LOCALAPPDATA%\OSRA\phone-claims` by default, or `$env:OSRA_PHONE_CLAIM_STORE`; `phone-claim.ps1 -Action Status` reads it (`scripts/hardware/phone-claim.ps1:14-18`) |
| Identity check | `adb devices -l` lists `R5CW116Y6GF`, and `adb -s R5CW116Y6GF shell getprop ro.product.model` prints `SM-F721B`. A different serial means a different device; stop and report |

### 2.1 State that outlives a run

Every item below is something the next holder inherits. The pre-flight in `docs/TESTING.md` §5.0 and the
release in §8 exist because of this table.

| State | Where it lives | How the next holder checks it |
|---|---|---|
| OSRA lock / pause / pause-internet overlay | `osra_lock_state` SharedPreferences on the device | `adb -s R5CW116Y6GF shell dumpsys activity activities \| grep topResumedActivity` — `LockActivity` means a run is still in effect |
| Queued restriction not yet delivered | `DeviceCommand` rows; the agent polls every 60 s | `GET /v1/devices/<id>/commands/history` — no `pending` or `delivered` `lock`/`pause`/`pause_internet`/`ring` from the previous owner (`docs/TESTING.md:154-157`; `AGENTS.md:248-251`) |
| Device Admin | Android device policy | the agent's status screen; `adb uninstall` succeeding is proof it is **off** |
| Pairing and device revocation | agent secure store + the `Device` row + Redis `revoked:device:*` | the status screen says whether the device is paired; `GET /v1/devices` as the parent |
| Seven onboarding grants | Android settings (accessibility, usage access, overlay, device admin, VPN consent, background location, Private DNS) | the status screen's "n of 7 required grants done" (`apps/child-android/app/src/main/java/com/familyshield/agent/setup/OnboardingPolicy.kt:18-28`; TR-16). Notification access is optional and not counted |
| `adb reverse` mappings | adb server on the host | `adb reverse --list` |
| Installed packages | the device | `adb shell pm list packages \| grep -i familyshield` |
| Test rows and keys | Postgres, Redis | `AGENTS.md` §7 verification queries (`AGENTS.md:180-186`) |
| Battery | the device | `adb shell dumpsys battery \| grep level` |

Two traps matter for handover. First, the probe's row 2 is `pm clear` and runs last on purpose
(`scripts/hardware/android-bypass-probe.ps1:127-130`). If it succeeds, the app data and the local pairing
are gone, while the server-side `Device` row still exists; if it fails — the expected outcome with a
Device Admin active — the app stays installed and paired. The release must state which case applies.
Second, after a reboot test do not queue `unlock` while the phone's own keyguard is still up; the
catch-up poll clears the overlay in the same second it appears and invalidates the row
(`docs/TESTING.md:259-261`).

## 3. Authority and eligibility

| Party | May hold DEV-01 | Role in the lease |
|---|---|---|
| Maintainer (owner) | yes, at any time, without a lease | outranks the warden and every lease; may suspend a run (`AGENTS.md:209-211`) |
| Kimi Code (warden) | yes, like any holder, for an accepted purpose | accepts purposes, arbitrates waits and conflicts, and holds break-glass (`AGENTS.md:208-210`) |
| KCL lead | yes, on a claim | requester from 2026-10-17; the lead no longer schedules the device |
| Antigravity | yes, on a claim | implementation lane; its hardware run is development feedback, never the acceptance signature (`AGENTS.md:11`) |
| Any other agent or tool | no, until listed in `AGENTS.md` §1 and here | an unlisted process gets no claim, even with repository access |

- A lease is valid only for an **accepted purpose**: a `TR-*` row or a work order on the board
  (`AGENTS.md:212-214`). "Looking at something" is not a purpose; if there is no row, ask the warden
  for one first.
- The warden does not grant access by hand. The claim is the permission; the warden's powers are
  accepting a purpose, deciding who gets a free slot, and break-glass. No chat message outranks the
  store.
- **The warden holds leases under the same rules**, including the end time and the release record
  (`AGENTS.md:215-216`). A self-claim is not a special case and has no longer ceiling than anyone else's.
- The maintainer's own use needs no notice. If they take the phone mid-run, the holder stops, clears the
  state (§8) and says so on the board; the warden records the interruption in §11.

## 4. The single-writer rule

The phone is physical state, not a service with per-agent accounts. There is no way to isolate two
writers, so there is exactly one.

**Allowed without a lease**

- reading the repository, building, and running unit/API suites that do not reach the device;
- `phone-claim.ps1 -Action Status`, the read-only way to see who holds it;
- `adb devices -l`, and only that: the identity check that prevents running against the wrong handset.

**Forbidden without a held lease**

- every other `adb` command, including `adb shell`, `install`, `uninstall`, `reverse`, `reboot`,
  `logcat -c`, `screencap`, `input` and `kill-server`;
- every parental command that reaches DEV-01: `lock`, `unlock`, `ring`, `stop_ring`, `pause`, `resume`,
  `pause_internet`, `resume_internet`, `locate_now`, `bonus_time`, `wind_down`, `sos_clear` — the one
  exception is the warden's recorded recovery under §9;
- changes made from the parent app against the paired device;
- changing OS settings on the phone (accessibility, Private DNS, overlay, radios, volume, keyguard).

`adb kill-server` is the sharpest example of why the list is broad: it drops the holder's connection and
can abort a run mid-row. `adb reverse --remove-all` does the same to the run's network path.

One lease, one agent: no sub-letting and no scheduling another agent's step inside your window
(`AGENTS.md:234-235`). Build and analysis happen before the claim, not during it. A lease covers the
named run, not a blanket permission: "while I have it, I'll also check X" is a new claim and a new
purpose.

The store is a local file on this Windows host. A remote agent cannot be locked out by it, so a remote
agent must honour the board line in `TEST-REQUESTS.md`; the store and the board are the two views of the
same lease (`AGENTS.md:237-240`).

## 5. Claiming, waiting and renewing

The command is the mechanism. Run it from the repository root in Windows PowerShell 5.1:

```powershell
.\scripts\hardware\phone-claim.ps1 -Action Claim -Owner "<agent>" -Purpose "TR-15: bypass probe"
```

Exit 0 means the phone is yours; 1 means someone else holds it or a `Wait` timed out; 2 is bad usage or a
store error; 3 means a `Heartbeat`/`Release` is under the wrong owner or the claim expired
(`scripts/hardware/phone-claim.ps1:52-53`). Use one consistent owner string — the name in §3 — because
the journal, the board and this register are matched on it by eye, not by an identity check.

| Step | Command | Why |
|---|---|---|
| See the holder | `.\scripts\hardware\phone-claim.ps1 -Action Status` (or `-Json`) | The store wins over the board when they disagree (`AGENTS.md:226-227`) |
| Queue | `... -Action Wait -Owner "<agent>" -Purpose "<TR-id>" -WaitMinutes N` | Polls for a free claim instead of two agents racing |
| Renew | `... -Action Heartbeat -Owner "<agent>"` | Before a build and between long probe sections; nothing renews in the background |
| Release | `... -Action Release -Owner "<agent>" -LeftState Clean -Note "<what you left>"` | Mandatory at the end; the other accepted values are `Locked` and `Unknown`, and the next holder checks which you chose |

**Length.** Default 60 minutes, accepted range 5–240 (`AGENTS.md:228-230`). A gate or probe run should
claim the length it needs up front, not silently overrun. At the end time the claim expires
automatically and the next claimant takes it; expiry does not clean the phone (`AGENTS.md:231-233`). An
expired claim is not a handover, and the next holder's pre-flight is not optional.

**Board line.** After a successful claim, post the same claim in the *Messages* section of
`docs/QA/TEST-REQUESTS.md`, newest first, exactly in this shape:

```text
DEVICE R5CW116Y6GF — <agent> — <TR-id: what you are running> — claimed until <HH:MM> UTC
```

The board line is how a human and a remote agent see the lease. It is a mirror, not a second lock.

**Arbitration.** When several agents want the same free slot, the warden decides. The order below is
policy for that decision and for whether a live lease is worth a break-glass; it is **not** a claim and
never overrides a live lease.

| Priority | Class | Examples |
|---|---|---|
| 0 | Maintainer's own use | calls, the handset as a phone — immediate; no notice |
| 1 | Phase gate / P0 safety verification | TR-15 (plan 1.9 gate), a lock or guard regression with a child-safety impact |
| 2 | Named TR hardware row | TR-10, TR-13…TR-18 |
| 3 | Exploratory or development loop | ad-hoc install, logcat, screenshots — first to yield |

A higher-priority run does not take a live lease. The holder is asked to release at a safe point; if the
holder is reachable, they release and the next agent claims. If the holder is unreachable and the claim
is **live**, only the warden's break-glass applies (`AGENTS.md:276-279`), and the reason goes in the
journal. If the holder is reachable but will not yield, the warden records the refusal and the
maintainer decides. A claim that has expired is taken with an ordinary `Claim`; no ceremony and no
contact is required.

## 6. Before the run

`docs/TESTING.md` §5.0 is the full pre-flight; this is the register's copy of the checks that decide
whether a run may start at all.

| Check | Command | Expected |
|---|---|---|
| Lease | `.\scripts\hardware\phone-claim.ps1 -Action Status` | `state HELD`, `holder` is you, `expires` in the future — not `FREE`, `EXPIRED`, or another name |
| Identity | `adb devices -l`; `adb -s R5CW116Y6GF shell getprop ro.product.model` | serial listed; `SM-F721B` |
| Keyguard | `adb -s R5CW116Y6GF shell dumpsys window \| grep isKeyguardShowing` | `false`. The probe aborts when it is `true` (`android-bypass-probe.ps1:42`) |
| Foreign overlay | `adb -s R5CW116Y6GF shell dumpsys activity activities \| grep topResumedActivity` | not `LockActivity` or `TamperGuardActivity` |
| Queued restriction | `GET /v1/devices/<id>/commands/history` with the parent token | no `pending`/`delivered` lock, pause, pause_internet or ring from the previous owner |
| Live agent from the previous run | `adb -s R5CW116Y6GF shell pidof com.familyshield.agent` | record it; a live process is the last run's, not yours (`docs/TESTING.md:153`) |
| Battery | `adb -s R5CW116Y6GF shell dumpsys battery \| grep level` | at least 30, or on charge — a screen-on probe drains fast |
| API | `curl -s http://127.0.0.1:<port>/health/deep` | `{"ok":true,"db":"up","redis":"up"}` (`services/api/src/routes/health.ts:14`) |
| Reverse | `adb reverse --list` | the mapping you expect, or empty |
| App state | `adb shell pm list packages \| grep -i familyshield`; the agent status screen | record paired/unpaired, build sha, admin on/off |
| Grants | the status screen | record "n of 7 required grants done" and the missing names |
| State file | a path outside the repo, e.g. `C:\KARIM\KCL\<run>\state.json` | created; it holds the parent token and `deviceId` the probe needs (`android-bypass-probe.ps1:41`) |

A run that starts from an unknown state cannot attribute what it measures, and the next holder cannot
tell residue from setup. If the pre-flight shows a pending restriction, do not start: the warden
settles it and the holder waits (`docs/TESTING.md:159-160`).

**Do not unlock the phone for the holder.** The keyguard PIN is the maintainer's. If the keyguard is
showing, stop and ask the maintainer; do not disable the keyguard, add a fingerprint, set the screen lock
to None, or guess the PIN (`AGENTS.md:252-254`; `docs/TESTING.md:176-177`).

## 7. While you hold it

- Stay inside the stated purpose and end time. Heartbeat before a build and between long probe sections;
  nothing renews the claim for you.
- A **safe point** is between probe rows, or after the current command's ack. Never stop mid-row: a
  half-run leaves a lock, an installed APK or a changed OS setting behind.
- **A `lock` is a test action, never a reservation** (`AGENTS.md:244-245`). Do not lock the phone to hold
  it while you are away, and do not end a lease with a restriction still applied. If your run uses
  `lock`, `pause` or `pause_internet`, the matching `unlock`/`resume` belongs in the same script or
  session, after the row. Verify the focus is no longer `LockActivity`; the device poll can take up to
  60 s (TR-13 measured 59 s). A script that dies between lock and unlock is the incident this document
  exists to prevent.
- Do not lock the phone with the power button during a run. The probe aborts on the keyguard, and on a
  phone with a secure lock screen nothing of ours runs before the first unlock after a reboot.
- Do not change the phone's own lock screen, accounts, OS version, developer options or USB-debugging
  authorisation. Do not accept an OS update on the maintainer's behalf.
- Do not issue `unlock` for someone else's live run. The only exceptions are the warden's break-glass
  (`AGENTS.md:276-279`) and the recorded recovery in §9; either invalidates the lock rows measured
  before it.
- If the owner takes the phone, note the time. If that changes what you measured, say so in the evidence
  rather than smoothing it over.
- If you must walk away, post `DEVICE PAUSED R5CW116Y6GF — <agent>` on the board with the exact state:
  locked/unlocked, paired/unpaired, installed build, reverse mappings. Prefer clearing the restriction
  first. A claim that runs out while you are away is treated as abandoned, not as a handover.

## 8. Releasing — checklist with evidence

Release is the last step of every run, together with `AGENTS.md` §7 (`AGENTS.md:172-190`). The table is
the device-specific application of it; every row needs its command output in the run log or PR.

| # | Step | Command | Pass condition |
|---|---|---|---|
| 1 | Clear lock / pause | `curl -s -X POST -H "Authorization: Bearer <parent token>" -H "Content-Type: application/json" -d '{"command":"unlock"}' http://127.0.0.1:<port>/v1/devices/<id>/command` | within 90 s, `topResumedActivity` is not `LockActivity`; no pause overlay |
| 2 | Stop a ring | POST `{"command":"stop_ring"}` to the same `/v1/devices/<id>/command` route if a ring test ran | silence; alarm volume restored to its pre-run value (TESTING §5e) |
| 3 | Radios | `adb shell svc wifi enable; adb shell svc data enable`; `adb shell settings get global airplane_mode_on` | `0`; both radios on (the probe turns them off in row 8) |
| 4 | Private DNS | restore the pre-run value; `adb shell settings get global private_dns_mode` | equals the value recorded in the pre-flight (TR-14's run recorded `null`, i.e. off) |
| 5 | Accessibility | restore the pre-run value; `adb shell settings get secure enabled_accessibility_services` | equals the pre-run value. If the OSRA service is re-enabled, write the **full** class name (`docs/TESTING.md:349`) |
| 6 | Overlay | `adb shell appops set com.familyshield.agent SYSTEM_ALERT_WINDOW <pre-run value>` | matches the pre-run value |
| 7 | Reverse | `adb reverse --remove-all` | `adb reverse --list` is empty |
| 8 | Uninstall | `adb uninstall com.familyshield.agent` (and any other package under test) | package gone. While Device Admin is active this fails by design; the PIN holder deactivates it first (TESTING §5a) — schedule that, do not force it |
| 9 | Unpair | `curl -s -X DELETE -H "Authorization: Bearer <parent token>" http://127.0.0.1:<port>/v1/devices/<id>` | `{"deleted":true}`. The `revoked:device:<id>` Redis key is deliberate security state and is **kept** (`services/api/src/routes/devices.ts:393-403`) |
| 10 | Test data | `psql -h 127.0.0.1 -U familyshield -d familyshield -v apply=1 -f services/api/scripts/cleanup-test-data.sql`; then `node services/api/scripts/cleanup-test-redis.mjs` (dry run) and the same with `--apply` | `SELECT (SELECT count(*) FROM "Family"), (SELECT count(*) FROM "Child")` returns `1 / 1`; nothing unexplained left (`AGENTS.md:180-186`) |
| 11 | Evidence | log path, probe JSON, screenshots, API log excerpt; the claim and release lines from `-Action Status` or the journal | survives outside the repo; quoted in the run log or PR (`AGENTS.md:269-270`) |
| 12 | Release the claim | `.\scripts\hardware\phone-claim.ps1 -Action Release -Owner "<agent>" -LeftState Clean -Note "<what you left>"` | the value is honest: `Clean`, `Locked` (the overlay is still up, a warning to the next holder, not a handover) or `Unknown` (you did not check) |

If the probe's row 2 (`pm clear`) succeeded, the phone is already wiped and unpaired locally; the
server-side `Device` row and its Redis revocation key still need step 9. If it failed (the expected
admin-tier result), the app is still paired and installed, and step 9 plus the PIN-gated uninstall both
apply. Record which case applies instead of copying "unpaired" from the template.

The parent PIN is not recorded in this document. The run owner and the maintainer hold it; a release that
needs the PIN waits for one of them rather than guessing.

## 9. Abandoned run or a phone left locked

The lease does the waiting: an expired claim is free, and a live claim whose owner is unreachable is the
warden's break-glass (`AGENTS.md:274-286`). The device state still needs a recovery, in this order.

1. **Do not press around on the phone.** Home, Recents and Settings just re-raise the overlay; each press
   makes the next observation noisier. Do not reboot: a reboot does not clear the overlay. Do not
   `adb uninstall`; Device Admin blocks it.
2. **Find the parent token and device id.** The run's state file (`-StateFile`, e.g.
   `C:\KARIM\KCL\tr07\tr10-state.json`) holds both (`android-bypass-probe.ps1:41`). The holder may still
   answer with the path even if they cannot continue the run.
3. **Unlock through the API.** Use the same API/DB the device is paired to; the command is durable
   (`docs/adr/0012-durable-device-command-queue.md:11-17`), and `unlock` is safe-direction, needing no
   active consent (`services/api/src/routes/devices.ts:48-49`, `:237-240`):

   ```bash
   curl -s -X POST -H "Authorization: Bearer <token>" -H "Content-Type: application/json" \
     -d '{"command":"unlock"}' http://127.0.0.1:<port>/v1/devices/<deviceId>/command
   adb -s R5CW116Y6GF shell dumpsys activity activities | grep topResumedActivity
   ```

   Allow up to 90 s (the 60 s poll plus delivery; TR-13 measured 59 s). If the top activity is no longer
   `LockActivity`, the phone is recovered.
4. **If the token is gone**, the maintainer can unlock from the parent app: they own the family, and
   `unlock` is available to any parent in that family with the `devices` permission. This is the clean
   second route.
5. **If the API or agent is unreachable**, `docs/TESTING.md` §5.0 documents the last resort:
   `adb shell am force-stop com.familyshield.agent`. It removes the overlay with the process, but it
   leaves the app in Android's stopped state — no receiver, job or accessibility rebinding until it is
   launched again (`docs/TESTING.md:179-182`; probe row 3, §5f). Record that you did it; the next holder
   relaunches the agent and re-grants.
6. **If the keyguard is showing, stop.** Only the maintainer unlocks the phone; a takeover of a
   keyguard-locked handset waits for the human (`AGENTS.md:283-284`). Never guess or reset the PIN.
7. **If all of the above fails**, the remaining route is the PIN: deactivate Device Admin (PIN-gated),
   uninstall, re-pair. That loses the pairing; only the maintainer performs it, and it is recorded as a
   lost pairing, not a normal release.
8. **Record the recovery** in the run log, on the board, and in §11: who unlocked, when, and by which
   route. Any lock/guard rows measured before an out-of-band unlock are invalid; the run may continue
   from the next row with a note, or be re-run.

Under the lock the phone can still place an emergency call — `LockEnforcementPolicy` exempts the dialers
and in-call UI (`LockState.kt:44-54`), and the probe asserts it as row S1. That protects the person
holding the phone; it is not a testing recovery.

## 10. Conflicts and escalation

- **Store and board disagree.** The store wins for a local agent (`AGENTS.md:226-227`); a remote agent
  cannot see the store, so the board is its only view and the warden reconciles the two.
- **Two agents believe they hold it.** The store uses an exclusive create, so two `Claim` calls cannot
  both win (`scripts/hardware/phone-claim.ps1:21-28`). Stop both runs, check `-Action Status`, and let
  the warden decide; do not "share" the phone.
- **A holder acts outside this document.** Record it and escalate; do not mirror it. A second writer
  makes the state worse. A run without a held lease, or one that collides with another's, is not
  evidence and the warden may require a repeat (`AGENTS.md:288-292`).
- **A live claim is unreachable.** The warden may break-glass with a reason of at least 10 characters;
  the reason is journalled (`AGENTS.md:276-279`). This is not a way to skip a queue.
- **Wrong serial.** Stop. Do not install on whatever is attached. A second physical device gets a new
  asset id (DEV-02) and a row in §2 and §11 before anyone uses it.
- **The phone disappears from `adb devices`.** The lease stays with its holder until expiry or release;
  report the absence to the maintainer. Do not restart the adb server while another run may be active.
- **Disagreement about a decision.** One evidence-backed exchange in `TEST-REQUESTS.md` or
  `DISCUSSION-LOG.md`, then the maintainer decides (`AGENTS.md` §6.3). No merging over it.

## 11. The register

Only the warden edits this section. Everyone else uses the claim and the board. History is append-only:
a failed or abandoned run stays, with its reason, because it explains the state the next holder inherits.

### 11.1 Store state and current run

Read on 2026-10-17 at 13:47Z:

```text
{ "serial": "R5CW116Y6GF", "state": "FREE" }
```

| Item | Record |
|---|---|
| Lease at 13:47Z | **FREE** — `-Action Status` returned `state FREE`, and the default store directory (`%LOCALAPPDATA%\OSRA\phone-claims`) did not exist, so no claim had ever been journalled |
| Reported run | TR-15 / plan 1.9 eleven-row probe, reported in progress at 13:35Z with Kimi as its owner |
| Consequence | If that probe is still running, it is running **without a lease**. The state is reconciled when the warden either claims it while it runs or records that it has ended; until one of those is written down, the phone is treated as held by that run and nobody else starts |
| Evidence status | The run predates the lease store. Whether its results stand under `AGENTS.md` §9.5 is the warden's call; the register records the facts, not a verdict |

This is the first entry in the register and it already shows the hazard: the mechanism arrived after the
run it was meant to govern. The next run starts with a claim or not at all.

### 11.2 Queue

The queue is `phone-claim.ps1 -Action Wait`, not a table here. This mirror exists so a human reading the
register can see who is waiting without opening the store.

| Position | Requester | Purpose | Waiting since (UTC) | Status |
|---|---|---|---|---|
| — | none recorded at 13:47Z on 2026-10-17 | — | — | — |

### 11.3 History

The rows below predate the lease store. They are reconstructed from `TEST-REQUESTS.md`; no claim id,
start/end time or release record was kept at the time, which is the gap this document closes. Times are
left blank rather than guessed. All runs are on DEV-01 (the Flip4) unless stated.

| Date (UTC) | Holder | Purpose | Lease | Outcome | Evidence |
|---|---|---|---|---|---|
| 2026-10-17 | KCL lead | TR-07 hardware half — pairing and SOS alert with v1 on and off | none (predates) | PASS, skew −1 s | `TEST-REQUESTS.md` TR-07; PR #65 |
| 2026-10-17 | KCL lead | TR-10 — pairing PIN, Device Admin, guard screen, admin-removed alert | none (predates) | PASS, alert 3.3 s | `TEST-REQUESTS.md` TR-10; PR #76 |
| 2026-10-17 | KCL lead | TR-13 — lock that holds (Home/Recents/Settings, reboot) | none (predates) | PASS | `C:\KARIM\KCL\tr07\tr13-lock.log`, `tr13-logcat.txt` |
| 2026-10-17 | KCL lead | TR-14 — DNS sinkhole, pause/resume, VPN disconnect alert | none (predates) | PASS | `C:\KARIM\KCL\tr07\tr14-filter.log` |
| 2026-10-17 | KCL lead | TR-16 — onboarding checklist, grant count | none (predates) | PASS | `C:\KARIM\KCL\tr07\tr16-walk.log` |
| 2026-10-17 | KCL lead | TR-17 — ring/locate, PIN gate over the lock screen | none (predates) | PASS | `tr17-ring.log`, `tr17-pin.log` |
| 2026-10-17 | KCL lead | TR-18 — release APK, targetSdk 35 FGS, encrypted store | none (predates) | partial: cleartext HTTPS endpoint still open | `TEST-REQUESTS.md` TR-18 |
| 2026-10-17 | Kimi Code (reported) | TR-15 — the eleven-row Phase 1 gate probe | **none** — store absent at 13:47Z | in progress or ended; unleased either way | to be posted with the run |
| 2026-10-17 | not identifiable | run that left the `lock` overlay in place and went unreachable | none | FAILED — no release | none; its cost is the reason this file exists |

### 11.4 Decisions

| Id | Date | Decision | By | Why |
|---|---|---|---|---|
| DEV-01-D1 | 2026-10-17 | The lease is `phone-claim.ps1`; this file never grants access | warden | two mechanisms would create two answers to "who has it"; the script is the one with an expiry |
| DEV-01-D2 | 2026-10-17 | The register is append-only; a run without a lease is recorded as unleased, not silently omitted | warden | the next holder needs the real state, including the runs that went wrong |
| DEV-01-D3 | 2026-10-17 | Recovery unlock (§9) may be issued without holding the lease, by the warden or the maintainer, and is logged | warden | an abandoned lock is worse than the bookkeeping; the record keeps the evidence honest |
| DEV-01-D4 | 2026-10-17 | **The 17:23–17:36Z gate run counts as evidence** even though it predated this rule and held no lease | warden | the rule did not exist when it started; one agent (the warden) was the only user of the handset, so there was no collision to void, and the run produced findings #80 and #81 — voiding it would discard the two most serious defects found so far on a technicality. Recorded here rather than assumed, and the lease applies to every run after it |
| DEV-01-D5 | 2026-10-17 | Recovery unlock for a stranded `lock` is issued **through the API the device is paired to** (`POST /v1/devices/:id/command {"command":"unlock"}`), not by clearing app data | warden | it is the product's own safe-direction path, it needs no PIN, and it leaves the pairing intact — `pm clear` also un-pairs, which turns a recoverable state into a re-enrolment. Demonstrated this day: the command was delivered and the agent released its overlay |
| DEV-01-D6 | 2026-10-17 | The gate result stands as **6/11 and NOT opened**; #78 does not merge until the emergency-dialer defect (#80) is fixed and S1 re-runs green | warden | 1.9 is signed off when the ten bypasses fail; six do, and one failure is a safety defect in code on that branch (issue #80), so merging would put a lock that blocks emergency calling on `main` |

## 12. Limits and the next step

The script says it plainly: the lease is coordination, not access control. Anyone who can write the store
can edit or delete a claim, nothing proves the holder is the agent named in it, and a remote process that
never reads the store or the board cannot be stopped by either
(`scripts/hardware/phone-claim.ps1:29-33`). What it does prove is that two cooperating agents will not
both believe they own the phone, and that a claim has an end. Two sessions of the same agent that use the
same owner string are also indistinguishable: either can heartbeat or release the claim. Where that
matters, give each session its own owner string and treat the lease as belonging to the agent, not the
session.

The obvious next control is a wrapper around the hardware scripts: before the first `adb`, run
`phone-claim.ps1 -Action Status -Json` and refuse unless the state is `HELD` for the caller, then release
on exit. It would not stop a direct `adb` call, but it would remove the accidental collision — the
failure that actually happened. It is not implemented here; it needs a decision because it touches the
shared scripts and all three agents' workflow.

Out of scope here: emulator runs, the Windows agent, a second physical device (add DEV-02), and
host-level collisions on ports, the database or Redis between concurrent agents. Those need their own
rule; this one is about the phone.

## 13. Document control

- v2, 2026-10-17, Kimi Code. Supersedes v1 of this file, which proposed a board-only lease; the standing
  rule in `AGENTS.md` §9 and its script are authoritative. Only the warden edits; corrections are
  requested on the board and discussed in `DISCUSSION-LOG.md`.
- Never delete a past state — supersede it (`AGENTS.md:93-96`). If a rule changes, add a decision row
  (§11.4) and update the section, so the reason survives the change.
- Line numbers in other files are as of 2026-10-17. Those files are edited concurrently; the section
  reference is the durable one, the line number is the convenience.

| Related document | What it covers |
|---|---|
| `AGENTS.md` §9 (`AGENTS.md:192-292`) | the binding lease rule: who may use it, claim, expiry, break-glass |
| `AGENTS.md` §7 (`AGENTS.md:172-190`) | device and database hygiene after every test |
| `docs/TESTING.md` §5.0 (`docs/TESTING.md:109-194`) | the operational lease procedure: claim, pre-flight, takeover, release |
| `docs/TESTING.md` §5a, §5f | lock/tamper behaviour and the eleven-row probe |
| `docs/QA/TESTING-STRATEGY.md` §4 | the 30/60-minute cadence for test requests |
| `scripts/hardware/phone-claim.ps1` | the lease implementation, store layout and exit codes |
| `docs/adr/0010-android-tamper-protection-tiers.md` | why the lock and admin behave as they do |
| `docs/adr/0012-durable-device-command-queue.md` | why a queued command survives a restart |
| `docs/QA/TEST-REQUESTS.md` | the board: claims, waiters and run announcements |
