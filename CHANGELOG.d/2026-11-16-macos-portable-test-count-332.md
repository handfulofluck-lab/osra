### CI: update macOS portable test count to 336 (#760)

- Adjust the expected portable macOS test count in `.github/workflows/ios-ci.yml`
  after the ring-command test additions, including
  `RingPolicyTests.testChildDismissedIsNotAStopSource` and
  `RingControllerTests.testMultipleLockScreenDismissalsIncrementCount`.
