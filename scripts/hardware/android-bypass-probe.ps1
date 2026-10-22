# OSRA - Android adversarial probe (plan 1.9, the Phase 1 gate).
# Attempts the ten bypasses a motivated child tries on a paired phone and reports PASS/FAIL per attempt.
# Windows PowerShell 5.1, ASCII only. Needs: adb on PATH or -Adb, a paired agent on the phone with the
# parent PIN set (no default: pass -Pin (see the local credentials note)), the test API reachable at -Base (adb reverse), the
# parent token + device id in -StateFile (as written by tr10-pair.ps1), psql for the alert rows.
#
#   .\android-bypass-probe.ps1 -Serial R5CW116Y6GF -Port 3023 -StateFile C:\KARIM\KCL\tr07\tr10-state.json [-AllowTestBuild]
#
# Build kind is part of the evidence (issue #178). Before any row the probe reads the installed
# package's flags (`dumpsys package`) and, as a second signal, `run-as <pkg> true`. On a testOnly or
# debuggable build it REFUSES to run (exit 3) unless -AllowTestBuild is passed: such an APK can be
# replaced with `adb install -r` without a signature match, its device admin can be removed with
# `dpm`, and its process is debuggable, so a PASS on it says nothing about the release artefact.
# Under -AllowTestBuild every row's evidence is prefixed `NOT EVIDENCE (testOnly/debuggable build)`
# and the summary says the run cannot open a gate. The decision is classify-build.ps1, which has
# fixtures from the Flip4 and a `-SelfTest` CI runs (workflow-lint). With -CheckBuild the probe reads
# the kind, prints the decision and exits (0 release, 3 blocked) without running any row.
#
# Row 3 (accepted 2026-10-18, QA/TESTING-STRATEGY.md 3a) waits one device-silence window plus one job
# tick, so the API under test must run with JOBS_ENABLED=1 and the window it was started with must be
# passed here as -SilenceMinutes (default 30, the product default; the job floors it at 5). A run with
# -SilenceMinutes 5 against an API started with DEVICE_SILENT_MINUTES=5 waits at most 10.5 minutes for
# the alert. The old expectation (the agent back within 120 s of the force-stop) is still measured and
# logged, as a NOTE, because Android cannot meet it and it gates nothing.
#
# Every check is a measured outcome, not a unit assertion: what the OS did, how long the alert took, what
# the status screen says. The table at the end is what goes into the PR (AGENTS.md section 6).
param(
    [string]$Serial = "",
    [string]$Adb = "adb",
    [int]$Port = 3023,
    [string]$StateFile = "",
    # The app PIN. Not `Mandatory` on purpose: a mandatory parameter that is missing makes PowerShell
    # prompt on an interactive host and *hang* a non-interactive run, which is what happened on
    # 2026-10-20 (#151). It falls back to $env:OSRA_TEST_APP_PIN and otherwise exits 2 with a message.
    [string]$Pin = "",
    [string]$Psql = "psql",
    [string]$DbUrl = "postgres://familyshield@127.0.0.1:5432/familyshield",
    [int]$SilenceMinutes = 30,
    [string]$Out = (Join-Path (Get-Location) "bypass-probe"),
    [switch]$AllowTestBuild,
    [switch]$CheckBuild
)
$ErrorActionPreference = "Continue"
# #151: a missing PIN must fail fast, not prompt. PowerShell only prompts for a *Mandatory* parameter, so
# the parameter is optional and the refusal lives here — exit 2 is "misused", distinct from a failed check
# (1) so a caller can tell "you forgot the PIN" from "the phone failed the gate".
if ([string]::IsNullOrWhiteSpace($Pin)) { $Pin = [string]$env:OSRA_TEST_APP_PIN }
if ([string]::IsNullOrWhiteSpace($Pin)) {
    Write-Error ("-Pin is required (or set OSRA_TEST_APP_PIN). The PIN is deliberately not in this repo " +
        "(#151); it is the app PIN for the test family, not the phone's keyguard PIN.")
    exit 2
}
$PKG = "com.familyshield.agent"; $BASE = "http://127.0.0.1:$Port"
if (-not (Test-Path $Out)) { New-Item -ItemType Directory -Force $Out | Out-Null }
$LOG = Join-Path $Out "bypass-probe.log"; if (Test-Path $LOG) { Remove-Item $LOG }
$S = @(); if ($Serial) { $S = @("-s", $Serial) }
. (Join-Path $PSScriptRoot "classify-build.ps1")
# Empty until the build check sets it. When it is set, every recorded row carries it, so a row copied
# out of the log or the JSON cannot pass for gate evidence by accident.
$script:EvidencePrefix = ""
function W($m) { $line = (Get-Date -Format "HH:mm:ss.fff") + " " + $m; $line | Add-Content $LOG -Encoding utf8; $line }
function Sh([string]$cmd) { (& $Adb @S shell $cmd 2>&1) -join "`n" }
function UiDump { Sh "rm -f /sdcard/uip.xml; uiautomator dump /sdcard/uip.xml" | Out-Null; $raw = (& $Adb @S exec-out cat /sdcard/uip.xml 2>$null) -join ""; if ($raw -match "^<") { [xml]$raw } else { $null } }
function Bounds($node) { if ($node.bounds -match "\[(\d+),(\d+)\]\[(\d+),(\d+)\]") { return @([int](([int]$matches[1]+[int]$matches[3])/2), [int](([int]$matches[2]+[int]$matches[4])/2)) } }
function Tap($xy) { Sh ("input tap " + $xy[0] + " " + $xy[1]) | Out-Null; Start-Sleep 1 }
function Texts($ui) { if ($ui) { @($ui.SelectNodes("//node[@text!='']") | ForEach-Object { $_.text }) -join " | " } else { "(no dump)" } }
function Focus { $w = (Sh "dumpsys activity activities") -split "`n" | Select-String "topResumedActivity=" | Select-Object -First 1; if ($w) { ($w.ToString() -replace '.*topResumedActivity=ActivityRecord\{\S+ u0 ', '' -replace ' t\d+\}.*', '').Trim() } else { "?" } }
# The window that holds input focus, which is what tells the owner whether the PIN pad is reachable
# (issue #87: LockActivity draws over the OS keyguard, so activity focus alone is not enough).
function FocusWindow { $w = (Sh "dumpsys window") -split "`n" | Select-String "mCurrentFocus=" | Select-Object -First 1; if ($w) { ($w.ToString() -replace '.*mCurrentFocus=', '').Trim() } else { "?" } }
function KeyguardUp { ((Sh "dumpsys window") -match "isKeyguardShowing=true") }
function Api($m, $path, $body, $token) { $h=@{}; if ($token) { $h["Authorization"]="Bearer $token" }; try { if ($body -ne $null) { Invoke-RestMethod -Method $m -Uri ($BASE+$path) -Headers $h -ContentType "application/json" -Body ($body|ConvertTo-Json -Depth 8) -TimeoutSec 15 } else { Invoke-RestMethod -Method $m -Uri ($BASE+$path) -Headers $h -TimeoutSec 15 } } catch { W "API $m $path -> $($_.Exception.Message)"; $null } }
function AlertCount($type) { $sql = "select count(*) from ""Alert"" where ""deviceId""='$DEV' and metadata->>'type'='$type';"; $f = Join-Path $Out "q.sql"; [IO.File]::WriteAllText($f, $sql); [int]((& $Psql -At -f $f $DbUrl) -join "") }
function SqlScalar($sql) { $f = Join-Path $Out "q.sql"; [IO.File]::WriteAllText($f, $sql); (((& $Psql -At -f $f $DbUrl) -join "`n").Trim()) }
# Row 3's two facts, read from Postgres so the row is a measurement of the server, not of the app.
function SilenceAlerts { [int](SqlScalar "select count(*) from ""Alert"" where ""deviceId""='$DEV' and severity='critical' and (metadata->>'type'='device_silent' or category='tamper');") }
function DeviceStatus { SqlScalar "select status from ""Device"" where id='$DEV';" }
function DeviceLastSeen { SqlScalar "select ""lastSeen"" from ""Device"" where id='$DEV';" }
function WaitAlert($type, $maxSec) { $before = AlertCount $type; $sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.Elapsed.TotalSeconds -lt $maxSec) { if ((AlertCount $type) -gt $before) { return [math]::Round($sw.Elapsed.TotalSeconds, 1) }; Start-Sleep 2 }; return -1 }
function StatusText { Sh "am start -n $PKG/.setup.PairingActivity" | Out-Null; Start-Sleep 2; Sh "input keyevent 4" | Out-Null; Sh "am start -n $PKG/.setup.PairingActivity" | Out-Null; Start-Sleep 4; Texts (UiDump) }  # re-open (Back + start) so the status re-renders; never force-stop here, that kills the 60-s loop the rows measure
function AgentAlive { ((Sh "pidof $PKG").Trim() -ne "") }
$results = New-Object System.Collections.ArrayList
function Evidence([string]$text) { if ($script:EvidencePrefix) { return ($script:EvidencePrefix + $text) }; return $text }
function Record($n, $name, $pass, $evidence) { $ev = Evidence $evidence; [void]$results.Add([pscustomobject]@{ n=$n; bypass=$name; result=$(if ($pass) { "PASS (blocked/alerted)" } else { "FAIL" }); evidence=$ev }); W ("#$n $name -> " + $(if ($pass) { "PASS" } else { "FAIL" }) + " : " + $ev) }
# A row that could not be measured is neither a pass nor a fail: it must not read green, and it must not
# accuse the product either. It is reported as NOT MEASURED and the run exits non-zero (see the end).
function RecordNote($n, $name, $note) { $ev = Evidence $note; [void]$results.Add([pscustomobject]@{ n=$n; bypass=$name; result="NOT MEASURED"; evidence=$ev }); W ("#$n $name -> NOT MEASURED : " + $ev) }
# A note is a recorded observation that gates nothing. Row 3's old expectation is what this is for: it
# stays visible in the table without turning the run red, because Android cannot meet it.
function RecordInfo($n, $name, $note) { $ev = Evidence $note; [void]$results.Add([pscustomobject]@{ n=$n; bypass=$name; result="NOTE"; evidence=$ev }); W ("#$n $name -> NOTE : " + $ev) }

$st = Get-Content $StateFile | ConvertFrom-Json; $TOKEN = $st.token; $DEV = $st.deviceId  # NOTE: PowerShell variables are case-insensitive — never name the token `$T` next to `$t = WaitAlert …`
if ((Sh "dumpsys window") -match "isKeyguardShowing=true") { W "ABORT: the phone is locked (keyguard showing) - the status screen and the OS screens cannot be read; unlock it and re-run"; exit 2 }

# ---- build kind, before any row (issue #178) ---------------------------------------------------------
# #170 makes every debug APK testOnly and debuggable. The rows below measure the protections that
# testOnly relaxes, so their verdict belongs to the artefact that was measured. Read it, name it, and
# refuse to pretend a debug PASS is gate evidence.
$build = Get-BuildKind -DumpsysText (Sh "dumpsys package $PKG") -Package $PKG
if ($build.Kind -eq "not-installed") {
    W ("ABORT: " + $PKG + " is not installed on the device (" + $build.Detail + ") - install the build under test and re-run; nothing was measured")
    exit 2
}
if ($build.Kind -eq "unknown") {
    W ("ABORT: could not read the installed package flags (" + $build.Detail + ") - run 'adb shell dumpsys package " + $PKG + "' by hand and re-run; nothing was measured")
    exit 2
}
# Second signal: `run-as` exits 0 only for a debuggable package, otherwise it prints
# "run-as: package not debuggable: <pkg>" and exits 1 (measured on the Flip4, Android 16).
$runAsOk = $false
(& $Adb @S shell "run-as $PKG true" 2>&1) | Out-Null
if ($LASTEXITCODE -eq 0) { $runAsOk = $true }
$buildKind = $build.Kind
if ($runAsOk -and $buildKind -eq "release") {
    $buildKind = "debuggable"
    $build.Detail = $build.Detail + "; run-as $PKG true exited 0"
}
$gateBlocked = ($buildKind -eq "test-only" -or $buildKind -eq "debuggable")
if ($gateBlocked -and -not $AllowTestBuild) {
    W ("REFUSED: " + $PKG + " on this device is a " + $buildKind + " build (" + $build.Detail + ").")
    W "Gate rows measured on a testOnly/debuggable build are NOT evidence: the APK can be replaced with 'adb install -r' without a signature match, its device admin can be removed with 'dpm', and its process is debuggable - so a PASS says nothing about the release artefact."
    W "Install the release-signed APK (scripts/hardware/android-signing-tr07.ps1) and re-run. For a development run that cannot open a gate, re-run with -AllowTestBuild."
    exit 3
}
if ($gateBlocked) {
    $script:EvidencePrefix = "NOT EVIDENCE (testOnly/debuggable build) - "
    W ("debug/testOnly build: tamper rows are not gate evidence - build kind " + $buildKind + " (" + $build.Detail + "); continuing under -AllowTestBuild, this run cannot open a gate")
} else {
    W ("build under test: release (" + $build.Detail + ") - gate-eligible")
}
# One summary string for both the end of a run and -CheckBuild, so the sentence an operator reads is
# exercised without a 35-minute probe run.
$script:GateBlocked = $gateBlocked
$script:GateBuildKind = $buildKind
$script:GateBuildDetail = $build.Detail
function GateSummary {
    if ($script:GateBlocked) { return ("GATE: this run cannot open a gate - it measured a " + $script:GateBuildKind + " build (" + $script:GateBuildDetail + "). Every row is NOT EVIDENCE for the release artefact; install the release-signed APK and re-run without -AllowTestBuild.") }
    return ("GATE: build kind release (" + $script:GateBuildDetail + ") - gate-eligible")
}
if ($CheckBuild) {
    W (GateSummary)
    if ($gateBlocked) { exit 3 }
    exit 0
}
W ("probe start - device " + $DEV + " - " + (Sh "getprop ro.product.model").Trim() + " / Android " + (Sh "getprop ro.build.version.release").Trim())

# 1. adb uninstall while admin is active
$u = (& $Adb @S uninstall $PKG 2>&1) -join " "
Record 1 "adb uninstall (device admin active)" ($u -match "DELETE_FAILED_DEVICE_POLICY_MANAGER") $u

# 3. force-stop: the server must notice the silent device within one silence window (QA/TESTING-STRATEGY.md
#    3a, accepted 2026-10-18). The row is asserted on the server's own record: a critical tamper /
#    device_silent alert for this device and Device.status = "offline". Backdating lastSeen in Postgres
#    would measure the job and not the product, so the row waits the real elapsed window: DEVICE_SILENT_MINUTES
#    (passed as -SilenceMinutes; the job floors it at 5) plus one scheduler tick (src/jobs/deviceSilence.ts,
#    TICK_MS = 5 min) plus 30 s of slack.
#    The previous expectation - the agent back within 120 s - is measured too, and reported as a NOTE:
#    Android keeps a force-stopped package in the stopped state, so no code change can meet it (TR-21).
$silenceBefore = SilenceAlerts; $seenBefore = DeviceLastSeen
Sh "am force-stop $PKG" | Out-Null; $sw = [Diagnostics.Stopwatch]::StartNew(); $back = $false
while ($sw.Elapsed.TotalSeconds -lt 120) { if (AgentAlive) { $back = $true; break }; Start-Sleep 3 }
$backSec = [int]$sw.Elapsed.TotalSeconds
RecordInfo "3-note" "old row 3: agent self-recovers within 120 s of am force-stop" ("process back within 120 s = " + $back + " after " + $backSec + " s (Android stopped state: no broadcast, job or accessibility rebinding until the app is launched again; TR-21 measured came back=False after 121 s). Not a gate: it is the expectation this row replaced")
$budget = ($SilenceMinutes + 5) * 60 + 30
# The stopwatch is NOT reset: the budget is measured from the force-stop, so the 120-s note above is part
# of the accepted "window plus one tick" and cannot extend it.
$new = 0; $firstAt = -1
while ($sw.Elapsed.TotalSeconds -lt $budget) {
    $new = (SilenceAlerts) - $silenceBefore
    if ($new -ge 1) { $firstAt = [math]::Round($sw.Elapsed.TotalSeconds, 1); break }
    Start-Sleep 10
}
if ($firstAt -lt 0) { $new = (SilenceAlerts) - $silenceBefore }
$statusAfter = DeviceStatus; $seenAfter = DeviceLastSeen
Record 3 "force-stop the agent (server notices the silent device)" (($new -eq 1) -and ($statusAfter -eq "offline")) ("silence window " + $SilenceMinutes + " min + 1 tick = " + $budget + " s budget: new critical tamper/device_silent alerts = " + $new + " (first after " + $(if ($firstAt -ge 0) { $firstAt } else { "never" }) + " s); Device.status = " + $statusAfter + "; lastSeen " + $seenBefore + " -> " + $seenAfter + "; self-recovery within 120 s = " + $back + " (note, not gated)")
# the rest of the probe needs a live agent: relaunch it the way the parent (or the next boot) would, and re-enable the
# accessibility service, which the OS drops from the enabled list when the app is force-stopped
Sh "am start -n $PKG/.setup.PairingActivity" | Out-Null; Start-Sleep 4; Sh "input keyevent 3" | Out-Null
Sh "settings put secure enabled_accessibility_services $PKG/$PKG.services.AccessibilityMonitorService" | Out-Null; Sh "settings put secure accessibility_enabled 1" | Out-Null; Start-Sleep 5

# 4. turn the accessibility service off (the OS switch, by adb) -> alert within 90 s
Sh "settings put secure enabled_accessibility_services ''" | Out-Null
Sh "am start-foreground-service -n $PKG/.services.LocationService" | Out-Null
$t = WaitAlert "accessibility" 90
Record 4 "accessibility service turned off" ($t -ge 0) ("tamper/accessibility alert after " + $t + " s")
Sh "settings put secure enabled_accessibility_services $PKG/$PKG.services.AccessibilityMonitorService" | Out-Null; Sh "settings put secure accessibility_enabled 1" | Out-Null

# 5. revoke "display over other apps" -> alert + status names it
Sh "appops set $PKG SYSTEM_ALERT_WINDOW deny" | Out-Null
$t = WaitAlert "overlay_revoked" 90; $stat = StatusText
Record 5 "overlay permission revoked" (($t -ge 0) -and ($stat -match "Display over other apps|of 7 required")) ("alert after " + $t + " s; status: " + ([regex]::Match($stat, "\d of 7 required grants done[^|]*").Value))
Sh "appops set $PKG SYSTEM_ALERT_WINDOW allow" | Out-Null

# 6. Private DNS set to a provider (bypasses any DNS filter silently) -> alert + status
Sh "settings put global private_dns_mode hostname; settings put global private_dns_specifier dns.google" | Out-Null
$t = WaitAlert "private_dns_bypass" 90; $stat = StatusText
Record 6 "Private DNS provider set" (($t -ge 0) -and ($stat -match "Private DNS|of 7 required")) ("alert after " + $t + " s; status: " + ([regex]::Match($stat, "\d of 7 required grants done[^|]*").Value))
Sh "settings put global private_dns_mode off" | Out-Null

# 7. lock survives Home / Recents / reboot-less escape attempts
$r = Api POST "/v1/devices/$DEV/command" @{ command="lock"; payload=@{} } $TOKEN
$sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.Elapsed.TotalSeconds -lt 90 -and (Focus) -notmatch "LockActivity") { Start-Sleep 1 }
$locked = (Focus) -match "LockActivity"
Sh "input keyevent 3" | Out-Null; Start-Sleep 3; $h = (Focus) -match "LockActivity"
Sh "input keyevent 187" | Out-Null; Start-Sleep 3; $rc = (Focus) -match "LockActivity"
Sh "am start -a android.settings.SETTINGS" | Out-Null; Start-Sleep 3; $se = (Focus) -match "LockActivity"
Record 7 "escape the lock (Home / Recents / Settings)" ($locked -and $h -and $rc -and $se) ("locked=$locked home=$h recents=$rc settings=$se")
Api POST "/v1/devices/$DEV/command" @{ command="unlock"; payload=@{} } $TOKEN | Out-Null
$sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.Elapsed.TotalSeconds -lt 90 -and (Focus) -match "LockActivity") { Start-Sleep 1 }

# 8. go offline to dodge a lock, then come back: the lock must hold offline and the queue must drain
Sh "svc wifi disable; svc data disable" | Out-Null; Start-Sleep 3
$r = Api POST "/v1/devices/$DEV/command" @{ command="lock"; payload=@{} } $TOKEN
Sh "svc wifi enable; svc data enable" | Out-Null
$sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.Elapsed.TotalSeconds -lt 120 -and (Focus) -notmatch "LockActivity") { Start-Sleep 1 }
$lockedAfterOffline = (Focus) -match "LockActivity"
Sh "svc wifi disable; svc data disable" | Out-Null; Start-Sleep 2; Sh "input keyevent 3" | Out-Null; Start-Sleep 3; $holdsOffline = (Focus) -match "LockActivity"
Sh "svc wifi enable; svc data enable" | Out-Null
Record 8 "offline / airplane to dodge or escape a lock" ($lockedAfterOffline -and $holdsOffline) ("lock arrived after reconnect: $lockedAfterOffline; held with radios off: $holdsOffline")
Api POST "/v1/devices/$DEV/command" @{ command="unlock"; payload=@{} } $TOKEN | Out-Null
$sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.Elapsed.TotalSeconds -lt 120 -and (Focus) -match "LockActivity") { Start-Sleep 1 }

# 9. disconnect the web filter VPN from Settings (needs the screenshot route on Samsung) - here: via the agent's own stop, then check the alert path
#    adb cannot press the OS dialog reliably on One UI (uiautomator never idles there); the probe records the alert that the revoke produced in TR-14 if present, else asks for a manual tap.
$before = AlertCount "content_filter_disconnected"
W "#9 manual step: Settings > Connections > More connection settings > VPN > OSRA > Disconnect (60 s window)"
$t = WaitAlert "content_filter_disconnected" 60
Record 9 "web filter (VPN) disconnected in Settings" ($t -ge 0) ("alert after " + $t + " s (manual tap; -1 = nobody tapped)")

# 10. deactivate device admin from Settings while the guard is up (manual on One UI) -> guard screen + alert
W "#10 manual step: Settings > Security > Other security settings > Device admin apps > OSRA (60 s window): the PIN screen must cover it"
$sw = [Diagnostics.Stopwatch]::StartNew(); $guard = $false; while ($sw.Elapsed.TotalSeconds -lt 60) { if ((Focus) -match "TamperGuardActivity") { $guard = $true; break }; Start-Sleep 1 }
$t = WaitAlert "protection_screen_opened" 30
Record 10 "deactivate device admin from Settings" ($guard -or ($t -ge 0)) ("guard on top: $guard; protection_screen_opened alert after " + $t + " s (manual; -1 = nobody opened it)")

# S1. SAFETY, not a bypass: the emergency dialer must stay reachable under lock (LockEnforcementPolicy exempts
#     com.android.phone / the dialers; a wrong answer here blocks a child from calling for help). No call is placed.
$r = Api POST "/v1/devices/$DEV/command" @{ command="lock"; payload=@{} } $TOKEN
$sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.Elapsed.TotalSeconds -lt 90 -and (Focus) -notmatch "LockActivity") { Start-Sleep 1 }
# `lock` is a real lockNow() (ADR-0010), so on a phone with a secure lock the OS KEYGUARD sits above
# LockActivity and above anything `am start` can launch. A dialer started by adb then never reaches the
# front, and the row would read "LockActivity on top" whether or not the overlay exempts the dialer -
# that is a measurement of the keyguard, not of the policy. Dismiss it (works on a swipe-only lock) and
# refuse to record a verdict while it is still up; a secure PIN can only be entered by the human.
Sh "wm dismiss-keyguard" | Out-Null; Start-Sleep 1
if ((Sh "dumpsys window") -match "isKeyguardShowing=true") { Sh "input swipe 540 1800 540 700 250" | Out-Null; Start-Sleep 2 }
$keyguardUp = ((Sh "dumpsys window") -match "isKeyguardShowing=true")
if ($keyguardUp) {
    RecordNote "S1" "emergency dialer reachable under lock (safety)" "NOT MEASURED: the OS keyguard was still up after the lock, so a dialer launched by adb cannot reach the front and the row would accuse LockActivity no matter what the policy does. Unlock the phone (swipe or the device PIN) with the lock overlay up and re-run."
} else {
    $dialer = (Sh "cmd package resolve-activity --brief -a com.android.phone.EmergencyDialer.DIAL" -split "`n" | Select-Object -Last 1).Trim()
    if (-not $dialer -or $dialer -match "No activity") { $dialer = "com.android.phone/.EmergencyDialer" }
    Sh "am start -n $dialer" | Out-Null; Start-Sleep 6
    $f1 = Focus; Start-Sleep 5; $f2 = Focus
    $stays = ($f1 -match "Emergency|phone|dialer|incallui") -and ($f2 -match "Emergency|phone|dialer|incallui") -and ($f2 -notmatch "LockActivity")
    Record "S1" "emergency dialer reachable under lock (safety)" $stays ("dialer=$dialer; focus after 6 s: $f1; after 11 s: $f2")
}
Sh "input keyevent 4" | Out-Null
Api POST "/v1/devices/$DEV/command" @{ command="unlock"; payload=@{} } $TOKEN | Out-Null
$sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.Elapsed.TotalSeconds -lt 90 -and (Focus) -match "LockActivity") { Start-Sleep 1 }

# S2. SAFETY/UX (issue #87): the parent overlay must never make the owner's own PIN unreachable.
#     lock is a real lockNow(), so the OS bouncer comes up; a pause sent while it is up must not draw over
#     it. Focus is read from the window manager, not the activity manager: "LockActivity on top" and "the
#     bouncer is reachable" can both be true in the activity stack, and only mCurrentFocus says which one
#     the owner is looking at. No PIN is entered: the row only requires the bouncer to hold focus.
$r = Api POST "/v1/devices/$DEV/command" @{ command="lock"; payload=@{} } $TOKEN
$sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.Elapsed.TotalSeconds -lt 60 -and -not (KeyguardUp)) { Start-Sleep 1 }
$keyguardUp = KeyguardUp
if (-not $keyguardUp) {
    RecordNote "S2" "owner can reach the keyguard while the overlay is up (safety, #87)" "NOT MEASURED: the keyguard never came up after the lock command, so there is no bouncer to reach."
} else {
    $r = Api POST "/v1/devices/$DEV/command" @{ command="pause"; payload=@{} } $TOKEN
    Start-Sleep 4
    $fw = FocusWindow
    $covers = $fw -match "LockActivity|BlockActivity"
    # Neither overlay may draw, and the keyguard must still be the thing in front: a null focus alone
    # would also be produced by a dead app, so the two conditions are asserted together.
    $kgStill = KeyguardUp
    Record "S2" "owner can reach the keyguard while the overlay is up (safety, #87)" ((-not $covers) -and $kgStill) ("keyguard up before and after the pause: " + $kgStill + "; mCurrentFocus after pause: " + $fw)
}
Api POST "/v1/devices/$DEV/command" @{ command="resume"; payload=@{} } $TOKEN | Out-Null
$sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.Elapsed.TotalSeconds -lt 60 -and (Focus) -match "LockActivity") { Start-Sleep 1 }
Sh "wm dismiss-keyguard" | Out-Null; Start-Sleep 1
if (KeyguardUp) { Sh "input swipe 540 1800 540 700 250" | Out-Null; Start-Sleep 2 }

# 2. pm clear (wipe app data) while admin is active - DESTRUCTIVE (it un-pairs the phone), so it runs last
$c = Sh "pm clear $PKG"
$stillPaired = ((Sh "dumpsys activity services $PKG") -match "LocationService") -or ((StatusText) -match "This device is paired")
Record 2 "pm clear (wipe data) with admin active" (($c -match "Failed") -or $stillPaired) ("pm clear -> " + $c.Trim() + "; paired after: " + $stillPaired)


W "---- RESULTS ----"
$results | Format-Table -AutoSize | Out-String -Width 220 | ForEach-Object { $_ } | Add-Content $LOG -Encoding utf8
$results | Format-Table -AutoSize | Out-String -Width 220
# The build is a field of the result, not something the reader has to infer from the evidence prefix:
# a consumer that ignores `gateEligible` can still see what kind of artefact produced the rows.
$report = [ordered]@{
    run = [ordered]@{
        package      = $PKG
        device       = $DEV
        buildKind    = $buildKind
        buildFlags   = @($build.Flags)
        testOnly     = ($buildKind -eq "test-only")
        debuggable   = ($buildKind -eq "debuggable")
        gateEligible = (-not $gateBlocked)
        allowTestBuild = [bool]$AllowTestBuild
    }
    results = $results
}
$report | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $Out "bypass-probe.json") -Encoding utf8
$fails = @($results | Where-Object { $_.result -eq "FAIL" }).Count
$unmeasured = @($results | Where-Object { $_.result -eq "NOT MEASURED" }).Count
$notes = @($results | Where-Object { $_.result -eq "NOTE" }).Count
$passed = @($results | Where-Object { $_.result -like "PASS*" }).Count
$gated = @($results | Where-Object { $_.result -ne "NOTE" }).Count
W ("probe done: " + $passed + "/" + $gated + " gated rows PASS, " + $fails + " FAIL, " + $unmeasured + " NOT MEASURED, " + $notes + " NOTE (recorded, not gated) (ten bypasses + the emergency-dialer safety check); log " + $LOG)
W (GateSummary)
# An unmeasured row is not a green row: fail the run so CI and the operator both notice.
exit ($fails + $unmeasured)
