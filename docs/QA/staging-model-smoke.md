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

The staged OSRA-only API allows ten seconds per model request, capped by approval expiry and a shared 25-second inference deadline for a batch. Completed receipts survive when other items time out.
