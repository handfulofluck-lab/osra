### Infrastructure — the stored agent key works for Terraform, and secrets rotation works on Windows (#766)
- `move-agent-key-to-store.sh` writes the helper path into `credential_process` without quotes, in its 8.3 short
  form. Terraform's AWS SDK passed the quotes to PowerShell literally ("Illegal characters in path"), so every
  production plan failed after the move, while the AWS CLI still worked.
- `production-secrets.sh` converts its temporary folder with `cygpath -m` on Windows, so `aws.exe` can read the
  `file://` values. The 15 Nov rotation needed a hand-set `TMPDIR` for this.
