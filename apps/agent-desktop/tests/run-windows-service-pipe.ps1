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
    $resultPath = Join-Path $probeDir 'probe-result.txt'
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        throw "The probe service name is already in use: $serviceName"
    }
    $clientProcess = Start-Process -FilePath $exe -ArgumentList 'client' -NoNewWindow -PassThru
    $binary = '"{0}" server {1} {2} {3} "{4}"' -f $exe, $sessionId, $userSid, $clientProcess.Id, $exe
    & sc.exe create $serviceName binPath= $binary
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the CI-only service.' }
    $created = $true
    if (Test-Path -LiteralPath $resultPath) {
        Remove-Item -LiteralPath $resultPath -Force
    }
    & sc.exe start $serviceName
    if ($LASTEXITCODE -ne 0) { throw 'Could not start the CI-only service.' }

    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    while (-not (Test-Path -LiteralPath $resultPath)) {
        if ($clientProcess.HasExited -and $clientProcess.ExitCode -ne 0) {
            throw "The native pipe client failed with exit code $($clientProcess.ExitCode)."
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw 'The real service/store probe did not produce a result within 90 seconds.'
        }
        Start-Sleep -Milliseconds 250
    }
    $result = (Get-Content -LiteralPath $resultPath -Raw).Trim()
    if ($result -ne 'OSRA_SERVICE_STORE_PASS') {
        throw "The real service/store probe failed: $result"
    }
    $clientProcess.WaitForExit()
    if ($clientProcess.ExitCode -ne 0) { throw 'The real service/pipe check failed.' }
    Write-Output $result
    Write-Output 'Real Windows service and restriction-store checks passed.'
}
finally {
    if ($clientProcess -and -not $clientProcess.HasExited) {
        Stop-Process -Id $clientProcess.Id -Force
    }
    if ($created) {
        & sc.exe stop $serviceName | Out-Null
        & sc.exe delete $serviceName | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not delete the CI-only service.' }
        $cleanupDeadline = [DateTime]::UtcNow.AddSeconds(30)
        while (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
            if ([DateTime]::UtcNow -ge $cleanupDeadline) {
                throw 'The CI-only service still exists after deletion.'
            }
            Start-Sleep -Milliseconds 250
        }
    }
    if (Test-Path -LiteralPath $probeDir) {
        Remove-Item -Recurse -Force $probeDir
    }
    if (Test-Path -LiteralPath $probeDir) {
        throw 'The probe directory still exists after cleanup.'
    }
    Write-Output 'OSRA_SERVICE_CLEANUP_PASS'
}
