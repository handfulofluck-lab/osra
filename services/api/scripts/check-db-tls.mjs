#!/usr/bin/env node
/**
 * Proves, against the real database, that this deployment verifies the database's certificate (#766 item 3,
 * #919 single-root fix, release security gate #637, "data in transit").
 *
 * Run it where the API runs, with the API's own DATABASE_URL, e.g. as a one-off ECS task:
 *
 *   node scripts/check-db-tls.mjs
 *
 * Four live connections, read-only (`select` on pg_stat_ssl for this session, nothing else), plus a check that
 * `sslcert` is a single-certificate root CA file:
 *
 *   1. the URL as given                                        must CONNECT, session TLS=true, sslcert has 1 cert
 *   2. the same URL, decoy CA                                  must be REFUSED  (chain checked against sslcert)
 *   3. the same URL, no CA file                                must be REFUSED  (nothing outside sslcert trusted)
 *   4. the same URL, 2-cert bundles (right-first & wrong-first) wrong-first [decoy CA, real CA] must be REFUSED;
 *                                                              right-first [real CA, decoy CA] distinguishes
 *                                                              engines that load only cert #1 (OpenSSL on Linux,
 *                                                              SChannel on Windows: right-first connects, wrong-first
 *                                                              refused) from engines that reject multi-cert PEMs in
 *                                                              both orders (Security.framework on macOS).
 *
 * Row 1 alone proves nothing: `sslmode=require` passes it and verifies no certificate. Rows 2, 3 and 4 are the
 * evidence (#919: `rds-global-bundle.pem` had 114 roots with eu-central-1's `rds-ca-rsa2048-g1` at #100, and even
 * `eu-central-1-bundle.pem` puts ECC384 before RSA2048).
 *
 * The URL holds the database password, so it is never printed: not on success, not on failure, and Prisma's own
 * error text is reduced to its last line before it is shown.
 *
 * Exit codes: 0 all rows as expected · 1 a row is wrong · 2 the environment is not ready to be checked.
 */
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
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
if (!existsSync(bundle)) {
  fail(1, `FAIL  sslcert file ${bundle} does not exist`);
}

const pemBlocks = (pem) => pem.match(/-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----/g) ?? [];

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

const bundlePem = readFileSync(bundle, "utf8");
const certs = pemBlocks(bundlePem);
const decoyPem = readFileSync(DECOY, "utf8");

console.log(`check-db-tls: platform=${process.platform}, CA file ${bundle} (${certs.length} certificate(s))`);
if (certs.length !== 1) {
  row(false, `0. sslcert must hold exactly 1 root certificate (Prisma loads only the first), found ${certs.length}`);
}

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

const tmpDir = mkdtempSync(join(tmpdir(), "check-db-tls-"));
try {
  const rightFirstPath = join(tmpDir, "right-first-bundle.pem");
  const wrongFirstPath = join(tmpDir, "wrong-first-bundle.pem");
  writeFileSync(rightFirstPath, `${bundlePem.trim()}\n${decoyPem.trim()}\n`, "utf8");
  writeFileSync(wrongFirstPath, `${decoyPem.trim()}\n${bundlePem.trim()}\n`, "utf8");
  const rightFirst = await attempt(variant((p) => p.set("sslcert", rightFirstPath)));
  const wrongFirst = await attempt(variant((p) => p.set("sslcert", wrongFirstPath)));
  if (wrongFirst.connected) {
    row(false, "4. with a 2-cert bundle whose first certificate is wrong (decoy before real CA) it CONNECTED");
  } else if (rightFirst.connected) {
    row(
      true,
      `4. wrong-first 2-cert bundle is refused while right-first connected (engine loads only the first certificate on ${process.platform}): ${wrongFirst.reason}`,
    );
  } else {
    row(
      true,
      `4. both 2-cert bundle orders are refused on ${process.platform} (engine rejects multi-certificate sslcert outright; right-first: ${rightFirst.reason}; wrong-first: ${wrongFirst.reason})`,
    );
  }
} finally {
  rmSync(tmpDir, { recursive: true, force: true });
}

if (wrong > 0) fail(1, `check-db-tls: ${wrong} row(s) wrong. This deployment does not prove it verifies the database's certificate.`);
console.log("check-db-tls: verified. The database's certificate chain and hostname are checked on every connection.");
