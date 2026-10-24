# Releasing OSRA

The release runbook: from the build a tester sideloads to the build a store accepts. It is written for
the release owner named in [`../AGENTS.md`](../AGENTS.md) §1 (Kimi Code under the split of 2026-10-17).

This page does not restate what other documents own. Roles are `AGENTS.md` §1; the gates and how to run
them are [`TESTING.md`](TESTING.md) §3–§4; the store checklist with its per-row owner is
[`test-guides/PUBLISHING-READINESS.md`](test-guides/PUBLISHING-READINESS.md); the secrets are
[`test-guides/CI-SECRETS.md`](test-guides/CI-SECRETS.md). Copies drift, so this page points.

**The rule this page exists to enforce.** A release is a claim that a specific set of bits, built from a
specific tree, passed gates run by someone other than the author of the change (`AGENTS.md` §6.5.2).
The release owner may merge and may release, but may not be the only verifier of what is being released.
Every step below either produces that evidence or cites it. Where a step cannot be done, the release
does not proceed quietly: the gap goes into the release record (R5) and the human decides
(`AGENTS.md` §6.5).

## 1. What counts as a release

| Kind | Artifact | Reaches | Authorised by | Evidence before it ships |
|---|---|---|---|---|
| **Test build** | release APK/AAB, published Windows exe | `dist/`, testers' hands | release owner | another lane's gate run on the branch; a hardware row if a platform claim changed |
| **Pilot track** | AAB signed with the upload key | Play internal/closed testing | maintainer (Play account) | test-build evidence, plus every Play row in `test-guides/PUBLISHING-READINESS.md` that can be closed without the account |
| **Store release** | AAB (Play), signed installer (Windows), TestFlight build (iOS) | production | maintainer | every row in `test-guides/PUBLISHING-READINESS.md` green, and a store-review pass |
| **Backend release** | container image + migrations | wherever the API is hosted | release owner, unless it is a new paid host | gates on the release commit, a migration rehearsal on a zero-migrated database |
| **Hotfix** | any of the above | same | same as the kind it fixes | the same evidence, on a shorter clock (§7) |

Two things are deliberately *not* releases, because calling them one is how an unverified build reaches a
tester:

- **A merge to `main`.** A merge is a claim that the branch passed its gates with a verification record
  (`AGENTS.md` §6.5), but it is not a build and has no artifact.
- **A green CI run.** CI compiles and unit-tests; it does not verify a claim on hardware, and it will
  happily produce a release build signed with a debug key (§8). CI is the floor, not the record.

## 2. Entry criteria

Do not start until all of these hold. Each is checkable, and each has failed here at least once.

| # | Criterion | Where it comes from |
|---|---|---|
| E1 | `main` is the intended commit and its CI is green. `ci.yml` and `workflow-lint` run on every push; since #352 each suite (`api`, `parent-app`, `child-android`, `agent-desktop`, `ai-engine`) runs only when its own files change, plus nightly on `main`, so a suite the release commit did not touch has no run *of that commit*. Start it with `workflow_dispatch` on the release commit rather than reading an older green. **`ios-ci` runs only when `apps/child-ios/**` changes** and has no nightly (path filter, `.github/workflows/ios-ci.yml:4-7`), so a release that did not touch iOS says "iOS not built" rather than inheriting an old green. A rejected workflow file means *zero* jobs ran, so an absent check is not a green one | `.github/workflows/ci.yml`, the five suite workflows, `workflow-lint.yml`, `main-guard.yml` |
| E2 | Every change since the last release carries a verification record from another lane, cited in its merge message | `AGENTS.md` §6.5.3 |
| E3 | Each platform being shipped has a hardware row on a build of that branch — the handset is leased, so the run is booked, not assumed | `AGENTS.md` §6.5.2, `TESTING.md` §5 |
| E4 | `CHANGELOG.md` `[Unreleased]` describes everything user-visible, with the unverified parts marked as such | `AGENTS.md` §8 |
| E5 | Signing material is present for every platform in the release, or the release is explicitly a debug-signed test build | `test-guides/CI-SECRETS.md` |
| E6 | No open `needs-human` item scopes this release (an entitlement, an account, a spend) | `AGENTS.md` §6.3 |

E2 is the one that gets skipped under time pressure, because the work is already merged and feels done.
It is also the one that makes the release record (R5) assemblable at all: if the merge messages do not
name a verifier and a `TR-*` row, the release has no evidence to cite and E2 fails.

## 3. The version, and where it lives

The version number labels the artifact. The dated heading in `CHANGELOG.md` labels the *release*
(`CHANGELOG.md:504`, `:547`, `:583`, `:613`); they are not the same thing and neither replaces the other.

| Carrier | Line | Notes |
|---|---|---|
| Android child agent `versionCode` | `apps/child-android/app/build.gradle.kts:29` | Play's monotonic counter; must increase on every upload, forever |
| Android child agent `versionName` | `apps/child-android/app/build.gradle.kts:30` | human label, currently `0.2.0` |
| Parent app version | `apps/parent-app/pubspec.yaml:3` | `0.1.0` today, with **no `+<build>` suffix** — and `apps/parent-app/android/app/build.gradle.kts:40` takes `versionCode` from it, so a second upload would reuse versionCode 1 and Play would refuse it. The release bump adds `+<n>` |
| JS workspace | `package.json:4`, `services/api/package.json:3` | both `0.1.0`; set together |
| Windows agent | `apps/agent-desktop/FamilyShield.Agent.csproj:2-11` | **no `<Version>`** today, so every build reports the SDK default and two builds are indistinguishable. A Windows release sets it or the record says "unversioned" |
| iOS agent | `apps/child-ios/Package.swift` | a SwiftPM package with no bundle version; there is no distributable iOS build yet (`docs/ROADMAP.md` 5.1, 5.6) |

Rules, each with the failure it prevents:

- **All carriers move in one commit.** A version bumped inside a feature PR means the release commit's
  version was never built or gated, and the artifact everyone tested carries a different number.
- **`versionCode` increases by one per published build, including rebuilds of the same version.** Two
  binaries with the same code make every bug report ambiguous and every store upload a rejection.
- **`git tag --list` is empty on 2026-10-17** — no release has ever been tagged, so the first release
  sets the convention: an annotated `v<version>` tag (e.g. `v0.3.0`) on the commit that contains its own
  release record (R5, R7). Tags are not branches: the pre-push hook only refuses `refs/heads/main`
  (`.githooks/pre-push:51`), so a tag push passes and is intended to.
- **Never put the tag name in the `CHANGELOG.md` heading.** The heading is committed before the tag
  exists; a heading that cites a tag created afterwards is false in the tree that carries it.

## 4. The runbook

Steps R1–R9. R1 freezes `main`; R2–R5 happen on the release branch; R6–R7 are the merge and the tag;
R8–R9 are distribution and closing. Stop at the first step that cannot be completed and say so in the PR
— the stopping is the process working.

### R1 — Freeze `main`

Announce the freeze in the Messages section of [`QA/TEST-REQUESTS.md`](QA/TEST-REQUESTS.md) with the
intended commit and the window. During the freeze only the release PR merges. The reason is mechanical,
not ceremonial: R3 builds from a tree, and if `main` moves after the build, the tree that was tested is
no longer the tree that ships.

Record the tree you are freezing:

```bash
git rev-parse main^{tree}          # the value the release record cites (R5)
git rev-parse --short main         # for the announcement only; the merge commit is a new sha
```

### R2 — Bump the version and promote the changelog

One branch, one commit, named `release/<version>`. That name follows the pattern in `AGENTS.md` §6, whose
list currently names only `qa/`, `fix/` and `feat/` — the release lane adds it, and §6 should name it too
so the next reader does not invent a fourth form. Content:

0. **Assemble the fragments first.** Entries are written as `CHANGELOG.d/<date>-<slug>.md` (see
   `CHANGELOG.d/README.md`); nothing else moves them into `CHANGELOG.md`.

   ```bash
   node scripts/assemble-changelog.mjs --check   # must exit 0: no fragment left unassembled
   node scripts/assemble-changelog.mjs           # insert them under [Unreleased], delete the files
   ```

   This is the step that makes "nobody forgets the changelog" true: a fragment still sitting in
   `CHANGELOG.d/` at release time is an entry that would ship unannounced, and `--check` says so.
1. Every carrier in §3.
2. `CHANGELOG.md:12` — insert a dated heading `## [YYYY-MM-DD] — <one-line summary>` above the existing
   `## [Unreleased]`, keeping `[Unreleased]` in place for the next cycle. Move the entries under it. Do
   not rewrite entries; a correction is a new line, and an unverified claim gets its qualifier before it
   ships (`AGENTS.md` §8).
3. Nothing else. A release commit that also fixes a bug is a bug fix nobody verified as part of the
   release.

### R3 — Build from a clean tree

Build the release commit, not the working tree and not a warm `build/` directory. Cleared outputs are one
of the environment axes in [`QA/TESTING-STRATEGY.md`](QA/TESTING-STRATEGY.md) §2 because "it works
because my output was already warm" is a recorded failure mode here
([`test-guides/HANDOFF-FOR-TESTING.md`](test-guides/HANDOFF-FOR-TESTING.md):23 — a stale AOT snapshot).

```bash
git status --short                 # must be empty
git rev-parse HEAD

# Android child agent (release APK: minified, resource-shrunk, HTTPS-only)
cd apps/child-android
./gradlew --stop
rm -rf app/build/intermediates app/build/outputs/apk/*/release app/build/generated
ANDROID_HOME=/c/KARIM/tools/android-sdk ./gradlew assemblePlayRelease assembleFullRelease --console=plain

# Parent app (AAB)
cd ../../apps/parent-app
flutter clean && flutter pub get && flutter build appbundle --release

# Windows agent: keep the flags the previous bundle used. A switch between framework-dependent and
# self-contained is user-visible (a tester without .NET 8 either can or cannot run it), so it is a
# release decision, not a build detail.
cd ../agent-desktop
dotnet publish -c Release -o <output-dir>
```

The Gradle delete-and-rebuild is not superstition: this host has produced
`Unable to delete directory …build…` and `AccessDenied` on intermediates, and the recovery is exactly that
clean sequence (`test-guides/HANDOFF-FOR-TESTING.md`:24).

For the backend, the image is built from the **repository root** — the API's `workspace:*` dependencies
resolve only with the root lockfile and `pnpm-workspace.yaml`. This replaced a Dockerfile built from the
`services/api` context whose install and build both ended in `|| true`, so a broken image reported success;
there is no `|| true` in the current one, and CI builds the image on every pull request
(`.github/workflows/api-image.yml`).

```bash
pnpm --filter @familyshield/api run build                          # type-check the same command the image runs
docker build -f services/api/Dockerfile -t osra-api:<version> .    # context: repo root
sh services/api/scripts/verify-image.sh                            # node, prisma CLI, entry file
```

Publishing to ECR is the workflow, not a local `docker buildx … --push`.
`.github/workflows/api-publish.yml` builds linux/arm64 on GitHub's arm64 runner and pushes
`<repo>:<12-character sha>` through a role assumed over GitHub's OIDC token, so no
AWS key lives in Actions ([`infra/terraform/README.md`](../infra/terraform/README.md#publishing-the-image),
ADR-0028 §8). It is `workflow_dispatch` only and refuses to run outside `handfulofluck-lab/osra`:

```bash
gh workflow run api-publish.yml      # run from main; the image is tagged with that commit's sha
```

Record the pushed digest in R5 and put `<repo>:<12-character sha>` into
`env/api_image`. **Docker is not installed on the maintainer's PC**, so the local `docker build` path is
unverified there; the `API image` CI job is the build gate for both. The local command remains the
fallback for a host with Docker and an AWS credential source:

```bash
REPO="$(terraform -chdir=infra/terraform/base output -raw ecr_repository_url)"
aws ecr get-login-password --region eu-north-1   | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.eu-north-1.amazonaws.com"
docker buildx build --platform linux/arm64 -f services/api/Dockerfile --tag "${REPO}:${SHA}" --push .
```

Migrations move with the API, never before it and never by hand: apply `prisma migrate deploy` and run
`prisma generate` as a separate step (a `migrate deploy` without `generate` is issue #47), then record the
head. Note the obvious trap in the obvious command — `ls … | tail -1` returns `migration_lock.toml`, not a
migration:

```bash
ls -d services/api/prisma/migrations/0* | sort | tail -1    # 0013_usage_model (13 migrations, 2026-10-17)
```

### R4 — Prove the artifacts

The build is not the artifact's evidence; these checks are. They are the same checks CI runs, repeated
here because a release artifact does not always come from CI (its artifacts expire after 14 days,
`.github/workflows/child-android.yml:102`, `parent-app.yml:83`).

```bash
export ANDROID_HOME=/c/KARIM/tools/android-sdk
BT=$(ls -d "$ANDROID_HOME"/build-tools/* | sort -V | tail -1)   # newest build-tools, as child-android.yml:78 does
FLAVOUR=play    # then again with FLAVOUR=full: both are release artifacts (ADR-0016)
APK=apps/child-android/app/build/outputs/apk/$FLAVOUR/release/app-$FLAVOUR-release.apk

"$BT/aapt2.exe"     dump badging "$APK" | head -3             # versionCode, versionName, minSdk
"$BT/aapt2.exe"     dump badging "$APK" | grep targetSdkVersion
"$BT/apksigner.bat" verify --verbose --print-certs "$APK"     # v2/v3 scheme, signer DN, SHA-256
sha256sum "$APK"
```

Read the output, do not skim it:

| Check | Passes when | If it fails |
|---|---|---|
| Signer DN | not `CN=Android Debug` | stop: the build is not shippable (see below) |
| `versionCode` / `versionName` | equal to the bump in R2 | the artifact is stale, or the bump missed a carrier (§3) |
| `targetSdkVersion` | `35` | `apps/child-android/app/build.gradle.kts:43` regressed (CI's step fails on it since #361) |
| Signature scheme | v2 **and** v3 verified (Play requires at least v2 for `targetSdk` 35) | the APK is signed with a scheme Play will reject — a debug-key fallback is *not* caught here, which is why the signer row comes first |
| AAB manifest | carries `android.permission.INTERNET` (`.github/workflows/parent-app.yml:74-78`) | the parent build is broken in the way Phase 0 already fixed once |

The debug-key case is the one that costs a release: both Android builds silently fall back to the debug
key when the keystore variables are absent (`apps/child-android/app/build.gradle.kts:79`,
`apps/parent-app/android/app/build.gradle.kts:61`), the APK installs, pairs and enforces rules exactly
like the real one, and the store rejects it — or worse, accepts it and the app's update path is now bound
to a key somebody will lose. The comment at `apps/parent-app/android/app/build.gradle.kts:60` claims "CI
fails the release job if the upload key is missing"; it does not (`.github/workflows/parent-app.yml:60-62` tolerates
it by design). That comment is a gate that looks present and does nothing, so this check is manual until
someone makes CI fail instead.

For the AAB there is no local equivalent of `apksigner verify`: Play signs with the app-signing key after
upload. What is checkable is which key signed the *upload* — record the upload certificate's SHA-256 once
with `keytool -list -v -keystore <upload.jks> -alias upload` and compare it on every release, and confirm
the build log shows the keystore was materialised (`.github/workflows/parent-app.yml:56-66`).

### R5 — Write the release record

`docs/releases/<version>-<date>.md`, one file per release, committed in the release PR. It is the document
the next reader opens when a tester reports a bug against "0.3.0", and the only place that ties a version
to a tree, a set of hashes and a set of gate numbers.

```markdown
# OSRA <version> — <date>

- **Status:** released | pilot | withdrawn (append a dated section, never edit this line away)
- **Tag:** `v<version>` (created in R7) · **Tree:** `<git rev-parse HEAD^{tree}>` on the release branch
- **Release owner:** <name> · **Authorised by:** <maintainer, for anything with an account or a spend>

## Artifacts

| Artifact | sha256 | Signer | Built on |
|---|---|---|---|
| `app-play-release.apk` (child, store) | `…` | SHA-256 of the upload cert | <host, toolchain versions> |
| `app-full-release.apk` (child, sideloaded) | `…` | same upload cert | |
| `app-release.aab` (parent) | `…` | same upload cert | |
| `OSRA.Agent.exe` | `…` | unsigned (Phase 5.4) | |

## Gates

| Gate | Result | Run by |
|---|---|---|
| `qa-probe` | … passed / … failed / … targets | <agent> (not the author) |
| `e2e` | …/… | |
| platform suites | | |
| hardware rows | TR-… on <device>, <date> | |

## Verification cited

- TR-… (PR #…) — what it measured.
- Merge messages this release relies on, each with its `verified by … TR-…` line.

## Migrations

Head: `<migration id>`; applied with `prisma migrate deploy` + `prisma generate`.

## Not verified in this release

State the gap and why. "iOS not built here (no Mac)", "Windows artifact unsigned", "no hardware row on
Android 13" are acceptable entries. An empty section is a claim, and it needs to be true.

## Post-release

Appended in R9: tag → commit, smoke numbers, watch-window outcome.
```

Two rules about this file, taken from the conventions in the documentation index,
[`docs/README.md`](README.md):

- **Append, never rewrite.** A correction after publication is a new dated section. The record's job is
  to say what was believed and what was measured, and rewriting it destroys exactly that.
- **Cite the tree, and the merge commit.** PRs land as true merge commits — `git rev-list --parents -n1`
  on a `(#NN)` commit on `main` shows two parents, the second being the branch head — so the sha a gate
  run cites stays reachable, but the commit sitting on `main` is a new one, and a record that cites only
  the branch sha sends the next reader to a branch that will be deleted. `AGENTS.md` §6.5.4 wants the
  verified sha to be the merged sha; check it as tree equality
  (`git rev-parse <merge-commit>^{tree}` equals `git rev-parse <verified-branch-sha>^{tree}` when the
  branch contains `main`), and record the value in `Tree:` so R7 can check the tag against it.

### R6 — Merge with its verification line

The release PR is a docs-plus-version change, so it is verified proportionally: the verifier reads the
diff line by line and confirms every cited `file:line` says what the text claims (`AGENTS.md` §6.5,
docs-only paragraph). The merge message then carries the line the next reader needs:

```
Merge #NNN — release <version>; verified by Antigravity, TR-NN (record read line by line at <branch sha>,
probe 109/0 · e2e 69/69 · hardware TR-14)
```

If `main` moved during the freeze, merge it into the branch first and have the gates re-run; the numbers
belong to the tree that lands.

### R7 — Tag

After the merge, on `main`:

```bash
git rev-parse main^{tree}                    # must equal the record's Tree: line
git tag -a v<version> -m "OSRA <version> — release record docs/releases/<version>-<date>.md"
git push origin v<version>
git rev-parse "v<version>^{commit}"          # goes into the record's Post-release section (R9)
```

The order is the point: the tag is created *after* the record is on `main`, so the tagged tree contains
the account of itself. A tag created first points at a tree whose record does not exist yet, and every
link in the record then resolves to a commit that does not contain it.

Pushing a tag is not pushing `main`; the hook allows it, and `main-guard.yml` only watches
`refs/heads/main`. Do not move or delete a published tag (§6).

### R8 — Distribute

**Test build.** Copy into `dist/` under the existing names — `OSRA-Parent.apk`, `OSRA-ChildAgent.apk`,
`OSRA-Agent-Windows/` — because the tester guides point at those names
([`test-guides/HANDOFF-FOR-TESTING.md`](test-guides/HANDOFF-FOR-TESTING.md):53-57). `dist/` is gitignored
on purpose (`.gitignore:9-10`, `AGENTS.md` §4): binaries never enter the repository, so the record's
sha256 is the only way to identify a build afterwards. Add a dated line to the handoff with the build
time and hash, and update what the release contains in
[`test-guides/README-TESTERS.md`](test-guides/README-TESTERS.md). The same filename with new contents is
how a tester ends up testing last month's build: the hash, not the filename, is the identity.

**Pilot or store.** The maintainer uploads (`AGENTS.md` §1): no agent touches a Play Console or App Store
Connect account. One upload format per track — an APK and an AAB signed differently on the same track
produces install conflicts for testers. State in the upload notes what is deliberately unsupported, from
the record's "Not verified" section.

**Windows.** Until the code-signing certificate exists (Phase 5.4,
`test-guides/PUBLISHING-READINESS.md`:45), the exe is unsigned and SmartScreen will warn. Say so in the
tester note rather than letting the warning read as tampering.

**iOS.** There is nothing to distribute: no distribution entitlement, no Xcode project, no TestFlight
build (`docs/ROADMAP.md` 5.1, 5.6). A release note that implies otherwise is a documentation bug.

### R9 — Close the release

1. **Post-release smoke, run by the testing lane**, on the tag: probe and e2e against a zero-migrated,
   non-UTC database, the pattern of TR-03/TR-08. The release owner already ran the release gates; the
   point of this row is that someone else runs them on what shipped.
2. **Hygiene** (`AGENTS.md` §7): device uninstalled and forwards removed, test rows deleted, Redis keys
   accounted for — with the command output in the run log, not a sentence saying it was done.
3. **Record post-release section**: tag → commit, smoke numbers, and the watch-window outcome below.
4. **Update the status surfaces** that make claims about the product: the progress table in
   [`ROADMAP.md`](ROADMAP.md), and the suite/status table in `README.md:112-120` if the numbers moved.
5. **Watch window: 24 hours.** `device_silent` alerts, a `tamper` spike, `/health/deep` and the API error
   rate. The release is not closed until the window is, and anything found inside it is a finding, not a
   follow-up.

## 5. Signing material and key custody

- **Upload keystore** (`upload.jks`): supplied as `OSRA_UPLOAD_KEYSTORE_B64` plus the three password/alias
  secrets (`test-guides/CI-SECRETS.md`:10-11), materialised by CI into `android/upload.jks` or
  `app/upload.jks` (`.github/workflows/parent-app.yml:56-66`, `child-android.yml:45-55`). Never in the repository, never in
  `dist/`.
- **Two keys, two fates.** The *upload* key can be reset through Play if it is lost; the *app signing* key,
  once Play App Signing holds it, cannot be recovered by us and cannot be replaced without a new app
  listing. Before the first upload, the keystore and its passwords exist in at least two offline copies
  held by the maintainer. A secret that lives only in GitHub Actions is one lost account away from being
  gone.
- **AWS deploy key (temporary).** The `osra-staging-deployer` IAM access key (ADR-0028 §8, #258) lives
  only in `~/.aws/credentials` on the maintainer's PC under the `osra-staging` profile. IAM keys do not
  expire on their own: **delete it on 2026-11-05 or when the staging stack is up, whichever is first**
  (`aws iam list-access-keys --user-name osra-staging-deployer` must then return none). No release that
  deploys to AWS is cut while this key still exists past that date.
- **Who may touch what.** Accounts, entitlements, key purchases and API keys are the maintainer's
  (`AGENTS.md` §1). The release owner prepares the artifact and the instructions; the human authorises
  and performs the account action.
- **What a missing key looks like.** Not an error: a debug-signed build that installs and runs (R4). That
  is why R4 reads the signer DN instead of trusting the build log.

## 6. Withdrawal and rollback

A release found to break a documented invariant is **withdrawn**, not quietly patched. The distinction
matters because testers and store users already have the bits.

- **Never move or delete a published tag.** Tag a new release. The old tag plus its record is the only
  honest account of what was shipped; deleting it deletes the evidence.
- **Never re-upload a different binary under the same version or versionCode.** Android will not tell a
  user which build they have; the version number is the only handle, and a reused one breaks it.
- **Code**: revert through a PR, gates re-run on the reverted tree, cited in the merge message
  (`AGENTS.md` §6.5, revert paragraph). A revert is cheaper to verify, not exempt.
- **Play**: a production release cannot be unpublished. Halt the staged rollout, ship a higher
  `versionCode` with the fix, and state in the listing/release notes what was wrong — users who already
  updated are not helped by silence.
- **Test builds**: publish a new build, announce it in the board message and the record, and ask testers to
  reinstall rather than assume an install-in-place.
- **Record**: a dated `## Withdrawn <date>` section at the top of the record with the reason, the affected
  artifact hashes, and what replaced it. `CHANGELOG.md` gets the same fact.

## 7. Hotfix

Same branch rules (`AGENTS.md` §6), same gates (`AGENTS.md` §3), same separation: another lane runs the
gates, the merge message cites it, and the record gets a dated addendum rather than a new version's
history being rewritten. The shortcuts a hotfix may take are scope ones — one fix, no refactor, no
bundled dependency bump, no "while I was in there" — never evidence ones. Version: patch bump plus a new
`versionCode`, even if the previous build shipped an hour ago.

If the fix cannot be verified in the time available, the honest release is the withdrawal (§6), not an
unverified build with a reassuring note.

## 8. Traps that have cost time, or would have

| Trap | What it looks like | Caught by |
|---|---|---|
| Debug-signed "release" | build succeeds, APK installs and enforces rules; signer is `CN=Android Debug` (`apps/child-android/app/build.gradle.kts:79`, `apps/parent-app/android/app/build.gradle.kts:61`) | R4 signer DN |
| Stale artifact under a familiar name | the shipped test bundle `dist/OSRA-ChildAgent.apk` is debug-signed and reports `versionCode='1' versionName='0.1.0'`, `targetSdkVersion:'34'`, while source declares 2 / 0.2.0 / 35 (`apps/child-android/app/build.gradle.kts:43-45`) — measured 2026-10-17 | R4 version checks |
| A comment promising a check | `apps/parent-app/android/app/build.gradle.kts:60` says CI fails when the upload key is missing; `.github/workflows/parent-app.yml:60-62` tolerates it by design | R4, done by hand until CI is changed |
| CI artifacts expire | `retention-days: 14` (`.github/workflows/child-android.yml:102`, `parent-app.yml:83`), so a release cannot be assembled from an old run | R3 build from the release commit |
| Image built from a failed build | the old `services/api` Dockerfile ended its install and build in `|| true`, so a broken image reported success; the current one has none and CI builds it on every pull request (R3) | R3 build outside the image |
| Version bump inside a feature PR | the release commit's version was never built; two artifacts claim the same version | §3, one commit for all carriers |
| Parent app reuses `versionCode` | `apps/parent-app/pubspec.yaml:3` has no `+<build>`, so `flutter.versionCode` (`apps/parent-app/android/app/build.gradle.kts:40`) falls back to 1 and Play rejects the second upload | R4 `aapt2 dump badging` |
| Green probe in UTC | time-zone bugs pass when every component sits in UTC (issue #53, `TESTING.md` §6) | R9 smoke on a non-UTC database |
| `migrate deploy` without `generate` | the API starts against a client that does not know the new columns (issue #47) | R3 migration step |
| Workflow rejected by GitHub | zero jobs run, the run is named after the file; `secrets` in an `if:` is the classic (`TESTING.md` §6) | E1 plus `node scripts/check-workflows.mjs --strict` |
| A CI check that passes without checking | `grep -q … && echo …` on a line that is not the step's last: bash `-e` ignores a failure in an `&&` list, and the step read an APK path that no longer existed after the flavours landed, so a release APK targeting 34 passed `child-android` (#361) | `check-workflows.mjs --strict` warns on the pattern; read the step's own output lines (`play release: targetSdk 35`, `full release: targetSdk 35`) |
| Warm build output | the parent APK once reused a stale AOT snapshot (`test-guides/HANDOFF-FOR-TESTING.md`:23) | R3 clean sequence |
| Tag before the record | the tag points at a tree where the record's own path does not exist, so its citations resolve against a commit that has nothing to show | R7 order |
| Git Bash on Windows | `apksigner`/`aapt2` are `.bat`/`.exe`; calling the bare names fails or picks an unexpected copy | the `$BT` path in R4 |

## 9. Decisions recorded as open

None of these blocks the next test build. Each blocks a first *store* release, and each is a decision for
the lead or the maintainer, recorded here rather than rediscovered at the console.

1. **Tag convention.** No tags exist. This page assumes annotated `v<version>` tags created by the release
   owner. If signed tags are wanted, that needs a key decision and a line here.
2. **Where artifacts live.** `dist/` is local and gitignored. There is no release hosting: a record's
   sha256 identifies a build but does not let anyone fetch it a month later. A release page or an object
   store is the maintainer's call, because it needs an account.
3. **The upload keystore** has not been issued (`test-guides/PUBLISHING-READINESS.md`:30). Until it is,
   store builds are impossible and every Android artifact is debug-signed.
4. **iOS** has no distribution path at all (Phase 5.1 entitlement pending); the runbook treats iOS as
   non-releasable rather than pretending a build exists.
5. **Who signs Windows builds** — the certificate purchase is approved but not made (Phase 5.4).

## 10. Checklist

Copy into the release PR and tick with evidence, not intention.

```markdown
- [ ] E1  main CI green on the release commit (api, parent-app, child-android, agent-desktop,
        ai-engine, workflow-lint; a suite the commit did not touch: run it by workflow_dispatch;
        ios-ci if apps/child-ios changed)
- [ ] E2  every merge message since the last release cites a verifier + TR row
- [ ] E3  hardware rows for each shipped platform, on this branch
- [ ] E4  CHANGELOG [Unreleased] promoted to a dated heading; unverified claims qualified
- [ ] E5  signing material present, or the release declared debug-signed
- [ ] E6  no open needs-human item in scope
- [ ] R1  freeze announced; tree recorded: <tree>
- [ ] R2  all version carriers bumped in one commit; parent app has +<build>
- [ ] R3  clean build from the release commit; API built outside the image; migrations head recorded
- [ ] R4  signer DN, versionCode/Name, targetSdk, signature scheme, hashes — output pasted
- [ ] R5  docs/releases/<version>-<date>.md committed, with "Not verified" filled honestly
- [ ] R6  merged with the verification line in the merge message
- [ ] R7  tag created after the merge; tree equality checked
- [ ] R8  distributed (dist/ + hashes, or maintainer upload) and testers told what is unsupported
- [ ] R9  post-release smoke by another lane; hygiene output; record closed after the 24 h window
```

Related: [`TESTING.md`](TESTING.md) for the gates · [`QA/TESTING-STRATEGY.md`](QA/TESTING-STRATEGY.md) for
the environment matrix · [`test-guides/PUBLISHING-READINESS.md`](test-guides/PUBLISHING-READINESS.md) for
the store checklist · [`test-guides/CI-SECRETS.md`](test-guides/CI-SECRETS.md) for what a missing secret
does · [`adr/0005-adversarial-acceptance-gate.md`](adr/0005-adversarial-acceptance-gate.md) and
[`adr/0007-engineered-process-controls.md`](adr/0007-engineered-process-controls.md) for why the gates
exist.
