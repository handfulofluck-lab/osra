# ADR-0019 — Which device commands are "safe-direction" (allowed without active consent)

**Status:** accepted
**Date:** 2026-10-17
**Deciders:** Claude (architecture), on the open item raised by Kimi on #50
**Relates to:** ADR-0002 (consent gate), ADR-0008 §2c; adds a rule, supersedes nothing

## Context

`services/api/src/routes/devices.ts` (`SAFE_DIRECTION_COMMANDS`) lets four commands through on `main`, and five on
`feat/android-dns-sinkhole` (#78): `unlock`, `resume`, `resume_internet`, `sos_clear`, plus `stop_ring`, which arrives with plan 1.7 without a recorded
reason. The consent gate (428) exists so a parent cannot keep monitoring or restricting a child after
consent ends; it must not trap a device in a restricted state.

## Decision

1. **The rule:** a command is safe-direction if and only if it can never start, extend or escalate
   monitoring or a restriction, and only returns the device toward its unrestricted state.
2. **`stop_ring` qualifies** and stays in the set: it silences an alarm at maximum volume. Refusing it
   after revocation would leave the phone ringing with no remote way to stop it.
3. **Every new command is classified in its own PR** against rule 1, and the probe gets a check: after
   revoke, each safe-direction command returns 2xx and every other command returns 428.

## Consequences

**Good.** The set has a test you can apply, not a list you have to remember.
**Bad, and accepted.** A parent can still send these five commands after revocation; each one only
reduces enforcement.
