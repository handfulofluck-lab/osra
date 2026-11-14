#!/usr/bin/env node
/**
 * Proves, against the real database, that this deployment verifies the database's certificate (#766 item 3,
 * release security gate #637, "data in transit").
 *
 * Run it where the API runs, with the API's own DATABASE_URL, e.g. as a one-off ECS task:
 *
 *   node scripts/check-db-tls.mjs
 *
 * Three connections, read-only (`select` on pg_stat_ssl for this session, nothing else):
 *
 *   1. the URL as given              must CONNECT, and the session must be TLS
 *   2. the same URL, decoy CA        must be REFUSED  (the server's chain is checked against sslcert)
 *   3. the same URL, no CA bundle    must be REFUSED  (nothing outside sslcert is trusted for this server)
 *
 * Row 1 alone proves nothing: `sslmode=require` passes it and verifies no certificate. Rows 2 and 3 are the
 * evidence. If either connects, the URL is not verifying and the script exits 1.
 *
 * The URL holds the database password, so it is never printed: not on success, not on failure, and Prisma's own
 * error text is reduced to its last line before it is shown.
 *
 * Exit codes: 0 all three rows as expected · 1 a row is wrong · 2 the environment is not ready to be checked.
 */
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { PrismaClient } from "@prisma/client";

const here = dirname(fileURLToPath(import.meta.url));
const DECOY = process.env.DB_TLS_DECOY_CA ?? ["/app/certs/decoy-ca.pem", resolve(here, "../certs/decoy-ca.pem")].find(existsSync);

function fail(code, message) {
  console.error(message);
  process.exit(code);
}

const raw = process.env.DATABASE_URL;
if (!raw) fail(2, "check-db-tls: DATABASE_URL is not set");
if (!DECOY || !existsSync(DECOY)) fail(2, "check-db-tls: the decoy CA (certs/decoy-ca.pem) is not in this image");

let base;
try {
  base = new URL(raw);
} catch {
  fail(2, "check-db-tls: DATABASE_URL is not a URL");
}
const bundle = base.searchParams.get("sslcert");
if (base.searchParams.get("sslmode") !== "require" || base.searchParams.get("sslaccept") !== "strict" || !bundle) {
  fail(1, "FAIL  the URL does not ask for verification: it needs sslmode=require, sslaccept=strict and sslcert=<CA bundle>");
}

function variant(change) {
  const url = new URL(base.href);
  change(url.searchParams);
  return url.href;
}

/** Connects, asks whether this session is encrypted, disconnects. Never throws; never returns the URL. */
async function attempt(url) {
  const prisma = new PrismaClient({ datasources: { db: { url } }, log: [] });
  try {
    const rows = await prisma.$queryRawUnsafe(
      "select ssl, version, cipher from pg_stat_ssl where pid = pg_backend_pid()",
    );
    return { connected: true, tls: rows[0] ?? null };
  } catch (err) {
    const lines = String(err?.message ?? err).split("\n").map((l) => l.trim()).filter(Boolean);
    // Prisma's last line is the driver's reason. Cut anything URL-shaped out of it all the same.
    const reason = (lines.at(-1) ?? "unknown").replace(/postgres(?:ql)?:\/\/\S+/gi, "[url]").slice(0, 160);
    return { connected: false, reason };
  } finally {
    await prisma.$disconnect().catch(() => {});
  }
}

let wrong = 0;
const row = (ok, text) => {
  if (!ok) wrong += 1;
  console.log(`${ok ? "PASS" : "FAIL"}  ${text}`);
};

console.log(`check-db-tls: CA bundle ${bundle}`);

const real = await attempt(base.href);
if (!real.connected) {
  row(false, `1. the URL as given should connect, and was refused: ${real.reason}`);
} else {
  row(real.tls?.ssl === true, `1. the URL as given connects; session TLS=${real.tls?.ssl} ${real.tls?.version ?? ""} ${real.tls?.cipher ?? ""}`.trimEnd());
}

const decoy = await attempt(variant((p) => p.set("sslcert", DECOY)));
row(!decoy.connected, decoy.connected ? "2. with the decoy CA it CONNECTED: the certificate chain is not being checked" : `2. with the decoy CA it is refused: ${decoy.reason}`);

const none = await attempt(variant((p) => p.delete("sslcert")));
row(!none.connected, none.connected ? "3. with no CA bundle it CONNECTED: something other than sslcert is trusted" : `3. with no CA bundle it is refused: ${none.reason}`);

if (wrong > 0) fail(1, `check-db-tls: ${wrong} row(s) wrong. This deployment does not prove it verifies the database's certificate.`);
console.log("check-db-tls: verified. The database's certificate chain and hostname are checked on every connection.");
