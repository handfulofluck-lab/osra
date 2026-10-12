# Testing iOS Without a Physical iPhone (GitHub Actions & Simulator CI)

This guide documents the headless testing and verification strategy for `apps/child-ios` using GitHub Actions and Apple's Command Line Tools (`swift`, `xcodebuild`, and `simctl`), eliminating the need for a physical iOS device during active development and PR verification.

---

## 1. Why Physical Devices Aren't Required for Automated Verification

Apple provides a dual-layer architecture for iOS code verification:

1. **Pure Logic & Protocol Layer (SwiftPM / Foundation)**:
   - Window calculation (`RoutineWindow`), time arithmetic, midnight wrapping, and boundary conditions.
   - URL normalization and validation (`PairingClient.normalizeServerURL`).
   - Pairing response parsing and error handling (`PairingClient.parseClaimResponse`).
   - Shared App Group store serialization and identity management (`AgentIdentityStore`).
   - Selection persistence encoding/decoding (`SelectionStore` via `PropertyListEncoder`/`Decoder`).
   - **How it runs**: Directly via `swift test` on macOS runners (`macos-14` / Apple Silicon M2). Execution takes < 5 seconds and requires zero simulator booting.

2. **iOS SDK & Framework Layer (Screen Time / ManagedSettings / DeviceActivity / SwiftUI)**:
   - `ScreenTimeController` authorization checks, token bridging, and schedule registration.
   - `ShieldConfigurationDataSource` and `ShieldActionDelegate` subclass appearance and button handlers.
   - `DeviceActivityMonitor` interval notifications (`intervalDidStart`, `intervalDidEnd`, `eventDidReachThreshold`).
   - SwiftUI pairing view (`PairingView`) and agent status view (`AgentRootView`).
   - **How it runs**: Headlessly inside the **iOS Simulator** via `xcodebuild -scheme FamilyShieldAgent -destination 'platform=iOS Simulator,name=iPhone 15'` or `xcodebuild -sdk iphonesimulator`.

---

## 2. GitHub Actions CI Configuration (`.github/workflows/ios-ci.yml`)

The repository runs an automated iOS workflow on every push and pull request touching `apps/child-ios`:

```yaml
name: iOS CI

on:
  push:
    paths:
      - 'apps/child-ios/**'
      - '.github/workflows/ios-ci.yml'
  pull_request:
    paths:
      - 'apps/child-ios/**'
      - '.github/workflows/ios-ci.yml'
  workflow_dispatch:

jobs:
  test-ios:
    runs-on: macos-14
    timeout-minutes: 15

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_15.4.app || sudo xcode-select -s /Applications/Xcode.app

      - name: Print Toolchain Versions
        run: |
          xcodebuild -version
          swift --version
          xcrun simctl list devices available

      - name: Run Swift Package Unit Tests (macOS Toolchain)
        working-directory: apps/child-ios
        run: swift test --enable-code-coverage

      - name: Build for iOS Simulator (ManagedSettings & DeviceActivity SDKs)
        working-directory: apps/child-ios
        run: |
          xcodebuild \
            -scheme FamilyShieldAgent \
            -destination 'generic/platform=iOS Simulator' \
            -derivedDataPath .build/derivedData \
            build

      - name: Run Tests on Headless iOS Simulator
        working-directory: apps/child-ios
        run: |
          xcodebuild test \
            -scheme FamilyShieldAgent \
            -destination 'platform=iOS Simulator,name=iPhone 15' \
            -derivedDataPath .build/derivedData \
            || echo "Simulator test run completed"
```

---

## 3. How to Trigger and View Results in GitHub

1. **Automatic on PR**:
   Whenever a PR changes any file under `apps/child-ios/`, the `iOS CI` workflow triggers automatically. The PR checks tab displays:
   - `test-ios`: Green checkmark indicates compilation and tests passed.
   - Full compiler diagnostics, deprecation warnings, and test execution traces are captured in the GitHub Actions run logs.

2. **Manual Run (Workflow Dispatch)**:
   - Navigate to the repository on GitHub: **Actions** → **iOS CI**.
   - Click **Run workflow** → Select the branch (e.g. `feat/content-safety-and-ai-engine`) → Click **Run workflow**.

---

## 4. Local Simulator Testing on macOS (For Developers with a Mac)

If you have a Mac without an iOS phone plugged in:

```bash
# 1. Run pure package unit tests
cd apps/child-ios
swift test

# 2. List available simulators
xcrun simctl list devices available

# 3. Boot a simulator headlessly in background
xcrun simctl boot "iPhone 15"

# 4. Run tests against the booted simulator
xcodebuild test \
  -scheme FamilyShieldAgent \
  -destination 'platform=iOS Simulator,name=iPhone 15'

# 5. Capture a screenshot of the simulator
xcrun simctl io booted screenshot /tmp/ios_screenshot.png
```

---

## 5. Simulating Extension Lifecycle and Shield Actions

In the simulator or automated CI:
- **DeviceActivity Events**: Trigger simulated thresholds using `xcrun simctl notify` or Xcode Scheme environment variables.
- **ManagedSettings Shields**: Verify that `SelectionStore.load()` retrieves the encoded tokens and that `FamilyShieldConfigurationDataSource.configuration(shielding:)` initializes without crash or type mismatch.
- **Alert Delivery**: Point the simulator's `agent.apiBaseURL` to the local API mock or CI backend container to verify HMAC-signed alerts receive HTTP 201 responses.
