# Ship Notes — OSRA World-Class Upgrade
**Date:** 2026-09-16 · **Plan:** `dist/KIMI-HANDOFF-WORLD-CLASS-2026-09-16.md` (features #1–#29, phases 0–7)

## What shipped

**Binaries (dist\):** `OSRA-Parent.apk` (55.9 MB, 89 widget tests) ·
`OSRA-ChildAgent.apk` (146 JVM tests) · `OSRA-Agent-Windows\`
(self-contained, 161 xunit tests, `reset-proxy.bat` included).

**Suites at ship time:** API **178/178** · Android **146/146** · Desktop **161/161** ·
Flutter **89/89** · AI 18 passed/1 skipped · **live E2E 44/44 through the public tunnel**
(incl. 10 new world-class checks: blocklist pack, bonus propagation, social-AI scan →
encrypted vault → decrypted read-back, invites, reports summary, wind-down, pause status).

## How to test each epic (5-minute walkthrough)

| Epic | Try this |
|---|---|
| #1 Default protection | Create a child → open Rules → web filter: all 13 categories ON. On Windows, browse `http://pokerstars.com` → blocked page + `web_threat` alert (pack syncs within 60 s). |
| #3 HTTPS filter | On the child PC: `setx FS_HTTPS_INSPECT 1`, restart agent, accept the root-cert dialog once → https blocked domains show the block page. |
| #11 Pause internet | Dashboard → child card → 'Internet' pill → Pause → PC/phone shows paused state; educational/always-allowed apps still open. |
| #2 Social AI | On the child phone, send/receive a WhatsApp message containing "kill yourself" (test) → parent gets `social_concern` alert; Social tab shows the decrypted snippet + coach card (EN/عربي). |
| #6 Calls/SMS | Call/text the child phone → Social tab 'Calls & texts' timeline updates (grant permissions from the agent's completion screen). |
| #8 Install approval | Install any app on the child phone → 'New app installed' alert → open it → 'Block this app' → app dies within ~60 s. |
| #10/#22 Bonus & wind-down | Child page → +30 bonus → limit extends; 'Wind down' → device warns then locks in 15/30 min. |
| #13 Multi-parent | Dashboard menu → Family members → Invite (co-parent, pick permissions) → share the accept token → invited parent registers and accepts. |
| #14 SOS | Phone: quick-settings 'OSRA SOS' tile → hold 5 s → critical alert. PC: Shift+F11 with `FS_SOS_HOTKEY=1`. |
| #19/#20 Tamper/VPN | Turn off the OSRA accessibility service or the Windows proxy, or start a VPN → critical/warning alert within a minute. |
| #4/#28/#29 Insights | Reports screen (bar chart + blocked domains), wellbeing ring on dashboard, live '● app · Nm today' chip. |
| #16 Coach | Open any social/self-harm alert → 'How to talk about this' → toggle عربي/EN. |

## Residual risks / honest gaps

- **HTTPS inspection** is opt-in (`FS_HTTPS_INSPECT=1`) with a self-signed root the child
  could remove (tamper alert covers removal of the *proxy*, not the cert). Browsers with
  certificate pinning (some apps) bypass it — documented.
- **Android pause-internet** enforces via overlay + app blocking; the VPNService sinkhole
  is the production path (NOTE in code). Some OEM battery killers can still stall the
  foreground service.
- **Social capture** is best-effort (no retry queue); Accessibility text heuristics vary
  per app version; over-redaction is the chosen failure mode.
- **Calls/SMS** are log-only (no default-dialer role); iOS cannot do this at all (NOTE in UI).
- **Digests** render in-app / via API; no SMTP in the test build (cron noted).
- **macOS agent** is proven scaffolding + docs (`apps/agent-macos`), not a built binary.
  **iOS** needs a Mac/Xcode wrapper (`dist/IOS-BUILD-NOTES.md`).
- **Chromebook/Kindle** are documented sideload paths (`dist/CHROMEBOOK-KINDLE-PATH.md`).
- Vault key: dev fallback derives from JWT_SECRET — set `VAULT_KEY` for real deployments.
- Alert categories for social carry metadata only; snippets live exclusively in the
  AES-GCM vault (per-phase decision overriding the addendum's example metadata).

## Verification commands

```
pnpm --filter @familyshield/api test           # 178
cd apps/agent-desktop && dotnet test tests/OSRA.Agent.Tests   # 161
cd apps/child-android && ./gradlew :app:testDebugUnitTest             # 146
cd apps/parent-app && flutter test                                      # 89
python -m pytest services/ai-engine/tests                               # 18+skip
node services/api/scripts/e2e.mjs            # 44 live checks (needs backend+redis)
```
