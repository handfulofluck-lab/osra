# Staging model acceptance

This test exercises roadmap 2.6 on a dedicated staging pairing with synthetic messages in the approved WhatsApp test chat. The Android notification capture, staging scan upload, model response and Parent alert are all part of the test.

## Runtime prerequisites

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


## Comparing staging providers

Set `OSRA_STAGING_QA_ENGINE` to `bedrock`, `own` or `both`. The staging API requests outcomes by adding
`include_provider_outcomes: true` to the private request. The legacy Bedrock request still returns its
original response in the default mode. Other modes require the caller to read provider outcomes.

Own inference requires the Frankfurt `runtime.sagemaker` private endpoint URL in
`OSRA_STAGING_QA_SAGEMAKER_ENDPOINT_URL`. Set `OSRA_STAGING_QA_V9_MODEL_SHA256`,
`OSRA_STAGING_QA_V9_THRESHOLDS_SHA256` and the corresponding `V9B` values from the verified serving
artifacts. The model pin refers to the weights reported by inference. The threshold pin refers to the
calibration actually used. Verify that the endpoint policy and task role restrict invocation to the two
approved staging checkpoints, and confirm that SageMaker data capture and container payload logging are off.

The serving contract accepts UTF-8 JSON containing `text` and `trace_id`. The candidate analyzer first
calls the v9 endpoint. Its handler can score a supported language, or return `trace_id`, `route: "v9b"`
and the detected `language` for Arabic or French. On a scored response the handler returns the trace,
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
