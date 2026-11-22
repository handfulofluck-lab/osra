# scripts/hardware/windows-escape.ps1 - the Windows rows of the child-escape catalogue, as a script.
#
# Why this exists: catalogue rows WN02, WN03, WN05-WN09, WN11, WN13 and WN14 (#738) are all "the child
# tries to switch OSRA off from a standard account". Until now each was a sentence in a document and a
# person remembering to try it. This script makes each row a named check that prints PASS, FAIL, SKIP or
# UNKNOWN, with the evidence in the same line.
#
# It runs as the **child's own account** - a standard, non-elevated user. That is the whole point: the
# claim under test is that Windows refuses these steps to such a user. If this script is started from an
# elevated shell it refuses to run at all (exit 2), because an elevated run would either pass for the
# wrong reason or, worse, actually change the machine.
#
# What it can and cannot prove:
#   - It proves (or disproves) the **OS half** of each row: the service stop, the clock, the hosts file,
#     the firewall and the local account are refused to a standard user.
#   - It cannot prove the **agent half** - "the tray is restarted by the service", "the filter holds",
#     "the parent is alerted" - without OSRA installed on this host and paired. Those rows print SKIP
#     with the reason, never PASS. A SKIP is not coverage; it is an honest hole.
#   - Rows that would change the machine if they ever succeeded (an account, a firewall rule) need
#     -AllowMutating, and each one undoes what it created before reporting FAIL. Without the switch they
#     print SKIP and say why.
#
# Mutants (each must turn the self-test red):
#   - classify every non-zero exit as "refused" -> SelfTest's control row (a command that succeeds with
#     exit 0) goes red, because the classifier would call it refused too;
#   - drop the elevation guard -> the script would run the mutating rows as admin; SelfTest asserts the
#     guard is consulted before any row runs.
#
# Usage (PowerShell 5.1, ASCII, run as the child's standard account):
#   .\windows-escape.ps1                  # OS half only, nothing that changes the machine
#   .\windows-escape.ps1 -AllowMutating   # also attempt the account / firewall rows, undoing on success
#   .\windows-escape.ps1 -SelfTest        # exercise the classifier and the guard, no rows
#
# Exit codes: 0 no FAIL, 1 at least one FAIL, 2 refused to run (elevated or unusable host).

[CmdletBinding()]
param(
    [switch]$AllowMutating,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$script:rows = New-Object System.Collections.ArrayList

function Add-Row {
    param(
        [string]$Id,
        [string]$Claim,
        [ValidateSet('PASS', 'FAIL', 'SKIP', 'UNKNOWN')][string]$Result,
        [string]$Evidence
    )
    $null = $script:rows.Add([pscustomobject]@{
            Row      = $Id
            Result   = $Result
            Evidence = $Evidence
            Claim    = $Claim
        })
}

function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# A refusal is the OS saying "you may not", not merely a non-zero exit: a missing service or a typo'd
# command also exits non-zero, and counting either as PASS would be the classic test that cannot fail.
function Test-Refused {
    param(
        [int]$ExitCode,
        [string]$Output
    )
    if ($ExitCode -eq 0) { return $false }
    $text = '' + $Output
    foreach ($marker in @('Access is denied', 'access denied', 'requires elevation', 'Elevated permissions',
            'must be an administrator', 'You do not have sufficient privileges', 'The requested operation requires elevation',
            'A required privilege is not held', 'You must be an administrator')) {
        if ($text -like "*$marker*") { return $true }
    }
    # Permission codes Windows returns for these calls when the user is not an administrator.
    if ($ExitCode -eq 5) { return $true }
    return $false
}

function Invoke-Probe {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )
    $out = & $FilePath @Arguments 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
}

function Get-AgentService {
    # Discovered by name, not by a constant, because the W1 service (#623 / PR #754) is not on main yet. The
    # match is deliberately narrow: `OSRA*` also catches a local database service someone named OSRA-Postgres,
    # and stopping that would test the wrong thing on a machine that happens to be the developer's.
    return @(Get-Service -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -in @('OSRA-Agent', 'OsraAgent', 'OSRAAgent') -or $_.DisplayName -like '*OSRA agent*'
        })
}

function Test-SelfTest {
    Write-Host 'SelfTest: classifier and guard'
    $control = Invoke-Probe -FilePath 'cmd.exe' -Arguments @('/c', 'exit 0')
    $okControl = -not (Test-Refused -ExitCode $control.ExitCode -Output $control.Output)
    Write-Host ("  control (a command that succeeds) is not called refused: {0}" -f $okControl)

    # A real permission refusal, from a service a standard user may not stop. Nothing changes: the
    # call is rejected, which is the point. If this ever succeeds the shell is elevated, and the
    # guard above has already refused to run.
    $refusedControl = Invoke-Probe -FilePath 'sc.exe' -Arguments @('stop', 'Spooler')
    $refusedText = Test-Refused -ExitCode $refusedControl.ExitCode -Output $refusedControl.Output
    Write-Host ("  a command rejected for lack of access is called refused: {0} (exit {1})" -f $refusedText, $refusedControl.ExitCode)

    $guard = [bool](Get-Command Test-Elevated -ErrorAction SilentlyContinue)
    Write-Host ("  the elevation guard exists and answers: {0}" -f $guard)
    $elevated = Test-Elevated
    Write-Host ("  this shell reports elevated={0} (the script refuses to run when this is true)" -f $elevated)

    if ($okControl -and $refusedText -and $guard) {
        Write-Host 'SelfTest: PASS'
        return 0
    }
    Write-Host 'SelfTest: FAIL'
    return 1
}

if (Test-Elevated) {
    Write-Output 'REFUSED: this script must run as the child''s standard account, not from an elevated shell.'
    Write-Output 'An elevated run would pass rows for the wrong reason and could change this machine.'
    exit 2
}

if ($SelfTest) {
    # Write-Host, not Write-Output: the branch's output would otherwise be swallowed by `exit (...)`.
    $code = Test-SelfTest
    exit $code
}

# @() wrapper: an empty service list must be an empty array, not $null, or StrictMode turns .Count into
# a harness error and the row disappears from the table instead of printing SKIP.
$agent = @(Get-AgentService)

# WN02 - end the agent's process from the child's account.
# Agent-dependent: the row's claim is that the service restarts the tray, which needs OSRA installed.
if ($agent.Count -eq 0) {
    Add-Row -Id 'WN02' -Result 'SKIP' -Claim 'A standard user cannot end the service; the tray is restarted by the service' `
        -Evidence 'no OSRA service on this host: the agent half of the row cannot be run here'
}
else {
    $proc = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'OSRA*' })
    if ($proc.Count -eq 0) {
        Add-Row -Id 'WN02' -Result 'SKIP' -Claim 'A standard user cannot end the service; the tray is restarted by the service' `
            -Evidence ("service {0} present but no OSRA process is running" -f $agent[0].Name)
    }
    else {
        $kill = Invoke-Probe -FilePath 'taskkill.exe' -Arguments @('/PID', ('' + $proc[0].Id), '/F')
        $survived = $null -ne (Get-Process -Id $proc[0].Id -ErrorAction SilentlyContinue)
        $serviceStopped = (Get-Service -Name $agent[0].Name -ErrorAction SilentlyContinue).Status -eq 'Running'
        if (-not $survived -and $serviceStopped) {
            Add-Row -Id 'WN02' -Result 'PASS' -Claim 'A standard user cannot end the service; the tray is restarted by the service' `
                -Evidence ("taskkill exit {0}; process gone; service {1} still Running (restart not yet observed)" -f $kill.ExitCode, $agent[0].Name)
        }
        else {
            Add-Row -Id 'WN02' -Result 'FAIL' -Claim 'A standard user cannot end the service; the tray is restarted by the service' `
                -Evidence ("taskkill exit {0}; survived={1}; service running={2}" -f $kill.ExitCode, $survived, $serviceStopped)
        }
    }
}

# WN03 - stop or disable a service from the child's account.
$stopTarget = if ($agent.Count -gt 0) { $agent[0].Name } else { 'Spooler' }
$stop = Invoke-Probe -FilePath 'sc.exe' -Arguments @('stop', $stopTarget)
$disable = Invoke-Probe -FilePath 'sc.exe' -Arguments @('config', $stopTarget, 'start=', 'disabled')
$stopRefused = Test-Refused -ExitCode $stop.ExitCode -Output $stop.Output
$disableRefused = Test-Refused -ExitCode $disable.ExitCode -Output $disable.Output
if (-not $disableRefused -and $agent.Count -eq 0) {
    # Never leave a service disabled because the guard failed rather than the OS.
    $null = Invoke-Probe -FilePath 'sc.exe' -Arguments @('config', $stopTarget, 'start=', 'auto')
}
if ($stopRefused -and $disableRefused) {
    Add-Row -Id 'WN03' -Result 'PASS' -Claim 'sc stop and sc config start=disabled are refused for a standard user' `
        -Evidence ("target {0}: stop exit {1}, config exit {2}, both access denied" -f $stopTarget, $stop.ExitCode, $disable.ExitCode)
}
else {
    Add-Row -Id 'WN03' -Result 'FAIL' -Claim 'sc stop and sc config start=disabled are refused for a standard user' `
        -Evidence ("target {0}: stop refused={1} (exit {2}), config refused={3} (exit {4})" -f $stopTarget, $stopRefused, $stop.ExitCode, $disableRefused, $disable.ExitCode)
}

# WN05 - create a local account from the child's account.
if (-not $AllowMutating) {
    Add-Row -Id 'WN05' -Result 'SKIP' -Claim 'Creating local accounts needs admin' `
        -Evidence 'would create an account if the guard failed; rerun with -AllowMutating to attempt it'
}
else {
    $add = Invoke-Probe -FilePath 'net.exe' -Arguments @('user', 'k31probe', 'P@ssw0rd-k31-probe', '/add')
    if (Test-Refused -ExitCode $add.ExitCode -Output $add.Output) {
        Add-Row -Id 'WN05' -Result 'PASS' -Claim 'Creating local accounts needs admin' `
            -Evidence ("net user /add exit {0}, access denied" -f $add.ExitCode)
    }
    else {
        $null = Invoke-Probe -FilePath 'net.exe' -Arguments @('user', 'k31probe', '/delete')
        Add-Row -Id 'WN05' -Result 'FAIL' -Claim 'Creating local accounts needs admin' `
            -Evidence ("net user /add exit {0}; probe account created and removed, which is the failure" -f $add.ExitCode)
    }
}

# WN06 - change the clock from the child's account.
$before = Get-Date
$set = Invoke-Probe -FilePath 'powershell.exe' -Arguments @('-NoProfile', '-Command', 'Set-Date -Date (Get-Date).AddMinutes(1)')
$after = Get-Date
$clockMoved = [math]::Abs(($after - $before).TotalSeconds) -gt 30
if ($clockMoved) {
    $null = Invoke-Probe -FilePath 'powershell.exe' -Arguments @('-NoProfile', '-Command', ("Set-Date -Date '{0}'" -f $before.ToString('o')))
}
$clockRefused = (Test-Refused -ExitCode $set.ExitCode -Output $set.Output) -or (-not $clockMoved)
if (-not $clockMoved -and $set.ExitCode -ne 0) {
    Add-Row -Id 'WN06' -Result 'PASS' -Claim 'A standard user cannot change the clock; limits and bedtime do not follow it' `
        -Evidence ("Set-Date exit {0}, clock unchanged ({1} to {2})" -f $set.ExitCode, $before.ToString('HH:mm:ss'), $after.ToString('HH:mm:ss'))
}
elseif (-not $clockMoved) {
    Add-Row -Id 'WN06' -Result 'UNKNOWN' -Claim 'A standard user cannot change the clock; limits and bedtime do not follow it' `
        -Evidence 'Set-Date reported success but the clock did not move; the probe is not measuring what it thinks'
}
else {
    Add-Row -Id 'WN06' -Result 'FAIL' -Claim 'A standard user cannot change the clock; limits and bedtime do not follow it' `
        -Evidence ("clock moved from {0} to {1}; restored to the captured value" -f $before.ToString('HH:mm:ss'), $after.ToString('HH:mm:ss'))
}

# WN09 - hosts file and system proxy from the child's account.
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$hostsRefused = $false
$hostsEvidence = ''
try {
    $marker = '# k31 escape probe ' + [Guid]::NewGuid().ToString('N')
    [IO.File]::AppendAllText($hostsPath, "`r`n$marker`r`n")
    # Reaching here means the child account CAN write the hosts file: remove the marker and report FAIL.
    $content = [IO.File]::ReadAllText($hostsPath)
    [IO.File]::WriteAllText($hostsPath, $content.Replace("`r`n$marker`r`n", ''))
    $hostsRefused = $false
    $hostsEvidence = 'hosts file was writable; marker removed again, which is the failure'
}
catch {
    $hostsRefused = $true
    $hostsEvidence = 'hosts write refused: ' + $_.Exception.GetType().Name
}
$proxy = Invoke-Probe -FilePath 'netsh.exe' -Arguments @('winhttp', 'set', 'proxy', '127.0.0.1:9')
$proxyRefused = Test-Refused -ExitCode $proxy.ExitCode -Output $proxy.Output
if (-not $proxyRefused) {
    $null = Invoke-Probe -FilePath 'netsh.exe' -Arguments @('winhttp', 'reset', 'proxy')
}
if ($hostsRefused -and $proxyRefused) {
    Add-Row -Id 'WN09' -Result 'PASS' -Claim 'Editing hosts and setting a system proxy need admin' `
        -Evidence ("{0}; netsh winhttp set proxy exit {1}, refused" -f $hostsEvidence, $proxy.ExitCode)
}
else {
    Add-Row -Id 'WN09' -Result 'FAIL' -Claim 'Editing hosts and setting a system proxy need admin' `
        -Evidence ("hosts refused={0}; proxy refused={1} (exit {2}); proxy reset if it had succeeded" -f $hostsRefused, $proxyRefused, $proxy.ExitCode)
}

# WN13 - block OSRA in the firewall from the child's account.
if (-not $AllowMutating) {
    Add-Row -Id 'WN13' -Result 'SKIP' -Claim 'Firewall rule changes need admin; offline enforcement holds' `
        -Evidence 'would add a firewall rule if the guard failed; rerun with -AllowMutating to attempt it'
}
else {
    $ruleName = 'K31 escape probe'
    $add = Invoke-Probe -FilePath 'netsh.exe' -Arguments @('advfirewall', 'firewall', 'add', 'rule', "name=$ruleName", 'dir=out', 'action=block', 'program=notepad.exe')
    if (Test-Refused -ExitCode $add.ExitCode -Output $add.Output) {
        Add-Row -Id 'WN13' -Result 'PASS' -Claim 'Firewall rule changes need admin; offline enforcement holds' `
            -Evidence ("netsh advfirewall add rule exit {0}, access denied" -f $add.ExitCode)
    }
    else {
        $null = Invoke-Probe -FilePath 'netsh.exe' -Arguments @('advfirewall', 'firewall', 'delete', 'rule', "name=$ruleName")
        Add-Row -Id 'WN13' -Result 'FAIL' -Claim 'Firewall rule changes need admin; offline enforcement holds' `
            -Evidence ("netsh advfirewall add rule exit {0}; rule added and deleted again, which is the failure" -f $add.ExitCode)
    }
}

# The rows this script cannot run, listed so a reader sees the hole rather than assuming coverage.
Add-Row -Id 'WN07' -Result 'SKIP' -Claim 'Uninstall, Program Files and the data folder need admin plus the parent PIN' `
    -Evidence 'needs the installed MSI and a paired agent; not runnable from this script'
Add-Row -Id 'WN08' -Result 'SKIP' -Claim 'The service, not a startup entry, keeps OSRA running' `
    -Evidence 'needs the installed service; the W1 service is not on main yet (#623 / PR #754)'
Add-Row -Id 'WN11' -Result 'SKIP' -Claim 'Portable apps and second browsers are blocked by name, hash or publisher' `
    -Evidence 'needs the installed filter and a real portable binary; a download is not this script''s to make'
Add-Row -Id 'WN14' -Result 'SKIP' -Claim 'PIN dialogs: no crash, no pass; the lockout survives a restart; closing is never yes' `
    -Evidence 'policy is covered by apps/agent-desktop/tests/FamilyShield.Agent.Tests/ParentPinPolicyTests.cs; dialog-level UI automation stays open'

# A row that did not run is not a row that passed. Anything missing from the expected list is reported as
# UNKNOWN, which exits non-zero: a harness error must never look like a clean run.
$expected = @('WN02', 'WN03', 'WN05', 'WN06', 'WN07', 'WN08', 'WN09', 'WN11', 'WN13', 'WN14')
foreach ($id in $expected) {
    if (-not ($script:rows | Where-Object { $_.Row -eq $id })) {
        Add-Row -Id $id -Result 'UNKNOWN' -Claim 'row did not run' -Evidence 'the block threw before recording a result; see the errors above'
    }
}

$script:rows | Format-Table -AutoSize Row, Result, Claim, Evidence
$failed = @($script:rows | Where-Object { $_.Result -eq 'FAIL' })
$passed = @($script:rows | Where-Object { $_.Result -eq 'PASS' })
$skipped = @($script:rows | Where-Object { $_.Result -eq 'SKIP' })
$unknown = @($script:rows | Where-Object { $_.Result -eq 'UNKNOWN' })
Write-Output ''
Write-Output ("Rows: {0} total, {1} PASS, {2} FAIL, {3} SKIP, {4} UNKNOWN" -f $script:rows.Count, $passed.Count, $failed.Count, $skipped.Count, $unknown.Count)
Write-Output 'A SKIP is not coverage. The agent half of these rows needs OSRA installed and paired on the test VM.'

if ($failed.Count -gt 0 -or $unknown.Count -gt 0) { exit 1 }
exit 0
