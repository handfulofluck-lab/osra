// Tokens and signatures for synthetic families, minted inside k6 (no credentials file).
// Same claims as the API: device tokens as routes/devices.ts pair/claim signs them, parent tokens as
// lib/sessions.ts signParentToken does (sv 0 = nothing revoked). Device secrets are derived exactly like
// services/api/scripts/loadtest-seed.ts ltDeviceSecret.
import crypto from "k6/crypto";
import encoding from "k6/encoding";

const SECRET = __ENV.JWT_SECRET;
if (!SECRET) throw new Error("JWT_SECRET is required (the load-test stack's own secret, never staging's or production's)");

const b64 = (s) => encoding.b64encode(s, "rawurl");
const HEAD = b64(JSON.stringify({ alg: "HS256", typ: "JWT" }));

function jwt(claims, ttl = 6 * 3600) {
  const now = Math.floor(Date.now() / 1000);
  const body = b64(JSON.stringify(Object.assign({}, claims, { iat: now, exp: now + ttl })));
  return `${HEAD}.${body}.${crypto.hmac("sha256", SECRET, `${HEAD}.${body}`, "base64rawurl")}`;
}

const deviceTokens = {};
export function deviceToken(d) {
  if (!deviceTokens[d.deviceId]) deviceTokens[d.deviceId] = jwt({ sub: d.deviceId, deviceId: d.deviceId, childId: d.childId, familyId: d.familyId, role: "device" });
  return deviceTokens[d.deviceId];
}

const parentTokens = {};
export function parentToken(p) {
  if (!parentTokens[p.parentId]) {
    const jti = crypto.hmac("sha256", SECRET, `jti:${p.parentId}:${__VU}`, "hex").slice(0, 32);
    parentTokens[p.parentId] = jwt({ sub: p.parentId, familyId: p.familyId, role: "parent", familyRole: p.familyRole, jti, sv: 0 });
  }
  return parentTokens[p.parentId];
}

export function deviceSignature(deviceId, raw) {
  const secret = crypto.hmac("sha256", SECRET, `lt-device:${deviceId}`, "hex");
  const ts = String(Math.floor(Date.now() / 1000));
  const nonce = crypto.hmac("sha256", secret, `${ts}:${Math.random()}:${__VU}:${__ITER}`, "hex").slice(0, 32);
  return {
    "x-familyshield-signature": crypto.hmac("sha256", secret, `${ts}.${nonce}.${raw}`, "hex"),
    "x-familyshield-timestamp": ts,
    "x-familyshield-nonce": nonce,
  };
}
