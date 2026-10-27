/**
 * Push delivery contracts (Phase 2a). Providers are deliberately transport-only: they take a
 * ready payload and a token and report one of three outcomes. Everything about *who* gets *what*
 * (token lookup, severity policy, pruning) lives in `notify.ts`, so it can be unit-tested with a
 * fake provider and so FCM/APNs can be swapped without touching alert code.
 */

export type PushPlatform = "android" | "ios" | "web";

export interface PushMessage {
  /** Omitted only for a data-only message (the device wake): there is nothing to show, only to act on. */
  title?: string;
  body?: string;
  /** Flat string map; FCM data payloads and APNs custom keys are both string-valued. */
  data: Record<string, string>;
  /** Collapse/thread key so repeated alerts for one child replace each other on the lock screen. */
  threadId?: string;
  /** "high" wakes the device; "normal" is batched by the OS. Critical alerts are always high. */
  priority: "high" | "normal";
  /**
   * True → the payload carries no `notification` block, so no operating system displays anything and
   * the app's own service handles it. This is what a *wake* is (#319): the child device must not be
   * able to learn a command from a push, and the parent's lock screen must not show one.
   */
  dataOnly?: boolean;
  /**
   * iOS parent alerts (#410): the visible text is built from these localization keys, never from a literal
   * string, so the child's name and the alert text never travel to Apple. The keys live in the parent app's
   * `Runner/{en,ar}.lproj/Localizable.strings`.
   */
  locKeys?: { titleKey: string; bodyKey: string };
  /** FCM `collapse_key` for Android; one wake reads every unseen alert, so repeated wakes are redundant. */
  collapseKey?: string;
}

export type PushResult =
  | { ok: true }
  /** The token is dead (unregistered / 410): the caller must delete it. */
  | { ok: false; invalidToken: true; reason: string }
  /** Transient or configuration failure; token stays. */
  | { ok: false; invalidToken: false; reason: string };

export interface PushProvider {
  readonly platform: PushPlatform;
  /** APNs only: whether it can send the child device wake (`APNS_DEVICE_BUNDLE_ID` is set, 5.5 PR D). */
  readonly canWakeDevices?: boolean;
  send(token: string, message: PushMessage): Promise<PushResult>;
}

/** Minimal fetch shape so providers can be tested without the network. */
export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;
