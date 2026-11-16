### Server — retry APNs sends once on connection-level errors (#843)

- `services/api/src/lib/push/apns.ts`: if an APNs send fails with a connection-level error (`ECONNRESET`, `EPIPE`, `ETIMEDOUT`, `GOAWAY`, `NGHTTP2`, `closed session`, `Connection reset`), retry it once with a fresh connection.
- `services/api/test/push.test.ts`: add tests for the retry path and for not retrying unrelated errors.
