$ErrorActionPreference = 'Stop'
if ($env:OSRA_WINDOWS_SERVICE_TEST -ne '1') {
    Write-Output 'The real Windows service probe is CI-only; set OSRA_WINDOWS_SERVICE_TEST=1 in its workflow.'
    exit 0
}

$serviceName = 'OSRAPipeProbe-K31'
$sessionId = (Get-Process -Id $PID).SessionId
$userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$probeDir = Join-Path (Get-Location) 'artifacts/windows-pipe-probe'
$created = $false

try {
    dotnet publish tests/WindowsPipeProbe -c Release -r win-x64 --self-contained true -o $probeDir
    if ($LASTEXITCODE -ne 0) { throw 'The probe did not publish.' }
    $exe = Join-Path $probeDir 'WindowsPipeProbe.exe'
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        throw "The probe service name is already in use: $serviceName"
    }
    $clientProcess = Start-Process -FilePath $exe -ArgumentList 'client' -NoNewWindow -PassThru
    $binary = '"{0}" server {1} {2} {3} "{4}"' -f $exe, $sessionId, $userSid, $clientProcess.Id, $exe
    & sc.exe create $serviceName binPath= $binary
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the CI-only service.' }
    $created = $true
    & sc.exe start $serviceName
    if ($LASTEXITCODE -ne 0) { throw 'Could not start the CI-only service.' }

    $clientProcess.WaitForExit()
    if ($clientProcess.ExitCode -ne 0) { throw 'The real service/pipe check failed.' }
    Write-Output 'Real Windows service and restriction-store checks passed.'
}
finally {
    if ($clientProcess -and -not $clientProcess.HasExited) {
        Stop-Process -Id $clientProcess.Id -Force
    }
    if ($created) {
        & sc.exe stop $serviceName | Out-Null
        & sc.exe delete $serviceName | Out-Null
    }
    if (Test-Path $probeDir) {
        Remove-Item -Recurse -Force $probeDir
    }
}
