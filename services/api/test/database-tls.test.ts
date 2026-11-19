import { execFileSync, spawn } from "node:child_process";
import { createHash, X509Certificate } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import tls from "node:tls";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { assertDatabaseTls } from "../src/lib/databaseTls.js";

/**
 * #766 item 3 / #919 / gate #637. Each refusal row names the mutant it kills: the line of `assertDatabaseTls` or
 * `check-db-tls.mjs` whose removal makes that row, and only a row of that kind, stop failing.
 */
const SINGLE_ROOT = "/app/certs/rds-eu-central-1-rsa2048-g1.pem";
const GLOBAL_BUNDLE = "/app/certs/rds-global-bundle.pem";
const PASSWORD = "s3cr3t-Pa55word-do-not-print";
const ONE_CERT = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n";
const TWO_CERTS = `${ONE_CERT}${ONE_CERT}`;
const files = {
  exists: (path: string) =>
    path === SINGLE_ROOT || path === GLOBAL_BUNDLE || path === "/app/certs/empty.pem",
  read: (path: string) => {
    if (path === SINGLE_ROOT) return ONE_CERT;
    if (path === GLOBAL_BUNDLE) return TWO_CERTS;
    return "";
  },
};
const url = (query: string) => `postgresql://osra_api:${PASSWORD}@db.example.eu-central-1.rds.amazonaws.com:5432/osra?${query}`;
const GOOD = `schema=public&sslmode=require&sslaccept=strict&sslcert=${SINGLE_ROOT}&connection_limit=10`;
/** `mode: null` leaves the variable out altogether. */
const check = (query: string, mode: string | null = "required") =>
  assertDatabaseTls({ ...(mode === null ? {} : { DATABASE_TLS_VERIFY: mode }), DATABASE_URL: url(query) }, files);

describe("DATABASE_TLS_VERIFY=required accepts only the URL Prisma verifies with", () => {
  it("accepts sslmode=require + sslaccept=strict + sslcert=<single root CA in the image>", () => {
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

  // Mutant: drop the sslmode check. This is staging's unverified URL (infra/terraform/env/secrets.tf).
  it("refuses sslmode=require alone, which encrypts and verifies nothing", () => {
    expect(() => check("schema=public&sslmode=require&connection_limit=10")).toThrow(/sslaccept=strict/);
  });

  // Mutant: accept any sslmode. Measured: Prisma connects on verify-full with the wrong CA.
  it.each(["verify-full", "verify-ca", "prefer", "disable"])("refuses sslmode=%s even with strict and a bundle", (mode) => {
    expect(() => check(`sslmode=${mode}&sslaccept=strict&sslcert=${SINGLE_ROOT}`)).toThrow(/sslmode=require/);
  });
  it("refuses a URL with no sslmode", () => {
    expect(() => check(`sslaccept=strict&sslcert=${SINGLE_ROOT}`)).toThrow(/sslmode=require/);
  });

  // Mutant: drop the sslrootcert refusal. The libpq spelling is ignored by Prisma, so the bundle is never read.
  it("refuses the libpq spelling sslrootcert by name", () => {
    expect(() => check(`sslmode=require&sslaccept=strict&sslrootcert=${SINGLE_ROOT}`)).toThrow(/sslrootcert, which Prisma ignores/);
    expect(() => check(`${GOOD}&sslrootcert=${SINGLE_ROOT}`)).toThrow(/sslrootcert, which Prisma ignores/);
  });

  // Mutant: compare sslaccept loosely or not at all.
  it.each(["accept_invalid_certs", "Strict", ""])("refuses sslaccept=%s", (accept) => {
    expect(() => check(`sslmode=require&sslaccept=${accept}&sslcert=${SINGLE_ROOT}`)).toThrow(/sslaccept=strict/);
  });

  // Mutant: drop the sslcert presence check. Without a bundle the RDS chain cannot verify and every boot fails
  // at the first query with an OpenSSL line; this says what to fix instead.
  it("refuses strict with no bundle", () => {
    expect(() => check("sslmode=require&sslaccept=strict")).toThrow(/sslcert=<path to the CA bundle>/);
  });

  // Mutant: drop isAbsolute. Prisma resolves a relative sslcert against its schema folder.
  it("refuses a relative bundle path", () => {
    expect(() => check("sslmode=require&sslaccept=strict&sslcert=certs/rds-eu-central-1-rsa2048-g1.pem")).toThrow(/absolute path/);
  });

  // Mutants: drop the exists check; drop the empty-content check; drop the multi-certificate check (#919).
  it("refuses an sslcert file that is not in the image, holds no certificate, or holds multiple certificates (#919)", () => {
    expect(() => check("sslmode=require&sslaccept=strict&sslcert=/app/certs/missing.pem")).toThrow(/is not in this image/);
    expect(() => check("sslmode=require&sslaccept=strict&sslcert=/app/certs/empty.pem")).toThrow(/holds no certificate/);
    expect(() => check(`sslmode=require&sslaccept=strict&sslcert=${GLOBAL_BUNDLE}`)).toThrow(
      /holds 2 certificates; Prisma loads only the first certificate/,
    );
  });

  // #919 real-file regression: fails on the 114-certificate rds-global-bundle.pem and passes on the single
  // rds-eu-central-1-rsa2048-g1.pem shipped in services/api/certs/.
  // Mutant: remove `if (certs.length > 1)` in databaseTls.ts and the global-bundle assertion stops throwing.
  it("fails on the real 114-certificate rds-global-bundle.pem and passes on the single eu-central-1 root (#919)", () => {
    const singleReal = fileURLToPath(new URL("../certs/rds-eu-central-1-rsa2048-g1.pem", import.meta.url));
    const globalReal = fileURLToPath(new URL("../certs/rds-global-bundle.pem", import.meta.url));
    expect(() =>
      assertDatabaseTls({
        DATABASE_TLS_VERIFY: "required",
        DATABASE_URL: url(`sslmode=require&sslaccept=strict&sslcert=${encodeURIComponent(singleReal)}`),
      }),
    ).not.toThrow();
    expect(() =>
      assertDatabaseTls({
        DATABASE_TLS_VERIFY: "required",
        DATABASE_URL: url(`sslmode=require&sslaccept=strict&sslcert=${encodeURIComponent(globalReal)}`),
      }),
    ).toThrow(/holds 114 certificates; Prisma loads only the first certificate/);
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
      `sslmode=require&sslaccept=strict&sslcert=${GLOBAL_BUNDLE}`,
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

describe("the CA certificates the image ships (services/api/certs)", () => {
  const read = (name: string) => readFileSync(fileURLToPath(new URL(`../certs/${name}`, import.meta.url)), "utf8");
  const certificates = (pem: string) =>
    (pem.match(/-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----/g) ?? []).map((c) => new X509Certificate(c));

  it("pins the single eu-central-1 rds-ca-rsa2048-g1 root certificate and its SHA-256 fingerprint (#919)", () => {
    const pem = read("rds-eu-central-1-rsa2048-g1.pem");
    const certs = certificates(pem);
    expect(certs).toHaveLength(1);
    const [root] = certs;
    expect(root.ca).toBe(true);
    expect(root.subject).toContain("CN=Amazon RDS eu-central-1 Root CA RSA2048 G1");
    expect(root.publicKey.asymmetricKeyType).toBe("rsa");
    expect(root.publicKey.asymmetricKeyDetails?.modulusLength).toBe(2048);
    expect(root.fingerprint256).toBe(
      "3D:8B:08:A7:39:0C:9B:10:D1:90:A6:B3:49:D7:03:AE:00:BA:E4:65:83:64:33:19:C7:FA:CC:F3:E5:DC:4A:8B",
    );
    expect(createHash("sha256").update(pem.replace(/\r\n/g, "\n")).digest("hex")).toBe(
      "6b25ace9d427f1d8a0fd8e146ebddf2384bcdb2bd1d835c620f8a7cf2895721f",
    );
    const twoYears = Date.now() + 2 * 365 * 24 * 3600 * 1000;
    expect(new Date(root.validTo).getTime()).toBeGreaterThan(twoYears);
    const globalFingerprints = certificates(read("rds-global-bundle.pem")).map((c) => c.fingerprint256);
    expect(globalFingerprints).toContain(root.fingerprint256);
  });

  it("holds Amazon RDS roots for Frankfurt (production) and Stockholm (staging) in the reference bundle", () => {
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

  it("keeps the decoy apart from the real roots, and no certificate file holds a key", () => {
    const decoy = certificates(read("decoy-ca.pem"));
    expect(decoy).toHaveLength(1);
    expect(decoy[0].subject).toContain("OSRA decoy CA");
    const real = certificates(read("rds-global-bundle.pem")).map((c) => c.fingerprint256);
    expect(real).not.toContain(decoy[0].fingerprint256);
    for (const name of ["rds-eu-central-1-rsa2048-g1.pem", "rds-global-bundle.pem", "decoy-ca.pem"]) {
      expect(read(name)).not.toMatch(/PRIVATE KEY/);
    }
  });
});

describe("scripts/check-db-tls.mjs live against Prisma's query engine (#919)", () => {
  const checkScript = fileURLToPath(new URL("../scripts/check-db-tls.mjs", import.meta.url));
  const apiDir = fileURLToPath(new URL("..", import.meta.url));

  function pgMsg(type: string, payload: Buffer): Buffer {
    const b = Buffer.alloc(1 + 4 + payload.length);
    b.write(type, 0, 1, "ascii");
    b.writeInt32BE(4 + payload.length, 1);
    payload.copy(b, 5);
    return b;
  }

  function rowDescription(): Buffer {
    const cols = [
      { name: "ssl", oid: 16, size: 1 },
      { name: "version", oid: 25, size: -1 },
      { name: "cipher", oid: 25, size: -1 },
    ];
    const parts: Buffer[] = [Buffer.alloc(2)];
    parts[0].writeInt16BE(cols.length, 0);
    for (const c of cols) {
      const nameBuf = Buffer.from(`${c.name}\0`, "utf8");
      const meta = Buffer.alloc(18);
      meta.writeInt32BE(0, 0);
      meta.writeInt16BE(0, 4);
      meta.writeInt32BE(c.oid, 6);
      meta.writeInt16BE(c.size, 10);
      meta.writeInt32BE(-1, 12);
      meta.writeInt16BE(0, 16);
      parts.push(nameBuf, meta);
    }
    return pgMsg("T", Buffer.concat(parts));
  }

  function dataRow(values: string[]): Buffer {
    const parts: Buffer[] = [Buffer.alloc(2)];
    parts[0].writeInt16BE(values.length, 0);
    for (const v of values) {
      const vb = Buffer.from(v, "utf8");
      const len = Buffer.alloc(4);
      len.writeInt32BE(vb.length, 0);
      parts.push(len, vb);
    }
    return pgMsg("D", Buffer.concat(parts));
  }

  function findOpenSsl(): string {
    for (const candidate of ["openssl", "C:/Program Files/Git/usr/bin/openssl.exe"]) {
      try {
        execFileSync(candidate, ["version"], { stdio: "ignore" });
        return candidate;
      } catch {
        // try next
      }
    }
    throw new Error("openssl binary is required for the live TLS handshake test");
  }

  function runCheckScript(databaseUrl: string): Promise<{ status: number | null; stdout: string; stderr: string }> {
    return new Promise((resolveRun) => {
      const child = spawn(process.execPath, [checkScript], {
        cwd: apiDir,
        env: { ...process.env, DATABASE_URL: databaseUrl },
      });
      let stdout = "";
      let stderr = "";
      child.stdout.on("data", (d) => {
        stdout += String(d);
      });
      child.stderr.on("data", (d) => {
        stderr += String(d);
      });
      child.on("close", (status) => resolveRun({ status, stdout, stderr }));
    });
  }

  // Planted test for #919 (#924 review):
  // 1) With a single right root CA, check-db-tls.mjs passes all 4 rows. Row 4 runs both 2-cert bundle orders
  //    ([real CA, decoy CA] right-first and [decoy CA, real CA] wrong-first):
  //    - On Linux (OpenSSL, production image) and Windows (SChannel), native-tls loads only the first PEM block, so
  //      right-first CONNECTS and wrong-first is REFUSED ("wrong-first 2-cert bundle is refused while right-first connected").
  //    - On macOS (Security.framework), native-tls rejects multi-certificate PEMs outright in both orders
  //      ("both 2-cert bundle orders are refused on darwin").
  // 2) With a multi-cert bundle whose first cert is wrong [wrong CA, right CA] — reproducing today's production
  //    rds-global-bundle.pem failure — check-db-tls.mjs exits 1 (both row 0 single-cert guard and row 1 TLS connect
  //    refusal fail) and never prints the database password.
  // Mutants:
  // - All platforms: write `${bundlePem}\n` (single real CA) to `wrongFirstPath` in check-db-tls.mjs -> row 4 CONNECTS -> exit 1.
  // - Linux / Windows (OpenSSL / SChannel): swap `wrongFirstPath` to `${bundlePem}\n${decoyPem}` -> row 4 CONNECTS -> exit 1;
  //   swap `rightFirstPath` to `${decoyPem}\n${bundlePem}` -> `while right-first connected` assertion fails.
  it(
    "passes all 4 rows on a single root CA (with platform-explicit 2-cert order proof) and fails on a wrong-first bundle (#919)",
    async () => {
      const openssl = findOpenSsl();
      const tmp = mkdtempSync(join(tmpdir(), "osra-db-tls-test-"));
      let server: net.Server | null = null;
      try {
        const genCa = (name: string, cn: string) => {
          execFileSync(
            openssl,
            [
              "req", "-x509", "-newkey", "rsa:2048", "-nodes",
              "-keyout", join(tmp, `${name}.key`),
              "-out", join(tmp, `${name}.pem`),
              "-days", "2", "-subj", `/CN=${cn}`,
              "-addext", "basicConstraints=critical,CA:TRUE",
              "-addext", "keyUsage=critical,keyCertSign,cRLSign",
            ],
            { stdio: "pipe" },
          );
          return readFileSync(join(tmp, `${name}.pem`), "utf8");
        };

        const rightCa = genCa("right-ca", "Test Right RDS Root CA");
        const wrongCa = genCa("wrong-ca", "Test Wrong First Root CA");
        writeFileSync(
          join(tmp, "ext.cnf"),
          "subjectAltName=DNS:localhost\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n",
        );
        execFileSync(
          openssl,
          ["req", "-newkey", "rsa:2048", "-nodes", "-keyout", join(tmp, "server.key"), "-out", join(tmp, "server.csr"), "-subj", "/CN=localhost"],
          { stdio: "pipe" },
        );
        execFileSync(
          openssl,
          [
            "x509", "-req", "-in", join(tmp, "server.csr"),
            "-CA", join(tmp, "right-ca.pem"), "-CAkey", join(tmp, "right-ca.key"), "-CAcreateserial",
            "-out", join(tmp, "server.pem"), "-days", "2", "-extfile", join(tmp, "ext.cnf"),
          ],
          { stdio: "pipe" },
        );

        const rightCaPath = join(tmp, "right-ca.pem");
        const wrongFirstPath = join(tmp, "wrong-first-bundle.pem");
        writeFileSync(wrongFirstPath, `${wrongCa}\n${rightCa}`, "utf8");

        const serverKey = readFileSync(join(tmp, "server.key"));
        const serverCert = readFileSync(join(tmp, "server.pem"));

        server = net.createServer((sock) => {
          sock.once("data", (buf) => {
            // PostgreSQL SSLRequest magic: length 8, code 80877103 (0x04d2162f).
            if (buf.length === 8 && buf.readInt32BE(4) === 80877103) {
              sock.write("S");
              const tlsSock = new tls.TLSSocket(sock, { isServer: true, key: serverKey, cert: serverCert });
              tlsSock.on("error", () => {});
              let startupDone = false;
              let rx = Buffer.alloc(0);
              tlsSock.on("data", (chunk) => {
                rx = Buffer.concat([rx, chunk]);
                if (!startupDone) {
                  if (rx.length < 4) return;
                  const sLen = rx.readInt32BE(0);
                  if (rx.length < sLen) return;
                  rx = rx.subarray(sLen);
                  startupDone = true;
                  const authOk = Buffer.alloc(4);
                  const param = (k: string, v: string) => Buffer.concat([Buffer.from(`${k}\0`), Buffer.from(`${v}\0`)]);
                  tlsSock.write(
                    Buffer.concat([
                      pgMsg("R", authOk),
                      pgMsg("S", param("server_version", "16.3")),
                      pgMsg("S", param("client_encoding", "UTF8")),
                      pgMsg("K", Buffer.alloc(8)),
                      pgMsg("Z", Buffer.from("I")),
                    ]),
                  );
                }
                while (rx.length >= 5) {
                  const tag = String.fromCharCode(rx[0]);
                  const mLen = rx.readInt32BE(1);
                  if (rx.length < 1 + mLen) break;
                  rx = rx.subarray(1 + mLen);
                  if (tag === "P") {
                    tlsSock.write(pgMsg("1", Buffer.alloc(0)));
                  } else if (tag === "D") {
                    tlsSock.write(Buffer.concat([pgMsg("t", Buffer.alloc(2)), rowDescription()]));
                  } else if (tag === "B") {
                    tlsSock.write(pgMsg("2", Buffer.alloc(0)));
                  } else if (tag === "E") {
                    tlsSock.write(Buffer.concat([dataRow(["t", "TLSv1.3", "TLS_AES_256_GCM_SHA384"]), pgMsg("C", Buffer.from("SELECT 1\0"))]));
                  } else if (tag === "S") {
                    tlsSock.write(pgMsg("Z", Buffer.from("I")));
                  } else if (tag === "Q") {
                    tlsSock.write(
                      Buffer.concat([
                        rowDescription(),
                        dataRow(["t", "TLSv1.3", "TLS_AES_256_GCM_SHA384"]),
                        pgMsg("C", Buffer.from("SELECT 1\0")),
                        pgMsg("Z", Buffer.from("I")),
                      ]),
                    );
                  } else if (tag === "X") {
                    tlsSock.end();
                    return;
                  }
                }
              });
            }
          });
        });

        await new Promise<void>((r) => server!.listen(0, "localhost", r));
        const port = (server.address() as net.AddressInfo).port;

        const okRun = await runCheckScript(
          `postgresql://osra_api:${PASSWORD}@localhost:${port}/osra?sslmode=require&sslaccept=strict&sslcert=${encodeURIComponent(rightCaPath)}`,
        );
        expect(okRun.status, okRun.stdout + okRun.stderr).toBe(0);
        expect(okRun.stdout).toContain(`check-db-tls: platform=${process.platform},`);
        expect(okRun.stdout).toContain("PASS  1. the URL as given connects; session TLS=true");
        expect(okRun.stdout).toContain("PASS  2. with the decoy CA it is refused:");
        expect(okRun.stdout).toContain("PASS  3. with no CA bundle it is refused:");
        if (process.platform === "darwin") {
          expect(okRun.stdout).toContain(
            "PASS  4. both 2-cert bundle orders are refused on darwin (engine rejects multi-certificate sslcert outright;",
          );
        } else {
          expect(okRun.stdout).toContain(
            `PASS  4. wrong-first 2-cert bundle is refused while right-first connected (engine loads only the first certificate on ${process.platform}):`,
          );
        }
        expect(okRun.stdout + okRun.stderr).not.toContain(PASSWORD);

        const plantedBundleRun = await runCheckScript(
          `postgresql://osra_api:${PASSWORD}@localhost:${port}/osra?sslmode=require&sslaccept=strict&sslcert=${encodeURIComponent(wrongFirstPath)}`,
        );
        expect(plantedBundleRun.status).toBe(1);
        expect(plantedBundleRun.stdout).toContain("FAIL  0. sslcert must hold exactly 1 root certificate");
        expect(plantedBundleRun.stdout).toContain("FAIL  1. the URL as given should connect, and was refused:");
        expect(plantedBundleRun.stdout + plantedBundleRun.stderr).not.toContain(PASSWORD);
      } finally {
        if (server) await new Promise<void>((r) => server!.close(() => r()));
        rmSync(tmp, { recursive: true, force: true });
      }
    },
    30_000,
  );
});
