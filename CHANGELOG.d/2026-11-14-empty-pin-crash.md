### Android child — an empty PIN entry is a wrong PIN, not a crash (osra-security#17)
- An empty PIN entry could raise an exception inside PBKDF2 on Android; the exception crossed into the UI
  and took the process down, and enforcement stopped with it.
- `ParentPin.verify` now treats any out-of-range input as a wrong PIN before the key derivation runs, and
  the derivation itself is wrapped so nothing it throws can reach a caller.
- Continue stays disabled until the field holds a length a PIN can have.
- The length policy and the wrapper are pinned through a key-derivation seam: a derivation that throws and
  one that records its calls, because the JVM's PBKDF2 provider accepts an empty password where Android's
  throws, so a row that only calls `verify` answers `false` for the wrong reason.
