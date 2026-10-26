### iOS child agent — a command the iPhone can't carry out is refused as `not_supported` (5.5, ADR-0034 amendment A6)
- The iPhone acks lock, ring, pause_internet and the other commands it cannot carry out as `failed` with
  `reason: "not_supported"`, the one reason every agent and the server use (ADR-0034, amendment A6, decided
  on #371). It was `unsupported_on_ios`.
- There is no alias, because no iOS build has reached anyone. Neither the server nor the parent app reads the
  old string.
- `DeviceCommandsTests` pins the new reason. Reverting the rename fails it.
