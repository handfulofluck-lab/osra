### CI — the child agent's Play bundle must be signed with the upload key (5.2)
- `child-android.yml` reads the signer of `app-play-release.aab` with `keytool -printcert -jarfile`. When
  the upload-key secret exists, the job fails unless the signer is `CN=OSRA Upload Key`. Without it, the job
  warns that the bundle is debug-signed and that Play will refuse it. A bundle with no signature fails.
- Raised by Kimi in the #534 review: until now, a green job could hand over a bundle Play refuses.
