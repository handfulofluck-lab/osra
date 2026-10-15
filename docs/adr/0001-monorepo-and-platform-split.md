# ADR-0001 — One monorepo, native agents per platform, Flutter for the parent app

- **Status:** accepted
- **Date:** 2026-09-14
- **Supersedes:** —

## Context

A parental-control product has to be *native where enforcement happens* and *portable where the parent
lives*. Enforcement means intercepting app launches, network requests and screen time on the child's
device — every platform exposes that differently:

- Android: an accessibility service, foreground services, `UsageStats`, `DeviceAdmin`/device-owner for
  the strong paths.
- iOS: the Screen Time / `FamilyControls` + `ManagedSettings` + `DeviceActivity` stack, which is
  only available to a native extension with entitlements.
- Windows: a local proxy (WinINET), process monitoring and session APIs.
- macOS: an unfinished scaffold in this release.

The parent, by contrast, needs one dashboard that works on whatever phone they already own, and the
backend must serve all of them with one data model.

Constraints when this was decided: a single small team (plus AI agents), no budget for app-store
review cycles during development, and testers who install APKs directly.

## Decision

One monorepo (`apps/`, `services/`, `packages/`, `docs/`, `infra/`) with:

- **Flutter** for the parent dashboard — one codebase for Android today and iOS/web later, sharing
  Dart models with the API contract.
- **Kotlin** for the Android child agent, **Swift** for the iOS agent, **C#/.NET 8** for Windows and
  macOS: each uses the strongest primitives that platform actually offers.
- **TypeScript (Fastify + Prisma)** for the API, **Python (FastAPI)** for the classification engine —
  the API stays typed against the shared contracts, the AI side stays where the model ecosystem lives.
- **`packages/shared-types`** as the single source of truth for wire contracts, built first in CI.

## Reasoning

- Enforcement quality is a *platform* concern; sharing one cross-platform runtime across agents would
  mean shipping the weakest common denominator (e.g. a WebView cannot block apps).
- The parent app's job is data display and rule editing — the highest-value place to share code, and
  Flutter gives one codebase with native-feeling UI on both phone platforms.
- A monorepo keeps the wire contract and the QA gates next to the code that must satisfy them: a
  change to a rules payload and the agent that parses it land in the same PR and the same CI run.
- Testers install APKs/EXE directly, so the repo also owns the *distribution* (`dist/`) and the tester
  guides — that is why documentation lives beside the code.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| React Native / Capacitor parent app | Weaker background/enforcement story, and the child agents must be native anyway — a second ecosystem for no gain |
| One cross-platform agent (e.g. Flutter + platform channels) | Channels still need the same native code, plus an extra layer; enforcement paths are too platform-specific |
| Separate repositories per app | Contract drift between API and agents was the single biggest defect source in early testing; split repos make the QA gate weaker, not stronger |
| A single language everywhere (e.g. Kotlin Multiplatform) | Would push the dashboard and the AI engine into unfamiliar toolchains for no product benefit |

## Consequences

- **Positive:** one CI run covers every platform's contract tests; the probe suite can exercise the
  server invariants that all agents depend on; a QA finding lands next to the code that violates it.
- **Negative:** the repo needs four toolchains (Node/pnpm, Flutter+JDK+Android SDK, .NET, Python) and
  the local machine pays for it in build times; onboarding is heavier; CI minutes are higher.
- **Neutral:** tests are per-platform, so a green suite means "every platform that ran went green",
  not "everything works" — see ADR-0005 and `docs/TESTING.md`.

## Evidence

- Repo layout and current suites: `README.md`, `docs/TESTING.md`.
- Contract drift incidents that motivated the monorepo: issues #13 (Flutter↔API contract mismatches),
  #17 (`items` vs `invites`), #31 (screen-time semantics).
- Platform-specific enforcement decisions are recorded in each agent's audit under `docs/QA/audits/`.
