import { X509Certificate } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { assertDatabaseTls } from "../src/lib/databaseTls.js";

/**
 * #766 item 3 / gate #637. Each refusal row names the mutant it kills: the line of `assertDatabaseTls` whose
 * removal makes that row, and only a row of that kind, stop failing.
 */
const BUNDLE = "/app/certs/rds-global-bundle.pem";
const PASSWORD = "s3cr3t-Pa55word-do-not-print";
const files = {
  exists: (path: string) => path === BUNDLE || path === "/app/certs/empty.pem",
  read: (path: string) => (path === BUNDLE ? "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n" : ""),
};
const url = (query: string) => `postgresql://osra_api:${PASSWORD}@db.example.eu-central-1.rds.amazonaws.com:5432/osra?${query}`;
const GOOD = `schema=public&sslmode=require&sslaccept=strict&sslcert=${BUNDLE}&connection_limit=10`;
/** `mode: null` leaves the variable out altogether. */
const check = (query: string, mode: string | null = "required") =>
  assertDatabaseTls({ ...(mode === null ? {} : { DATABASE_TLS_VERIFY: mode }), DATABASE_URL: url(query) }, files);

describe("DATABASE_TLS_VERIFY=required accepts only the URL Prisma verifies with", () => {
  it("accepts sslmode=require + sslaccept=strict + sslcert=<bundle in the image>", () => {
    expect(() => check(GOOD)).not.toThrow();
  });

  it("is off when the variable is unset or empty (staging, development, the CI image check)", () => {
    expect(() => check("sslmode=require", null)).not.toThrow();
    expect(() => check("sslmode=require", "")).not.toThrow();
    expect(() => assertDatabaseTls({}, files)).not.toThrow();
  });

  // Mutant: drop the `mode !== DATABASE_TLS_REQUIRED` refusal and a typo silently means "off".
  it.each(["require", "true", "1", "on", "Required", "verify-full"])("refuses the misspelt switch %s instead of reading it as off", (mode) => {
    expect(() => check(GOOD, mode)).toThrow(/must be "required" or unset/);
  });

  // Mutant: drop the sslmode check. This is today's production URL (infra/terraform/env/secrets.tf).
  it("refuses sslmode=require alone, which encrypts and verifies nothing", () => {
    expect(() => check("schema=public&sslmode=require&connection_limit=10")).toThrow(/sslaccept=strict/);
  });

  // Mutant: accept any sslmode. Measured: Prisma connects on verify-full with the wrong CA.
  it.each(["verify-full", "verify-ca", "prefer", "disable"])("refuses sslmode=%s even with strict and a bundle", (mode) => {
    expect(() => check(`sslmode=${mode}&sslaccept=strict&sslcert=${BUNDLE}`)).toThrow(/sslmode=require/);
  });
  it("refuses a URL with no sslmode", () => {
    expect(() => check(`sslaccept=strict&sslcert=${BUNDLE}`)).toThrow(/sslmode=require/);
  });

  // Mutant: drop the sslrootcert refusal. The libpq spelling is ignored by Prisma, so the bundle is never read.
  it("refuses the libpq spelling sslrootcert by name", () => {
    expect(() => check(`sslmode=require&sslaccept=strict&sslrootcert=${BUNDLE}`)).toThrow(/sslrootcert, which Prisma ignores/);
    expect(() => check(`${GOOD}&sslrootcert=${BUNDLE}`)).toThrow(/sslrootcert, which Prisma ignores/);
  });

  // Mutant: compare sslaccept loosely or not at all.
  it.each(["accept_invalid_certs", "Strict", ""])("refuses sslaccept=%s", (accept) => {
    expect(() => check(`sslmode=require&sslaccept=${accept}&sslcert=${BUNDLE}`)).toThrow(/sslaccept=strict/);
  });

  // Mutant: drop the sslcert presence check. Without a bundle the RDS chain cannot verify and every boot fails
  // at the first query with an OpenSSL line; this says what to fix instead.
  it("refuses strict with no bundle", () => {
    expect(() => check("sslmode=require&sslaccept=strict")).toThrow(/sslcert=<path to the CA bundle>/);
  });

  // Mutant: drop isAbsolute. Prisma resolves a relative sslcert against its schema folder.
  it("refuses a relative bundle path", () => {
    expect(() => check("sslmode=require&sslaccept=strict&sslcert=certs/rds-global-bundle.pem")).toThrow(/absolute path/);
  });

  // Mutants: drop the exists check; drop the content check.
  it("refuses a bundle that is not in the image, or holds no certificate", () => {
    expect(() => check("sslmode=require&sslaccept=strict&sslcert=/app/certs/missing.pem")).toThrow(/is not in this image/);
    expect(() => check("sslmode=require&sslaccept=strict&sslcert=/app/certs/empty.pem")).toThrow(/holds no certificate/);
  });

  // Mutant: read parameters with `get` (first wins). `strict` first and `accept_invalid_certs` second would pass.
  it.each(["sslmode=disable", "sslaccept=accept_invalid_certs", "sslcert=/tmp/other.pem"])("refuses a second %s after a good one", (extra) => {
    expect(() => check(`${GOOD}&${extra}`)).toThrow(/times; name it once/);
  });

  it("refuses a missing, malformed or non-PostgreSQL URL", () => {
    expect(() => assertDatabaseTls({ DATABASE_TLS_VERIFY: "required" }, files)).toThrow(/DATABASE_URL must be set/);
    expect(() => assertDatabaseTls({ DATABASE_TLS_VERIFY: "required", DATABASE_URL: "not a url" }, files)).toThrow(/is not a URL/);
    expect(() => assertDatabaseTls({ DATABASE_TLS_VERIFY: "required", DATABASE_URL: `mysql://u:p@h/db?${GOOD}` }, files)).toThrow(/postgresql:\/\//);
  });

  // The URL holds the password, and a boot failure goes to the log. Mutant: interpolate the URL into any message.
  it("never puts the password, the user or the host in a refusal", () => {
    const refusals = [
      "sslmode=require",
      "sslmode=verify-full&sslrootcert=/x.pem",
      "sslmode=require&sslaccept=strict",
      "sslmode=require&sslaccept=strict&sslcert=rel.pem",
      "sslmode=require&sslaccept=strict&sslcert=/app/certs/missing.pem",
      `${GOOD}&sslmode=disable`,
    ];
    for (const query of refusals) {
      let message = "";
      try {
        check(query);
      } catch (err) {
        message = (err as Error).message;
      }
      expect(message).not.toBe("");
      expect(message).not.toContain(PASSWORD);
      expect(message).not.toContain("osra_api");
      expect(message).not.toContain("rds.amazonaws.com");
    }
  });
});

describe("the CA bundle the image ships (services/api/certs)", () => {
  const read = (name: string) => readFileSync(fileURLToPath(new URL(`../certs/${name}`, import.meta.url)), "utf8");
  const certificates = (pem: string) =>
    (pem.match(/-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----/g) ?? []).map((c) => new X509Certificate(c));

  it("holds Amazon RDS roots for Frankfurt (production) and Stockholm (staging), all valid for two more years", () => {
    const roots = certificates(read("rds-global-bundle.pem"));
    expect(roots.length).toBeGreaterThan(50);
    const twoYears = Date.now() + 2 * 365 * 24 * 3600 * 1000;
    for (const root of roots) {
      expect(root.subject).toContain("Amazon RDS");
      expect(root.ca).toBe(true);
      expect(new Date(root.validTo).getTime(), root.subject).toBeGreaterThan(twoYears);
    }
    const subjects = roots.map((r) => r.subject).join("\n");
    expect(subjects).toContain("Amazon RDS eu-central-1 Root CA");
    expect(subjects).toContain("Amazon RDS eu-north-1 Root CA");
  });

  it("keeps the decoy apart from the real bundle, and neither file holds a key", () => {
    const decoy = certificates(read("decoy-ca.pem"));
    expect(decoy).toHaveLength(1);
    expect(decoy[0].subject).toContain("OSRA decoy CA");
    const real = certificates(read("rds-global-bundle.pem")).map((c) => c.fingerprint256);
    expect(real).not.toContain(decoy[0].fingerprint256);
    for (const name of ["rds-global-bundle.pem", "decoy-ca.pem"]) expect(read(name)).not.toMatch(/PRIVATE KEY/);
  });
});
