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
# VERDICT RULE (#221 D2). The device-vs-API comparison (C1-C4) is repeated after EVERY observed
# change of `appsReportedAt`, and the verdict comes from the LAST of those comparisons. The
# comparison at the start of the run is information only (C0): an app uninstalled between syncs is
# still stored by the API at that moment, so a start-only verdict calls it STALE and fails a phone
# that is about to upload the correct list (run 2 reported FAIL; a fresh comparison matched 93/93).
# With no observed change there is no verdict comparison: the run is WAITING (exit 4), and the start
# comparison stays in the log and JSON as information rather than a verdict.
#
# TOLERANCE for "on the device but not stored yet": an app whose `firstInstallTime` is at or after
# `reportedAt - ToleranceSeconds` is treated as installed after the last sync and is reported as
# TOLERATED, not FAIL. The default -ToleranceSeconds 60 is a clock-skew margin between the phone and
# the API host, not a product grace period. An app installed before that boundary is a FAIL. The
# reverse direction has no tolerance: a stored package the device no longer has is STALE and FAILs
# at the verdict comparison (the last one after a sync).
#
# The OSRA agent package is excluded from the device set because the collector deliberately skips
# itself (a parent must not be able to block the protection agent), so comparing it would be a false
# MISSING. Since the 2026-10-29 rename that is `com.osratech.child`: the Kotlin package is still
# `com.familyshield.agent`, but the OS reports the applicationId.
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
$AGENT_PKG = "com.osratech.child"
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
        [string]$AgentPackage = "com.osratech.child"
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

# #221 D2: which comparison supplies the verdict. The start-of-run comparison is information only;
# the verdict is the LAST comparison taken after an observed `appsReportedAt` change. No observed
# change means there is no verdict comparison, and the run is WAITING (exit 4).
function Select-VerdictComparison {
    param([object[]]$AfterChange = @())
    if ($AfterChange -and $AfterChange.Count -gt 0) {
        return [pscustomobject]@{
            Comparison = $AfterChange[$AfterChange.Count - 1]
            Source     = "after-sync"
            Count      = $AfterChange.Count
        }
    }
    return [pscustomobject]@{ Comparison = $null; Source = "none"; Count = 0 }
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

    # #221 D2: a package uninstalled between two syncs. At the start the API still stores it, so the
    # start comparison is STALE; the upload that follows removes it and the list matches again. The
    # old harness gave the verdict from that start comparison and reported FAIL (run 2), while a
    # fresh comparison matched 93/93. The fixture below would have FAILed under that rule and PASSes
    # under the new one.
    $storedBeforeSync = $device + "com.example.gone"
    $startCmp = Compare-AppInventory -DeviceLaunchable $device -DeviceAll $all -Stored $storedBeforeSync -Tolerated @()
    $afterCmp = Compare-AppInventory -DeviceLaunchable $device -DeviceAll $all -Stored $device -Tolerated @()
    $noChange = Select-VerdictComparison -AfterChange @()
    $oneChange = Select-VerdictComparison -AfterChange @($afterCmp)
    Check "start-of-run STALE is information, not a verdict" ((-not $startCmp.Pass) -and ($startCmp.Stale.Count -eq 1) -and ($null -eq $noChange.Comparison) -and ($noChange.Source -eq "none")) ("start pass " + $startCmp.Pass + "; stale " + ($startCmp.Stale -join ", ") + "; verdict source " + $noChange.Source)
    Check "package removed between syncs -> PASS on the post-sync comparison (old start-only rule: FAIL)" ($oneChange.Comparison.Pass -and ($oneChange.Source -eq "after-sync")) ("source " + $oneChange.Source + ", pass " + $oneChange.Comparison.Pass)
    $twoChanges = Select-VerdictComparison -AfterChange @($startCmp, $afterCmp)
    Check "verdict is the LAST post-sync comparison" ($twoChanges.Comparison.Pass -and ($twoChanges.Count -eq 2)) ("compared " + $twoChanges.Count + ", pass " + $twoChanges.Comparison.Pass)
    $staleFinal = Select-VerdictComparison -AfterChange @($startCmp)
    Check "a stale list after the last sync -> FAIL" ((-not $staleFinal.Comparison.Pass) -and $staleFinal.Comparison.Stale.Count -eq 1) ("stale " + ($staleFinal.Comparison.Stale -join ", "))

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

# Reads the phone's current package lists into a snapshot. $null means the lists could not be read;
# the caller decides whether that is a start abort (exit 3) or a skipped post-sync comparison.
function Get-DeviceSnapshot {
    $raw3 = Sh "pm list packages -3"
    $thirdPartyNow = @($raw3 -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -like "package:*" } | ForEach-Object { $_.Substring(8) } | Sort-Object -Unique)
    $rawAll = Sh "pm list packages"
    $allNow = @($rawAll -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -like "package:*" } | ForEach-Object { $_.Substring(8) } | Sort-Object -Unique)
    $rawLaunch = Sh "cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER"
    $launchableNow = @([regex]::Matches($rawLaunch, "(?m)^\s+([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*)/") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    if ($thirdPartyNow.Count -eq 0 -or $launchableNow.Count -eq 0) { return $null }
    return [pscustomobject]@{
        ThirdParty  = $thirdPartyNow
        AllPackages = $allNow
        LaunchableAll = $launchableNow
        DeviceApps  = @(Get-DeviceAppSet -ThirdParty $thirdPartyNow -Launchable $launchableNow -AgentPackage $AGENT_PKG)
    }
}

# One device-vs-API comparison for a snapshot, including the install-time tolerance. #221 D2: the
# live run calls this at the start (information) and again after every observed appsReportedAt change.
function Compare-DeviceSnapshot {
    param(
        [object]$Snapshot,
        [string[]]$Stored = @(),
        [object]$ReportedAt = $null,
        [int]$ToleranceSeconds = 60
    )
    $cmp0 = Compare-AppInventory -DeviceLaunchable $Snapshot.DeviceApps -DeviceAll $Snapshot.AllPackages -Stored $Stored -Tolerated @()
    $installTimes = @{}
    $tolerated = @()
    if ($ReportedAt -and $cmp0.Missing.Count -gt 0) {
        $deviceOffset = (Sh "date +%z").Trim()
        foreach ($pkg in $cmp0.Missing) {
            $first = Get-DeviceInstallTime -Package $pkg -DeviceOffset $deviceOffset
            if ($first) { $installTimes[$pkg] = $first }
        }
        $tolerated = Get-ToleratedInstalls -InstallTimes $installTimes -ReportedAt ([DateTimeOffset]$ReportedAt) -ToleranceSeconds $ToleranceSeconds
    }
    return [pscustomobject]@{
        Comparison = Compare-AppInventory -DeviceLaunchable $Snapshot.DeviceApps -DeviceAll $Snapshot.AllPackages -Stored $Stored -Tolerated $tolerated
        Tolerated  = $tolerated
    }
}

# C1-C4 for one comparison. $Verdict false means the row is information only (NOTE): the start
# comparison, or an earlier post-sync comparison that a later one supersedes.
function Record-InventoryChecks {
    param([object]$Cmp, [string]$Label, [bool]$Verdict, [int]$ToleranceSeconds = 60)
    $suffix = if ($Label) { " (" + $Label + ")" } else { "" }
    Record "C1" ("matched launchable user apps" + $suffix) $(if ($Verdict) { "PASS" } else { "NOTE" }) ($Cmp.Matched.Count.ToString() + " of " + $Cmp.DeviceCount + " on the device are stored")
    Record "C2" ("on device but not stored (outside the tolerance)" + $suffix) $(if (-not $Verdict) { "NOTE" } elseif ($Cmp.Missing.Count -eq 0) { "PASS" } else { "FAIL" }) $(if ($Cmp.Missing.Count -eq 0) { "none" } else { ($Cmp.Missing -join ", ") })
    Record "C3" ("stored but no longer on the device" + $suffix) $(if (-not $Verdict) { "NOTE" } elseif ($Cmp.Stale.Count -eq 0) { "PASS" } else { "FAIL" }) $(if ($Cmp.Stale.Count -eq 0) { "none" } else { ($Cmp.Stale -join ", ") })
    Record "C4" ("installed after the last sync (tolerated)" + $suffix) "NOTE" $(if ($Cmp.ToleratedMissing.Count -eq 0) { "none" } else { ($Cmp.ToleratedMissing -join ", ") + "; tolerance " + $ToleranceSeconds + " s" })
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

$deviceSnapshot = Get-DeviceSnapshot
if (-not $deviceSnapshot) {
    W "ABORT: could not read the package lists (pm list packages -3 or query-activities empty). Nothing was measured."
    exit 3
}
$thirdParty = $deviceSnapshot.ThirdParty
$allPackages = $deviceSnapshot.AllPackages
$launchableAll = $deviceSnapshot.LaunchableAll
$deviceApps = $deviceSnapshot.DeviceApps
W ("device reports " + $thirdParty.Count + " third-party packages, " + $launchableAll.Count + " launchable packages total, " + $deviceApps.Count + " launchable third-party apps (agent excluded)")

$agentInstalled = ($allPackages -contains $AGENT_PKG)
Record "D1" "third-party packages read (pm list packages -3)" "PASS" ($thirdParty.Count.ToString() + " packages; launchable user apps " + $deviceApps.Count)
Record "D2" "OSRA agent installed on the device" $(if ($agentInstalled) { "PASS" } else { "NOTE" }) $(if ($agentInstalled) { $AGENT_PKG + " is installed" } else { $AGENT_PKG + " is not installed: the API list cannot advance and the cadence cannot be observed" })

# ---- API inventory --------------------------------------------------------------------------------
$uri = $Base.TrimEnd("/") + "/v1/devices/" + [uri]::EscapeDataString($DeviceId) + "/apps"
$inv = $null
$startStored = @()
$startReportedAt = $null
$last = $null
$startCmp = $null
$outputCmp = [pscustomobject]@{
    Pass = $false; Missing = @(); ToleratedMissing = @(); Stale = @(); Matched = @()
    DeviceCount = $deviceApps.Count; StoredCount = 0
}
$outputStored = @()
$outputSnapshot = $deviceSnapshot
$changeComparisons = @()
$comparisonSource = "none"
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
    if ($inv.apps) { $startStored = @($inv.apps | ForEach-Object { [string]$_.packageId }) }
    if ($inv.reportedAt) { $startReportedAt = [DateTimeOffset]::Parse([string]$inv.reportedAt) }
    $last = $startReportedAt
    Record "A1" "API inventory read (GET /v1/devices/:id/apps)" "PASS" ($startStored.Count.ToString() + " stored; reportedAt " + $(if ($startReportedAt) { $startReportedAt.ToString("o") } else { "null" }))

    # #221 D2: the start comparison is information only. It is the comparison most likely to be STALE
    # on a phone whose list changed since the last upload; the verdict waits for an observed sync.
    $startCmp = (Compare-DeviceSnapshot -Snapshot $deviceSnapshot -Stored $startStored -ReportedAt $startReportedAt -ToleranceSeconds $ToleranceSeconds).Comparison
    Record "C0" "start-of-run comparison (information only; the verdict is the last comparison after a sync)" "NOTE" ("matched " + $startCmp.Matched.Count + " of " + $startCmp.DeviceCount + ", missing " + $startCmp.Missing.Count + ", stale " + $startCmp.Stale.Count + ", would be " + $(if ($startCmp.Pass) { "PASS" } else { "FAIL" }))

    # ---- cadence ----------------------------------------------------------------------------------
    if (-not $startReportedAt) {
        $cadenceNote = "the API has no appsReportedAt (the agent has never reported)"
    } else {
        $now = [DateTimeOffset]::UtcNow
        $age = ($now - $startReportedAt).TotalSeconds
        $fresh = Test-FreshBaseline -AgeSeconds $age
        $marks = @()
        if ($fresh) {
            $marks += $startReportedAt
            W ("cadence: current appsReportedAt is " + [math]::Round($age / 60.0, 1) + " min old; using it as the first endpoint and waiting for one change")
        } else {
            W ("cadence: current appsReportedAt is " + [math]::Round($age / 60.0, 1) + " min old; too old for a 14-16 min pair, so two observed changes are required")
        }
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
                # The sync just landed, so re-read the phone and compare the list the API now stores
                # with the device as it is at this moment. This is the comparison the verdict uses.
                $syncSnapshot = Get-DeviceSnapshot
                if (-not $syncSnapshot) {
                    W ("comparison after sync " + ($changeComparisons.Count + 1) + " skipped: package lists unreadable")
                } else {
                    $syncStored = @()
                    if ($poll.apps) { $syncStored = @($poll.apps | ForEach-Object { [string]$_.packageId }) }
                    $syncCmp = (Compare-DeviceSnapshot -Snapshot $syncSnapshot -Stored $syncStored -ReportedAt $r2 -ToleranceSeconds $ToleranceSeconds).Comparison
                    $changeComparisons += [pscustomobject]@{
                        Comparison = $syncCmp
                        Snapshot   = $syncSnapshot
                        Stored     = $syncStored
                        ReportedAt = $r2
                    }
                    W ("comparison after sync " + $changeComparisons.Count + " (appsReportedAt " + $r2.ToString("o") + "): matched " + $syncCmp.Matched.Count + " of " + $syncCmp.DeviceCount + ", missing " + $syncCmp.Missing.Count + ", stale " + $syncCmp.Stale.Count + " -> " + $(if ($syncCmp.Pass) { "PASS" } else { "FAIL" }))
                }
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

    # #221 D2: C1-C4 are recorded after every observed change; only the last one can be FAIL. Earlier
    # post-sync comparisons stay in the table as NOTE so the history is visible without deciding the run.
    $selection = Select-VerdictComparison -AfterChange $changeComparisons
    $comparisonSource = $selection.Source
    if ($selection.Comparison) {
        $verdictRun = $changeComparisons[$changeComparisons.Count - 1]
        $outputCmp = $verdictRun.Comparison
        $outputStored = $verdictRun.Stored
        $outputSnapshot = $verdictRun.Snapshot
        $last = $verdictRun.ReportedAt
        for ($i = 0; $i -lt $changeComparisons.Count; $i++) {
            $isLast = ($i -eq ($changeComparisons.Count - 1))
            $label = "after sync " + ($i + 1) + " of " + $changeComparisons.Count + $(if ($isLast) { "" } else { ", superseded" })
            Record-InventoryChecks -Cmp $changeComparisons[$i].Comparison -Label $label -Verdict $isLast -ToleranceSeconds $ToleranceSeconds
        }
    } else {
        $outputCmp = $startCmp
        $outputStored = $startStored
        $outputSnapshot = $deviceSnapshot
        Record-InventoryChecks -Cmp $startCmp -Label "start, no change observed" -Verdict $false -ToleranceSeconds $ToleranceSeconds
        if ($cadenceStatus -eq "PASS") {
            Record "C6" "post-sync list comparison read" "FAIL" "the cadence passed but no comparison after a sync could be read; no verdict on the list"
        }
    }

    # A stored third-party package that is present but no longer launchable is a NOTE, not a FAIL:
    # the acceptance is existence, and the next change upload replaces the row.
    $extraNonLaunchable = @($outputStored | Where-Object { ($outputSnapshot.ThirdParty -contains $_) -and ($outputSnapshot.LaunchableAll -notcontains $_) } | Sort-Object -Unique)
    if ($extraNonLaunchable.Count -gt 0) {
        Record "C5" "stored but not launchable now" "NOTE" ($extraNonLaunchable -join ", ")
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
        thirdParty     = $outputSnapshot.ThirdParty.Count
        launchableAll  = $outputSnapshot.LaunchableAll.Count
        launchableUser = $outputSnapshot.DeviceApps.Count
        agentInstalled = $agentInstalled
    }
    api         = [ordered]@{
        stored          = $outputStored.Count
        reportedAt      = $(if ($last) { $last.ToString("o") } else { $null })
        startStored     = $startStored.Count
        startReportedAt = $(if ($startReportedAt) { $startReportedAt.ToString("o") } else { $null })
        syncComparisons = $changeComparisons.Count
    }
    tolerance   = [ordered]@{
        seconds = $ToleranceSeconds
        rule    = "firstInstallTime at or after reportedAt minus the skew margin is treated as installed after the last sync"
    }
    comparison  = [ordered]@{
        source = $comparisonSource
        rule   = "the verdict is the last C1-C4 comparison after an observed appsReportedAt change; the start comparison is information only"
    }
    counts      = [ordered]@{
        matched   = $outputCmp.Matched.Count
        missing   = $outputCmp.Missing.Count
        tolerated = $outputCmp.ToleratedMissing.Count
        stale     = $outputCmp.Stale.Count
    }
    missing     = @($outputCmp.Missing)
    tolerated   = @($outputCmp.ToleratedMissing)
    stale       = @($outputCmp.Stale)
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
W ("TR-48 verdict: " + $verdict + " (device " + $outputSnapshot.DeviceApps.Count + " launchable user apps, API " + $outputStored.Count + " stored; verdict " + $comparisonSource + "); log " + $LOG)
exit $exitCode
