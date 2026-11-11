#!/usr/bin/env node
// Uploads an Android App Bundle to a Google Play track through the Play Developer API (roadmap 5.2/5.7).
//
// No dependencies: the service-account JWT is signed with node:crypto and the API is called with fetch,
// so no third-party action ever holds the key. The key arrives only through the PLAY_SERVICE_ACCOUNT_JSON
// environment variable (a GitHub Actions secret); it is never printed or written to disk.
//
// Usage:
//   node scripts/play-upload.mjs --package com.osratech.child --check
//       Opens an edit and deletes it again: proves the key and the Play Console link work, changes nothing.
//   node scripts/play-upload.mjs --package com.osratech.child --aab app.aab [--track internal]
//                                [--status draft|completed] [--validate-only]
//
// Play refuses API uploads for an app that has never had a bundle uploaded in Play Console, so the first
// bundle of each app goes in by hand; every later one can come from here. While an app has never been
// published, a release must stay "draft" (the default).
import { createSign } from "node:crypto";
import { readFileSync, statSync } from "node:fs";

const API = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications";
const UPLOAD = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications";
const SCOPE = "https://www.googleapis.com/auth/androidpublisher";
const PACKAGES = new Set(["com.osratech.parent", "com.osratech.child"]);
const TRACKS = new Set(["internal", "alpha", "beta"]); // production is Karim's call, never from CI
const STATUSES = new Set(["draft", "completed"]);

function args(argv) {
  const out = { track: "internal", status: "draft", check: false, validateOnly: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--check") out.check = true;
    else if (a === "--validate-only") out.validateOnly = true;
    else if (["--package", "--aab", "--track", "--status"].includes(a)) out[a.slice(2)] = argv[++i];
    else throw new Error(`unknown argument ${a}`);
  }
  if (!PACKAGES.has(out.package)) throw new Error(`--package must be one of ${[...PACKAGES].join(", ")}`);
  if (!TRACKS.has(out.track)) throw new Error(`--track must be one of ${[...TRACKS].join(", ")}`);
  if (!STATUSES.has(out.status)) throw new Error(`--status must be one of ${[...STATUSES].join(", ")}`);
  if (!out.check && !out.aab) throw new Error("--aab is required unless --check");
  return out;
}

function b64url(s) {
  return Buffer.from(s).toString("base64").replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
}

async function accessToken() {
  const raw = process.env.PLAY_SERVICE_ACCOUNT_JSON;
  if (!raw) throw new Error("PLAY_SERVICE_ACCOUNT_JSON is not set");
  const key = JSON.parse(raw);
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = b64url(
    JSON.stringify({ iss: key.client_email, scope: SCOPE, aud: key.token_uri, iat: now, exp: now + 3600 }),
  );
  const signer = createSign("RSA-SHA256");
  signer.update(`${head}.${claims}`);
  const sig = signer.sign(key.private_key).toString("base64").replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
  const res = await fetch(key.token_uri, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: `${head}.${claims}.${sig}`,
    }),
  });
  if (!res.ok) throw new Error(`token request failed: HTTP ${res.status}`);
  console.log(`signed in as ${key.client_email}`);
  return (await res.json()).access_token;
}

async function call(token, method, url, body, contentType = "application/json") {
  const res = await fetch(url, {
    method,
    headers: { authorization: `Bearer ${token}`, "content-type": contentType },
    body: body === undefined ? undefined : contentType === "application/json" ? JSON.stringify(body) : body,
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${url.replace(/\?.*/, "")} -> HTTP ${res.status}: ${text.slice(0, 500)}`);
  return text ? JSON.parse(text) : {};
}

async function main() {
  const o = args(process.argv.slice(2));
  const token = await accessToken();
  const base = `${API}/${o.package}/edits`;
  const edit = await call(token, "POST", base, {});
  console.log(`opened edit ${edit.id} on ${o.package}`);

  if (o.check) {
    const tracks = await call(token, "GET", `${base}/${edit.id}/tracks`);
    console.log(`tracks: ${(tracks.tracks || []).map((t) => t.track).join(", ") || "(none yet)"}`);
    await call(token, "DELETE", `${base}/${edit.id}`);
    console.log("check passed: the key works and nothing was changed");
    return;
  }

  console.log(`uploading ${o.aab} (${statSync(o.aab).size} bytes)`);
  const bundle = await call(
    token,
    "POST",
    `${UPLOAD}/${o.package}/edits/${edit.id}/bundles?uploadType=media`,
    readFileSync(o.aab),
    "application/octet-stream",
  );
  console.log(`uploaded versionCode ${bundle.versionCode}`);
  await call(token, "PUT", `${base}/${edit.id}/tracks/${o.track}`, {
    track: o.track,
    releases: [{ status: o.status, versionCodes: [String(bundle.versionCode)] }],
  });
  console.log(`track ${o.track}: release ${bundle.versionCode} set to ${o.status}`);

  if (o.validateOnly) {
    await call(token, "POST", `${base}/${edit.id}:validate`);
    await call(token, "DELETE", `${base}/${edit.id}`);
    console.log("validated and discarded (--validate-only)");
    return;
  }
  await call(token, "POST", `${base}/${edit.id}:commit`);
  console.log(`committed: ${o.package} versionCode ${bundle.versionCode} on ${o.track} (${o.status})`);
}

main().catch((e) => {
  console.error(`::error::${e.message}`);
  process.exit(1);
});
