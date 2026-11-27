// Parent A pauses a child; parent B of the same synthetic family should get a WebSocket frame.
// Same check as the k6 `rush` scenario, with Node 22's built-in WebSocket.
import { createHmac, randomBytes } from "node:crypto";
import { ltParent, ltDevices } from "../k6/lib/ids.js";
import { parentActions } from "../k6/lib/calls.js";
const API = process.env.API ?? "http://localhost:3000", SECRET = process.env.JWT_SECRET;
const b64u = (b) => Buffer.from(b).toString("base64url");
const jwt = (c) => { const n = Math.floor(Date.now() / 1000); const h = b64u('{"alg":"HS256","typ":"JWT"}'); const p = b64u(JSON.stringify({ ...c, iat: n, exp: n + 3600 })); return `${h}.${p}.${createHmac("sha256", SECRET).update(`${h}.${p}`).digest("base64url")}`; };
const tok = (p) => jwt({ sub: p.parentId, familyId: p.familyId, role: "parent", familyRole: p.familyRole, jti: randomBytes(16).toString("hex"), sv: 0 });
const a = ltParent(0, 0), b = ltParent(0, 1);
const t = await (await fetch(`${API}/v1/ws-ticket`, { method: "POST", headers: { authorization: `Bearer ${tok(b)}` } })).json();
const ws = new WebSocket(`${API.replace(/^http/, "ws")}/v1/ws?ticket=${t.ticket}`);
let sent = 0;
ws.onmessage = (m) => { if (sent) { console.log(`frame after ${Date.now() - sent} ms: ${String(m.data).slice(0, 120)}`); ws.close(); process.exit(0); } };
ws.onopen = async () => { await new Promise((r) => setTimeout(r, 300)); sent = Date.now(); const c = parentActions.pause(a); const r = await fetch(`${API}${c.path}`, { method: "POST", headers: { authorization: `Bearer ${tok(a)}` } }); console.log("pause", r.status);
  // The child's phone (child 2 of family 0) polls, gets the pause and acks it: that ack is what parents see.
  const d = ltDevices(0).find((x) => x.childId === a.children[1]);
  const dt = jwt({ sub: d.deviceId, deviceId: d.deviceId, childId: d.childId, familyId: d.familyId, role: "device" });
  const cmds = await (await fetch(`${API}/v1/devices/${d.deviceId}/commands`, { headers: { authorization: `Bearer ${dt}` } })).json();
  console.log("device got", cmds.map((x) => x.type).join(","));
  for (const cmd of cmds) await fetch(`${API}/v1/devices/${d.deviceId}/commands/${cmd.id}/ack`, { method: "POST", headers: { authorization: `Bearer ${dt}`, "content-type": "application/json" }, body: JSON.stringify({ status: "ok" }) });
};
setTimeout(() => { console.log("no frame within 5 s"); process.exit(1); }, 5000);
