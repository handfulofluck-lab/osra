# Shared by rotate-agent-key.sh and move-agent-key-to-store.sh: write an access key id and secret into the
# DPAPI store that agent-credential.ps1 reads. The pair goes to PowerShell on stdin (printf is a shell
# builtin, so neither value appears in any process's arguments) and is encrypted for the current Windows user.
AGENT_STORE="${AGENT_STORE:-$HOME/.aws/osra-agent.dpapi}"

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
  helper=$(cygpath -w "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/agent-credential.ps1")
  OSRA_STORE="$win" OSRA_HELPER="$helper" powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \
    '$ErrorActionPreference = "Stop"; (& $env:OSRA_HELPER -Store $env:OSRA_STORE | ConvertFrom-Json).AccessKeyId' | tr -d '\r'
}
