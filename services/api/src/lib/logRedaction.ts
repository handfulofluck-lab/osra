/**
 * What the request log may say about a request (#442 PR 3).
 *
 * Fastify's default request serializer logs `req.url` with its query string, and some links carry their
 * credential there: the account-deletion and digest-confirm links (`?token=`), the realtime ticket
 * (`?ticket=`), and a client that wrongly puts a JWT on the socket URL (`/v1/ws?token=`, refused by the
 * gateway but still logged before it refuses). The value is replaced, the parameter name is kept, so a
 * log line still says which kind of request it was.
 */
const SECRET_QUERY_PARAMS = /([?&](?:token|ticket)=)[^&#]*/gi;

export function redactUrl(url: string): string {
  return url.replace(SECRET_QUERY_PARAMS, "$1[redacted]");
}

type LoggedRequest = {
  method: string;
  url: string;
  hostname?: string;
  ip?: string;
  socket?: { remotePort?: number };
};

/** Fastify `logger.serializers`: the default request fields, with the URL redacted. */
export const LOGGER_SERIALIZERS = {
  req(req: LoggedRequest) {
    return {
      method: req.method,
      url: redactUrl(req.url),
      hostname: req.hostname,
      remoteAddress: req.ip,
      remotePort: req.socket?.remotePort,
    };
  },
};

/**
 * #1108 (Ahmed's R3, condition 1): Pino `redact` paths. No route logs a request body today, but the
 * parent-PIN route carries a PIN, a password and an authenticator code, and its command carries a PIN hash;
 * if any of them is ever attached to a log object — a body, an error's context, a command row — the value is
 * replaced before the line is written.
 */
export const LOGGER_REDACT = {
  paths: [
    "req.body.pin",
    "req.body.password",
    "req.body.mfaCode",
    "body.pin",
    "body.password",
    "body.mfaCode",
    "pin",
    "password",
    "mfaCode",
    "pinHash",
    "payload.pinHash",
    "*.pinHash",
    "*.payload.pinHash",
    // An error object whose context carries the request body (seen in the zero-log test: `err.body`).
    "*.pin",
    "*.password",
    "*.mfaCode",
    "*.body.pin",
    "*.body.password",
    "*.body.mfaCode",
  ],
  censor: "[redacted]",
};
