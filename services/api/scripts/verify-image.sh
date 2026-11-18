#!/usr/bin/env sh
# Builds the API image and asserts the three things the old Dockerfile could not: that Node runs, that
# the Prisma CLI resolves, and that the file CMD points at was actually emitted by the build.
#
#   sh services/api/scripts/verify-image.sh               # build from the repo root, then check
#   IMAGE=osra-api:ci SKIP_BUILD=1 sh services/api/scripts/verify-image.sh
#
# CI (.github/workflows/api-image.yml) builds with buildx and runs this with SKIP_BUILD=1.
set -eu

cd "$(dirname "$0")/../../.."   # the repository root is the build context
IMAGE="${IMAGE:-osra-api:local}"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  docker build -f services/api/Dockerfile -t "$IMAGE" .
fi

# 1. Node is present and executable in the runtime stage.
docker run --rm "$IMAGE" node -v

# 2. The Prisma CLI and its engine are IN the image. `--network none` is the point: without a TTY,
#    npx assumes --yes and happily downloads a missing package, so `npx prisma` could pass on an image
#    with no Prisma in it — and a Fargate task in a private subnet cannot download anything.
docker run --rm --network none --workdir /app/services/api "$IMAGE" node_modules/.bin/prisma --version
# 2b. tsx, which runs the seed, is present for the same reason.
docker run --rm --network none --workdir /app/services/api "$IMAGE" node_modules/.bin/tsx --version

# 3. The entry file named by CMD exists in the image (`node dist/server.js`, cwd /app/services/api).
#    `sh -c` rather than `--entrypoint test`: Alpine's test is a shell builtin, not a binary.
docker run --rm "$IMAGE" sh -c 'test -f /app/services/api/dist/server.js'

# 4. The single eu-central-1 RDS root CA is where production's DATABASE_URL says it is
#    (`sslcert=/app/certs/rds-eu-central-1-rsa2048-g1.pem`, #919 / #766 item 3), holds exactly one certificate
#    (Prisma 5.22 loads only the first PEM block of sslcert), and the user the API runs as can read it and cannot
#    write it. The reference global bundle, the decoy CA and the checker ship alongside it.
docker run --rm "$IMAGE" sh -c '
  set -eu
  r=/app/certs/rds-eu-central-1-rsa2048-g1.pem
  b=/app/certs/rds-global-bundle.pem
  # Every row says which one failed: a bare `test` under `set -e` stops the script with no line at all.
  no() { echo "image check 4: $1"; ls -ld /app/certs /app/certs/* 2>&1 || true; id; exit 1; }
  test -r "$r" || no "the API user cannot read $r"
  if test -w "$r"; then no "the API user can rewrite $r"; fi
  test "$(grep -c "BEGIN CERTIFICATE" "$r")" -eq 1 || no "$r must hold exactly 1 certificate"
  test -r "$b" || no "the API user cannot read $b"
  # `if`, not `! test`: under `set -e` a negated command that fails does not stop the script.
  if test -w "$b"; then no "the API user can rewrite $b"; fi
  test "$(grep -c "BEGIN CERTIFICATE" "$b")" -ge 50 || no "$b holds fewer than 50 certificates"
  if grep -q "PRIVATE KEY" /app/certs/*.pem; then no "a private key is in /app/certs"; fi
  test -r /app/certs/decoy-ca.pem || no "the decoy CA is missing or unreadable"
  test -f /app/services/api/scripts/check-db-tls.mjs || no "scripts/check-db-tls.mjs is not in the image"
'
# 4b. With the switch on, the image refuses to boot on a URL that would not verify (the refusal comes before
#     any connection, so no database is needed), and says why without printing the URL.
out="$(docker run --rm --network none -e DATABASE_TLS_VERIFY=required \
  -e DATABASE_URL="postgresql://u:image-check-pw@db.invalid:5432/x?sslmode=require" \
  -e JWT_SECRET=image-check-not-a-dev-value -e VAULT_KEY=image-check -e CORS_ALLOW_ANY_ORIGIN=1 \
  "$IMAGE" 2>&1 || true)"
echo "$out" | grep -q "sslaccept=strict" || { echo "the image booted, or failed for another reason, on an unverified database URL:"; echo "$out" | tail -5; exit 1; }
if echo "$out" | grep -q "image-check-pw"; then echo "the boot refusal printed the database password"; exit 1; fi

# 4c. #919: pointing sslcert at the multi-certificate global bundle is also refused before any connection.
out_bundle="$(docker run --rm --network none -e DATABASE_TLS_VERIFY=required \
  -e DATABASE_URL="postgresql://u:image-check-pw@db.invalid:5432/x?sslmode=require&sslaccept=strict&sslcert=/app/certs/rds-global-bundle.pem" \
  -e JWT_SECRET=image-check-not-a-dev-value -e VAULT_KEY=image-check -e CORS_ALLOW_ANY_ORIGIN=1 \
  "$IMAGE" 2>&1 || true)"
echo "$out_bundle" | grep -q "only the first certificate" || { echo "the image did not refuse a multi-certificate sslcert bundle:"; echo "$out_bundle" | tail -5; exit 1; }
if echo "$out_bundle" | grep -q "image-check-pw"; then echo "the bundle boot refusal printed the database password"; exit 1; fi

# 4d. #919 (#924 review): inside the Linux runtime image itself, run scripts/check-db-tls.mjs against a local TLS
#     PostgreSQL wire server and prove both the positive right-first control ([real CA, decoy CA] CONNECTS) and the
#     negative wrong-first check ([decoy CA, real CA] is REFUSED) on OpenSSL.
out_tls="$(docker run --rm --network none --workdir /app/services/api "$IMAGE" node --input-type=module -e '
import { execFileSync, spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import tls from "node:tls";

const pgMsg = (t, p) => { const b = Buffer.alloc(5 + p.length); b.write(t, 0, 1, "ascii"); b.writeInt32BE(4 + p.length, 1); p.copy(b, 5); return b; };
const rowDesc = () => {
  const cols = [["ssl", 16, 1], ["version", 25, -1], ["cipher", 25, -1]];
  const h = Buffer.alloc(2); h.writeInt16BE(cols.length, 0); const parts = [h];
  for (const [n, oid, sz] of cols) { const m = Buffer.alloc(18); m.writeInt32BE(oid, 6); m.writeInt16BE(sz, 10); m.writeInt32BE(-1, 12); parts.push(Buffer.from(n + "\0"), m); }
  return pgMsg("T", Buffer.concat(parts));
};
const dataRow = (vs) => {
  const h = Buffer.alloc(2); h.writeInt16BE(vs.length, 0); const parts = [h];
  for (const v of vs) { const b = Buffer.from(v); const l = Buffer.alloc(4); l.writeInt32BE(b.length, 0); parts.push(l, b); }
  return pgMsg("D", Buffer.concat(parts));
};

const tmp = mkdtempSync(join(tmpdir(), "img-db-tls-"));
try {
  execFileSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", join(tmp, "ca.key"), "-out", join(tmp, "ca.pem"), "-days", "2", "-subj", "/CN=ImgTestCA", "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign"], { stdio: "pipe" });
  writeFileSync(join(tmp, "ext.cnf"), "subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n");
  execFileSync("openssl", ["req", "-newkey", "rsa:2048", "-nodes", "-keyout", join(tmp, "srv.key"), "-out", join(tmp, "srv.csr"), "-subj", "/CN=localhost"], { stdio: "pipe" });
  execFileSync("openssl", ["x509", "-req", "-in", join(tmp, "srv.csr"), "-CA", join(tmp, "ca.pem"), "-CAkey", join(tmp, "ca.key"), "-CAcreateserial", "-out", join(tmp, "srv.pem"), "-days", "2", "-extfile", join(tmp, "ext.cnf")], { stdio: "pipe" });
  const key = readFileSync(join(tmp, "srv.key")), cert = readFileSync(join(tmp, "srv.pem"));
  const srv = net.createServer((sock) => {
    sock.once("data", (buf) => {
      if (buf.length === 8 && buf.readInt32BE(4) === 80877103) {
        sock.write("S");
        const ts = new tls.TLSSocket(sock, { isServer: true, key, cert });
        ts.on("error", () => {});
        let up = false, rx = Buffer.alloc(0);
        ts.on("data", (c) => {
          rx = Buffer.concat([rx, c]);
          if (!up) {
            if (rx.length < 4) return;
            const n = rx.readInt32BE(0); if (rx.length < n) return;
            rx = rx.subarray(n); up = true;
            const kv = (k, v) => Buffer.concat([Buffer.from(k + "\0"), Buffer.from(v + "\0")]);
            ts.write(Buffer.concat([pgMsg("R", Buffer.alloc(4)), pgMsg("S", kv("server_version", "16.3")), pgMsg("S", kv("client_encoding", "UTF8")), pgMsg("K", Buffer.alloc(8)), pgMsg("Z", Buffer.from("I"))]));
          }
          while (rx.length >= 5) {
            const tag = String.fromCharCode(rx[0]), mLen = rx.readInt32BE(1);
            if (rx.length < 1 + mLen) break;
            rx = rx.subarray(1 + mLen);
            if (tag === "P") ts.write(pgMsg("1", Buffer.alloc(0)));
            else if (tag === "D") ts.write(Buffer.concat([pgMsg("t", Buffer.alloc(2)), rowDesc()]));
            else if (tag === "B") ts.write(pgMsg("2", Buffer.alloc(0)));
            else if (tag === "E") ts.write(Buffer.concat([dataRow(["t", "TLSv1.3", "TLS_AES_256_GCM_SHA384"]), pgMsg("C", Buffer.from("SELECT 1\0"))]));
            else if (tag === "S") ts.write(pgMsg("Z", Buffer.from("I")));
            else if (tag === "Q") ts.write(Buffer.concat([rowDesc(), dataRow(["t", "TLSv1.3", "TLS_AES_256_GCM_SHA384"]), pgMsg("C", Buffer.from("SELECT 1\0")), pgMsg("Z", Buffer.from("I"))]));
            else if (tag === "X") { ts.end(); return; }
          }
        });
      }
    });
  });
  await new Promise((r) => srv.listen(0, r));
  const port = srv.address().port;
  const dbUrl = "postgresql://u:image-check-pw@localhost:" + port + "/x?sslmode=require&sslaccept=strict&sslcert=" + encodeURIComponent(join(tmp, "ca.pem"));
  const code = await new Promise((r) => {
    const ch = spawn(process.execPath, ["scripts/check-db-tls.mjs"], { env: { ...process.env, DATABASE_URL: dbUrl }, stdio: "inherit" });
    ch.on("close", r);
  });
  await new Promise((r) => srv.close(r));
  if (code !== 0) process.exit(code ?? 1);
} finally {
  rmSync(tmp, { recursive: true, force: true });
}
' 2>&1)" || { echo "image check 4d (live check-db-tls.mjs inside image) failed:"; echo "$out_tls"; exit 1; }
echo "$out_tls"
echo "$out_tls" | grep -q "PASS  4. wrong-first 2-cert bundle is refused while right-first connected (engine loads only the first certificate on linux)" \
  || { echo "image check 4d did not prove right-first connected and wrong-first refused on Linux:"; echo "$out_tls"; exit 1; }
if echo "$out_tls" | grep -q "image-check-pw"; then echo "image check 4d printed the database password"; exit 1; fi

echo "verified: $IMAGE — node, prisma CLI, /app/services/api/dist/server.js and the RDS CA bundle are all present"
