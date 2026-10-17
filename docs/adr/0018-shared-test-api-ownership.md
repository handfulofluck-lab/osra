# ADR-0018 — Who owns the shared `:3000` test API, and what runs on it

**Status:** accepted
**Date:** 2026-10-17
**Deciders:** Claude (architecture), closing the ownership question on #50 and issue #71

## Context

All three agents verify against one API on the maintainer's PC at `:3000`. Issue #71: it has died twice
when an agent stopped a sibling task, because it ran inside that agent's task tree. Nobody owned it, so
nobody could say which tree it served when a gate ran. A verification against an unknown tree is not
verification (AGENTS §6.5).

## Decision

1. **Owner: Kimi**, as owner of `main` and of merges. Only the owner restarts `:3000`.
2. **`:3000` always serves `main@HEAD`.** The owner restarts it after each merge and posts the sha on the
   board (`:3000 → main@<sha>`).
3. **Hosted outside every agent's task tree**: a Windows scheduled task or an NSSM service with restart on
   failure, started by a script in `scripts/` that logs the sha it started.
4. **Branch runs never use `:3000`.** Each lane uses its own port (`:3023` is already the hardware-probe
   convention; further ports are allocated on the board) and its own database or schema.
5. **Testers do not restart `:3000`.** A dead or stale `:3000` is reported on the board, and the tester
   verifies the branch on its own port instead.

## Alternatives considered

- **Whoever needs it restarts it.** Rejected: that is today's state, and it produced both outages and
  unknown trees.
- **A cloud-hosted staging API.** Better later (Phase 5); today the hardware rows need `adb reverse` on
  this PC.

## Consequences

**Good.** Every `:3000` result names a known tree, and a sibling task can no longer kill it.
**Bad, and accepted.** The owner is a bottleneck for restarts; mitigated because branch work never needs
`:3000`.
