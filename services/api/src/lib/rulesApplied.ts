/**
 * #865: the family's "the phone has the rules" number, and whether it has reached what the server issued.
 *
 * Two indicators told a parent opposite things: the rules banner reads `appliedRulesVersion` reduced
 * across the child's devices, while the delivery status reads command acknowledgements. This module
 * owns the reduction the banner reads (`family.ts` uses the same shape for `appliedRulesVersion`) and
 * the threshold the realtime push fires on, so the push cannot describe a different number than the
 * banner.
 */

/**
 * The lowest version any device reported, or null when none has ever reported.
 *
 * Only *reported* versions count. A device that has never reported is not a device known to be
 * behind — the same rule `family.ts` applies when it answers the child's `appliedRulesVersion`, and
 * the reason a fresh install does not leave the banner up forever.
 */
export function familyAppliedVersion(versions: Array<number | null | undefined>): number | null {
  const reported = versions.filter((version): version is number => typeof version === "number");
  if (reported.length === 0) return null;
  return Math.min(...reported);
}

/**
 * Whether the family has caught up with the issued ruleset.
 *
 * `issued` 0 means no ruleset has ever been written for the child; there is nothing to catch up to and
 * nothing to announce. `applied > issued` cannot come through the route (it drops a version above the
 * issued one), and is treated as caught up: a number the server did not issue is a bug, not a lag.
 */
export function rulesAppliedReached(applied: number | null, issued: number): boolean {
  if (applied === null || issued <= 0) return false;
  return applied >= issued;
}
