"""File the P0/P1 QA findings as GitHub issues (labels created on demand)."""
import json, os, urllib.request, urllib.error

TOKEN = os.environ["GH_TOKEN"]
REPO = "handfulofluck-lab/osra"
API = "https://api.github.com"

def req(method, path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    r = urllib.request.Request(f"{API}{path}", data=data, method=method)
    r.add_header("Authorization", f"token {TOKEN}")
    r.add_header("Accept", "application/vnd.github+json")
    if data: r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r) as res:
            return res.status, json.loads(res.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")

LABELS = [
    ("sev:critical", "b60205"), ("sev:high", "d93f0b"), ("sev:medium", "fbca04"), ("sev:low", "0e8a16"),
    ("platform:api", "1d76db"), ("platform:android", "3ddc84"), ("platform:windows", "0078d4"),
    ("platform:flutter", "02569b"), ("platform:ios", "000000"), ("qa", "5319e7"),
]
for name, color in LABELS:
    st, _ = req("POST", f"/repos/{REPO}/labels", {"name": name, "color": color})
    print(f"label {name}: {st}")

INBOX = "docs/QA/ANTIGRAVITY-INBOX.md"

ISSUES = [
 dict(id="P0-1", sev="critical", plat="api", title="API-02: per-device HMAC signing secrets leak to parents and to any device JWT",
   checks="probe F5, F6, F7, G3, G4, G5, G6b",
   body="`/v1/family/me`, `/v1/family/export`, `/v1/devices`, `/v1/devices/:id` all return the device row's `internalSecret` (the key that authenticates agent→server alerts). A **device JWT** also gets 200 on `/v1/devices` and on a *sibling* device. Root cause: parent payloads strip only `pushToken` (`routes/family.ts:53,186`); `internalSecret` passes through by omission; the device list/detail guards are role-agnostic (`devices.ts:163,176`).\n\n**Fix:** Prisma `select` allowlist for all client payloads; `requireParent` on `/v1/devices` list+detail; a device may read only its own row.\n**Impact:** export files/backups contain the proof-of-authenticity key; any child device can harvest sibling keys (enables #P0-4)."),
 dict(id="P0-2", sev="critical", plat="ios", title="IOS-01: every iOS alert is rejected with 401 (signature keyed off a body field iOS never sends)",
   checks="probe J4",
   body="Verified live: a request signed with the device's **own** secret but **without** a top-level `deviceId` → 401; the same body **with** `deviceId` → 201. `lib/internalAuth.ts:20-30` only looks up the per-device secret when the body carries `deviceId`; the iOS reporter payload has none (`DeviceActivityMonitor.swift:43-59`).\n\n**Fix (server-side preferred):** bind the secret lookup to the authenticated device (e.g. `x-device-id` header) instead of the request body — this also unblocks the already-written iOS client, which cannot be rebuilt here (no Mac).\n**Impact:** the whole iOS alert pipeline is inert."),
 dict(id="P0-3", sev="critical", plat="api", title="AND-01: tamper / vpn_detected / install_request / unknown_contact alerts are rejected 400 and dropped",
   checks="probe section I",
   body="`POST /v1/alerts/internal` returns 400 for the four categories the Android agent actually sends (`AccessibilityOffReceiver.kt:38`, `LocationService.kt:266`, `PackageAddedReceiver.kt:66`, `CommsLogger.kt:230`); `packages/shared-types/src/world-class.ts` already defines them.\n\n**Fix:** extend the server enum to match shared-types (check Windows/macOS senders too) and add a test per category.\n**Impact:** parents never learn about disabled accessibility (tamper), VPN use, new installs, or unknown contacts."),
 dict(id="P0-4", sev="high", plat="api", title="API-01: a device can inject alerts/location pings into a sibling child",
   checks="probe G7",
   body="Verified live: signing with device A's own secret but `childId` = sibling child B → 201, and the alert lands on B. The HMAC path never compares the body's `childId` to the signing device's family (`alerts.ts:87-101`, `location.ts:45-55,110-120`, `social.ts:90-99`).\n\n**Fix:** `verifyInternalSignature` returns the device's `{deviceId, childId, familyId}`; each route asserts the body `childId` is in that family (and equals the device's own child for telemetry/ping)."),
 dict(id="P0-5", sev="high", plat="api", title="API-04: device revocation only applies under /v1/devices",
   checks="probe G10, G11, G12",
   body="Verified live: after unpair the device JWT still gets 200 on `/v1/rules/:childId` and can still mint a WS ticket; `/v1/location/ping` returns **500 leaking a Prisma error** instead of 401. The revocation hook is inside the `deviceRoutes` plugin, so Fastify encapsulation limits it to that prefix (`devices.ts:287-297`, mounted `server.ts:55`). Live e2e passes because its revocation check only exercises the guarded route.\n\n**Fix:** register the revocation check on the root app; fail 401 before touching the DB."),
 dict(id="P1-1", sev="high", plat="android", title="AND-02: screen-time counters are in-memory only — a reboot resets the day's limits",
   checks="new unit test",
   body="`data/RuleRepository.kt:41` reads `UsageCounters`, which is never persisted nor rebuilt from the Room `usage_events` (`data/UsageCounters.kt:5`). Reboot → full allowance restored.\n**Fix:** persist/rebuild today's per-app minutes on process start."),
 dict(id="P1-2", sev="high", plat="android", title="AND-03: no cached rules → every app is allowed (fail-open)",
   checks="appliance test",
   body="`data/RuleRepository.kt:65` — `val ruleSet = cached ?: return Decision.ALLOW`. Before the first sync (or after storage loss) nothing is blocked.\n**Fix:** fail closed when paired but no rules are cached, or gate setup completion on a persisted rule set."),
 dict(id="P1-3", sev="high", plat="android", title="AND-04/AND-05: block and lock overlays are dismissible",
   checks="—",
   body="`enforcement/BlockActivity.kt:143` exposes a working **Close** button and `AppBlocker.kt:39` debounces 2 s → burst access. `commands/LockActivity.kt:49` has no back/home guard, so the parent `lock`/`pause` overlay is dismissed with Back.\n**Fix:** remove the child-facing dismiss path (or gate behind parent PIN), intercept back/home, re-raise immediately."),
 dict(id="P1-4", sev="high", plat="windows", title="WIN-01/WIN-02: lock overlay defeated by Alt+F4 & second monitor; bedtime uses the child's own Windows lock",
   checks="—",
   body="`LockOverlay.cs:100-106` has no `FormClosing`/`WndProc` guard (Alt+F4 closes it) and maximises on the primary monitor only; `lock`/`pause` overlays are shown once and never re-asserted (`ScreenTimeEnforcer.cs:72`). Bedtime uses `LockWorkStation()` (`ScreenTimeEnforcer.cs:57-63`) — the child knows their own password, and killing the agent ends the re-lock loop.\n**Fix:** cancel `SC_CLOSE`, cover all screens, re-assert from the enforcer, and pair bedtime with the agent-owned PIN overlay."),
 dict(id="P1-5", sev="high", plat="windows", title="WIN-03/WIN-04: screen time is double-counted, and idle/locked time burns the budget",
   checks="xunit",
   body="`ProcessMonitor.cs:383-393` (foreground sampler) and `:150-175` (rule sampler) both write `app_usage` for the same minute → limits reached at ~2×. `:379-393` records an `idle` pseudo-process while away/locked, and `MinutesUsedToday()` sums it → an overnight lock consumes the daily budget.\n**Fix:** single accumulator per tick; never accrue while idle/locked."),
 dict(id="P1-6", sev="high", plat="windows", title="WIN-05/WIN-06: rename defeats app blocking; the filter is WinINET-only",
   checks="—",
   body="Blocking matches process **name** only (`ProcessMonitor.cs:130,311`) → copying `notepad.exe` to `notes.exe` bypasses it silently; kill failures are logged at Debug. The proxy sets only the HKCU WinINET proxy (`WebFilterProxy.cs:242-252`) → WinHTTP clients, per-app proxy settings (Firefox) and VPN tunnels bypass filtering; VPN is alert-only. This matches the original tester report (\"web filter didn't work on Firefox/Chrome\").\n**Fix:** match path/hash, set WinHTTP too (or document), and act on VPN rather than alert only."),
 dict(id="P1-7", sev="high", plat="flutter", title="FLT-01: concurrent 401s race the token refresh → whole session revoked / forced logout",
   checks="widget/unit test",
   body="`lib/api/client.dart:16-45` — parallel 401s each trigger a refresh; the losers replay a now-rotated refresh token, and reuse detection revokes the family's sessions (`auth.ts:216-245`), logging the parent out.\n**Fix:** single-flight the refresh (mutex/future sharing) and queue the failed requests."),
 dict(id="P1-8", sev="high", plat="flutter", title="FLT-02…FLT-06: parent-app ↔ API contract mismatches (5 bugs)",
   checks="widget tests",
   body="- **FLT-02** `screenTimeTodayMinutes` read by the UI (`models.dart:81,100`, `dashboard_screen.dart:114,182`) but never sent by the API → progress always 0.\n- **FLT-03** \"Always allowed\" apps are dropped by the server schema (`rules.ts:54-64,105-124`, `schema.prisma:82`) → silently never saved.\n- **FLT-04** Router lacks `refreshListenable` (`app.dart:16-23`) → a restored session is stranded on the login screen.\n- **FLT-05** Pending invites read `items` while the API returns `invites` (`family_provider.dart:94-99`, `invites.ts:59-66`).\n- **FLT-06** Location history parses `ts`, API returns `timestamp` (`world_class_provider.dart:68-75`, `location.ts:143-158`) → \"today's route\" empty."),
 dict(id="P1-9", sev="high", plat="ios", title="IOS-02…IOS-05: iOS shielding cannot work; two files will not compile; bedtime wipes shields",
   checks="compiles on macOS + tests",
   body="- **IOS-03** `store.shield.applicationCategories` / `webDomainCategories` type mismatch — compile error (`ScreenTimeController.swift:42-44`).\n- **IOS-04** `ShieldConfiguration.Label(text:color:)` passes `nil` to a non-optional colour — compile error (`ShieldConfiguration.swift:32-36`).\n- **IOS-02** Shield tokens are synthesised from bundle identifiers and no `FamilyActivityPicker`/selection persistence exists — shielding can never work as written (`ScreenTimeController.swift:88-90`, `DeviceActivityMonitor.swift:116-128`).\n- **IOS-05** `intervalDidEnd` clears the store using keys nothing ever writes (`DeviceActivityMonitor.swift:114-129,145-156`) → bedtime end un-shields rule-blocked apps; overlapping routines clobber one shared store."),
]

created = []
for it in ISSUES:
    title = f"[{it['id']}] {it['title']}"
    body = (f"{it['body']}\n\n---\n**Severity:** {it['sev']} · **Platform:** {it['plat']}\n"
            f"**Acceptance (must pass before merge):** {it['checks']}\n"
            f"**Full queue:** `{INBOX}` · **Evidence:** `docs/QA/audits/` · **Protocol:** `AGENTS.md`")
    st, res = req("POST", f"/repos/{REPO}/issues", {
        "title": title, "body": body,
        "labels": [f"sev:{it['sev']}", f"platform:{it['plat']}", "qa"],
    })
    created.append((st, res.get("number"), res.get("html_url", res.get("message", ""))))
    print(f"{it['id']}: {st} #{res.get('number')}")

print("\ncreated:", sum(1 for s, _, _ in created if s == 201), "of", len(ISSUES))
