# ADR-0006 — Content monitoring: bounded, encrypted snippets and concern alerts — not chat archives

- **Status:** accepted
- **Date:** 2026-10-12
- **Supersedes:** —

## Context

"Know what your child is exposed to" is the feature that makes a parental-control product worth paying
for, and the feature most likely to destroy trust if it is done carelessly. The tempting design is to
upload everything the child types and store it — full WhatsApp threads, entire search histories. That
design:

- is disproportionate (the child's conversations become a searchable archive on someone's server);
- is a liability (one breach exposes every family's private conversations);
- is legally exposed under GDPR-K data-minimisation, and hard to defend to a child;
- and is not what the parent actually needs — they need to know *when something is wrong*, and then to
  have enough context to talk about it.

Competitors differentiate on exactly this: Qustodio's social monitoring reports alerts with snippets
rather than a chat dump.

## Decision

- **Interception is event-based and bounded.** The Android agent extracts at most a bounded excerpt from
  a monitored app's visible conversation surface (10 monitored apps: WhatsApp, Instagram, TikTok,
  Snapchat, Discord, Roblox, YouTube, YouTube Kids, Telegram, Reddit, Messenger), not the conversation.
- **Detection happens against concern categories** (self-harm, bullying, grooming, predatory contact,
  violence, and the general AI-concern bucket) and produces an **alert** plus, when flagged, a short
  snippet.
- **Snippets are encrypted at rest** in the snippet vault (`VAULT_KEY`, AES); the parent API decrypts
  only for the owning family, and the raw query text never appears in alert bodies or logs.
- **The parent-facing read path is family-scoped and explicit**: `GET /v1/content/searches?childId=…`
  returns `{ items: [...] }` with the decrypted snippet for that child only.
- **Search/YouTube interception is pre-navigation**: the Windows filter extracts `?q=` /
  `?search_query=` and injects `YouTube-Restrict: Strict` + `X-SafeSearch: true` for YouTube hosts,
  because query-parameter rewriting is trivially bypassed by modern single-page clients.
- **Alerts are throttled per child and engine**, so a distressing but repetitive pattern does not flood
  the parent — the first one carries the signal.

## Reasoning

- Data minimisation is the only defensible default: the product's promise is "you will know if something
  is wrong", not "we keep everything".
- Bounded excerpts plus encryption make the *worst case* of a breach far smaller, and give the parent a
  concrete hook for a conversation (the coach cards exist for the same reason).
- Event-based interception keeps the on-device cost proportional to risk rather than to usage: no
  continuous screen capture, no OCR of everything, no unbounded storage — which also keeps the Android
  agent inside battery and Play-policy limits.
- Pre-navigation interception matters because once the child is on the results page, filtering by
  rewriting the request is a race the client can win.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| Archive all monitored messages for the parent to browse | Disproportionate, high breach impact, legally weak, erodes the family relationship — and it is not what the paid feature is for |
| On-device detection only, alerts with no snippet | Safer, but the parent cannot tell a false positive from a real concern, which is the main complaint about competitors |
| Server-side OCR of screenshots | Very expensive, high data volume, and the same proportionality problem |
| Block the app entirely instead of monitoring | Loses the educational value and pushes usage to unmonitored apps |

## Consequences

- **Positive:** the parent read path is small and testable (verified: cross-family read `403`, no snippet
  leakage, decrypted only for the owning family); the vault limits blast radius; throttling keeps alerts
  meaningful.
- **Negative:** the agent must do the bounded extraction on-device (main-thread cost and node recycling
  are real engineering concerns — see the Android audit `AND-09`); "bounded" means the parent sometimes
  lacks context, which is a deliberate trade.
- **Known gaps (tracked):** the local fallback classifier covers only a few phrasings (widened after
  `#30`, still narrower than the AI engine); the AI engine path was not runtime-verified in the QA
  environment; consent revocation would need to stop monitoring immediately once implemented (probe
  target `J3`).

## Evidence

- Specs: `docs/SPEC-CONTENT-SAFETY.md`, `docs/SPEC-AI-CONCERN-ENGINE.md`.
- Server: `services/api/src/routes/content.ts`, `services/api/src/lib/snippetVault.ts`, tests in
  `services/api/test/content.test.ts`.
- Windows: `Services/SafeSearch.cs` (strict headers), `Services/WebFilterProxy.cs` (`ExtractSearchQuery`).
- Android: `social/MonitoredApps.kt`, `social/SocialCapture.kt`.
- Adversarial checks and incidents: `#29` (cross-family write on the new routes), `#30` (fallback
  coverage) — see `CHANGELOG.md`.
