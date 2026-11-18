/**
 * Production must check who it is talking to before it sends the database password (#766 item 3, gate #637).
 *
 * `sslmode=require` encrypts the connection and accepts any certificate, so anything that can answer on the
 * database's address can read the password and every query. Prisma only checks the certificate chain and the
 * hostname when the URL carries all three of:
 *
 *   sslmode=require & sslaccept=strict & sslcert=<path to the single root CA PEM>
 *
 * The spellings every PostgreSQL guide gives do NOT work here. Measured on Prisma 5.22 against PostgreSQL 16
 * with a certificate from a private CA (2026-11-14) and against eu-central-1 RDS (#919, 2026-11-18):
 *
 *   sslmode=require&sslaccept=strict&sslcert=<single right CA>            connects
 *   sslmode=require&sslaccept=strict&sslcert=<another CA>                 refused (certificate verify failed)
 *   sslmode=require&sslaccept=strict&sslcert=<bundle, wrong CA first>     refused (Prisma loads only the first PEM block)
 *   same, host spelled as an address the certificate lacks                refused
 *   sslmode=require&sslaccept=strict (no sslcert)                         refused
 *   sslmode=verify-full&sslrootcert=<right CA>                            connects, and so does
 *   sslmode=verify-full&sslcert=<another CA>                              connects: nothing was verified
 *
 * So a URL that reads as the strictest setting verifies nothing, and no error says so. This check is what
 * says so: with DATABASE_TLS_VERIFY=required the API refuses to start on any URL but the verifying form.
 * The production Terraform sets the variable; staging and development leave it unset and are untouched.
 *
 * No message here contains the URL or any part of it: the URL holds the database password.
 */
import { existsSync, readFileSync } from "node:fs";
import { isAbsolute } from "node:path";

export const DATABASE_TLS_REQUIRED = "required";

type FileReader = { exists(path: string): boolean; read(path: string): string };

const realFiles: FileReader = {
  exists: (path) => existsSync(path),
  read: (path) => readFileSync(path, "utf8"),
};

/** The one value of each parameter, or a refusal when it is given twice (which copy wins is the driver's secret). */
function single(params: URLSearchParams, name: string): string | undefined {
  const all = params.getAll(name);
  if (all.length > 1) {
    throw new Error(`DATABASE_URL names ${name} ${all.length} times; name it once (DATABASE_TLS_VERIFY=required)`);
  }
  return all[0];
}

export function assertDatabaseTls(env: NodeJS.ProcessEnv, files: FileReader = realFiles): void {
  const mode = env.DATABASE_TLS_VERIFY;
  if (mode === undefined || mode === "") return;
  // A typo must not read as "off": `require`, `true` and `1` are refused instead of ignored.
  if (mode !== DATABASE_TLS_REQUIRED) {
    throw new Error(`DATABASE_TLS_VERIFY must be "${DATABASE_TLS_REQUIRED}" or unset`);
  }

  const raw = env.DATABASE_URL;
  if (!raw) throw new Error("DATABASE_URL must be set when DATABASE_TLS_VERIFY=required");
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new Error("DATABASE_URL is not a URL (DATABASE_TLS_VERIFY=required)");
  }
  if (url.protocol !== "postgresql:" && url.protocol !== "postgres:") {
    throw new Error("DATABASE_URL must be a postgresql:// URL (DATABASE_TLS_VERIFY=required)");
  }

  const params = url.searchParams;
  if (params.has("sslrootcert")) {
    throw new Error(
      "DATABASE_URL uses sslrootcert, which Prisma ignores: the CA bundle goes in sslcert (DATABASE_TLS_VERIFY=required)",
    );
  }
  const sslmode = single(params, "sslmode");
  if (sslmode !== "require") {
    throw new Error(
      "DATABASE_URL must carry sslmode=require; Prisma does not verify on verify-ca or verify-full, " +
        "verification comes from sslaccept=strict (DATABASE_TLS_VERIFY=required)",
    );
  }
  if (single(params, "sslaccept") !== "strict") {
    throw new Error("DATABASE_URL must carry sslaccept=strict (DATABASE_TLS_VERIFY=required)");
  }
  const bundle = single(params, "sslcert");
  if (!bundle) {
    throw new Error("DATABASE_URL must carry sslcert=<path to the CA bundle> (DATABASE_TLS_VERIFY=required)");
  }
  // Prisma resolves a relative path against its schema folder, which is not where the image keeps the bundle.
  if (!isAbsolute(bundle)) {
    throw new Error("DATABASE_URL's sslcert must be an absolute path (DATABASE_TLS_VERIFY=required)");
  }
  if (!files.exists(bundle)) {
    throw new Error(`DATABASE_URL's sslcert file ${bundle} is not in this image (DATABASE_TLS_VERIFY=required)`);
  }
  const pem = files.read(bundle);
  const certs = pem.match(/-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----/g) ?? [];
  if (certs.length === 0) {
    throw new Error(`DATABASE_URL's sslcert file ${bundle} holds no certificate (DATABASE_TLS_VERIFY=required)`);
  }
  // #919: Prisma 5.22 loads only the first PEM block from sslcert; a multi-CA bundle whose first cert is not the
  // instance's root fails with P1011 ("self-signed certificate in certificate chain").
  if (certs.length > 1) {
    throw new Error(
      `DATABASE_URL's sslcert file ${bundle} holds ${certs.length} certificates; Prisma loads only the first ` +
        `certificate of sslcert, so point sslcert at the single root CA file (DATABASE_TLS_VERIFY=required)`,
    );
  }
}
