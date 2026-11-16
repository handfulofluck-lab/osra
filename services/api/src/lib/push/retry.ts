/**
 * #842: bounded retry for a push send whose failure was the connection, not the request.
 *
 * APNs loses an HTTP/2 session when the connection drops (#843 retried that once); FCM's fetch rejects
 * with `TypeError: fetch failed` and the real errno on `cause.code`. Both get the same helper here, so
 * "which errors are retryable" is one answer instead of two. Everything else — a 4xx, a dead token, a
 * payload error — is returned at once: retrying it only spends the caller's time.
 */

const RETRYABLE_CODES = new Set([
  "ECONNRESET",
  "EPIPE",
  "ETIMEDOUT",
  "ECONNREFUSED",
  "EHOSTUNREACH",
  "ENETUNREACH",
  "EAI_AGAIN",
]);

/** The two spellings seen in the wild: Node's errno on `code`, and APNs/HTTP/2 wording in the message. */
const RETRYABLE_PATTERNS = ["ECONNRESET", "EPIPE", "ETIMEDOUT", "GOAWAY", "NGHTTP2", "closed session", "Connection reset", "fetch failed", "socket hang up"];

export const PUSH_ATTEMPTS = 3;
export const PUSH_BASE_MS = 200;
export const PUSH_CAP_MS = 2_000;

export function isRetryableConnectionError(err: unknown): boolean {
  if (!err) return false;
  const cause = (err as { cause?: NodeJS.ErrnoException }).cause;
  for (const code of [(err as NodeJS.ErrnoException).code, cause?.code]) {
    if (code && RETRYABLE_CODES.has(String(code))) return true;
  }
  const message = [(err as Error).message, cause?.message].filter(Boolean).join(" | ");
  return RETRYABLE_PATTERNS.some((pattern) => message.includes(pattern));
}

/** 200, 400, 800 … capped at [capMs]; attempt is 1-based. */
export function backoffDelay(attempt: number, baseMs = PUSH_BASE_MS, capMs = PUSH_CAP_MS): number {
  return Math.min(capMs, baseMs * 2 ** Math.max(0, attempt - 1));
}

export interface BackoffOptions {
  attempts?: number;
  baseMs?: number;
  capMs?: number;
  /** Injected so a test never waits; production uses a real timer. */
  sleep?: (ms: number) => Promise<void>;
}

/**
 * Runs `fn` up to `attempts` times. Between attempts it sleeps an exponential delay, and only when the
 * failure is connection-level; the last error is rethrown so the caller reports the same reason it did
 * before this helper existed. A send that may already have arrived can therefore be delivered twice —
 * at-least-once, which is what the alert path already assumes.
 */
export async function withBackoff<T>(fn: () => Promise<T>, opts: BackoffOptions = {}): Promise<T> {
  const attempts = Math.max(1, opts.attempts ?? PUSH_ATTEMPTS);
  const baseMs = opts.baseMs ?? PUSH_BASE_MS;
  const capMs = opts.capMs ?? PUSH_CAP_MS;
  const sleep = opts.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  let lastError: unknown;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      return await fn();
    } catch (err) {
      lastError = err;
      if (attempt === attempts || !isRetryableConnectionError(err)) throw err;
      await sleep(backoffDelay(attempt, baseMs, capMs));
    }
  }
  throw lastError;
}
