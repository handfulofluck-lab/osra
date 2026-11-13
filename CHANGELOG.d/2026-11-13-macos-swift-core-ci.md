### Mac step (i): the shared Swift package builds and tests on macOS (#653)
- The package declares macOS 14 support and keeps iOS-only Screen Time and UI code behind `#if os(iOS)` without moving code or changing iPhone behaviour.
- `ios-ci.yml` adds a `macos-core` job on the existing `macos-26` image: native `swift build`, discovery of 210 macOS package tests with named pairing/signer/rule/string checks, then `swift test`. Five iOS-only authorization tests stay on iOS because macOS has no `authorizedWhenInUse` state.
- The job shares the existing iOS workflow's path filters, triggers and concurrency group. No Mac application, enforcement backend or user-visible text is added in this step.
