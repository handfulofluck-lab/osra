### iOS child agent — builds as an app with its three extensions on the macOS runner (5.5, #372)
- `apps/child-ios/project.yml` is an XcodeGen spec for four targets that link the existing
  `FamilyShieldAgent` package:
  - the `OSRAAgent` host app, with `@main` moved out of the library into `App/`;
  - the Device Activity monitor extension;
  - the shield configuration extension;
  - the shield action extension.
- The generated `.xcodeproj` is not committed.
- Each target has an entitlements file with Family Controls and the app group
  `group.dev.familyshield.agent`. Bundle ids are placeholders under `dev.familyshield.agent`, and
  `DEVELOPMENT_TEAM` is empty: the public repository holds no team id, profile or certificate.
- The three principal classes are now `public` with `@objc(<name>)`, so each extension finds its class
  under the name in its `Info.plist`, and the linker keeps the class in that extension's binary.
- `ios-ci.yml` now:
  - runs on `macos-26` with the newest Xcode on the image (it was `macos-14` / Xcode 15.4);
  - keeps the package build and XCTest run;
  - generates the project with a pinned, checksummed XcodeGen;
  - builds the app unsigned for the Simulator and for devices;
  - runs `scripts/check-app-bundle.py`, which fails on a missing extension, a wrong extension point
    or principal class, or an entitlements file without both keys;
  - has a 30-minute timeout.
- Not yet: signing, a real iPhone and TestFlight (they wait on 5.1), the Keychain, rule sync and APNs.
