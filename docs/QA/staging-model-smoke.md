# Staging model acceptance

This test exercises roadmap 2.6 on a dedicated staging pairing with synthetic messages in the approved WhatsApp test chat. The Android notification capture, staging scan upload, model response and Parent alert are all part of the test.

## Runtime prerequisites

The staged OSRA-only API allows ten seconds per model request, capped by approval expiry and a shared 25-second inference deadline for a batch. Completed receipts survive when other items time out.

- Use the independently approved staging cut and the private analyzer service. In the staging account, confirm that Frankfurt GPT OSS 20B is available with invocation logging disabled and the approved retention settings. The analyzer uses its task role for that one model.
- The Frankfurt Bedrock Runtime hostname resolves to the restricted interface endpoint throughout the staging VPC while the analyzer is provisioned. Check for other staging callers of that hostname before provisioning.
- Configure `OSRA_DEPLOYMENT_SCOPE`, `OSRA_STAGING_QA_ANALYZER_ENABLED`, `OSRA_STAGING_QA_EXPIRES_AT` and `OSRA_STAGING_QA_FIXTURE_SHA256` in both services. Enable the gate for at most one hour. Use exact SHA-256 digests of the approved post-redaction synthetic fixtures.
- Configure the API's `OSRA_STAGING_QA_DEVICE_ID`, `OSRA_STAGING_QA_CHILD_ID` and `OSRA_STAGING_QA_ANALYZER_URL` through the private staging configuration. Restrict access to the analyzer to the API. Inject the approved prompt privately into `OSRA_STAGING_QA_SYSTEM_PROMPT`; the analyzer checks the pinned digest.
- Verify the Flip4 test-chat capture restriction before enabling the model lane. Use the ordinary pairing, consent and notification listener. Keep content, identifiers and credentials out of shared evidence.

## Pass evidence

1. Send the approved synthetic positive from the test chat with WhatsApp in the background on the Flip4. Wait for the staging scan to be accepted.
2. Find the matching opaque trace. It must show the Frankfurt model, a successful verdict without fallback, and an alert belonging to the same scan. For a model-only positive, confirm the rules did not flag it. Allow for the existing per-app alert throttle before repeating.
3. Open the matching notification on Parent. Check the app, concern and event time, plus the authorized detail or activity view.
4. Repeat with the approved harmless fixture. Confirm the model completed without fallback and that the control created no new alert.
5. Disable the staging QA gate after the run. Report each result with a fixture name, exact build, UAE time and sanitized trace evidence.

If the analyzer returns `model_unavailable`, match the trace to its `failure_kind` in staging logs. The fixed categories distinguish AWS access, provider validation, SDK validation, credentials, transport, throttling, the local deadline, and unusable results. Include the category and timing in the test receipt. Leave message text and provider details out of the receipt.



## Comparing staging providers

Set `OSRA_STAGING_QA_ENGINE` to `bedrock`, `own` or `both`. The staging API requests outcomes by adding
`include_provider_outcomes: true` to the private request. The legacy Bedrock request still returns its
original response in the default mode. Other modes require the caller to read provider outcomes.

Own inference requires the Frankfurt `runtime.sagemaker` private endpoint URL in
`OSRA_STAGING_QA_SAGEMAKER_ENDPOINT_URL`. Set `OSRA_STAGING_QA_V9_MODEL_SHA256`,
`OSRA_STAGING_QA_V9_THRESHOLDS_SHA256` and the corresponding `V9B` values from the verified serving
artifacts. The model pin hashes the loaded weights file. The threshold pin hashes the exact calibration
file loaded for that checkpoint. Model archives and reserialized calibration values have different
digests. Verify the serving manifest at startup, confirm that the endpoint policy and task role restrict
invocation to the two approved checkpoints, and check that SageMaker data capture and container
payload logging are off.

The serving contract accepts UTF-8 JSON containing `text` and `trace_id`. The candidate analyzer first
calls the v9 endpoint. Its handler can score a supported language, or return `trace_id`, `route: "v9b"`
and the detected `language` for Arabic or French. The routed request carries that value as `lang`.
On a scored response the handler returns the trace,
`model`, `language`, `model_sha256`, `thresholds_sha256`, the seven native `probs`, its calibrated
`flagged_categories` and its `verdict` (`safe` or `flagged`). An uncertain v9 result also requires a
verified v9b response tagged `uncertain`. The analyzer takes the higher score for each category and
retains flags supplied by either checkpoint under model `v9+v9b`. Confirm this handshake with the serving
operator using a synthetic fixture on the private endpoint before enabling the run.

In the staging response, `outcomes` contains exactly the selected providers. A scored result includes
the actual model, native probabilities, explicit flagged categories, severity and a boolean flag. OSRA
returns its serving language. Its calibrated flags carry warning severity; the original Bedrock severity
function determines Bedrock flags. A failed provider returns `status: "unavailable"` and a bounded reason
only. Both providers share a two-second processing deadline, shortened when test approval expires.
For the live receipt, count a benign result only when a provider completed. Check both scoring orders,
one failed peer and the effect on the single Parent alert. Keep per-scan evidence in private staging
through the approved wipe.

For the in-process staging CPU service (#1015), set `OSRA_STAGING_QA_OWN_MODEL_ENABLED=1`
in the analyzer and select `own` as the engine. The analyzer calls the CPU route in the same
process, checks its trace and Frankfurt region, then verifies the actual language, checkpoint and
calibrated flags. For each model, pin the SHA-256 of the model weights and the serving configuration
that the CPU service actually loads. The standalone calibration file has a different digest.
If the CPU service is absent, fails, or returns a mismatched receipt, the result is unavailable.
Leaving the CPU selector unset or setting it to `0` selects the existing hosted OSRA path.

For the staging OSRA-only run, the CPU call has eight seconds, the collector nine and the API request ten. The approval expiry can shorten any call. Bedrock and parallel comparison retain their two-second collector deadline.
