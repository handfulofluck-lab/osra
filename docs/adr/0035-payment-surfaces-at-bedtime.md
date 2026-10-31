# 0035 — OS payment surfaces stay blocked during bedtime

- **Status:** accepted (2026-10-31)
- **Issue:** #172 (policy question raised during the #165 / #171 retest)
- **Deciders:** Claude (architecture), Karim (product); implemented by Kimi

## Context

The retest that produced #171 showed `com.samsung.android.spay` raising content-change events while the
launcher was in front. Fixing the window resolution stopped the overlay following that event, and it
exposed the policy question underneath: with a **bedtime** rule active, an OS payment surface (Samsung
Pay, Google Wallet, OEM banking shells) is blocked like any other app.

That matters in two directions. A child who needs to pay for something during bedtime — a bus home, a
late collection — hits a block screen. And the essential set exists precisely so that protection cannot
make the phone unsafe or unusable: the dialer, the emergency dialer and the launcher are in it for that
reason.

Three options were put to the maintainer:

1. Exempt payment surfaces **during bedtime only** (not during a full `lock`), visible to the parent.
2. **Keep them blocked**, and say so in the parent-facing description of what bedtime blocks.
3. Exempt by **role/capability** — "the app that handles NFC payment" — rather than by package name.

## Decision

**Option 2: payment surfaces stay blocked during bedtime.**

- Nothing is added to `EssentialPackages.EXACT`. `PaymentSurfacePinTest` fails if `spay`,
  `walletnfcrel` or any name that looks like a wallet is added, so the decision cannot be undone by a
  one-line "fix" to a support ticket.
- The parent app's always-allowed section says that bedtime blocks payment apps, and offers the shortcut
  that already exists: add one to **Always allowed** if the family needs it at night.
- A full `lock` is unchanged: it already blocks everything but the essential set, and that is not a
  quiet-hours rule.

## Why not the alternatives

- **Option 1 (exempt during bedtime).** Bedtime is a quiet-hours rule, not a security state, which is the
  argument for exempting — but the exemption would be *on by default for every family*, widening a hole
  in the one rule most parents set on day one, to save a few families one tap. The always-allowed list
  already gives those families that tap, per app, deliberately.
- **Option 3 (role/capability detection).** It is the right shape and it would also cover an OEM shell no
  table has heard of. It is not something a beta should bet a product decision on: the detection is
  per-OEM, per-Android-version and hard to state as a pure rule, and getting it wrong in either direction
  is worse than the gap it fixes. It stays available if a family reports the need.
- **Doing nothing.** The gap is not the blocking — it is that a parent had no way to know bedtime blocked
  payment apps, and no obvious place to fix it for their child. That is what option 2 changes.

## Costs

- A child who needs to pay during bedtime is blocked until a parent adds that app to Always allowed. That
  is deliberate, and the copy says it.
- The list of "payment surfaces" is not exhaustive, and this ADR does not pretend otherwise: it names two,
  and the pin test guards the shape (no wallet-like entry) rather than the names.

## Evidence

- Decision and four build items: #172, Claude's 2026-10-31 message on #50.
- The behaviour cannot be changed by accident: `PaymentSurfacePinTest` (two rows).
- Hardware row for the record: bedtime active, open Samsung Pay, expect the block screen (Claude's
  `hardware: Flip4 rows`, #484).
