#!/usr/bin/env node
import { execFile } from "node:child_process";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

async function defaultAwsCli(args) {
  try {
    const { stdout } = await execFileAsync("aws", args, { encoding: "utf8", maxBuffer: 1024 * 1024 });
    return stdout.trim();
  } catch {
    throw new Error("aws_cli_failed");
  }
}

function connectionUrl(secret) {
  let parsed = secret;
  try { parsed = JSON.parse(secret); } catch {}
  if (parsed && typeof parsed === "object" && typeof parsed.DATABASE_URL === "string") return parsed.DATABASE_URL;
  if (parsed && typeof parsed === "object" && parsed.host && parsed.username) {
    const auth = `${encodeURIComponent(parsed.username)}:${encodeURIComponent(parsed.password ?? "")}`;
    return `postgresql://${auth}@${parsed.host}:${parsed.port ?? 5432}/${parsed.dbname ?? "postgres"}`;
  }
  if (typeof parsed === "string" && /^postgres(?:ql)?:\/\//.test(parsed)) return parsed;
  throw new Error("database_secret_shape");
}

async function defaultExecuteSql(secret, sql, params) {
  const url = new URL(connectionUrl(secret));
  const env = {
    ...process.env,
    PGHOST: url.hostname,
    PGPORT: url.port || "5432",
    PGDATABASE: decodeURIComponent(url.pathname.slice(1)),
    PGUSER: decodeURIComponent(url.username),
    PGPASSWORD: decodeURIComponent(url.password),
    PGSSLMODE: url.searchParams.get("sslmode") ?? process.env.PGSSLMODE ?? "require",
  };
  const args = ["--no-psqlrc", "--set", "ON_ERROR_STOP=1", "--quiet", "--file", "-"];
  for (const [name, value] of Object.entries(params)) args.push("--set", `${name}=${value}`);
  const child = execFileAsync("psql", args, { env, encoding: "utf8" });
  child.child.stdin.end(sql);
  try { await child; } catch { throw new Error("grant_sql_failed"); }
}

const SQL = `INSERT INTO "family_purchases"
  ("id", "family_id", "source", "product_id", "store_ref", "status", "expires_at", "auto_renews", "last_verified_at", "cause")
VALUES
  (:'id', :'family_id', 'grant', :'product_id', :'store_ref', 'active', :'expires_at'::timestamptz, false, NOW(), :'cause');`;

/** Maintainer-only local operation. Tests inject both boundaries; no agent run touches AWS or a database. */
export async function runGrant(input, deps = {}) {
  const expiresMs = typeof input.expiresAt === "string" ? Date.parse(input.expiresAt) : NaN;
  if (!Number.isFinite(expiresMs)) throw new Error("expires_at_required_finite_iso8601");
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(input.familyId ?? "")) throw new Error("family_id_required_uuid");
  if (typeof input.secretName !== "string" || !input.secretName.trim()) throw new Error("database_secret_name_required");
  if (typeof input.reason !== "string" || !input.reason.trim() || input.reason.length > 500) throw new Error("grant_reason_required");
  if (input.productId !== undefined && (typeof input.productId !== "string" || !input.productId.trim() || input.productId.length > 200)) throw new Error("invalid_product_id");

  const awsCli = deps.awsCli ?? defaultAwsCli;
  const executeSql = deps.executeSql ?? defaultExecuteSql;
  const log = deps.log ?? ((event) => console.log(event));
  const args = ["secretsmanager", "get-secret-value", "--secret-id", input.secretName, "--query", "SecretString", "--output", "text"];
  if (input.profile) args.push("--profile", input.profile);
  if (input.region) args.push("--region", input.region);
  const secret = await awsCli(args);
  const storeRef = deps.newStoreRef?.() ?? randomBytes(32).toString("hex");
  const params = {
    id: randomUUID(),
    family_id: input.familyId,
    product_id: input.productId ?? "family",
    store_ref: createHash("sha256").update(storeRef, "utf8").digest("hex"),
    expires_at: new Date(expiresMs).toISOString(),
    cause: input.reason,
  };
  await executeSql(secret, SQL, params);
  log("grant_recorded");
}

function parseCli(argv) {
  const names = new Map([
    ["--family-id", "familyId"], ["--expires-at", "expiresAt"], ["--reason", "reason"],
    ["--secret-name", "secretName"], ["--profile", "profile"], ["--region", "region"], ["--product-id", "productId"],
  ]);
  const result = {};
  for (let i = 0; i < argv.length; i += 2) {
    const key = names.get(argv[i]);
    if (!key || argv[i + 1] === undefined) throw new Error("usage: grant.mjs --family-id UUID --expires-at ISO8601 --reason TEXT --secret-name NAME [--profile NAME] [--region NAME] [--product-id ID]");
    result[key] = argv[i + 1];
  }
  return result;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  runGrant(parseCli(process.argv.slice(2))).catch((error) => {
    const safe = /^(?:expires_at|family_id|database_secret_name|grant_reason|invalid_product_id|aws_cli_failed|database_secret_shape|grant_sql_failed)/.test(error?.message ?? "");
    console.error(safe ? error.message : "grant_failed");
    process.exitCode = 1;
  });
}
