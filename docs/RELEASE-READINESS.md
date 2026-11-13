# Seven clients to release: audit and re-plan (2026-11-13)

Asked for by the maintainer on 2026-11-13: all seven clients ready, security-tested, free of known
bugs, with full engineering documentation on GitHub once the repository is private. This file is the
honest state of each client on `main@a2b2232c` and the plan that follows from it. Dates are
**estimates, not promises**. The row-by-row status stays in [`ROADMAP.md`](ROADMAP.md).

## The answer first

**Yes, the full ask moves dates.** What holds and what slips:

| Wave | Clients | Was | Now (estimate) | Change |
|---|---|---|---|---|
| Closed beta A | Android child (Play), Android parent, iPhone parent and OSRA Kids iPhone (external TestFlight), server | mid to late Dec 2026 | **15 to 22 Dec 2026** | holds, if the five gates below are signed by 12 Dec |
| Closed beta B | Windows; Android child Full (website) | Windows with Android in Dec (ROADMAP 5.4), 8 Jan 2027 (gate #635) | **Full: 12 Jan 2027. Windows: 22 Jan 2027** | **Windows slips about 5 weeks** against the Dec plan, 2 weeks against #635 |
| Public 1 | Android child (Play + Full), Android parent, iPhone parent, OSRA Kids iPhone | 1 Feb 2027 | **1 Feb 2027** | holds, with no slack for a second store rejection |
| Public 1b | Windows | 1 Feb 2027 | **late Feb 2027** | slips about 4 weeks |
| Public 2 | Mac | March 2027 | **late March 2027 at best, April 2027 likely** | at risk; holds only if Mac building moves off Ahmed (see "Who does what") |
| Engineering docs on GitHub | all | not planned | drafts by 4 Dec, owner-checked by 11 Dec, **merged at the private switch (closed beta A)** | does not move a client date: Claude writes them alongside verification |

Why Windows and Mac slip: no Windows build step (W1 to W4, #623 to #626) has started, the code-signing
certificate is still in SSL.com validation, and there is no Windows test machine (the agent rewrites DNS and
the firewall, so it cannot be tested on the maintainer's PC). The Mac has its design and two spike rows,
but build step (i) (#653) has not started, and its builder (Ahmed) is also the only person who can sign
all eight security gates.

## What "ready" means (the release bar, per client)

"Bug-free" cannot be proven, so the bar is measured instead:

1. **Security:** the client's gate issue has all its boxes ticked and Ahmed's `Security-signoff:` line for
   the exact build. Every gate is at **0 of 10 boxes today** (0 of 11 for Windows).
2. **Bugs:** no open `sev:high` or `sev:medium` issue for that client. A `sev:low` ships only if the
   maintainer accepts it in writing on the gate issue.
3. **Measured on hardware:** that client's rows of the scenario suite (S0 to S5, #665) recorded as PASS. Every
   row is ⬜ today.
4. **Docs:** that client's engineering document reviewed by its code owner and verified by Claude.
5. **Words and look:** Arabic signed by the Arabic Bureau (#604), visible UI signed by the UI/UX Bureau (#650).

## Audit: where each client stands

| # | Client | Gate | Open blockers (issues) | Biggest risk |
|---|---|---|---|---|
| 0 | Server API (every client depends on it) | #637, 0/10 | one open private security item; production stack in Frankfurt not built (5.8); HTTPS staging cert to enforce | **the production stack**: closed beta A needs it, or the beta runs on staging |
| 1 | Android child, Play | #630, 0/10 | one High and three Medium/Low private security items; #671, #673 (sev:medium); #672 SOS without location; Play review items #442, #538, #562, #638, #682 | the High private item |
| 2 | Android child, Full (website) | #631, 0/10 | #615 self-updater (waits on the m1/m2 public keys + Ahmed); 5.10 PRs A to E (#586) not started; #589 page in draft | **download hosting**: AWS refused CloudFront verification and GitHub Pages is not fit for installers; Cloudflare or a CloudFront retry is needed |
| 3 | Parent app, Android | #632, 0/10 | two private items; #545, #539, #642, #676 (sev:medium), #603; plan screen #620/#622; "Add a computer" #627/#657 | the family plan (B1 to B4) is new work |
| 4 | Parent app, iPhone | #633, 0/10, no security review yet | #598 map crash, #599, #643 (all sev:high); #558 push entitlement (APNs key, #695); #600 "Ask parent" (ADR-0040); StoreKit #621 | three sev:high bugs on one screen family |
| 5 | OSRA Kids, iPhone | #634, 0/10, hardware run under way | #677, #691, #696, #661/#689, #602, #680, #681; D2/D4 fixes merged, re-run owed on the next Kids build | App Store Kids review time |
| 6 | Windows | #635, 0/11 | W1 to W4 (#623 to #626) not started; #627/#657; SSL.com validation; HTTPS interception root box | **no test machine**, no certificate yet |
| 7 | Mac | #636, 0/10 | #653 step (i) not started; spike rows (c)(d) open; Developer ID waits on the Apple team-name fix | builder capacity (Ahmed) |

Engineering documentation today: 41 ADRs, `SPEC*.md`, `RELEASING.md`, `TESTING.md` and a Terraform README.
**Missing:** a system architecture overview; backend, database and security architecture documents; and an
engineering README for every client except the old Mac scaffold (`apps/agent-macos`).

## Dates that hold the plan (critical path)

| By | What | Owner |
|---|---|---|
| 22 Nov | Server gate #637 signed on the staging image; production stack plan for Frankfurt reviewed | Ahmed; Claude |
| 29 Nov | All sev:high bugs on clients 1, 3, 4, 5 merged; the High private item fixed | Kimi, Ahmed |
| 29 Nov | Windows W1 merged; W2 in review; Windows test machine running | K31; maintainer decision |
| 4 Dec | Engineering doc drafts complete (in the project folder, not on GitHub) | Claude |
| 6 Dec | Production stack applied in `eu-central-1` (ADR-0028/0030) | Claude, maintainer approval |
| 12 Dec | Gates #637, #630, #632, #634, #633 signed; Claude's QA pass on the same builds; S1 to S3 and the iPhone S5 rows PASS | Ahmed, Claude |
| 15 to 22 Dec | **Closed beta A**: Play closed test (12 testers, 14 days) + external TestFlight; repository goes private; docs PR merged | maintainer (Play/TestFlight), Kimi (merge) |
| 12 Jan | Full Android gate #631 signed, `/android/` page live with download hosting fixed | Kimi, Ahmed |
| 22 Jan | Windows gate #635 signed; signed MSI on `/windows/` for closed beta B | K31, Ahmed, maintainer (signing) |
| 1 Feb | **Public 1** | all |
| late Feb | Windows public | all |
| late Mar to Apr | Mac gate #636, notarised build on `/mac/` | K31 (code), Claude (Mac test bed), Ahmed |

The Play 14-day closed test that starts by 22 Dec ends by 5 Jan, which leaves room for Google's production
review before 1 Feb.

## Who does what

The aim is that Ahmed spends his time on the gates, because nothing reaches an outside tester without his
signature and he is the only person who can give it.

- **Ahmed (security + iOS):** the gates, in order #637 → #630 → #632 → #634 → #633, then #631, #635, #636; the
  High private item; iPhone fixes #677, #691, #696; history gitleaks scan and key rotation before the
  private switch (#609); a security-accuracy read of the security architecture document. **Mac code moves
  to K31 (Claude runs it on the Mac test bed); Ahmed reviews each Mac PR for security instead of writing it.**
- **Kimi (lead developer, the only merger):** the Android, parent app and API bugs (#671, #673, #676, #681,
  #680, #643, #598, #599, #545, #539, #538, #562), family plan B2 to B4 (#620 to #622), "Add a computer"
  (#627/#657), the Full build (5.10 PRs A to E, #586, #615), CI trim for the private repo, and every merge.
- **K31 (code + tests, never merges):** Windows W1 to W4 (#623 to #626) first; family plan B1 (#619, #700);
  then the Mac build steps (i) to (vi), starting with #653; #638, #642, #608, #614, #667.
- **Claude (architecture, QA, coordination):** verification of every PR and the after-merge check; the QA box
  on every gate; the scenario suite runs on the Flip4, iPhone and Mac; the production stack plan and apply;
  building, running and notarising K31's Mac steps on the Mac test bed (Claude writes no product code,
  AGENTS.md); all engineering documentation (below); this plan and the roadmap.
- **Maintainer (decisions and accounts only):** SSL.com validation call; a Windows test machine; the Apple
  team-name fix; prices (M3); 12 Play testers; GitHub Pro just before the private switch; download hosting
  for installers.

## Engineering documentation plan

Written by Claude, checked for accuracy by each area's code owner, verified by Claude, and **merged only
after the repository is private** (closed beta A). Drafts live in the project folder until then, never on a
public branch. Security detail (attack paths, findings, keys) goes to the private `osra-security` repository
now; the public-safe security model goes in `docs/architecture/SECURITY.md`.

| Document | Covers | Accuracy reviewer |
|---|---|---|
| `docs/architecture/OVERVIEW.md` | system context, components, data flows, trust boundaries, deployment | Kimi |
| `docs/architecture/BACKEND.md` | `services/api`, `realtime`, `ai-engine`; auth, command queue, push, AI scoring | Kimi |
| `docs/architecture/DATABASE.md` | Prisma schema, migrations, retention and erasure, family plan tables | Kimi |
| `docs/architecture/SECURITY.md` | device auth, sessions, consent, encryption, gates; detail stays in `osra-security` | Ahmed |
| `docs/architecture/INFRA.md` | Terraform, regions, CI/CD, releasing and signing | Claude, then Ahmed |
| `docs/clients/ANDROID-CHILD.md` | Play and Full flavours, blocking, DNS, tamper tiers, updater | Kimi |
| `docs/clients/PARENT-APP.md` | Flutter parent app, Android and iPhone, push, billing | Kimi |
| `docs/clients/IOS-KIDS.md` | OSRA Kids, extensions, App Group, shields, PIN | Ahmed |
| `docs/clients/WINDOWS.md` | service + tray, DNS filter, firewall, MSI, self-update | K31 |
| `docs/clients/MACOS.md` | Swift agent, content filter, daemon, overlay blocking | K31 |
| `docs/ROADMAP.md` + this file | full roadmap and release plan | maintainer |
