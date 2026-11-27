import fs from "node:fs";
import { spawnSync } from "node:child_process";

const WORKFLOW = ".github/workflows/child-android.yml";
const BUILD_SCRIPT = "scripts/build-child-staging-apk.sh";
const GRADLE_FILE = "apps/child-android/app/build.gradle.kts";

const uncommented = (text) => text.split(/\r?\n/).filter((line) => !/^\s*#/.test(line)).join("\n");
const steps = (workflow) => uncommented(workflow).split(/^\s*- name:/m).slice(1).map((step) => `- name:${step}`);

function contractErrors(workflow, script, gradle) {
  const errors = [];
  const require = (condition, code) => { if (!condition) errors.push(code); };
  const workflowSteps = steps(workflow);
  const invocationIdx = workflowSteps.findIndex((step) => step.includes("scripts/build-child-staging-apk.sh"));
  require(invocationIdx >= 0, "missing_ci_invocation");
  if (invocationIdx >= 0) {
    require(/CI_SYNTHETIC:\s*["']?1["']?/.test(workflowSteps[invocationIdx]), "ci_not_synthetic");
    // No artifact upload may run after the synthetic staging APK step (otherwise a synthetic/staging APK leaks).
    for (const later of workflowSteps.slice(invocationIdx + 1)) {
      require(!later.includes("upload-artifact"), "public_staging_apk_artifact");
    }
  }
  for (const step of workflowSteps.filter((s) => s.includes("upload-artifact"))) {
    require(!/child-.*staging/i.test(step), "public_staging_apk_artifact");
  }

  const active = uncommented(script);
  require(active.includes("assembleFullRelease"), "missing_apk_build");
  require(
    active.includes("google_app_id") && active.includes("gcm_defaultSenderId") && active.includes("project_id") && active.includes("VALUES_XML"),
    "missing_google_services_assertion",
  );
  require(active.includes("string/google_app_id") && active.includes("string/gcm_defaultSenderId"), "missing_packaged_fcm_assertion");
  require(active.includes("android.permission.BIND_NOTIFICATION_LISTENER_SERVICE"), "missing_full_flavor_permission_assertion");
  require(active.includes("android.permission.INTERNET"), "missing_internet_assertion");
  require(active.includes("package: name='com.osratech.child.full' versionCode="), "missing_package_version_assertion");
  require(active.includes("OSRA_EXPECTED_SIGNER_SHA256"), "missing_signer_guard");
  require(active.includes("verify --print-certs"), "missing_signer_verification");
  require(active.includes("${API_BASE:?") || active.includes('[[ -z "${API_BASE:-}" ]]'), "missing_api_base_requirement");
  require(active.includes("${BUILD_NUMBER:?") || active.includes('[[ -z "${BUILD_NUMBER:-}" ]]'), "missing_build_number_requirement");
  require(active.includes('if [[ "${CI_SYNTHETIC:-0}" != "1" ]]'), "real_build_guard_not_conditional");
  require(active.includes("unset OSRA_UPLOAD_KEYSTORE") && active.includes("unset OSRA_FULL_KEYSTORE"), "inherited_signing_not_cleared");
  require(active.includes("^[0-9A-Fa-f]{64}$"), "missing_exact_digest");
  require(active.includes("grep -Fxi"), "weak_digest_comparison");
  require(active.includes('rm -f "$VALUES_XML"'), "missing_freshness_guard");
  require(!active.includes("gh release upload"), "private_upload_in_build_script");

  const activeGradle = gradle.split(/\r?\n/).filter((line) => !/^\s*\/\//.test(line)).join("\n");
  require(
    /\(\s*hasReleaseKey\s*\|\|\s*hasFullKey\s*\)\s*&&\s*!file\("google-services\.json"\)\.exists\(\)/.test(activeGradle),
    "missing_full_key_firebase_guard",
  );
  return errors;
}

const validWorkflow = `
      - name: Prove staging Child Full APK without publishing it
        env:
          CI_SYNTHETIC: "1"
        run: bash ../../scripts/build-child-staging-apk.sh
`;
const validScript = `#!/usr/bin/env bash
: "\${API_BASE:?}" "\${BUILD_NUMBER:?}"
unset OSRA_UPLOAD_KEYSTORE
unset OSRA_FULL_KEYSTORE
if [[ "\${CI_SYNTHETIC:-0}" != "1" ]]; then
  : "\${OSRA_EXPECTED_SIGNER_SHA256:?}"
  [[ "$VALUE" =~ ^[0-9A-Fa-f]{64}$ ]]
  grep -Fxi "digest"
  apksigner verify --print-certs "$APK"
fi
rm -f "$VALUES_XML"
./gradlew assembleFullRelease
google_app_id gcm_defaultSenderId project_id VALUES_XML
string/google_app_id string/gcm_defaultSenderId
android.permission.BIND_NOTIFICATION_LISTENER_SERVICE
android.permission.INTERNET
package: name='com.osratech.child.full' versionCode=
`;
const validGradle = `
if ((hasReleaseKey || hasFullKey) && !file("google-services.json").exists()) {
    throw GradleException("google-services.json is missing")
}
`;

const cases = [
  ["valid contract", validWorkflow, validScript, validGradle, null],
  ["missing invocation", validWorkflow.replace("scripts/build-child-staging-apk.sh", "echo no-op"), validScript, validGradle, "missing_ci_invocation"],
  ["real-only CI inputs", validWorkflow.replace('CI_SYNTHETIC: "1"', 'CI_SYNTHETIC: "0"'), validScript, validGradle, "ci_not_synthetic"],
  ["commented-out invocation", uncommented(validWorkflow).replace(/^/gm, "# "), validScript, validGradle, "missing_ci_invocation"],
  ["public staging APK artifact", `${validWorkflow}\n      - name: upload\n        uses: actions/upload-artifact@v4\n        with:\n          name: child-staging-apk`, validScript, validGradle, "public_staging_apk_artifact"],
  ["missing Google Services assertion", validWorkflow, validScript.replace("project_id", ""), validGradle, "missing_google_services_assertion"],
  ["missing packaged FCM assertion", validWorkflow, validScript.replace("string/google_app_id", ""), validGradle, "missing_packaged_fcm_assertion"],
  ["missing Full permission assertion", validWorkflow, validScript.replace("android.permission.BIND_NOTIFICATION_LISTENER_SERVICE", ""), validGradle, "missing_full_flavor_permission_assertion"],
  ["missing INTERNET assertion", validWorkflow, validScript.replace("android.permission.INTERNET", ""), validGradle, "missing_internet_assertion"],
  ["missing package/version assertion", validWorkflow, validScript.replace("package: name='com.osratech.child.full' versionCode=", ""), validGradle, "missing_package_version_assertion"],
  ["missing signer guard", validWorkflow, validScript.replace("OSRA_EXPECTED_SIGNER_SHA256", ""), validGradle, "missing_signer_guard"],
  ["missing signer verification", validWorkflow, validScript.replace("verify --print-certs", ""), validGradle, "missing_signer_verification"],
  ["missing API requirement", validWorkflow, validScript.replace("${API_BASE:?}", ""), validGradle, "missing_api_base_requirement"],
  ["missing build number requirement", validWorkflow, validScript.replace("${BUILD_NUMBER:?}", ""), validGradle, "missing_build_number_requirement"],
  ["unconditional real guard", validWorkflow, validScript.replace('if [[ "${CI_SYNTHETIC:-0}" != "1" ]]', "if true"), validGradle, "real_build_guard_not_conditional"],
  ["inherited Full signing not cleared", validWorkflow, validScript.replace("unset OSRA_FULL_KEYSTORE", ""), validGradle, "inherited_signing_not_cleared"],
  ["missing exact digest", validWorkflow, validScript.replace("^[0-9A-Fa-f]{64}$", ""), validGradle, "missing_exact_digest"],
  ["weak digest comparison", validWorkflow, validScript.replace("grep -Fxi", "grep -qi"), validGradle, "weak_digest_comparison"],
  ["missing freshness guard", validWorkflow, validScript.replace('rm -f "$VALUES_XML"', ""), validGradle, "missing_freshness_guard"],
  ["private upload in build script", validWorkflow, `${validScript}\ngh release upload`, validGradle, "private_upload_in_build_script"],
  ["missing Full keystore Firebase guard in Gradle", validWorkflow, validScript, validGradle.replace("(hasReleaseKey || hasFullKey)", "hasReleaseKey"), "missing_full_key_firebase_guard"],
];

const behavioralCases = [
  ["missing API_BASE", { BUILD_NUMBER: "99" }],
  ["missing BUILD_NUMBER", { API_BASE: "https://api.staging.osratech.com" }],
  ["wrong API_BASE (production)", { API_BASE: "https://api.osratech.com", BUILD_NUMBER: "99", OSRA_EXPECTED_SIGNER_SHA256: "a".repeat(64) }],
  ["missing signer digest", { API_BASE: "https://api.staging.osratech.com", BUILD_NUMBER: "99" }],
  ["malformed signer digest", { API_BASE: "https://api.staging.osratech.com", BUILD_NUMBER: "99", OSRA_EXPECTED_SIGNER_SHA256: ".*" }],
];

function runBehavioralSelftests() {
  let passed = 0;
  for (const [name, overrides] of behavioralCases) {
    const env = { ...process.env, ...overrides };
    delete env.CI_SYNTHETIC;
    if (name !== "malformed signer digest" && name !== "wrong API_BASE (production)") delete env.OSRA_EXPECTED_SIGNER_SHA256;
    const result = spawnSync("bash", [BUILD_SCRIPT], { env, encoding: "utf8" });
    const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;
    if (result.status !== 0 && !output.includes("Child Full staging APK verified")) {
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
  for (const [name, workflow, script, gradle, expected] of cases) {
    const errors = contractErrors(workflow, script, gradle);
    if (expected === null ? errors.length === 0 : errors.includes(expected)) {
      passed += 1;
    } else {
      fail(`${name}: expected ${expected ?? "no errors"}, got ${errors.join(",") || "no errors"}`);
    }
  }
  passed += runBehavioralSelftests();
  if (!process.exitCode) console.log(`child-staging-build selftest: ${passed}/${cases.length + behavioralCases.length} checks pass`);
} else {
  const workflow = fs.existsSync(WORKFLOW) ? fs.readFileSync(WORKFLOW, "utf8") : "";
  const script = fs.existsSync(BUILD_SCRIPT) ? fs.readFileSync(BUILD_SCRIPT, "utf8") : "";
  const gradle = fs.existsSync(GRADLE_FILE) ? fs.readFileSync(GRADLE_FILE, "utf8") : "";
  const errors = contractErrors(workflow, script, gradle);
  if (!script) errors.push("missing_build_script");
  if (errors.length) {
    for (const error of errors) fail(error);
  } else {
    console.log("child staging build contract: OK");
  }
}
