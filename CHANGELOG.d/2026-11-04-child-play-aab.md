### CI — the child agent's Play build is also made as an app bundle (5.2)
- `child-android.yml` runs `bundlePlayRelease` and uploads `app-play-release.aab` as the
  `child-android-play-release-aab` artifact, because Google Play takes bundles, not APKs. Only the play
  flavour is bundled; the full build stays sideloaded (ADR-0021).
- It is signed with the Play upload key now held in the `OSRA_UPLOAD_*` secrets (set 2026-11-04), and the
  job fails if the bundle is missing.
