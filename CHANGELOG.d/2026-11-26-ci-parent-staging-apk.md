### CI — staging Parent APK build proof
- `scripts/build-parent-staging-apk.sh` builds the staging Parent APK and verifies the Firebase release task, package/versionCode, `INTERNET`, `POST_NOTIFICATIONS`, and signer.
- Public CI uses only synthetic Firebase configuration and publishes no APK artifact. The real build reuses the same helper on the approved private channel and requires the Lab Parent certificate digest.
- `scripts/check-parent-staging-build.mjs` adds 19 self-tests and runs in `workflow-lint`; `docs/TESTING.md` documents the synthetic and private procedures. Synthetic builds clear inherited upload-signing inputs, real builds require an exact 64-hex lab digest, and generated Firebase resources must match the input JSON.
