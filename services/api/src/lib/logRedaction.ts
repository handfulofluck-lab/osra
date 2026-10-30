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
