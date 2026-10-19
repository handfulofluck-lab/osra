# TR-23 (roadmap 3.2): measure the first-run pairing path on the physical handset as a proxy for
# "a non-engineer parent pairs in five minutes". This is a MEASUREMENT script: it drives the app
# through the real UI (uiautomator bounds + `input tap`/`input text`) from a clean install to the
# screen that says the device is paired with device-admin protection on, and records wall-clock
# timestamps for every step. It does not change the app, and it does not send `lock`.
#
# The parent PIN is NOT in this file: it arrives as -Pin at run time (the lead supplies it) and is
# only typed into the two password fields. Nothing here echoes or logs it.
#
# Windows PowerShell 5.1, ASCII only.  Usage:
#   .\android-pairing-time.ps1 -Pin <pin> [-Runs 3] [-Base http://127.0.0.1:3000] [-Apk <path>] [-DryRun]
#
# Every wait the script introduces is counted and reported (see the JSON `overhead` block), so the
# note that cites these numbers can say what is mechanical and what is the app's own latency.
param(
  [Parameter(Mandatory = $true)][string]$Pin,
  [int]$Runs = 3,
  [string]$Base = "http://127.0.0.1:3000",
  [string]$Apk = "C:\KARIM\wt-pt\apps\child-android\app\build\outputs\apk\full\debug\app-full-debug.apk",
  [string]$Out = "C:\KARIM\tr-kimi\hw-2026-10-19",
  [string]$ChildName = "TR-23-PairingTime",
  [switch]$DryRun,
  [switch]$KeepChild,
  [switch]$StopAtAdmin
)
$ErrorActionPreference = "Continue"
$adb = "C:\KARIM\tools\android-sdk\platform-tools\adb.exe"
$S = "R5CW116Y6GF"
$PKG = "com.familyshield.agent"
$ADMIN = "com.familyshield.agent/.security.ParentalAdminReceiver"
. (Join-Path $PSScriptRoot "classify-build.ps1")   # the build kind is recorded with every run (issue #178)
$BASE = $Base
if (-not (Test-Path $Out)) { New-Item -ItemType Directory -Force $Out | Out-Null }
$LOG = Join-Path $Out "pairing-time.log"
if ($DryRun) { $LOG = Join-Path $Out "pairing-time-dryrun.log" }
$sw = [Diagnostics.Stopwatch]::StartNew()
$script:DumpMs = 0
$script:SleepMs = 0
$script:InputMs = @{}

function NowMs { return $sw.Elapsed.TotalMilliseconds }
# (NowMs - $x) is parsed by PowerShell as the command NowMs with an argument, not as a subtraction:
# that bug silently turned every "difference" into an absolute elapsed time. Subtract through a
# helper, and only after NowMs has been invoked on its own.
function Delta([double]$from) { $t = NowMs; return ($t - $from) }
# Record a mark from the wall clock at the call site, so the value and the log line are the same
# instant (the hashes returned by WaitText carry no timestamp for this reason).
function Stamp([string]$key) {
  $at = [math]::Round((NowMs), 0)
  $script:marks[$key] = $at
  Mark $key $script:marks $at
}
function Mark([string]$label, [hashtable]$marks, [double]$at) {
  $marks[$label] = [math]::Round($at, 0)
  W ("MARK {0,-22} +{1,8:N0} ms" -f $label, $at)
}
function W($m) {
  $line = "[+{0,8:N0} ms] {1}" -f (NowMs), $m
  $line | Add-Content $LOG -Encoding utf8
  Write-Host $line
}
function Sh([string]$cmd) { (& $adb -s $S shell $cmd 2>&1) -join "`n" }
function UiDump {
  Sh "rm -f /sdcard/ui.xml; uiautomator dump /sdcard/ui.xml" | Out-Null
  try {
    $raw = (& $adb -s $S exec-out cat /sdcard/ui.xml 2>$null) -join ""
    if ($raw -match "^<") { return [xml]$raw }
  } catch { }
  return $null
}
function Texts($ui) {
  if (-not $ui) { return "" }
  return (@($ui.SelectNodes("//node") | ForEach-Object {
        if ($_.text) { $_.text } elseif ($_.'content-desc') { $_.'content-desc' }
      }) -join " | ")
}
function Bounds($node) {
  if ($node.bounds -match "\[(\d+),(\d+)\]\[(\d+),(\d+)\]") {
    return @([int](([int]$matches[1] + [int]$matches[3]) / 2), [int](([int]$matches[2] + [int]$matches[4]) / 2))
  }
  return $null
}
function Tap($xy) { Sh ("input tap " + $xy[0] + " " + $xy[1]) | Out-Null }
function Pause([int]$ms) { Start-Sleep -Milliseconds $ms; $script:SleepMs += $ms }
# Wait until the focused window is no longer the agent's: used when an OS surface (device-admin
# activation) takes the foreground, because the previous screen's text would otherwise match.
function WaitOtherWindow([int]$timeoutSec = 30) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  $focus = ""
  while ((Get-Date) -lt $deadline) {
    $focus = Sh "dumpsys window | grep mCurrentFocus"
    if ($focus -notmatch "com\.familyshield\.agent") { return @{ ok = $true; focus = $focus } }
    Pause 100
  }
  return @{ ok = $false; focus = $focus }
}
function FindExact($ui, [string]$needle) {
  if (-not $ui) { return $null }
  return @($ui.SelectNodes("//node") | Where-Object { $_.text -and ($_.text -eq $needle) }) | Select-Object -First 1
}
# A labelled text node is not a control: "Pair this device with your OSRA server." contains
# "PAIR THIS DEVICE", so every button lookup goes through the widget class as well as the text.
function FindButton($ui, [string]$needle) {
  if (-not $ui) { return $null }
  return @($ui.SelectNodes("//node[@class='android.widget.Button']") | Where-Object { $_.text -and ($_.text.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) }) | Select-Object -First 1
}
# Time one adb input call on its own: this is the mechanical typing cost, reported separately from
# the app's own latency.
function TimeInput([string]$cmd, [string]$key) {
  $t = [Diagnostics.Stopwatch]::StartNew()
  Sh $cmd | Out-Null
  $script:InputMs[$key] = [math]::Round($t.Elapsed.TotalMilliseconds, 0)
  W ("input '" + $key + "' took " + $script:InputMs[$key] + " ms")
}
# A sideloaded APK makes Play Protect ask "Send app for a security check?" over the launcher. It is
# an artefact of installing outside the store, not part of a parent's first run, and it blocks the
# screen until answered; dismiss it with "Don't send" (nothing is uploaded) before the launch.
function DismissPlayProtect([int]$timeoutSec = 20) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    $focus = Sh "dumpsys window | grep mCurrentFocus | tail -1"
    if ($focus -notmatch "PlayProtect") { Pause 500; continue }
    $raw = Sh "uiautomator dump /sdcard/pp.xml >/dev/null 2>&1; cat /sdcard/pp.xml"
    $pp = $null
    try { if ($raw -match "^<\?xml") { $pp = [xml]$raw } } catch { }
    if ($pp) {
      $dn = FindExact $pp "Don't send"
      if ($dn) { Tap (Bounds $dn); W "play protect prompt dismissed (Don't send)"; Pause 1500; return $true }
    }
    Pause 500
  }
  W "no play protect prompt"
  return $false
}
# Poll the view tree until $needle appears; returns the matching dump plus what the poll cost.
function WaitText([string]$needle, [int]$timeoutSec = 60) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  $last = $null; $dumps = 0
  while ((Get-Date) -lt $deadline) {
    $d0 = NowMs; $ui = UiDump; $script:DumpMs += (Delta $d0); $dumps++
    $last = $ui
    if ($ui -and ((Texts $ui) -match $needle)) {
      W ("matched '" + $needle + "' after " + $dumps + " dump(s)")
      return @{ ok = $true; ui = $ui; dumps = $dumps }
    }
  }
  W ("TIMEOUT waiting for '" + $needle + "' after " + $dumps + " dump(s)")
  return @{ ok = $false; ui = $last; dumps = $dumps }
}
function FindText($ui, [string]$needle) {
  if (-not $ui) { return $null }
  return @($ui.SelectNodes("//node") | Where-Object { $_.text -and ($_.text.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) }) | Select-Object -First 1
}
function Edits($ui) {
  if (-not $ui) { return @() }
  return @(@($ui.SelectNodes("//node[@class='android.widget.EditText']")) | Sort-Object { [int]([regex]::Match($_.bounds, "\[\d+,(\d+)\]").Groups[1].Value) })
}
function Shot([string]$name) {
  $f = Join-Path $Out ("pairing-time-" + $name + ".png")
  & cmd /c ("`"$adb`" -s $S exec-out screencap -p > `"$f`"") 2>$null | Out-Null
  try {
    $b = [IO.File]::ReadAllBytes($f)
    for ($i = 0; $i -lt 4096; $i++) {
      if ($b[$i] -eq 0x89 -and $b[$i + 1] -eq 0x50) { if ($i -gt 0) { [IO.File]::WriteAllBytes($f, $b[$i..($b.Length - 1)]) }; break }
    }
  } catch { }
  W "screenshot $f"
}
function Api($method, $path, $body, $token) {
  $h = @{}; if ($token) { $h["Authorization"] = "Bearer $token" }
  try {
    if ($null -ne $body) {
      Invoke-RestMethod -Method $method -Uri ($BASE + $path) -Headers $h -ContentType "application/json" -Body ($body | ConvertTo-Json -Depth 8) -TimeoutSec 20
    } else {
      Invoke-RestMethod -Method $method -Uri ($BASE + $path) -Headers $h -TimeoutSec 20
    }
  } catch { W "API $method $path -> $($_.Exception.Message)"; $null }
}

W ("pairing-time start runs=$Runs base=$BASE dry=$DryRun (app PIN: supplied by the lead, not recorded)")
$model = (Sh "getprop ro.product.model").Trim()
$rel = (Sh "getprop ro.build.version.release").Trim()
$build = (Sh "getprop ro.build.display.id").Trim()
W "device $model Android $rel build $build"
W ("apk " + $Apk + " sha256 " + (Get-FileHash -Algorithm SHA256 $Apk).Hash.ToLower())
if ((Sh "dumpsys window") -match "isKeyguardShowing=true") { W "ABORT: keyguard showing"; exit 2 }
if (-not (Test-Path $Apk)) { W "ABORT: apk missing"; exit 2 }

$login = Api POST "/v1/auth/login" @{ email = "demo@familyshield.dev"; password = "CorrectHorseBatteryStaple!" } $null
if (-not $login.token) { W "ABORT: login failed"; exit 2 }
$TOKEN = $login.token
W "login ok"

$me = Api GET "/v1/family/me" $null $TOKEN
$child = @($me.children | Where-Object { $_.displayName -eq $ChildName }) | Select-Object -First 1
if (-not $child) {
  $region = $me.family.region
  $created = Api POST "/v1/family/children" @{ displayName = $ChildName; birthYear = 2011; consent = @{ method = "sms_plus"; jurisdiction = $region } } $TOKEN
  if (-not $created.child.id) { W ("ABORT: child create failed: " + ($created | ConvertTo-Json -Depth 6)); exit 2 }
  $childId = $created.child.id
  W "created measurement child $ChildName ($childId)"
} else {
  $childId = $child.id
  W "reusing measurement child $ChildName ($childId)"
}
# The parent token is deliberately not written to disk: only what is needed to identify the run.
$state = @{ childId = $childId; baseUrl = $BASE; apk = $Apk; apkSha256 = (Get-FileHash -Algorithm SHA256 $Apk).Hash.ToLower() }
$state | ConvertTo-Json | Set-Content (Join-Path $Out "pairing-time-state.json") -Encoding utf8

function RemoveApp {
  $dpm = Sh "dumpsys device_policy"
  if ($dpm -match [regex]::Escape("com.familyshield.agent/.security.ParentalAdminReceiver")) {
    $r = Sh "dpm remove-active-admin --user 0 $ADMIN"
    W ("dpm remove-active-admin -> " + (($r -split "`n") -join " | "))
  }
  $u = Sh "pm uninstall $PKG"
  W ("pm uninstall -> " + (($u -split "`n") -join " | "))
  $u2 = Sh "pm uninstall --user 0 $PKG"
  W ("pm uninstall --user 0 -> " + (($u2 -split "`n") -join " | "))
}

$results = @()
for ($run = 1; $run -le $Runs; $run++) {
  W ("================ RUN " + $run + " ================")
  $script:marks = @{}
  $script:pairStart = NowMs

  # --- clean install (part of the setup, outside the measured first-run window)
  RemoveApp
  $inst = (& $adb -s $S install -t -r $Apk 2>&1) -join " "
  W ("adb install -> " + $inst)
  $cl = Sh "pm clear $PKG"
  W ("pm clear -> " + (($cl -split "`n") -join " | "))
  $lp = Sh "pm list packages $PKG"
  W ("installed -> " + (($lp -split "`n") -join " | "))
  if ($lp -notmatch "package:") { W "ABORT: install did not land"; break }
  # A pairing time is a proxy measurement, and these numbers still belong to a build: a debug/testOnly
  # install is slower and is not the artefact that ships (issue #178).
  $build = Get-BuildKind -DumpsysText (Sh "dumpsys package $PKG") -Package $PKG
  W ("build under test: " + $build.Kind + " (" + $build.Detail + ")")
  if ($build.Kind -ne "release") {
    W ("NOTE: pairing numbers on a " + $build.Kind + " build are a proxy and cannot open a gate (issue #178)")
  }
  DismissPlayProtect 20 | Out-Null
  Sh "logcat -c" | Out-Null

  # --- a fresh six-digit code from the parent API, as a parent app would show it
  $pair = Api POST "/v1/devices/pair" @{ childId = $childId } $TOKEN
  if (-not $pair.code) { W ("ABORT: pair code failed: " + ($pair | ConvertTo-Json -Depth 6)); break }
  $code = [string]$pair.code
  W ("pair code issued (expires " + $pair.expiresAt + ")")

  (& $adb -s $S reverse --remove-all 2>&1) | Out-Null
  $revOut = (& $adb -s $S reverse "tcp:3000" "tcp:3000" 2>&1) -join " "
  W ("reverse tcp:3000 -> " + $revOut + " | list: " + (((& $adb -s $S reverse --list 2>&1) -join " ")))

  $script:DumpMs = 0; $script:SleepMs = 0

  # ---- t0: first launch. Marks record absolute script milliseconds; every duration in the JSON is
  # the difference of two marks, so the absolute base cancels out.
  $marks["t0_launch"] = [math]::Round((NowMs), 0)
  W "MARK t0_launch          +$($marks['t0_launch']) ms (absolute script time)"
  $am = Sh "am start -W -n $PKG/.setup.PairingActivity"
  W ("am start -W -> " + (($am -split "`n") -join " | "))

  $w = WaitText "PAIR THIS DEVICE" 60
  Stamp "t1_form"
  if (-not $w.ok) { W "ABORT: pairing form did not appear"; Shot ("run" + $run + "-fail-form"); break }
  W ("form: " + (Texts $w.ui))
  Shot ("run" + $run + "-01-form")

  $ui = $w.ui
  $edits = Edits $ui
  $pairBtn = FindButton $ui "PAIR THIS DEVICE"
  if (-not $pairBtn) { $pairBtn = @($ui.SelectNodes("//node[@class='android.widget.Button']")) | Select-Object -First 1 }
  W "form edits=$($edits.Count) button=$($pairBtn.text)"
  if ($edits.Count -lt 2 -or -not $pairBtn) { W "ABORT: form controls not found"; break }

  # ---- typed entry: mechanical, no human think/typing pauses (reported as such)
  Tap (Bounds $edits[0]); Pause 250
  $marks["t1b_server_focus"] = [math]::Round((NowMs), 0)
  Mark "t1b_server_focus" $marks $marks["t1b_server_focus"]
  TimeInput ("input text " + $BASE) "server"
  $marks["t2_server_typed"] = [math]::Round((NowMs), 0)
  Mark "t2_server_typed" $marks $marks["t2_server_typed"]
  Pause 250
  Tap (Bounds $edits[1]); Pause 250
  $marks["t2b_code_focus"] = [math]::Round((NowMs), 0)
  Mark "t2b_code_focus" $marks $marks["t2b_code_focus"]
  TimeInput ("input text " + $code) "code"
  $marks["t3_code_typed"] = [math]::Round((NowMs), 0)
  Mark "t3_code_typed" $marks $marks["t3_code_typed"]
  Shot ("run" + $run + "-02-filled")

  Sh "input keyevent 111" | Out-Null; Pause 400
  $marks["t4_pair_tap"] = [math]::Round((NowMs), 0)
  Mark "t4_pair_tap" $marks $marks["t4_pair_tap"]
  Tap (Bounds $pairBtn)

  $w = WaitText "set the parent PIN" 60
  Stamp "t5_pin_screen"
  if (-not $w.ok) { W ("ABORT: PIN screen did not appear: " + (Texts $w.ui)); Shot ("run" + $run + "-fail-pin"); break }
  W ("pin screen: " + (Texts $w.ui))
  Shot ("run" + $run + "-03-pin")

  $ui = $w.ui
  $edits = Edits $ui
  $save = FindButton $ui "SAVE PIN"
  if (-not $save) { $save = @($ui.SelectNodes("//node[@class='android.widget.Button']")) | Select-Object -Last 1 }
  W "pin screen edits=$($edits.Count) save=$($save.text)"
  if ($edits.Count -ge 2 -and $save) {
    Tap (Bounds $edits[0]); Pause 250
    TimeInput ("input text " + $Pin) "pin"
    Pause 150
    Tap (Bounds $edits[1]); Pause 250
    TimeInput ("input text " + $Pin) "pinRepeat"
    $marks["t6_pin_typed"] = [math]::Round((NowMs), 0)
    Mark "t6_pin_typed" $marks $marks["t6_pin_typed"]
    Sh "input keyevent 111" | Out-Null; Pause 400
    $marks["t7_save_tap"] = [math]::Round((NowMs), 0)
    Mark "t7_save_tap" $marks $marks["t7_save_tap"]
    Tap (Bounds $save)

    $w = WaitText "Protect this device" 60
    Stamp "t8_protect_screen"
    if (-not $w.ok) { W ("ABORT: protect screen did not appear: " + (Texts $w.ui)); Shot ("run" + $run + "-fail-protect"); break }
    W ("protect screen: " + (Texts $w.ui))
    Shot ("run" + $run + "-04-protect")

    $adminBtn = FindButton $w.ui "ACTIVATE DEVICE ADMIN"
    if (-not $adminBtn) { W "ABORT: activate-admin button not found"; break }
    $marks["t9_admin_tap"] = [math]::Round((NowMs), 0)
    Mark "t9_admin_tap" $marks $marks["t9_admin_tap"]
    Tap (Bounds $adminBtn)

    # The OS device-admin screen: a system surface, not ours. Wait until the focused window is no
    # longer the agent (otherwise our own "ACTIVATE DEVICE ADMIN" text matches), then find the
    # system screen's Activate control.
    $ow = WaitOtherWindow 30
    W ("os admin window: " + (($ow.focus -split "`n") -join " | "))
    $uiOS = $null; $activate = $null
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline -and -not $activate) {
      $d0 = NowMs; $uiOS = UiDump; $script:DumpMs += (Delta $d0)
      if ($uiOS) {
        # One UI reports this system button as clickable=false; the measurement taps it all the same,
        # because that is what a parent's finger does. The attribute is logged for the record.
        $node = FindExact $uiOS "Activate"
        if ($node) { W ("os Activate node: clickable=" + $node.clickable + " enabled=" + $node.enabled + " bounds=" + $node.bounds) }
        if ($node) { $activate = $node }
      }
      if (-not $activate) { Pause 200 }
    }
    if ($uiOS) { $uiOS.OuterXml | Set-Content (Join-Path $Out ("pairing-time-run" + $run + "-osadmin.xml")) -Encoding utf8 }
    Stamp "t10_os_admin"
    if (-not $activate) { W ("ABORT: OS admin screen did not show Activate: " + (Texts $uiOS)); Shot ("run" + $run + "-fail-osadmin"); break }
    W ("os admin screen: " + (Texts $uiOS))
    Shot ("run" + $run + "-05-os-admin")
    if ($StopAtAdmin) { W "stop at admin (debug): leaving the OS screen up"; break }
    $marks["t11_activate_tap"] = [math]::Round((NowMs), 0)
    Mark "t11_activate_tap" $marks $marks["t11_activate_tap"]
    Tap (Bounds $activate)
    Pause 500
    $dpmAfter = Sh "dumpsys device_policy"
    W ("device_policy after Activate: " + (($dpmAfter -match [regex]::Escape("com.familyshield.agent/.security.ParentalAdminReceiver"))))

    $w = WaitText "This device is paired" 60
    Stamp "t12_paired"
    if (-not $w.ok) { W ("ABORT: paired status did not appear: " + (Texts $w.ui)); Shot ("run" + $run + "-fail-paired"); break }
    $statusText = Texts $w.ui
    W ("status: " + $statusText)
    $dpmNow = Sh "dumpsys device_policy | grep -E 'ParentalAdminReceiver|Enabled admin'"
    W ("device_policy read-back: " + (($dpmNow -split "`n") -join " | "))
    Shot ("run" + $run + "-06-paired")
  } else {
    W "ABORT: PIN controls not found"
    break
  }

  $protection = ($statusText -match "Protection: device admin") -or ($statusText -match "Protection: device owner")
  $totalS = [math]::Round(($marks["t12_paired"] - $marks["t0_launch"]) / 1000.0, 1)
  W ("RUN $run TOTAL " + $totalS + " s  protection=" + $protection)

  # ---- resolve the device row this run created, then unpair it (residue stays out of the DB)
  $me2 = Api GET "/v1/family/me" $null $TOKEN
  $c2 = @($me2.children | Where-Object { $_.id -eq $childId }) | Select-Object -First 1
  $dev = @($c2.devices | Sort-Object { $_.lastSeen } -Descending) | Select-Object -First 1
  $devId = $null
  if ($dev) {
    $devId = $dev.id
    W ("paired device: " + $dev.id + " model=" + $dev.model + " os=" + $dev.osVersion + " lastSeen=" + $dev.lastSeen)
  } else { W "WARN: no device row after pairing" }

  $results += [pscustomobject]@{
    run         = $run
    codePrefix  = $code.Substring(0, 2) + "****"   # never the whole code
    totalS      = $totalS
    protection  = $protection
    build       = $build.Kind
    statusText  = $statusText
    deviceId    = $devId
    overhead    = @{ dumpMs = [math]::Round($script:DumpMs, 0); sleepMs = [math]::Round($script:SleepMs, 0); inputMs = $script:InputMs }
    marks       = $marks
    durations   = [ordered]@{
      launch_to_form          = [math]::Round(($marks["t1_form"] - $marks["t0_launch"]) / 1000.0, 1)
      server_focus_and_type   = [math]::Round(($marks["t2_server_typed"] - $marks["t1_form"]) / 1000.0, 1)
      code_focus_and_type     = [math]::Round(($marks["t3_code_typed"] - $marks["t2_server_typed"]) / 1000.0, 1)
      pair_tap_to_pin_screen  = [math]::Round(($marks["t5_pin_screen"] - $marks["t4_pair_tap"]) / 1000.0, 1)
      pin_typed               = [math]::Round(($marks["t7_save_tap"] - $marks["t5_pin_screen"]) / 1000.0, 1)
      save_to_protect_screen  = [math]::Round(($marks["t8_protect_screen"] - $marks["t7_save_tap"]) / 1000.0, 1)
      admin_tap_to_os_screen  = [math]::Round(($marks["t10_os_admin"] - $marks["t9_admin_tap"]) / 1000.0, 1)
      os_activate_to_paired   = [math]::Round(($marks["t12_paired"] - $marks["t11_activate_tap"]) / 1000.0, 1)
    }
  }
  if ($devId) { $del = Api DELETE ("/v1/devices/" + $devId) $null $TOKEN; W "unpaired device row" }
  RemoveApp
  $results | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $Out "pairing-time-runs.json") -Encoding utf8
  if ($DryRun -and $run -ge 1) { W "dry run: stopping after run 1"; break }
}

W "================ SUMMARY ================"
foreach ($r in $results) { W ("run " + $r.run + " total " + $r.totalS + " s protection=" + $r.protection + " overhead(dump=" + $r.overhead.dumpMs + "ms sleep=" + $r.overhead.sleepMs + "ms)") }
$ok = @($results | Where-Object { $_.protection }) | Select-Object -First $Runs
# The total is the measurement; the protection flag is an outcome, not a gate — on the Flip4 the
# system admin sheet's Activate control is inert, so this reports it instead of failing the run.
$sorted = @($results | ForEach-Object { $_.totalS } | Sort-Object)
if ($sorted.Count -ge 1) {
  $median = if ($sorted.Count % 2) { $sorted[[int](($sorted.Count - 1) / 2)] } else { [math]::Round((($sorted[$sorted.Count / 2 - 1] + $sorted[$sorted.Count / 2]) / 2), 1) }
  W ("median of " + $sorted.Count + " runs: " + $median + " s  (" + ($sorted -join ", ") + ")")
  W ("runs reaching device admin: " + $ok.Count + " of " + $sorted.Count)
}
$results | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $Out "pairing-time-runs.json") -Encoding utf8
if (-not $KeepChild) {
  $d = Api DELETE ("/v1/family/children/" + $childId) $null $TOKEN
  W ("deleted measurement child " + $ChildName + ": " + (($d | ConvertTo-Json -Depth 4 -Compress)))
}
(& $adb -s $S reverse --remove-all 2>&1) | Out-Null
W "done"
exit 0
