/**
 * Push delivery contracts (Phase 2a). Providers are deliberately transport-only: they take a
 * ready payload and a token and report one of three outcomes. Everything about *who* gets *what*
 * (token lookup, severity policy, pruning) lives in `notify.ts`, so it can be unit-tested with a
 * fake provider and so FCM/APNs can be swapped without touching alert code.
 */

export type PushPlatform = "android" | "ios" | "web";

export interface PushMessage {
  title: string;
  body: string;
  /** Flat string map; FCM data payloads and APNs custom keys are both string-valued. */
  data: Record<string, string>;
  /** Collapse/thread key so repeated alerts for one child replace each other on the lock screen. */
  threadId?: string;
  /** "high" wakes the device; "normal" is batched by the OS. Critical alerts are always high. */
  priority: "high" | "normal";
}

export type PushResult =
  | { ok: true }
  /** The token is dead (unregistered / 410): the caller must delete it. */
  | { ok: false; invalidToken: true; reason: string }
  /** Transient or configuration failure; token stays. */
  | { ok: false; invalidToken: false; reason: string };

export interface PushProvider {
  readonly platform: PushPlatform;
  send(token: string, message: PushMessage): Promise<PushResult>;
}

/** Minimal fetch shape so providers can be tested without the network. */
export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;
