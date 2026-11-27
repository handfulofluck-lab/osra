// One pass of every call in the k6 mix against a running API, with Node instead of k6, so the id rule,
// the token claims, the device signatures and the payloads are checked on a laptop before any AWS spend.
//   API=http://localhost:3000 JWT_SECRET=... LOADTEST_FAMILIES=200 node loadtest/smoke/node-smoke.mjs
import { createHmac, randomBytes } from "node:crypto";
import { ltDevices, ltParent } from "../k6/lib/ids.js";
import { deviceCalls, parentReads, parentActions } from "../k6/lib/calls.js";

const API = process.env.API ?? "http://localhost:3000";
const SECRET = process.env.JWT_SECRET;
const FAMILIES = Number(process.env.LOADTEST_FAMILIES ?? 200);
if (!SECRET) throw new Error("JWT_SECRET is required");

const b64u = (b) => Buffer.from(b).toString("base64url");
function jwt(claims) {
  const now = Math.floor(Date.now() / 1000);
  const head = b64u(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const body = b64u(JSON.stringify({ ...claims, iat: now, exp: now + 3600 }));
  return `${head}.${body}.${createHmac("sha256", SECRET).update(`${head}.${body}`).digest("base64url")}`;
}
const deviceToken = (d) => jwt({ sub: d.deviceId, deviceId: d.deviceId, childId: d.childId, familyId: d.familyId, role: "device" });
const parentToken = (p) => jwt({ sub: p.parentId, familyId: p.familyId, role: "parent", familyRole: p.familyRole, jti: randomBytes(16).toString("hex"), sv: 0 });
const deviceSecret = (id) => createHmac("sha256", SECRET).update(`lt-device:${id}`).digest("hex");
function signV2(secret, raw) {
  const ts = String(Math.floor(Date.now() / 1000));
  const nonce = randomBytes(16).toString("hex");
  return { "x-familyshield-signature": createHmac("sha256", secret).update(`${ts}.${nonce}.${raw}`).digest("hex"), "x-familyshield-timestamp": ts, "x-familyshield-nonce": nonce };
}

async function send(call, who) {
  const raw = call.body === undefined ? undefined : JSON.stringify(call.body);
  const headers = { ...(raw ? { "content-type": "application/json" } : {}), "x-osra-client": "loadtest/1.0.0 (1; android; loadtest)" };
  if (call.auth === "device") headers.authorization = `Bearer ${deviceToken(who)}`;
  if (call.auth === "parent") headers.authorization = `Bearer ${parentToken(who)}`;
  if (call.auth === "device-hmac") Object.assign(headers, signV2(deviceSecret(who.deviceId), raw ?? ""));
  const t = Date.now();
  const res = await fetch(`${API}${call.path}`, { method: call.method, headers, body: raw });
  const text = await res.text();
  return { name: call.name, status: res.status, ms: Date.now() - t, body: res.status >= 300 ? text.slice(0, 200) : "" };
}

const results = [];
for (const fam of [0, 1, Math.max(0, FAMILIES - 1)]) {
  const d = ltDevices(fam)[0];
  for (const build of Object.values(deviceCalls)) results.push(await send(build(d), d));
  const p = ltParent(fam, 1);
  for (const build of Object.values(parentReads)) results.push(await send(build(p), p));
  for (const build of [parentActions.bonus, parentActions.pause, parentActions.resume, parentActions.rulesPatch]) results.push(await send(build(p), p));
}
let bad = 0;
for (const r of results) {
  const ok = r.status >= 200 && r.status < 300;
  if (!ok) bad++;
  console.log(`${ok ? "ok  " : "FAIL"} ${r.status} ${String(r.ms).padStart(4)} ms  ${r.name} ${r.body}`);
}
console.log(`${results.length - bad}/${results.length} calls answered 2xx`);
process.exitCode = bad ? 1 : 0;
