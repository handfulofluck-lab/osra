# AWS CLI credential_process helper for the deployer user (Ahmed control 4, osra-security#27).
# The key is kept encrypted with Windows DPAPI under Karim's Windows account (the PC's credential store), not
# in plain text in ~/.aws/credentials. Only that Windows user on that PC can decrypt it. Profile entry, written
# by move-agent-key-to-store.sh:
#   [profile osra-staging]
#   credential_process = powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\...\agent-credential.ps1"
# Prints the JSON the AWS CLI and SDKs expect on stdout, and nothing else.
param([string]$Store = (Join-Path $env:USERPROFILE ".aws\osra-agent.dpapi"))
$ErrorActionPreference = "Stop"
$secure = ConvertTo-SecureString (Get-Content -Raw -Path $Store).Trim()
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
  $lines = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) -split "`r?`n"
} finally {
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}
[ordered]@{ Version = 1; AccessKeyId = $lines[0].Trim(); SecretAccessKey = $lines[1].Trim() } | ConvertTo-Json -Compress
