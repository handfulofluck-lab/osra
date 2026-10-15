# Documentation index

Start here. This page is the map: what each document is for, and which one to read when.

## Orientation

| If you are… | Read |
|---|---|
| New to the project | [`../README.md`](../README.md) → [`../docs/SPEC.md`](SPEC.md) |
| Setting the test environment up | [`TESTING.md`](TESTING.md) → [`test-guides/INSTALLATION-GUIDE.md`](test-guides/INSTALLATION-GUIDE.md) |
| Running or interpreting tests | [`TESTING.md`](TESTING.md) |
| Touching an agent (human or AI) | [`../AGENTS.md`](../AGENTS.md) — roles, definition of done, PR rules, hygiene |
| Wondering **why** something is built this way | [`adr/`](adr/README.md) — decision records with the rejected alternatives |
| Fixing a known defect | [`QA/ANTIGRAVITY-INBOX.md`](QA/ANTIGRAVITY-INBOX.md) — the prioritised queue |
| Auditing security/quality | [`QA/QA-REPORT-2026-10-11.md`](QA/QA-REPORT-2026-10-11.md) + [`QA/audits/`](QA/audits/) |
| Tracking what changed and when | [`../CHANGELOG.md`](../CHANGELOG.md) |
| Preparing a store release | [`test-guides/PUBLISHING-READINESS.md`](test-guides/PUBLISHING-READINESS.md) |
| Comparing against competitors | [`COMPETITIVE-ANALYSIS.md`](COMPETITIVE-ANALYSIS.md) |

## Specification

| Document | Contents |
|---|---|
| [`SPEC.md`](SPEC.md) | Product and API specification: data model, endpoints, invariants, platform contracts |
| [`SPEC-ADDENDUM-WORLD-CLASS.md`](SPEC-ADDENDUM-WORLD-CLASS.md) | The 29 world-class features and their implementation contracts |
| [`SPEC-CONTENT-SAFETY.md`](SPEC-CONTENT-SAFETY.md) | Track 1 — web/YouTube content filtering and search interception |
| [`SPEC-AI-CONCERN-ENGINE.md`](SPEC-AI-CONCERN-ENGINE.md) | Track 2 — multimodal concern engine, monitored apps, encrypted snippets |
| [`COMPETITIVE-ANALYSIS.md`](COMPETITIVE-ANALYSIS.md) | Feature-by-feature comparison with Qustodio / Google Family Link |

## Engineering practice

| Document | Contents |
|---|---|
| [`TESTING.md`](TESTING.md) | Every suite and gate: how to run it, what it covers, how to read failures, the hardware procedure, environment traps |
| [`adr/`](adr/README.md) | Architecture decision records — context, decision, reasoning, rejected alternatives, costs |
| [`../CHANGELOG.md`](../CHANGELOG.md) | What changed on which day, with the PR/issue that carried it, and the verification state |
| [`../AGENTS.md`](../AGENTS.md) | Binding working agreement for AI agents and humans: roles, DoD, PR/review protocol, device hygiene |
| [`../.github/PULL_REQUEST_TEMPLATE.md`](../.github/PULL_REQUEST_TEMPLATE.md) | The restatement-first PR contract |

## Quality assurance

| Document | Contents |
|---|---|
| [`QA/QA-REPORT-2026-10-11.md`](QA/QA-REPORT-2026-10-11.md) | Consolidated QA state: method, results, limits, priority order |
| [`QA/ANTIGRAVITY-INBOX.md`](QA/ANTIGRAVITY-INBOX.md) | The prioritised work queue with per-item acceptance criteria |
| [`QA/audits/`](QA/audits/) | Raw per-platform audits (`API`, `ANDROID`, `WINDOWS`, `FLUTTER`, `IOS-MACOS`) with `file:line` evidence |
| [`QA/DISCUSSION-LOG.md`](QA/DISCUSSION-LOG.md) | The append-only, full-detail dialogue between the implementing and verifying agents |
| [`test-guides/OSRA-REVIEW-RESPONSE-2026-09-18.md`](test-guides/OSRA-REVIEW-RESPONSE-2026-09-18.md) | Mapping of an external code review to the fixes that answered it |

## Tester-facing guides

| Document | Contents |
|---|---|
| [`test-guides/README-TESTERS.md`](test-guides/README-TESTERS.md) | What the test release contains and what is deliberately unsupported |
| [`test-guides/INSTALLATION-GUIDE.md`](test-guides/INSTALLATION-GUIDE.md) / [`.html`](test-guides/INSTALLATION-GUIDE.html) | Step-by-step setup for testers (host PC → tunnel → parent → child → checklist) |
| [`test-guides/SHIP-NOTES.md`](test-guides/SHIP-NOTES.md) | Per-feature test recipes for a test session |
| [`test-guides/WORLD-CLASS-CHANGELOG.md`](test-guides/WORLD-CLASS-CHANGELOG.md) | Feature-level changelog for the world-class batch |
| [`test-guides/PUBLISHING-READINESS.md`](test-guides/PUBLISHING-READINESS.md) | What is still required before a store release |
| [`test-guides/IOS-CI-TESTING.md`](test-guides/IOS-CI-TESTING.md) | How the headless iOS CI works and how to run it locally on a Mac |
| [`test-guides/CHROMEBOOK-KINDLE-PATH.md`](test-guides/CHROMEBOOK-KINDLE-PATH.md) | Roadmap for the Chromebook/Kindle paths |
| [`../apps/child-ios/QA-IOS.md`](../apps/child-ios/QA-IOS.md) | iOS status, limitations and what still requires a Mac |

## Conventions

- **Dates in filenames** mark point-in-time records (audits, reports, changelogs). They are not
  updated in place; a later state gets a new file, and the old one stays as history.
- **Every claim of the form "fixed" or "verified"** states where it was verified and what was *not*
  verified. An unqualified claim in these docs is a documentation bug — please report it.
- **Open questions are recorded, not hidden**: probe targets in `QA/ANTIGRAVITY-INBOX.md`, gaps in the
  audits, and unresolved decisions in the changelog's "verification state" notes.
