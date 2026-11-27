import fs from "node:fs";
import { spawnSync } from "node:child_process";

const WORKFLOW = ".github/workflows/parent-app.yml";
const BUILD_SCRIPT = "scripts/build-parent-staging-apk.sh";

const uncommented = (text) => text.split(/\r?\n/).filter((line) => !/^\s*#/.test(line)).join("\n");
const steps = (workflow) => uncommented(workflow).split(/^\s*- name:/m).slice(1).map((step) => `- name:${step}`);

function contractErrors(workflow, script) {
  const errors = [];
  const require = (condition, code) => { if (!condition) errors.push(code); };
  const workflowSteps = steps(workflow);
  const invocations = workflowSteps.filter((step) => step.includes("scripts/build-parent-staging-apk.sh"));
  require(invocations.length > 0, "missing_ci_invocation");
  require(invocations.some((step) => /CI_SYNTHETIC:\s*["']?1["']?/.test(step)), "ci_not_synthetic");
  for (const step of workflowSteps.filter((step) => step.includes("upload-artifact"))) {
    require(!/parent-app-staging-apk|\.apk(?:\b|["'])/i.test(step), "public_apk_artifact");
  }
  const active = uncommented(script);
  require(active.includes("flutter build apk --release"), "missing_apk_build");
  require(active.includes("google_app_id") && active.includes("project_id") && active.includes("VALUES_XML"), "missing_google_services_assertion");
  require(active.includes("android.permission.POST_NOTIFICATIONS"), "missing_post_notifications_assertion");
  require(active.includes("android.permission.INTERNET"), "missing_internet_assertion");
  require(active.includes("package: name='com.osratech.parent' versionCode="), "missing_package_version_assertion");
  require(active.includes("OSRA_EXPECTED_SIGNER_SHA256"), "missing_signer_guard");
  require(active.includes("verify --print-certs"), "missing_signer_verification");
  require(active.includes("${API_BASE:?") || active.includes('[[ -z "${API_BASE:-}" ]]'), "missing_api_base_requirement");
  require(active.includes("${BUILD_NUMBER:?") || active.includes('[[ -z "${BUILD_NUMBER:-}" ]]'), "missing_build_number_requirement");
  require(active.includes('if [[ "${CI_SYNTHETIC:-0}" != "1" ]]'), "real_build_guard_not_conditional");
  require(active.includes("unset OSRA_UPLOAD_KEYSTORE"), "inherited_signing_not_cleared");
  require(active.includes("^[0-9A-Fa-f]{64}$"), "missing_exact_digest");
  require(active.includes("grep -Fxi"), "weak_digest_comparison");
  require(active.includes('rm -f "$VALUES_XML"'), "missing_freshness_guard");
  require(!active.includes("gh release upload"), "private_upload_in_build_script");
  return errors;
}

const validWorkflow = `
      - name: Prove staging Parent APK
        env:
          CI_SYNTHETIC: "1"
        run: scripts/build-parent-staging-apk.sh
`;
const validScript = `#!/usr/bin/env bash
: "\${API_BASE:?}" "\${BUILD_NUMBER:?}"
unset OSRA_UPLOAD_KEYSTORE
if [[ "\${CI_SYNTHETIC:-0}" != "1" ]]; then
  : "\${OSRA_EXPECTED_SIGNER_SHA256:?}"
  [[ "$VALUE" =~ ^[0-9A-Fa-f]{64}$ ]]
  grep -Fxi "digest"
  apksigner verify --print-certs "$APK"
fi
rm -f "$VALUES_XML"
flutter build apk --release
google_app_id project_id VALUES_XML
android.permission.POST_NOTIFICATIONS
android.permission.INTERNET
package: name='com.osratech.parent' versionCode=
`;

const cases = [
  ["valid contract", validWorkflow, validScript, null],
  ["missing invocation", validWorkflow.replace("scripts/build-parent-staging-apk.sh", "echo no-op"), validScript, "missing_ci_invocation"],
  ["real-only CI inputs", validWorkflow.replace('CI_SYNTHETIC: "1"', 'CI_SYNTHETIC: "0"'), validScript, "ci_not_synthetic"],
  ["commented-out invocation", uncommented(validWorkflow).replace(/^/gm, "# "), validScript, "missing_ci_invocation"],
  ["public APK artifact", `${validWorkflow}\n- name: upload\n  uses: actions/upload-artifact@v4\n  with:\n    path: build/app/outputs/flutter-apk/*.apk`, validScript, "public_apk_artifact"],
  ["missing Google Services assertion", validWorkflow, validScript.replace("google_app_id", ""), "missing_google_services_assertion"],
  ["missing notification assertion", validWorkflow, validScript.replace("android.permission.POST_NOTIFICATIONS", ""), "missing_post_notifications_assertion"],
  ["missing INTERNET assertion", validWorkflow, validScript.replace("android.permission.INTERNET", ""), "missing_internet_assertion"],
  ["missing package/version assertion", validWorkflow, validScript.replace("package: name='com.osratech.parent' versionCode=", ""), "missing_package_version_assertion"],
  ["missing signer guard", validWorkflow, validScript.replace("OSRA_EXPECTED_SIGNER_SHA256", ""), "missing_signer_guard"],
  ["missing signer verification", validWorkflow, validScript.replace("verify --print-certs", ""), "missing_signer_verification"],
  ["missing API requirement", validWorkflow, validScript.replace("${API_BASE:?}", ""), "missing_api_base_requirement"],
  ["missing build number requirement", validWorkflow, validScript.replace("${BUILD_NUMBER:?}", ""), "missing_build_number_requirement"],
  ["unconditional real guard", validWorkflow, validScript.replace('if [[ "${CI_SYNTHETIC:-0}" != "1" ]]', "if true"), "real_build_guard_not_conditional"],
  ["inherited signing not cleared", validWorkflow, validScript.replace("unset OSRA_UPLOAD_KEYSTORE", ""), "inherited_signing_not_cleared"],
  ["missing exact digest", validWorkflow, validScript.replace("^[0-9A-Fa-f]{64}$", ""), "missing_exact_digest"],
  ["weak digest comparison", validWorkflow, validScript.replace("grep -Fxi", "grep -qi"), "weak_digest_comparison"],
  ["missing freshness guard", validWorkflow, validScript.replace('rm -f "$VALUES_XML"', ""), "missing_freshness_guard"],
  ["private upload in build script", validWorkflow, `${validScript}\ngh release upload`, "private_upload_in_build_script"],
];

const behavioralCases = [
  ["missing API_BASE", { BUILD_NUMBER: "99" }],
  ["missing BUILD_NUMBER", { API_BASE: "https://api.staging.osratech.com" }],
  ["missing signer digest", { API_BASE: "https://api.staging.osratech.com", BUILD_NUMBER: "99" }],
  ["malformed signer digest", { API_BASE: "https://api.staging.osratech.com", BUILD_NUMBER: "99", OSRA_EXPECTED_SIGNER_SHA256: ".*" }],
];

function runBehavioralSelftests() {
  let passed = 0;
  for (const [name, overrides] of behavioralCases) {
    const env = { ...process.env, ...overrides };
    delete env.CI_SYNTHETIC;
    if (name !== "malformed signer digest") delete env.OSRA_EXPECTED_SIGNER_SHA256;
    const result = spawnSync("bash", [BUILD_SCRIPT], { env, encoding: "utf8" });
    const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;
    if (result.status !== 0 && !output.includes("Parent staging APK verified")) {
      passed += 1;
    } else {
      fail(`${name}: expected non-zero exit and no success line, got status=${result.status}`);
    }
  }
  return passed;
}

function fail(code) {
  console.error(`::error::${code}`);
  process.exitCode = 1;
}

if (process.argv.includes("--selftest")) {
  let passed = 0;
  for (const [name, workflow, script, expected] of cases) {
    const errors = contractErrors(workflow, script);
    if (expected === null ? errors.length === 0 : errors.includes(expected)) {
      passed += 1;
    } else {
      fail(`${name}: expected ${expected ?? "no errors"}, got ${errors.join(",") || "no errors"}`);
    }
  }
  passed += runBehavioralSelftests();
  if (!process.exitCode) console.log(`parent-staging-build selftest: ${passed}/${cases.length + behavioralCases.length} checks pass`);
} else {
  const workflow = fs.existsSync(WORKFLOW) ? fs.readFileSync(WORKFLOW, "utf8") : "";
  const script = fs.existsSync(BUILD_SCRIPT) ? fs.readFileSync(BUILD_SCRIPT, "utf8") : "";
  const errors = contractErrors(workflow, script);
  if (!script) errors.push("missing_build_script");
  if (errors.length) {
    for (const error of errors) fail(error);
  } else {
    console.log("parent staging build contract: OK");
  }
}
