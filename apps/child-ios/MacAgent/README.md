# OSRA Agent for the Mac (roadmap 5.9, build step ii)

The Mac's background agent: a launch daemon that runs as root with no window. It **pairs** with the server,
**syncs the child's rules** and **sends heartbeats**. It enforces nothing yet: web filtering is step (iii)
and the lock screen and app blocking are step (iv) of [ADR-0036](../../../docs/adr/0036-macos-child-agent-on-macos-27.md).
Issue #775.

## Where the code is, and why

| Path | What |
|---|---|
| `Package.swift` | Its own Swift package, nested in the shared package's folder. It depends on the package above (`..`) and copies nothing from it |
| `Sources/OSRAMacAgentCore/` | Everything testable: the cycle (`AgentLoop`), the System keychain store, the secret proof, the heartbeat, the capability report, the child-account check, the commands |
| `Sources/osra-agent/` | The binary, one line: it hands its arguments to `AgentCLI` |
| `Tests/OSRAMacAgentCoreTests/` | Unit tests; each names the fault that would break it |
| `launchd/com.osratech.agent.plist` | The launch daemon: `RunAtLoad`, `KeepAlive` |
| `scripts/install-dev.sh`, `scripts/uninstall-dev.sh` | The **test bed's** installer. The product's installer is step (vi) |

It is a nested package rather than a target of the shared one so that the iPhone builds never compile a
macOS-only program, and it sits under `apps/child-ios/` so the existing CI path filter covers it unchanged.
`apps/agent-macos/` (the never-built .NET scaffold) is retired by ADR-0036 decision 2; removing it is its own
change.

From the shared package it uses, unchanged: `PairingClient` (claim, wait for the parent's Allow),
`InternalSigner` (HMAC, ADR-0014), `AgentIdentityStore` with its `SecretStore` slot, `RuleSyncClient` /
`RuleSyncer` / `RuleStore`, `CommandClient` / `CommandDrainer`, and `DeviceRevocation`. The one change to the
shared package is additive: `PairingClient.claim` takes a `ClaimDevice` (default: the iPhone, as before), so
the Mac can say `platform: "macos"` and send its capability report with the claim.

## What it does

- **Server.** One constant, `https://api.staging.osratech.com` (`MacAgentServer`). Pairing has no server
  field and no server option (ADR-0041 D5); nothing on the Mac can point the daemon elsewhere. Production
  arrives with the installer step as its own change.
- **Pairing.** `osra-agent pair` takes the 6-digit code, claims it, waits for the parent's Allow, then
  **proves the HMAC secret** before it stores anything or says `paired` (below).
- **Secrets.** The device token and the HMAC secret are in the **System keychain**, stored by the daemon's
  own binary as root. Another program has to ask for them, and that needs an administrator's password. The
  ids and the synced rules are in root's preferences (`/var/root/Library/Preferences`), which a standard user
  cannot read either.
- **The cycle** (`AgentLoop`): every 60 s it polls the command queue, the server's interval for a device it
  cannot wake by push. A rule change in the parent app queues `rules_updated`, which the shared drainer
  answers with a rule sync, so a change arrives within one poll. Commands the Mac cannot run are acknowledged
  `failed: not_supported`, never left silent. At start and every 15 minutes it also syncs the rules and sends
  a heartbeat (`POST /v1/devices/:id/telemetry` with the capability report), which is what shows the Mac as
  online in the parent app.
- **Honest report.** Every feature planned for the Mac is reported `unavailable`, and no "applied rules
  version" is sent, because nothing is enforced yet.
- **Child account.** `pair --child-user <account>` checks whether that macOS account is an administrator
  (ADR-0036 rule 4) and prints `warning: child_account_admin`; the daemon logs `child_account=…`. The warning
  the parent reads in the app needs the `child_account_admin` capability on the server and Bureau wording:
  a later change.
- **Log.** Subsystem `com.osratech.agent`. Lines are fixed words and numbers only (state, HTTP status, rules
  version, counts): no ids, names, codes, tokens or rule contents.

### The secret proof

`#775`: "a wrong HMAC key must be refused by the server and the daemon must not report paired". No call the
daemon makes in this step is signed (rule sync, the poll and the heartbeat use the device token), so a wrong
secret would go unnoticed until the first alert. `SecretProof` therefore sends one request signed with the
secret and no token to `POST /v1/location/ping` **with no pings**: that route checks a device's signature
first and reads the body second. `401` means the signature was refused (`invalid_signature` for a wrong key);
`400` means it was accepted and the empty batch refused; nothing is stored either way. Pairing stores the
identity only after `accepted`. The daemon repeats the proof at every start and for every new pairing, and
while it is refused it sends nothing as the device: no poll, no heartbeat, so the parent sees the Mac go
offline.

## Commands (all but `version` need root)

```
osra-agent run                      the daemon (launchd starts it)
osra-agent pair [<code>] [--child-user <account>] [--device-name <name>]
osra-agent status                   paired | not_paired | secret_refused …, rules version, last sync
osra-agent unpair                   clears this Mac's side only
osra-agent version
```

With no code on the command line, `pair` reads it from standard input. The words these print are for the
test bed and the installer, not for families: this step has no screen and no translated text.

## Build and test

```bash
cd apps/child-ios/MacAgent
swift build
swift test
```

CI runs the same in the `macos-core` job of `.github/workflows/ios-ci.yml`.

## Test-Mac rows (the "Done when" of #775)

On the test Mac, as an administrator, with staging up:

```bash
cd apps/child-ios/MacAgent
sudo ./scripts/install-dev.sh
sudo /Library/PrivilegedHelperTools/com.osratech.agent pair --child-user <the child's account>   # type the code
log stream --predicate 'subsystem == "com.osratech.agent"' --level info
```

| Row | Do | Expect |
|---|---|---|
| Pair | make a code in the parent app (Add a computer), run `pair`, tap Allow | `waiting_for_parent`, then `paired`; log `state=paired`, `event=rules_synced version=N`, `event=heartbeat status=202`; the Mac is online in the parent app |
| Rule change | change a rule in the parent app | within about a minute: `event=commands handled=1 refused=0` and `event=rules_synced version=N+1` |
| Wrong HMAC key | `sudo ./scripts/install-dev.sh --plant-wrong-hmac-key` (`version` then prints `PLANTED FAULT`), make a code, run `pair`, tap Allow | `waiting_for_parent`, then `error: secret_refused invalid_signature`, exit 1; never `paired`; `status` prints `not_paired`; no heartbeat line in the log. Install again without the flag afterwards, and remove the device the server made in the parent app. The daemon's side of this (a stored secret the server refuses) is `AgentLoopTests.testARefusedSecretIsNeverPairedAndNothingIsSentAsTheDevice` |
| Killed daemon | `sudo kill -9 $(pgrep -f com.osratech.agent)` | launchd starts it again within about 10 s (`event=start`) |
| Secret unreadable | as a **standard** user: `security find-generic-password -s com.osratech.agent -w /Library/Keychains/System.keychain` | refused (it asks for an administrator, or fails); `ls /var/root/Library/Preferences` is refused for that user too |

`sudo ./scripts/uninstall-dev.sh` removes everything the install put there.

## Not in this step

The pairing window and the parent PIN (step iv), the content filter (iii), the lock overlay and app blocking
(iv), the Safeguard check (v), the notarised installer and `SMAppService` registration (vi), push wake, and
the `child_account_admin` capability.
