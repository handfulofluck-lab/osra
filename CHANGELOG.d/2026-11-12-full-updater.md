### Full — the sideloaded build updates itself, and refuses anything that is not ours (ADR-0039 D5, plan 5.10 PR B)
- **Before:** a family that installed Full from the page stayed on the version they first installed. No update
  path existed at all, so a security fix could not reach them — the one consequence ADR-0039 called out as
  fatal to the whole download idea.
- **After:** Full checks `https://osratech.com/android/latest.json` every 12 hours, once at boot and once
  after pairing. It installs a new build only when a detached **Ed25519 signature over the exact bytes** of the
  manifest verifies against one of two compiled-in keys (`m1` primary, `m2` offline backup), the manifest names
  its `keyId`, the package is ours, the `versionCode` is higher than the installed one, it is not below the
  highest `versionCode`/`releasedAt` this phone has ever accepted, it is not past `expiresAt`, and the APK is
  on `https://osratech.com/android/` — checked by URL component, not by prefix, with redirects refused on the
  client. The APK is hashed **while the same bytes stream into the open `PackageInstaller` session**; the
  session is committed only if size and SHA-256 match and the archive is signed by our own certificate.
- **Play is untouched, and by name:** `REQUEST_INSTALL_PACKAGES` is declared in `app/src/full/AndroidManifest.xml`
  only, `PlayManifestPolicy` denies it for the store build, and the built artefacts prove the split —
  `aapt2 dump permissions` prints **0** for `app-play-debug.apk` and **1** for `app-full-debug.apk`.
- **The trust core is pure JVM**, with no `android.*` imports, so all 28 refusals are ordinary unit tests, and a
  source test pins that `PackageInstaller` is named in exactly one class (`FullUpdater`). No server command,
  push, intent or deep link can start an install.
- **The boundary is the compiler, not R8.** The updater and its trust core live in `app/src/full/` (ADR-0039 D5
  says "Full only (`src/full/`)") and its rows in `app/src/testFull/`, with Tink 1.24.0 as a
  `fullImplementation`: the Play variant compiles none of the updater, has none of those rows, and cannot
  compile a `main` line that names it. `UpdateCheckScheduler` stays in `main` for the four `main` callers;
  that one seam is the whole exception. (Play still resolves `tink-android:1.8.0` through
  `androidx.security:security-crypto` for `SecureStore` — pre-existing, and not the updater's verifier.)
- **Ahmed's two security findings on #615, each with a row that bites.** **R1** — the rotation check compared
  the archive's *current* signers with the installed app's certificates, so the very `old -> new` rotation
  the check exists to allow was refused as `foreign_signer`; it now walks the platform's signed
  `signingCertificateHistory` (`FullUpdatePolicy.checkArchiveSigners`), and `sameSignerIsAccepted`,
  `rotatedSignerStillAccepted` and `foreignSignerIsRefused` pin the three cases, with
  `FullUpdaterSignerSourceTest` pinning that the adapter really reads the lineage. **R2** — the
  install-confirmation intent from the status broadcast is resolved with `MATCH_SYSTEM_ONLY` and started only
  when it lands on a system-image package (`FullUpdatePolicy.confirmationTargetIsSystemInstaller`);
  otherwise `update_refused:untrusted_confirm_intent`.
- **What this does not promise (stated, not hidden):** the two manifest keys still ship as **placeholders**
  until the maintainer pastes the real base64 values into `FullUpdateKeys`; until then every check refuses
  `manifest_key_unavailable`, which is the fail-closed direction. Ed25519 verification is Google **Tink**
  (`com.google.crypto.tink:tink-android`, pinned exactly) on **every API level**, so the API<33 provider gap
  is closed by one code path and the 28 JVM rows exercise the verifier that actually ships — a phone on
  Android 8–12 no longer refuses for want of a provider. And because the first Full install comes from a
  browser, Android makes the **first** update ask the child; `setRequestUpdateOwnership(true)` on Android 14+
  is what makes later ones silent.
- **Also here:** D5.8's `install_updates` capability row and D5.6's "update pending/required" on the parent are
  **not** in this change; they need the capability report and a server-side poller, and are their own rows.
