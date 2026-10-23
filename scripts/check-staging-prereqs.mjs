#!/usr/bin/env node
/**
 * Fails when a staging session is about to start without the things it needs — or, worse, is about to
 * take something away.
 *
 * Why (issue #337): on 2026-10-23 a `terraform -chdir=infra/terraform/base apply` from a fresh clone
 * deleted the validated `api.staging.osratech.com` certificate, silently, because `base/terraform.tfvars`
 * is gitignored and most of `base` is `count`-gated on variables that live in it. The symptoms pointed
 * elsewhere: the first thing noticed was an image publish failing with an OIDC error that names GitHub.
 *
 * `up.sh` now refuses without that file and `prevent_destroy` protects the certificate, the OIDC provider
 * and the publish role (#339). This script is the *pre-session* view: it says what a session would find
 * missing before it spends anything, so the answer arrives in one command instead of after a failure.
 *
 * Usage:
 *   node scripts/check-staging-prereqs.mjs            # check this clone and the account
 *   node scripts/check-staging-prereqs.mjs --selftest # prove each rule fails on its own mutant
 *
 * Exit 0 = ready, 1 = problems (listed), 2 = environment problem (no aws CLI, no credentials).
 */
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

/**
 * The decision, with no I/O — so the rules can be tested without an AWS account.
 *
 * `observed` is what a probe found out in the world:
 *   baseTfvars      boolean  — infra/terraform/base/terraform.tfvars exists in this clone
 *   publishRoleArn  string   — base's publish_role_arn output, "" when empty
 *   apiImage        string   — the image the env stack would deploy, "" when unset
 *   imageTags       string[] — tags present in the ECR repository
 */
export function stagingProblems(observed) {
  const problems = [];

  // Rule 1 — the file whose absence destroys things. up.sh refuses too; this reports it before a
  // session even tries, and names the consequence rather than the symptom.
  if (!observed.baseTfvars) {
    problems.push(
      "base/terraform.tfvars is missing: base state is shared in S3, so an apply from this clone would evaluate the count-gated resources to zero and DESTROY the certificate, the OIDC provider and the publish role. Create it from terraform.tfvars.example.",
    );
  }

  // Rule 2 — the publish path. An empty role does not stop a session, it stops a publish, and the error
  // it produces later names GitHub rather than the empty variable that caused it.
  if (!observed.publishRoleArn) {
    problems.push(
      "base has no publish_role_arn, so an image publish (gh workflow run api-publish.yml) will fail with an OIDC error that names GitHub. Cause is almost always empty github_repo/github_owner_id/github_repo_id in base/terraform.tfvars.",
    );
  }

  // Rule 3 — the image. env/api_image has no default on purpose; naming a tag that is not in ECR fails
  // at task start, after the session has begun paying.
  if (observed.apiImage && !observed.imageTags.includes(observed.apiImage.split(":").pop())) {
    problems.push(
      `env/api_image names a tag that is not in ECR (${observed.apiImage}). Publish it first: gh workflow run api-publish.yml — the tag is the 12-character commit sha.`,
    );
  }

  return problems;
}

/* ───────────────────────────── the CLI ───────────────────────────── */

const here = fileURLToPath(new URL("..", import.meta.url)).replace(/[\/]$/, "");

/**
 * Only "the thing does not exist" is a finding. Every other failure — a missing profile, AccessDenied,
 * a network error, throttling — is the environment, and reporting it as a missing publish role would be
 * the misleading-symptom failure this script exists to prevent. Pure, so the self-test covers it the
 * same way the three rules are covered.
 */
export function classifyAwsFailure(detail, notFound) {
  if (/command not found|ENOENT|not recognized/i.test(detail)) return "ENV: the aws CLI is not on PATH";
  if (notFound.test(detail)) return "missing";
  const line = detail.split(/\r?\n/).find((l) => l.trim()) ?? "unknown error";
  return `ENV: aws failed: ${line.trim()}`;
}

function aws(args, notFound) {
  try {
    return execFileSync("aws", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
  } catch (err) {
    const verdict = classifyAwsFailure(`${err.stderr ?? ""}${err.code === "ENOENT" ? " ENOENT" : ""}`, notFound);
    if (verdict === "missing") return "";
    throw new Error(verdict);
  }
}

function observe() {
  const profile = process.env.AWS_PROFILE ?? "osra-staging";
  const region = process.env.AWS_REGION ?? "eu-north-1";
  const regionArgs = ["--profile", profile, "--region", region];

  const baseTfvars = existsSync(`${here}/infra/terraform/base/terraform.tfvars`);
  const publishRoleArn = aws(["iam", "get-role", "--role-name", `${(process.env.TF_PROJECT ?? "osra")}-staging-publish`, ...regionArgs, "--query", "Role.Arn", "--output", "text"], /NoSuchEntity/);
  const envTfvars = existsSync(`${here}/infra/terraform/env/terraform.tfvars`) ? "present" : "";
  let apiImage = "";
  if (envTfvars) {
    try {
      const tfvars = execFileSync("node", ["-e", `const t=require('fs').readFileSync(${JSON.stringify(`${here}/infra/terraform/env/terraform.tfvars`)},'utf8');const m=t.match(/api_image\\s*=\\s*"([^"]+)"/);process.stdout.write(m?m[1]:'')`], { encoding: "utf8" });
      apiImage = tfvars.trim();
    } catch {
      apiImage = "";
    }
  }
  const imageTags = aws(["ecr", "list-images", "--repository-name", `${(process.env.TF_PROJECT ?? "osra")}-staging/api`, ...regionArgs, "--query", "imageIds[].imageTag", "--output", "text"]).split(/\s+/).filter(Boolean);

  return { baseTfvars, publishRoleArn, apiImage, imageTags };
}

/* ───────────────────────────── the self-test ─────────────────────────────
 * One case per rule, plus the passing control. Mutant for each: delete the rule's condition and its
 * case fails; nothing else does.
 */
const CASES = [
  {
    name: "a complete clone with a role and a published image is ready",
    observed: { baseTfvars: true, publishRoleArn: "arn:aws:iam::1:role/x", apiImage: "repo/api:abc123", imageTags: ["abc123"] },
    expect: [],
  },
  {
    name: "rule 1: no base/terraform.tfvars is a problem, and names the destroy risk (#337)",
    observed: { baseTfvars: false, publishRoleArn: "arn:aws:iam::1:role/x", apiImage: "", imageTags: [] },
    expect: ["base/terraform.tfvars is missing"],
  },
  {
    name: "rule 2: an empty publish_role_arn is a problem, and names the misleading OIDC error",
    observed: { baseTfvars: true, publishRoleArn: "", apiImage: "", imageTags: [] },
    expect: ["no publish_role_arn"],
  },
  {
    name: "rule 3: an api_image tag that is not in ECR is a problem",
    observed: { baseTfvars: true, publishRoleArn: "arn:aws:iam::1:role/x", apiImage: "repo/api:deadbee", imageTags: ["abc123"] },
    expect: ["not in ECR"],
  },
  {
    // Finding 1 (#343 review): only "not found" is a finding; every other AWS failure is ENV (exit 2).
    // Mutant: return "missing" for any error and this fails - a bad profile would read as a missing role.
    name: "classifyAwsFailure: NoSuchEntity is a finding, a bad profile is the environment",
    classify: [
      ["An error occurred (NoSuchEntity) when calling the GetRole operation", /NoSuchEntity/, "missing"],
      ["Could not connect to the endpoint URL: network error", /NoSuchEntity/, "ENV:"],
      ["An error occurred (AccessDenied) when calling the GetRole operation", /NoSuchEntity/, "ENV:"],
      ["aws: command not found", /NoSuchEntity/, "ENV: the aws CLI is not on PATH"],
    ],
  },
  {
    name: "no api_image set is not a problem on its own — env may still be unconfigured",
    observed: { baseTfvars: true, publishRoleArn: "arn:aws:iam::1:role/x", apiImage: "", imageTags: [] },
    expect: [],
  },
];

function runSelftest() {
  let failed = 0;
  for (const c of CASES) {
    if (c.classify) {
      const bad = c.classify.filter(([detail, notFound, want]) => {
        const got = classifyAwsFailure(detail, notFound);
        return want === "missing" ? got !== "missing" : !got.startsWith(want);
      });
      if (bad.length === 0) console.log(`PASS  ${c.name}`);
      else {
        failed++;
        console.log(`FAIL  ${c.name}: ${bad.map(([d]) => classifyAwsFailure(d, /NoSuchEntity/)).join(" | ")}`);
      }
      continue;
    }
    const problems = stagingProblems(c.observed);
    const ok = c.expect.length === 0 ? problems.length === 0 : c.expect.every((e) => problems.some((p) => p.includes(e)));
    if (ok) console.log(`PASS  ${c.name}`);
    else {
      failed++;
      console.log(`FAIL  ${c.name}: ${problems.length ? problems.join(" | ") : "no problems reported"}`);
    }
  }
  console.log(`\nstaging-prereqs self-test: ${CASES.length - failed}/${CASES.length} cases`);
  process.exit(failed ? 1 : 0);
}

if (process.argv.includes("--selftest")) {
  runSelftest();
} else {
  let problems;
  try {
    problems = stagingProblems(observe());
  } catch (err) {
    console.error(String(err.message ?? err));
    process.exit(2);
  }
  if (problems.length) {
    console.log("A staging session from this clone would hit these problems:");
    for (const p of problems) console.log(`  - ${p}`);
    console.log("\nAGENTS.md §4: a gate may be extended, not narrowed. up.sh refuses the destructive one itself (#339).");
    process.exit(1);
  }
  console.log("staging prerequisites: ready (base/terraform.tfvars, publish role, published image)");
}
