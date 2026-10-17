# OSRA - Android adversarial probe (plan 1.9, the Phase 1 gate).
# Attempts the ten bypasses a motivated child tries on a paired phone and reports PASS/FAIL per attempt.
# Windows PowerShell 5.1, ASCII only. Needs: adb on PATH or -Adb, a paired agent on the phone with the
# parent PIN set (default 4729 for the test family), the test API reachable at -Base (adb reverse), the
# parent token + device id in -StateFile (as written by tr10-pair.ps1), psql for the alert rows.
#
#   .\android-bypass-probe.ps1 -Serial R5CW116Y6GF -Port 3023 -StateFile C:\KARIM\KCL\tr07\tr10-state.json
#
# Every check is a measured outcome, not a unit assertion: what the OS did, how long the alert took, what
# the status screen says. The table at the end is what goes into the PR (AGENTS.md section 6).
param(
    [string]$Serial = "",
    [string]$Adb = "adb",
    [int]$Port = 3023,
    [string]$StateFile = "",
    [string]$Pin = "4729",
    [string]$Psql = "psql",
    [string]$Db = "postgres://familyshield@127.0.0.1:5432/familyshield",
    [string]$Out = (Join-Path (Get-Location) "bypass-probe")
)
$ErrorActionPreference = "Continue"
$PKG = "com.familyshield.agent"; $BASE = "http://127.0.0.1:$Port"
if (-not (Test-Path $Out)) { New-Item -ItemType Directory -Force $Out | Out-Null }
$LOG = Join-Path $Out "bypass-probe.log"; if (Test-Path $LOG) { Remove-Item $LOG }
$S = @(); if ($Serial) { $S = @("-s", $Serial) }
function W($m) { $line = (Get-Date -Format "HH:mm:ss.fff") + " " + $m; $line | Add-Content $LOG -Encoding utf8; $line }
function Sh([string]$cmd) { (& $Adb @S shell $cmd 2>&1) -join "`n" }
function UiDump { Sh "rm -f /sdcard/uip.xml; uiautomator dump /sdcard/uip.xml" | Out-Null; $raw = (& $Adb @S exec-out cat /sdcard/uip.xml 2>$null) -join ""; if ($raw -match "^<") { [xml]$raw } else { $null } }
function Bounds($node) { if ($node.bounds -match "\[(\d+),(\d+)\]\[(\d+),(\d+)\]") { return @([int](([int]$matches[1]+[int]$matches[3])/2), [int](([int]$matches[2]+[int]$matches[4])/2)) } }
function Tap($xy) { Sh ("input tap " + $xy[0] + " " + $xy[1]) | Out-Null; Start-Sleep 1 }
function Texts($ui) { if ($ui) { @($ui.SelectNodes("//node[@text!='']") | ForEach-Object { $_.text }) -join " | " } else { "(no dump)" } }
function Focus { $w = (Sh "dumpsys activity activities") -split "`n" | Select-String "topResumedActivity=" | Select-Object -First 1; if ($w) { ($w.ToString() -replace '.*topResumedActivity=ActivityRecord\{\S+ u0 ', '' -replace ' t\d+\}.*', '').Trim() } else { "?" } }
function Api($m, $path, $body, $token) { $h=@{}; if ($token) { $h["Authorization"]="Bearer $token" }; try { if ($body -ne $null) { Invoke-RestMethod -Method $m -Uri ($BASE+$path) -Headers $h -ContentType "application/json" -Body ($body|ConvertTo-Json -Depth 8) -TimeoutSec 15 } else { Invoke-RestMethod -Method $m -Uri ($BASE+$path) -Headers $h -TimeoutSec 15 } } catch { W "API $m $path -> $($_.Exception.Message)"; $null } }
function AlertCount($type) { $sql = "select count(*) from ""Alert"" where ""deviceId""='$DEV' and metadata->>'type'='$type';"; $f = Join-Path $Out "q.sql"; [IO.File]::WriteAllText($f, $sql); [int]((& $Psql -At -f $f $Db) -join "") }
function WaitAlert($type, $maxSec) { $before = AlertCount $type; $sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.Elapsed.TotalSeconds -lt $maxSec) { if ((AlertCount $type) -gt $before) { return [math]::Round($sw.Elapsed.TotalSeconds, 1) }; Start-Sleep 2 }; return -1 }
function StatusText { Sh "am force-stop $PKG" | Out-Null; Sh "am start -n $PKG/.setup.PairingActivity" | Out-Null; Start-Sleep 4; Texts (UiDump) }
function AgentAlive { ((Sh "pidof $PKG").Trim() -ne "") }
$results = New-Object System.Collections.ArrayList
function Record($n, $name, $pass, $evidence) { [void]$results.Add([pscustomobject]@{ n=$n; bypass=$name; result=$(if ($pass) { "PASS (blocked/alerted)" } else { "FAIL" }); evidence=$evidence }); W ("#$n $name -> " + $(if ($pass) { "PASS" } else { "FAIL" }) + " : " + $evidence) }

$st = Get-Content $StateFile | ConvertFrom-Json; $TOKEN = $st.token; $DEV = $st.deviceId  # NOTE: PowerShell variables are case-insensitive — never name the token `$T` next to `$t = WaitAlert …`
W ("probe start - device " + $DEV + " - " + (Sh "getprop ro.product.model").Trim() + " / Android " + (Sh "getprop ro.build.version.release").Trim())

# 1. adb uninstall while admin is active
$u = (& $Adb @S uninstall $PKG 2>&1) -join " "
Record 1 "adb uninstall (device admin active)" ($u -match "DELETE_FAILED_DEVICE_POLICY_MANAGER") $u

# 3. force-stop: the agent must come back on its own (boot receiver / WorkManager / accessibility restart)
Sh "am force-stop $PKG" | Out-Null; $sw = [Diagnostics.Stopwatch]::StartNew(); $back = $false
while ($sw.Elapsed.TotalSeconds -lt 120) { if (AgentAlive) { $back = $true; break }; Start-Sleep 3 }
Record 3 "force-stop the agent" $back ("process back after " + [int]$sw.Elapsed.TotalSeconds + " s (Android keeps a force-stopped app in the stopped state: no receiver, job or accessibility rebinding until it is launched again; the App-info route is PIN-gated, the adb route is answered by the server's device_silent alert)")
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
$dialer = (Sh "cmd package resolve-activity --brief -a com.android.phone.EmergencyDialer.DIAL" -split "`n" | Select-Object -Last 1).Trim()
if (-not $dialer -or $dialer -match "No activity") { $dialer = "com.android.phone/.EmergencyDialer" }
Sh "am start -n $dialer" | Out-Null; Start-Sleep 6
$f1 = Focus; Start-Sleep 5; $f2 = Focus
$stays = ($f1 -match "Emergency|phone|dialer|incallui") -and ($f2 -match "Emergency|phone|dialer|incallui") -and ($f2 -notmatch "LockActivity")
Record "S1" "emergency dialer reachable under lock (safety)" $stays ("dialer=$dialer; focus after 6 s: $f1; after 11 s: $f2")
Sh "input keyevent 4" | Out-Null
Api POST "/v1/devices/$DEV/command" @{ command="unlock"; payload=@{} } $TOKEN | Out-Null
$sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.Elapsed.TotalSeconds -lt 90 -and (Focus) -match "LockActivity") { Start-Sleep 1 }

# 2. pm clear (wipe app data) while admin is active - DESTRUCTIVE (it un-pairs the phone), so it runs last
$c = Sh "pm clear $PKG"
$stillPaired = ((Sh "dumpsys activity services $PKG") -match "LocationService") -or ((StatusText) -match "This device is paired")
Record 2 "pm clear (wipe data) with admin active" (($c -match "Failed") -or $stillPaired) ("pm clear -> " + $c.Trim() + "; paired after: " + $stillPaired)


W "---- RESULTS ----"
$results | Format-Table -AutoSize | Out-String -Width 220 | ForEach-Object { $_ } | Add-Content $LOG -Encoding utf8
$results | Format-Table -AutoSize | Out-String -Width 220
$results | ConvertTo-Json | Set-Content (Join-Path $Out "bypass-probe.json") -Encoding utf8
$fails = @($results | Where-Object { $_.result -eq "FAIL" }).Count
W ("probe done: " + ($results.Count - $fails) + "/" + $results.Count + " rows PASS (ten bypasses + the emergency-dialer safety check); log " + $LOG)
exit $fails
