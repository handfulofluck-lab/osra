# OSRA - TR-48 (#201): prove the on-device installed-app list and its sync cadence.
#
# What it measures, and nothing else:
#   1. The launchable third-party package list the DEVICE reports (`adb shell pm list packages -3`,
#      intersected with the launcher activities from `cmd package query-activities`).
#   2. The list the API stored for that device (`GET /v1/devices/:id/apps` with a parent token).
#   3. Two consecutive `appsReportedAt` timestamps, asserted 14-16 minutes apart.
#
# It does not change the app, and it never sends `lock`, `pause` or any input event: every adb call
# below is a read. The parent token is read from -StateFile or -Token and is never logged or written
# to the JSON result.
#
# CADENCE NOTE (important, and why the run can honestly say WAITING). The agent uploads the inventory
# only when its fingerprint changes, or when the server copy is older than 24 h
# (`InstalledAppsReporter.reportIfChanged`). `appsReportedAt` therefore does NOT advance every 15
# minutes on a stationary phone. This harness waits for the API value to move:
#   - if the current `appsReportedAt` is at most 16 minutes old, it is used as the first endpoint and
#     one observed change is enough;
#   - if it is older, that value cannot be part of a 14-16 minute pair, so two observed changes are
#     required.
# If the deadline arrives with fewer marks, the result is WAITING and the exit code is non-zero. It
# never invents a timestamp. To exercise the upload path, change the launcher-visible list on the
# phone (install or uninstall a harmless app) once per telemetry tick.
#
# TOLERANCE for "on the device but not stored yet": an app whose `firstInstallTime` is at or after
# `reportedAt - ToleranceSeconds` is treated as installed after the last sync and is reported as
# TOLERATED, not FAIL. The default -ToleranceSeconds 60 is a clock-skew margin between the phone and
# the API host, not a product grace period. An app installed before that boundary is a FAIL. The
# reverse direction has no tolerance: a stored package the device no longer has is STALE and FAILs.
#
# The OSRA agent package (`com.familyshield.agent`) is excluded from the device set because the
# collector deliberately skips itself (a parent must not be able to block the protection agent), so
# comparing it would be a false MISSING.
#
# Windows PowerShell 5.1 and pwsh 7, ASCII only. Needs: adb, the API reachable at -Base, and a parent
# token with the `rules` permission (the route is permission-gated on purpose).
#
# Usage:
#   .\app-list-cadence.ps1 -StateFile C:\KARIM\KCL\tr07\tr10-state.json [-Base http://127.0.0.1:3000]
#   .\app-list-cadence.ps1 -DeviceId <device id> -Token <parent JWT> [-Serial R5CW116Y6GF]
#   .\app-list-cadence.ps1 -SelfTest          # fixtures only; no phone, no API
#
# Exit: 0 PASS, 1 FAIL, 2 setup/usage error, 3 build/device cannot be measured, 4 WAITING.
#
# The table and the JSON result are what go into the TR-48 row (AGENTS.md section 6).

param(
    [string]$DeviceId = "",
    [string]$Token = "",
    [string]$StateFile = "",
    [string]$Serial = "R5CW116Y6GF",
    [string]$Adb = "adb",
    [string]$Base = "http://127.0.0.1:3000",
    [string]$Out = (Join-Path (Get-Location) "app-list-cadence"),
    [int]$ToleranceSeconds = 60,
    [int]$CadenceWaitMinutes = 35,
    [int]$PollSeconds = 20,
    [switch]$SelfTest
)
$ErrorActionPreference = "Continue"
$AGENT_PKG = "com.familyshield.agent"
$CADENCE_MIN_S = 14 * 60
$CADENCE_MAX_S = 16 * 60

# ---------------------------------------------------------------------------------------------------
# Pure functions. They are the whole decision, so -SelfTest can exercise them without a phone.
# ---------------------------------------------------------------------------------------------------

# The launchable third-party set: what the device reports, minus the agent's own package.
function Get-DeviceAppSet {
    param(
        [string[]]$ThirdParty = @(),
        [string[]]$Launchable = @(),
        [string]$AgentPackage = "com.familyshield.agent"
    )
    $tp = @(); if ($ThirdParty) { $tp = @($ThirdParty | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $la = @(); if ($Launchable) { $la = @($Launchable | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    return @($tp | Where-Object { ($la -contains $_) -and ($_ -ne $AgentPackage) } | Sort-Object -Unique)
}

# Package ids whose first install is at or after the last report (less the skew margin).
function Get-ToleratedInstalls {
    param(
        [hashtable]$InstallTimes = @{},
        [DateTimeOffset]$ReportedAt,
        [int]$ToleranceSeconds = 60
    )
    $cut = $ReportedAt.AddSeconds(-1 * $ToleranceSeconds)
    $out = @()
    if ($InstallTimes) {
        foreach ($key in $InstallTimes.Keys) {
            if ($InstallTimes[$key] -ge $cut) { $out += $key }
        }
    }
    return @($out | Sort-Object -Unique)
}

# Set comparison, in the two directions that matter, with the tolerated set called out.
function Compare-AppInventory {
    param(
        [string[]]$DeviceLaunchable = @(),
        [string[]]$DeviceAll = @(),
        [string[]]$Stored = @(),
        [string[]]$Tolerated = @()
    )
    $devL = @(); if ($DeviceLaunchable) { $devL = @($DeviceLaunchable | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object -Unique) }
    $devA = @(); if ($DeviceAll) { $devA = @($DeviceAll | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object -Unique) }
    $sto = @(); if ($Stored) { $sto = @($Stored | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object -Unique) }
    $tol = @(); if ($Tolerated) { $tol = @($Tolerated | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object -Unique) }

    $missing = @($devL | Where-Object { ($sto -notcontains $_) -and ($tol -notcontains $_) } | Sort-Object -Unique)
    $toleratedMissing = @($devL | Where-Object { ($sto -notcontains $_) -and ($tol -contains $_) } | Sort-Object -Unique)
    $stale = @($sto | Where-Object { $devA -notcontains $_ } | Sort-Object -Unique)
    $matched = @($devL | Where-Object { $sto -contains $_ } | Sort-Object -Unique)

    return [pscustomobject]@{
        Pass            = (($missing.Count -eq 0) -and ($stale.Count -eq 0))
        Missing         = $missing
        ToleratedMissing = $toleratedMissing
        Stale           = $stale
        Matched         = $matched
        DeviceCount     = $devL.Count
        StoredCount     = $sto.Count
    }
}

# The acceptance window is 14-16 minutes inclusive. Seconds, so the table can print the raw gap.
function Test-CadenceInterval {
    param([double]$Seconds)
    return (($Seconds -ge $CADENCE_MIN_S) -and ($Seconds -le $CADENCE_MAX_S))
}

# A baseline older than the window cannot be half of a 14-16 minute pair, so the harness must wait
# for two observed changes instead of using it. The boundary is the same 16 minutes.
function Test-FreshBaseline {
    param([double]$AgeSeconds, [int]$MaxAgeSeconds = $CADENCE_MAX_S)
    return (($AgeSeconds -ge 0) -and ($AgeSeconds -le $MaxAgeSeconds))
}

# Reads one package's first install time in the device's own timezone. The phone can list more than
# one user state, and the 1970 row is a placeholder, so the first non-1970 value wins.
function Get-DeviceInstallTime {
    param([string]$Package, [string]$DeviceOffset)
    $raw = Sh ("dumpsys package " + $Package)
    $times = @([regex]::Matches($raw, "firstInstallTime=(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})") | ForEach-Object { $_.Groups[1].Value })
    $best = $null
    foreach ($t in $times) {
        if ($t -notmatch "^1970-") { $best = $t; break }
    }
    if (-not $best) { return $null }
    $off = $DeviceOffset.Trim()
    if ($off -notmatch "^([+-])(\d{2})(\d{2})$") { return $null }
    $iso = ($best -replace " ", "T") + $Matches[1] + $Matches[2] + ":" + $Matches[3]
    try { return [DateTimeOffset]::Parse($iso, [Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
}

# ---------------------------------------------------------------------------------------------------
# Self-test fixtures. No phone and no API: every case is a pure decision.
# ---------------------------------------------------------------------------------------------------
function Invoke-AppListCadenceSelfTest {
    $script:failed = 0
    $script:total = 0
    function Check([string]$name, [bool]$ok, [string]$got) {
        $script:total++
        if ($ok) {
            Write-Host ("PASS  " + $name + " -> " + $got)
        } else {
            $script:failed++
            Write-Host ("FAIL  " + $name + " -> " + $got)
        }
    }

    $reported = [DateTimeOffset]::Parse("2026-10-19T08:30:00.000Z")
    $thirdParty = @("com.example.game", "com.example.reader", "com.android.settings", $AGENT_PKG)
    $launchable = @("com.example.game", "com.example.reader", "com.android.settings", $AGENT_PKG, "com.android.chrome")
    $all = @("com.example.game", "com.example.reader", "com.android.settings", $AGENT_PKG, "com.android.chrome", "com.android.systemui")
    $device = Get-DeviceAppSet -ThirdParty $thirdParty -Launchable $launchable -AgentPackage $AGENT_PKG
    Check "device set keeps launchable third-party apps" (($device -contains "com.example.game") -and ($device -contains "com.example.reader")) (($device -join ", "))
    Check "device set drops the agent itself" (-not ($device -contains $AGENT_PKG)) ("count " + $device.Count)
    Check "device set drops non-third-party launchers" (-not ($device -contains "com.android.chrome")) ("count " + $device.Count)

    # Exact match.
    $cmp = Compare-AppInventory -DeviceLaunchable $device -DeviceAll $all -Stored $device -Tolerated @()
    Check "exact match -> PASS" ($cmp.Pass -and $cmp.Missing.Count -eq 0 -and $cmp.Stale.Count -eq 0) ("missing " + $cmp.Missing.Count + ", stale " + $cmp.Stale.Count + ", matched " + $cmp.Matched.Count)

    # Extra on device, installed before the last sync: must FAIL.
    $cmp = Compare-AppInventory -DeviceLaunchable ($device + "com.example.newapp") -DeviceAll $all -Stored $device -Tolerated @()
    Check "extra on device -> FAIL" ((-not $cmp.Pass) -and $cmp.Missing.Count -eq 1 -and $cmp.Stale.Count -eq 0) ("missing " + ($cmp.Missing -join ", "))

    # Extra on device, installed after the last sync: tolerated, PASS.
    $times = @{ "com.example.newapp" = $reported.AddMinutes(2) }
    $tol = Get-ToleratedInstalls -InstallTimes $times -ReportedAt $reported -ToleranceSeconds 60
    $cmp = Compare-AppInventory -DeviceLaunchable ($device + "com.example.newapp") -DeviceAll $all -Stored $device -Tolerated $tol
    Check "tolerance window: installed after report -> PASS" ($cmp.Pass -and $cmp.ToleratedMissing.Count -eq 1 -and $cmp.Missing.Count -eq 0) ("tolerated " + ($cmp.ToleratedMissing -join ", "))

    # Within the 60 s skew margin: tolerated.
    $times = @{ "com.example.newapp" = $reported.AddSeconds(-30) }
    $tol = Get-ToleratedInstalls -InstallTimes $times -ReportedAt $reported -ToleranceSeconds 60
    $cmp = Compare-AppInventory -DeviceLaunchable ($device + "com.example.newapp") -DeviceAll $all -Stored $device -Tolerated $tol
    Check "tolerance window: 30 s early (clock skew) -> PASS" ($cmp.Pass -and $cmp.ToleratedMissing.Count -eq 1) ("tolerated " + $cmp.ToleratedMissing.Count)

    # Outside the margin: FAIL.
    $times = @{ "com.example.newapp" = $reported.AddSeconds(-61) }
    $tol = Get-ToleratedInstalls -InstallTimes $times -ReportedAt $reported -ToleranceSeconds 60
    $cmp = Compare-AppInventory -DeviceLaunchable ($device + "com.example.newapp") -DeviceAll $all -Stored $device -Tolerated $tol
    Check "tolerance window: 61 s early -> FAIL" ((-not $cmp.Pass) -and $cmp.Missing.Count -eq 1 -and $cmp.ToleratedMissing.Count -eq 0) ("missing " + ($cmp.Missing -join ", "))

    # Stored package the device no longer has: must FAIL.
    $cmp = Compare-AppInventory -DeviceLaunchable $device -DeviceAll $all -Stored ($device + "com.example.gone") -Tolerated @()
    Check "stored package gone from device -> FAIL" ((-not $cmp.Pass) -and $cmp.Stale.Count -eq 1) ("stale " + ($cmp.Stale -join ", "))

    # Cadence window, inclusive at both ends.
    Check "cadence 14:00 -> PASS" (Test-CadenceInterval 840) "840 s"
    Check "cadence 15:00 -> PASS" (Test-CadenceInterval 900) "900 s"
    Check "cadence 16:00 -> PASS" (Test-CadenceInterval 960) "960 s"
    Check "cadence 13:59 -> FAIL" (-not (Test-CadenceInterval 839)) "839 s"
    Check "cadence 16:01 -> FAIL" (-not (Test-CadenceInterval 961)) "961 s"
    Check "fresh baseline 16:00 -> usable" (Test-FreshBaseline -AgeSeconds 960) "960 s"
    Check "fresh baseline 16:01 -> too old" (-not (Test-FreshBaseline -AgeSeconds 961)) "961 s"

    Write-Host ("app-list-cadence self-test: " + ($script:total - $script:failed) + "/" + $script:total + " fixtures passed")
    if ($script:failed -gt 0) {
        Write-Host ("SELFTEST FAILED: " + $script:failed + " of " + $script:total + " fixtures")
        exit 1
    }
    exit 0
}

if ($SelfTest) { Invoke-AppListCadenceSelfTest }

# ---------------------------------------------------------------------------------------------------
# Live run.
# ---------------------------------------------------------------------------------------------------
if (-not $Token -and $StateFile) {
    if (-not (Test-Path $StateFile)) { Write-Host ("ABORT: state file not found: " + $StateFile); exit 2 }
    $st = Get-Content $StateFile -Raw | ConvertFrom-Json
    $Token = [string]$st.token
    if (-not $Token) { $Token = [string]$st.parentToken }
    if (-not $DeviceId) { $DeviceId = [string]$st.deviceId }
}
if (-not $Token -or -not $DeviceId) {
    Write-Host "ABORT: pass -StateFile (token + deviceId) or both -DeviceId and -Token. Nothing was measured."
    exit 2
}
if (-not (Test-Path $Out)) { New-Item -ItemType Directory -Force $Out | Out-Null }
$LOG = Join-Path $Out "app-list-cadence.log"
if (Test-Path $LOG) { Remove-Item $LOG }
$S = @("-s", $Serial)
if (-not (Get-Command $Adb -ErrorAction SilentlyContinue)) {
    $candidate = "C:\KARIM\tools\android-sdk\platform-tools\adb.exe"
    if (Test-Path $candidate) { $Adb = $candidate }
}

function W($m) { $line = (Get-Date -Format "HH:mm:ss.fff") + " " + $m; $line | Add-Content $LOG -Encoding utf8; Write-Host $line }
function Sh([string]$cmd) { (& $Adb @S shell $cmd 2>&1) -join "`n" }
function Record($n, $name, $status, $evidence) {
    [void]$results.Add([pscustomobject]@{ n = $n; check = $name; result = $status; evidence = $evidence })
    W ("#" + $n + " " + $name + " -> " + $status + " : " + $evidence)
}

$results = New-Object System.Collections.ArrayList
$verdict = "FAIL"
$exitCode = 1

W ("TR-48 app-list-cadence start serial=" + $Serial + " device=" + $DeviceId + " base=" + $Base)

$devices = (& $Adb devices 2>&1) -join "`n"
if ($devices -notmatch ([regex]::Escape($Serial) + "\s+device")) {
    W ("ABORT: " + $Serial + " is not attached as an adb device")
    W (($devices -split "`n" | Where-Object { $_ -match "\S" }) -join " | ")
    exit 2
}
$model = (Sh "getprop ro.product.model").Trim()
$rel = (Sh "getprop ro.build.version.release").Trim()
W ("device " + $model + " Android " + $rel)
if ((Sh "dumpsys window") -match "isKeyguardShowing=true") {
    W "ABORT: the phone is locked (keyguard showing). Unlock it and re-run; nothing was sent to the device."
    exit 2
}

$raw3 = Sh "pm list packages -3"
$thirdParty = @($raw3 -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -like "package:*" } | ForEach-Object { $_.Substring(8) } | Sort-Object -Unique)
$rawAll = Sh "pm list packages"
$allPackages = @($rawAll -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -like "package:*" } | ForEach-Object { $_.Substring(8) } | Sort-Object -Unique)
$rawLaunch = Sh "cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER"
$launchableAll = @([regex]::Matches($rawLaunch, "(?m)^\s+([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*)/") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
if ($thirdParty.Count -eq 0 -or $launchableAll.Count -eq 0) {
    W ("ABORT: could not read the package lists (third-party " + $thirdParty.Count + ", launchable " + $launchableAll.Count + "). Nothing was measured.")
    exit 3
}
$deviceApps = Get-DeviceAppSet -ThirdParty $thirdParty -Launchable $launchableAll -AgentPackage $AGENT_PKG
W ("device reports " + $thirdParty.Count + " third-party packages, " + $launchableAll.Count + " launchable packages total, " + $deviceApps.Count + " launchable third-party apps (agent excluded)")

$agentInstalled = ($allPackages -contains $AGENT_PKG)
Record "D1" "third-party packages read (pm list packages -3)" "PASS" ($thirdParty.Count.ToString() + " packages; launchable user apps " + $deviceApps.Count)
Record "D2" "OSRA agent installed on the device" $(if ($agentInstalled) { "PASS" } else { "NOTE" }) $(if ($agentInstalled) { $AGENT_PKG + " is installed" } else { $AGENT_PKG + " is not installed: the API list cannot advance and the cadence cannot be observed" })

# ---- API inventory --------------------------------------------------------------------------------
$uri = $Base.TrimEnd("/") + "/v1/devices/" + [uri]::EscapeDataString($DeviceId) + "/apps"
$inv = $null
$stored = @()
$reportedAt = $null
$cmp = [pscustomobject]@{
    Pass = $false; Missing = @(); ToleratedMissing = @(); Stale = @(); Matched = @()
    DeviceCount = $deviceApps.Count; StoredCount = 0
}
$cadenceStatus = "WAITING"
$cadenceNote = ""
$t1 = $null; $t2 = $null; $gapSeconds = $null

try {
    $inv = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ Authorization = "Bearer " + $Token } -TimeoutSec 20
} catch {
    W ("API GET /v1/devices/" + $DeviceId + "/apps -> " + $_.Exception.Message)
}

if (-not $inv) {
    Record "A1" "API inventory read (GET /v1/devices/:id/apps)" "FAIL" "the request failed; no stored list to compare"
    $cadenceNote = "no API inventory; cadence not measured"
    Record "T1" "two consecutive appsReportedAt timestamps 14-16 min apart" "WAITING" $cadenceNote
} else {
    if ($inv.apps) { $stored = @($inv.apps | ForEach-Object { [string]$_.packageId }) }
    if ($inv.reportedAt) { $reportedAt = [DateTimeOffset]::Parse([string]$inv.reportedAt) }
    Record "A1" "API inventory read (GET /v1/devices/:id/apps)" "PASS" ($stored.Count.ToString() + " stored; reportedAt " + $(if ($reportedAt) { $reportedAt.ToString("o") } else { "null" }))

    # ---- comparison -------------------------------------------------------------------------------
    $cmp0 = Compare-AppInventory -DeviceLaunchable $deviceApps -DeviceAll $allPackages -Stored $stored -Tolerated @()
    $installTimes = @{}
    $tolerated = @()
    if ($reportedAt -and $cmp0.Missing.Count -gt 0) {
        $deviceOffset = (Sh "date +%z").Trim()
        foreach ($pkg in $cmp0.Missing) {
            $first = Get-DeviceInstallTime -Package $pkg -DeviceOffset $deviceOffset
            if ($first) { $installTimes[$pkg] = $first }
        }
        $tolerated = Get-ToleratedInstalls -InstallTimes $installTimes -ReportedAt $reportedAt -ToleranceSeconds $ToleranceSeconds
    }
    $cmp = Compare-AppInventory -DeviceLaunchable $deviceApps -DeviceAll $allPackages -Stored $stored -Tolerated $tolerated

    Record "C1" "matched launchable user apps" "PASS" ($cmp.Matched.Count.ToString() + " of " + $cmp.DeviceCount + " on the device are stored")
    Record "C2" "on device but not stored (outside the tolerance)" $(if ($cmp.Missing.Count -eq 0) { "PASS" } else { "FAIL" }) $(if ($cmp.Missing.Count -eq 0) { "none" } else { ($cmp.Missing -join ", ") })
    Record "C3" "stored but no longer on the device" $(if ($cmp.Stale.Count -eq 0) { "PASS" } else { "FAIL" }) $(if ($cmp.Stale.Count -eq 0) { "none" } else { ($cmp.Stale -join ", ") })
    Record "C4" "installed after the last sync (tolerated)" "NOTE" $(if ($cmp.ToleratedMissing.Count -eq 0) { "none" } else { ($cmp.ToleratedMissing -join ", ") + "; tolerance " + $ToleranceSeconds + " s" })

    # A stored third-party package that is present but no longer launchable is a NOTE, not a FAIL:
    # the acceptance is existence, and the next change upload replaces the row.
    $extraNonLaunchable = @($stored | Where-Object { ($thirdParty -contains $_) -and ($launchableAll -notcontains $_) } | Sort-Object -Unique)
    if ($extraNonLaunchable.Count -gt 0) {
        Record "C5" "stored but not launchable now" "NOTE" ($extraNonLaunchable -join ", ")
    }

    # ---- cadence ----------------------------------------------------------------------------------
    if (-not $reportedAt) {
        $cadenceNote = "the API has no appsReportedAt (the agent has never reported)"
    } else {
        $now = [DateTimeOffset]::UtcNow
        $age = ($now - $reportedAt).TotalSeconds
        $fresh = Test-FreshBaseline -AgeSeconds $age
        $marks = @()
        if ($fresh) {
            $marks += $reportedAt
            W ("cadence: current appsReportedAt is " + [math]::Round($age / 60.0, 1) + " min old; using it as the first endpoint and waiting for one change")
        } else {
            W ("cadence: current appsReportedAt is " + [math]::Round($age / 60.0, 1) + " min old; too old for a 14-16 min pair, so two observed changes are required")
        }
        $last = $reportedAt
        $deadline = (Get-Date).AddMinutes($CadenceWaitMinutes)
        while ((Get-Date) -lt $deadline -and $marks.Count -lt 2) {
            Start-Sleep -Seconds $PollSeconds
            $poll = $null
            try {
                $poll = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ Authorization = "Bearer " + $Token } -TimeoutSec 20
            } catch {
                W ("cadence poll -> " + $_.Exception.Message)
            }
            if (-not $poll -or -not $poll.reportedAt) { continue }
            $r2 = [DateTimeOffset]::Parse([string]$poll.reportedAt)
            if ($r2 -ne $last) {
                W ("appsReportedAt moved: " + $last.ToString("o") + " -> " + $r2.ToString("o"))
                $marks += $r2
                $last = $r2
            }
        }
        if ($marks.Count -ge 2) {
            $t1 = $marks[0]; $t2 = $marks[1]
            $gapSeconds = [math]::Round(($t2 - $t1).TotalSeconds, 0)
            if (Test-CadenceInterval $gapSeconds) { $cadenceStatus = "PASS" } else { $cadenceStatus = "FAIL" }
            $cadenceNote = "gap " + $gapSeconds + " s; window " + $CADENCE_MIN_S + "-" + $CADENCE_MAX_S + " s"
        } else {
            $cadenceStatus = "WAITING"
            $cadenceNote = "fewer than two endpoints within " + $CadenceWaitMinutes + " min; no value invented (an unchanged list uploads only every 24 h)"
        }
    }
    Record "T1" "two consecutive appsReportedAt timestamps 14-16 min apart" $cadenceStatus ($cadenceNote + $(if ($t1) { "; t1 " + $t1.ToString("o") } else { "" }) + $(if ($t2) { "; t2 " + $t2.ToString("o") } else { "" }))
}

$fails = @($results | Where-Object { $_.result -eq "FAIL" }).Count
if ($fails -gt 0) { $verdict = "FAIL"; $exitCode = 1 }
elseif ($cadenceStatus -eq "WAITING") { $verdict = "WAITING"; $exitCode = 4 }
else { $verdict = "PASS"; $exitCode = 0 }

$report = [ordered]@{
    generatedAt = [DateTimeOffset]::UtcNow.ToString("o")
    serial      = $Serial
    deviceId    = $DeviceId
    baseUrl     = $Base
    agentPackage = $AGENT_PKG
    device      = [ordered]@{
        model          = $model
        android        = $rel
        thirdParty     = $thirdParty.Count
        launchableAll  = $launchableAll.Count
        launchableUser = $deviceApps.Count
        agentInstalled = $agentInstalled
    }
    api         = [ordered]@{
        stored     = $stored.Count
        reportedAt = $(if ($reportedAt) { $reportedAt.ToString("o") } else { $null })
    }
    tolerance   = [ordered]@{
        seconds = $ToleranceSeconds
        rule    = "firstInstallTime at or after reportedAt minus the skew margin is treated as installed after the last sync"
    }
    counts      = [ordered]@{
        matched   = $cmp.Matched.Count
        missing   = $cmp.Missing.Count
        tolerated = $cmp.ToleratedMissing.Count
        stale     = $cmp.Stale.Count
    }
    missing     = @($cmp.Missing)
    tolerated   = @($cmp.ToleratedMissing)
    stale       = @($cmp.Stale)
    cadence     = [ordered]@{
        field         = "appsReportedAt"
        windowSeconds = @($CADENCE_MIN_S, $CADENCE_MAX_S)
        t1            = $(if ($t1) { $t1.ToString("o") } else { $null })
        t2            = $(if ($t2) { $t2.ToString("o") } else { $null })
        gapSeconds    = $gapSeconds
        verdict       = $cadenceStatus
        note          = $cadenceNote
    }
    results     = $results
    verdict     = $verdict
    exitCode    = $exitCode
}
$report | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $Out "app-list-cadence.json") -Encoding utf8

W "---- RESULTS ----"
$results | Format-Table -AutoSize | Out-String -Width 220
$results | Format-Table -AutoSize | Out-String -Width 220 | Add-Content $LOG -Encoding utf8
W ("TR-48 verdict: " + $verdict + " (device " + $deviceApps.Count + " launchable user apps, API " + $stored.Count + " stored); log " + $LOG)
exit $exitCode
