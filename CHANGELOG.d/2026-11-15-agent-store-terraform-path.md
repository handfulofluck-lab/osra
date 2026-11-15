### Infrastructure — the stored agent key works for Terraform, and secrets rotation works on Windows (#766)
- `move-agent-key-to-store.sh` installs the key helper beside the DPAPI store
  (`%USERPROFILE%\.aws\osra-agent-credential.ps1`) and points `credential_process` at that copy, without quotes.
  Quotes made Terraform's AWS SDK fail every production plan after the move ("Illegal characters in path"), and
  the helper no longer runs from inside a git checkout, whose checked-out branch decided the script (Fable on
  #821). The installer refuses a path with a space. A profile that was already moved (no key lines, a
  `credential_process` set, whatever the old path's spelling) is repointed on a re-run, and the script requires the same caller identity before and after, checks that the profile runs the installed copy and that it reads the stored key.
- `rotate-agent-key.sh` recognises store mode by the profile's shape rather than the helper's name. It stops before creating a key if the installed helper is missing, and `--check` prints the mode without rotating.
- `production-secrets.sh` converts its temporary folder with `cygpath -m` on Windows, so `aws.exe` can read the
  `file://` values. The 15 Nov rotation needed a hand-set `TMPDIR` for this.
