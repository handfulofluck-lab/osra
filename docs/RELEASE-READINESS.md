# Seven clients to release: audit and re-plan (2026-11-13)

Asked for by the maintainer on 2026-11-13: all seven clients ready, security-tested, free of known
bugs, with full engineering documentation on GitHub once the repository is private. This file is the
honest state of each client on `main@a2b2232c` and the plan that follows from it. Dates are
**estimates, not promises**. The row-by-row status stays in [`ROADMAP.md`](ROADMAP.md).

## The answer first

**Re-planned twice on 2026-11-13.** The morning audit moved Windows and Mac later. In the afternoon the
maintainer asked for the fastest plan the team's measured pace allows, and adopted it with four working
changes (S1 to S4, below). Dates are now given as **P50** (as likely early as late) and **P85** (beaten 85
times in 100). The morning dates are kept for comparison.

| Wave | Clients | Morning plan | **Now P50** | P85 |
|---|---|---|---|---|
| Closed beta A | Android child (Play), Android parent, server | 15 to 22 Dec 2026 | **2 Dec 2026** | 9 Dec |
| Closed beta A (iPhone) | iPhone parent and OSRA Kids iPhone (external TestFlight) | 15 to 22 Dec 2026 | **7 Dec 2026** | 14 Dec |
| Closed beta B | Android child Full (website) | 12 Jan 2027 | **21 Dec 2026** | 8 Jan 2027 |
| Closed beta B | Windows | 22 Jan 2027 | **5 Jan 2027** | 15 Jan |
| Public 1 | Android child (Play + Full), Android parent, iPhone parent, OSRA Kids iPhone | 1 Feb 2027 | **12 Jan 2027** | 19 Jan |
| Public 1b | Windows | late Feb 2027 | **1 Feb 2027** | 15 Feb |
| Public 2 | Mac | late Mar to Apr 2027 | **mid Feb 2027** | early Mar |
| Engineering docs on GitHub | all | merged at the private switch | merged at the private switch (beta A) | no client date moves |

No security gate is shortened: every client still needs its gate fully ticked and the `Security-signoff:`
line for the exact build before anyone outside the team gets it.

### How the dates were measured

From every PR (478) and issue (236) in this repository, 11 Oct to 13 Nov 2026:

- In a normal week the team merges 100 to 155 PRs and closes about 45 issues. The median PR merges 1 to 2
  hours after it opens.
- The slow part is waiting, not writing: one week in five had almost no merges (2 to 8 Nov, one merge in
  nine days, because merging and signing had a single owner), and 52% of all hours fell inside gaps of
  more than 10 hours with no merge.
- Yardstick for the computer clients: the OSRA Kids iPhone app went from its first PR to TestFlight in
  about 20 days (80 PRs) with one builder.
- P85 allows one more lost week before Public 1. Store billing (family plan B2/B3) has no earlier
  comparable and carries the widest range.

### Working changes adopted with the plan (2026-11-13)

- **S1. This plan and its gate calendar** (below) replace the morning dates.
- **S2. A second K31 session builds the Mac** (step (i) #653 onward) in parallel with K31's Windows work, instead of after it.
- **S3. Backup merging.** When a PR has a valid `Verified-sha:` signature at its head, verified-gate is
  green and the lead developer has been silent for 4 hours, the coordinator turns on GitHub auto-merge for
  it. The gate itself is unchanged. Ahmed (or K31 for docs and CI) may also sign the coordinator's PRs.
- **S4. The lead developer's session runs through the night**, so merges no longer stop for about 13 hours.

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

| By (P50) | What | Owner |
|---|---|---|
| 18 Nov | Production Terraform plan PR for `eu-central-1` up for review | Claude |
| 20 Nov | Server gate #637 signed on the staging image; download hosting for installers chosen; code-signing validation done | Ahmed; maintainer |
| 24 Nov | All sev:high bugs on clients 1, 3, 4, 5 merged; the High private item fixed | Kimi, Ahmed |
| 26 Nov | Gate #630 (Android child Play) signed | Ahmed |
| 27 Nov | Production stack applied (maintainer's go after the #637 read); the 12 Play testers named | Claude; maintainer |
| 1 Dec | Gate #632 (Android parent) signed; repository private (#609) | Ahmed; maintainer |
| **2 Dec** | **Closed beta A starts on Play** (closed test, 12 testers, 14 days to 16 Dec) | maintainer, Kimi |
| 3 Dec / 4 Dec | Gates #634 (OSRA Kids iPhone) and #633 (iPhone parent) signed | Ahmed |
| 7 Dec | External TestFlight for both iPhone apps | maintainer, Claude |
| 7 Dec | Windows W4 merged (K31); Mac step (i) to (iii) merged (second K31 session) | K31 |
| 11 Dec | Family plan B1 to B4 merged | K31, Kimi |
| 18 Dec | iPhone production submissions in (ahead of Apple's holiday slowdown); Play production access requested | maintainer, Claude |
| 18 Dec | Gate #631 (Full) signed | Ahmed |
| **21 Dec** | Android child Full on `/android/` | Kimi |
| 4 Jan | Gate #635 (Windows) signed | Ahmed |
| **5 Jan** | Windows closed beta B | K31, maintainer (signing) |
| **12 Jan** | **Public 1** | all |
| late Jan | Gate #636 (Mac) signed, notarised build | Ahmed, Claude |
| **1 Feb** | Windows public | all |
| **mid Feb** | Mac public | all |

Gate calendar: Claude pre-fills each gate with its evidence (CI runs, scans, QA box, scenario rows) before
Ahmed opens it, so a gate is a review of evidence, one every two working days.

## Who does what

The aim is that Ahmed spends his time on the gates, because nothing reaches an outside tester without his
signature and he is the only person who can give it.

- **Ahmed (security + iOS):** the gates, in order #637 → #630 → #632 → #634 → #633, then #631, #635, #636; the
  High private item; iPhone fixes #677, #691, #696; history gitleaks scan and key rotation before the
  private switch (#609); a security-accuracy read of the security architecture document. **Mac code moves
  to a second K31 session (S2; Claude runs it on the Mac test bed); Ahmed reviews each Mac PR for security
  instead of writing it. iPhone fixes #677, #691, #696 and #661 move to K31 or Kimi, with Ahmed's review.**
- **Kimi (lead developer, the only merger):** the Android, parent app and API bugs (#671, #673, #676, #681,
  #680, #643, #598, #599, #545, #539, #538, #562), family plan B2 to B4 (#620 to #622), "Add a computer"
  (#627/#657), the Full build (5.10 PRs A to E, #586, #615), CI trim for the private repo, and every merge.
- **K31 (code + tests, never merges):** Windows W1 to W4 (#623 to #626) first; family plan B1 (#619, #700);
  the Mac build steps (i) to (vi), starting with #653, go to the second K31 session (S2); #638, #642, #608, #614, #667.
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
