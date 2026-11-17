### API — push sends retry a dropped connection with a capped backoff (#842)
- APNs retried once on a connection-level error (#843); this makes the retry bounded and shared, and
  gives FCM the same treatment.
- One helper (`services/api/src/lib/push/retry.ts`) decides what is retryable: `ECONNRESET`, `EPIPE`,
  `ETIMEDOUT`, `ECONNREFUSED`, `EHOSTUNREACH`, `ENETUNREACH` and `EAI_AGAIN`, read from the error's
  `code` or from the `cause` Node's `fetch` wraps it in, plus the HTTP/2 wording APNs uses. A 4xx, a dead
  token and a payload error are returned at once and never slept on.
- Three attempts, waiting 200 ms then 400 ms, capped at 2 s; the last error is what the caller reports,
  so the wake log reads as before. The wait is injected in tests, which never sleep.
- FCM's OAuth token exchange stays single-attempt: one send never turns into several token calls.
- Delivery is at-least-once — a send that may already have arrived can be repeated, which is the
  assumption the alert path already makes.
- Tests: the delay table, errno and `cause.code` detection, APNs succeeding on the third attempt with
  200/400 ms, FCM retrying without a second token exchange, a non-connection failure returning at once,
  and exhaustion reporting the last error after three attempts.
