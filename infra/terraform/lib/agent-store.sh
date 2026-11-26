# Shared by rotate-agent-key.sh and move-agent-key-to-store.sh: write an access key id and secret into the
# DPAPI store that agent-credential.ps1 reads. The pair goes to PowerShell on stdin (printf is a shell
# builtin, so neither value appears in any process's arguments) and is encrypted for the current Windows user.
AGENT_STORE="${AGENT_STORE:-$HOME/.aws/osra-agent.dpapi}"
# The helper the profile runs lives beside the store, outside any git checkout (Fable on #821): whatever
# branch is checked out must not decide the script that hands out the key. No space allowed in its path,
# because credential_process cannot quote it for Terraform's AWS SDK (it passes quotes literally).
AGENT_HELPER="${AGENT_HELPER:-$HOME/.aws/osra-agent-credential.ps1}"
# Matches both the installed name and the pre-#821 in-repo name, so a profile moved earlier still counts.
AGENT_HELPER_PATTERN='agent-credential\.ps1'

# Copies the repository's helper to AGENT_HELPER and prints the credential_process line for it.
agent_helper_install() { # repo_helper
  local win
  cp "$1" "$AGENT_HELPER"
  win=$(cygpath -w "$AGENT_HELPER")
  case "$win" in *" "*) echo "helper path has a space, credential_process cannot carry it: $win" >&2; return 1 ;; esac
  printf 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File %s' "$win"
}

agent_store_write() { # id secret
  local win
  win=$(cygpath -w "$AGENT_STORE")
  printf '%s\n%s\n' "$1" "$2" | OSRA_STORE="$win" powershell.exe -NoProfile -NonInteractive -Command \
    '$ErrorActionPreference = "Stop"; $t = [Console]::In.ReadToEnd(); ConvertTo-SecureString $t -AsPlainText -Force | ConvertFrom-SecureString | Set-Content -NoNewline -Path $env:OSRA_STORE'
}

# Prints only the access key id the store holds now, read back through agent-credential.ps1 exactly as the
# AWS CLI reads it. The secret stays inside PowerShell and is never printed (Fable B3 on #793).
agent_store_id() {
  local win helper
  win=$(cygpath -w "$AGENT_STORE")
  helper=$(cygpath -w "$AGENT_HELPER")
  OSRA_STORE="$win" OSRA_HELPER="$helper" powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \
    '$ErrorActionPreference = "Stop"; (& $env:OSRA_HELPER -Store $env:OSRA_STORE | ConvertFrom-Json).AccessKeyId' | tr -d '\r'
}
