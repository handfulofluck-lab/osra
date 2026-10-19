# scripts/hardware/android-signing-tr07.ps1 - the TR-07 hardware half, scripted (ADR-0014; plan item 1.9 seed).
#
# What it proves, on a real phone over adb:
#   1. the Android agent built from <branch> pairs through its own launcher form against an API built from the
#      same checkout (pair/claim 201, then the device JWT polls commands/rules/blocklists);
#   2. a child-side SOS (quick-settings tile -> SosActivity -> 5 s countdown) produces POST /v1/alerts/internal
#      -> 201 with the v2 signature (timestamp + nonce) - first with INTERNAL_SIGNING_ALLOW_V1=1, then with the
#      switch off (the default since 2026-10-17);
#   3. the phone's clock skew against the host (the signing window is +/-300 s).
# Then it cleans up (AGENTS.md section 7): uninstall, reverse removed, test device unpaired, alert rows deleted.
#
# Host assumptions (the Windows test PC): Postgres on 5432 and Redis on 6379 already running (start-backend.bat),
# JDK 17 under C:\KARIM\tools\jdk-17 (or JAVA_HOME), Android SDK with platform-tools, node + pnpm under
# C:\KARIM\tools\node, psql under C:\KARIM\tools\pg. USB debugging authorised on the phone. Secrets for the
# test API are generated per run and never written to the report.
#
# Usage (PowerShell 5.1):  .\android-signing-tr07.ps1 -Branch main            # default root C:\KARIM\KCL, port 3022
# Evidence lands in <Root>\run\: report.txt, api-v1on.log, api-v1off.log, *.png (phone screenshots), gradle.log.
# First verified run: 2026-10-17, Galaxy Z Flip4 (SM-F721B, Android 16) - PR #65 comment, board TR-07.
param(
  [string]$Branch = "main",
  [string]$Root = "C:\KARIM\KCL",
  [int]$Port = 3022
)
$ROOT   = $Root
$WORK   = Join-Path $ROOT "osra"
$OUT    = Join-Path $ROOT "run"
$BRANCH = $Branch
$PORT   = $Port
$BASE   = "http://127.0.0.1:$PORT"
$PKG    = "com.familyshield.agent"
$TOOLS  = "C:\KARIM\tools"
New-Item -ItemType Directory -Force -Path $OUT | Out-Null
$REPORT = Join-Path $OUT "report.txt"
"" | Set-Content $REPORT
function W($s) { $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $s; $line | Tee-Object -FilePath $REPORT -Append | Out-Null }
function Cleanup() {
  try { if ($script:ADB -and $script:SERIAL) { & $script:ADB -s $script:SERIAL shell am force-stop $PKG 2>&1 | Out-Null; & $script:ADB -s $script:SERIAL uninstall $PKG 2>&1 | Out-Null; & $script:ADB -s $script:SERIAL reverse --remove-all 2>&1 | Out-Null; W "  cleanup: app uninstalled, reverse removed" } } catch {}
  try { Stop-Api } catch {}
}
function Fail($s) { W ("FAIL: " + $s); Cleanup; W "=== TR-07 ABORTED ==="; exit 1 }
function Section($s) { W ""; W ("=== " + $s + " ===") }

$script:apiProc = $null
function Stop-Api { if ($script:apiProc -and -not $script:apiProc.HasExited) { Stop-Process -Id $script:apiProc.Id -Force -ErrorAction SilentlyContinue; Start-Sleep 2 } $script:apiProc = $null }
function Start-Api($allowV1, $logName) {
  Stop-Api
  $env:PORT = "$PORT"; $env:JOBS_ENABLED = "0"; $env:INTERNAL_SIGNING_ALLOW_V1 = "$allowV1"; $env:LOG_LEVEL = "info"
  $log = Join-Path $OUT $logName
  $script:apiProc = Start-Process -FilePath "node" -ArgumentList "dist\server.js" -WorkingDirectory (Join-Path $WORK "services\api") -RedirectStandardOutput $log -RedirectStandardError ($log + ".err") -PassThru -WindowStyle Hidden
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep 1
    try { $h = Invoke-RestMethod -TimeoutSec 2 "$BASE/health"; if ($h.ok) { W ("API up on :$PORT with INTERNAL_SIGNING_ALLOW_V1=$allowV1 (pid {0}, log {1})" -f $script:apiProc.Id, $logName); return $true } } catch {}
    if ($script:apiProc.HasExited) { break }
  }
  W ("API did not come up; tail of {0}.err:" -f $logName); if (Test-Path ($log + ".err")) { Get-Content ($log + ".err") -Tail 20 | ForEach-Object { W ("  " + $_) } }
  return $false
}
function Api($method, $path, $body, $token) {
  $h = @{}
  if ($token) { $h["Authorization"] = "Bearer $token" }
  try {
    if ($body -ne $null) { return Invoke-RestMethod -Method $method -Uri ($BASE + $path) -Headers $h -ContentType "application/json" -Body ($body | ConvertTo-Json -Depth 6) -TimeoutSec 15 }
    return Invoke-RestMethod -Method $method -Uri ($BASE + $path) -Headers $h -TimeoutSec 15
  } catch { W ("  API $method $path -> " + $_.Exception.Message); return $null }
}
function Adb { param([Parameter(ValueFromRemainingArguments=$true)]$a) & $script:ADB -s $script:SERIAL @a 2>&1 }
function Shot($name) {
  $f = Join-Path $OUT "$name.png"
  & cmd /c ("`"" + $script:ADB + "`" -s " + $script:SERIAL + " exec-out screencap -p > `"" + $f + "`"") 2>$null
  try {
    $b = [IO.File]::ReadAllBytes($f); $sig = [byte[]](0x89,0x50,0x4E,0x47)
    for ($i = 0; $i -lt [Math]::Min($b.Length - 4, 4096); $i++) { if ($b[$i] -eq 0x89 -and $b[$i+1] -eq 0x50 -and $b[$i+2] -eq 0x4E -and $b[$i+3] -eq 0x47) { if ($i -gt 0) { [IO.File]::WriteAllBytes($f, $b[$i..($b.Length-1)]) }; break } }
  } catch {}
  W ("  screenshot $name.png")
}
function UiDump() {
  & $script:ADB -s $script:SERIAL shell uiautomator dump /sdcard/ui.xml 2>&1 | Out-Null
  $xml = (& $script:ADB -s $script:SERIAL exec-out cat /sdcard/ui.xml 2>$null) -join ""
  try { return [xml]$xml } catch { return $null }
}
function Bounds($node) { if ($node.bounds -match "\[(\d+),(\d+)\]\[(\d+),(\d+)\]") { return @([int](($([int]$matches[1]) + [int]$matches[3]) / 2), [int](($([int]$matches[2]) + [int]$matches[4]) / 2)) } return $null }
function Tap($xy) { Adb shell input tap $xy[0] $xy[1] | Out-Null; Start-Sleep 1 }
function AlertsLog($logName) {
  # Fastify/pino: "incoming request" carries req.url; "request completed" carries res.statusCode; both share reqId.
  $log = Join-Path $OUT $logName
  if (-not (Test-Path $log)) { return @() }
  $ids = @{}; $hits = @()
  foreach ($line in Get-Content $log) {
    try { $j = $line | ConvertFrom-Json } catch { continue }
    if ($j.req -and $j.req.url -eq "/v1/alerts/internal") { $ids[$j.reqId] = $j.req.method }
    if ($j.res -and $ids.ContainsKey($j.reqId)) { $hits += ("{0} /v1/alerts/internal -> {1}" -f $ids[$j.reqId], $j.res.statusCode) }
  }
  return $hits
}

Section "0. host"
W ("host=$env:COMPUTERNAME user=$env:USERNAME time=" + (Get-Date -Format o))
$env:PATH = "$TOOLS\node;" + $env:PATH
if (Test-Path "$TOOLS\jdk-17\bin\java.exe") { $env:JAVA_HOME = "$TOOLS\jdk-17"; $env:PATH = "$TOOLS\jdk-17\bin;" + $env:PATH }
W ("JAVA_HOME=" + $env:JAVA_HOME)
foreach ($t in "git","node","pnpm","java") { $c = Get-Command $t -ErrorAction SilentlyContinue; if ($c) { W ("{0,-6} {1}" -f $t, $c.Source) } else { W ("{0,-6} NOT FOUND on PATH" -f $t) } }
if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) { if (Get-Command corepack -ErrorAction SilentlyContinue) { & corepack enable 2>&1 | Out-Null } }
if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) { Fail "pnpm not found (looked on PATH and $TOOLS\node)" }
W ("node " + (& node -v)); W ("pnpm " + (& pnpm -v)); W ("java " + ((& java -version 2>&1) -join " | "))
$sdk = @("C:\KARIM\KARIMtoolsandroid-sdk", $env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, "$env:LOCALAPPDATA\Android\Sdk") | Where-Object { $_ -and (Test-Path (Join-Path $_ "platform-tools\adb.exe")) } | Select-Object -First 1
if (-not $sdk) { Fail "no Android SDK with platform-tools\adb.exe found" }
$env:ANDROID_HOME = $sdk; $env:ANDROID_SDK_ROOT = $sdk
$script:ADB = Join-Path $sdk "platform-tools\adb.exe"
W ("ANDROID_HOME=$sdk  adb=$script:ADB")
foreach ($p in 5432, 6379) { $ok = (Test-NetConnection 127.0.0.1 -Port $p -WarningAction SilentlyContinue).TcpTestSucceeded; W ("  127.0.0.1:$p listening=$ok"); if (-not $ok) { Fail "port $p not listening (Postgres/Redis must be up - run start-backend.bat first)" } }
if ((Test-NetConnection 127.0.0.1 -Port $PORT -WarningAction SilentlyContinue).TcpTestSucceeded) {
  $owners = Get-NetTCPConnection -LocalPort $PORT -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique
  foreach ($owner in $owners) {
    $cl = (Get-CimInstance Win32_Process -Filter "ProcessId=$owner" -ErrorAction SilentlyContinue).CommandLine
    if ($cl -and $cl -like "*KCL\osra*") { Stop-Process -Id $owner -Force -ErrorAction SilentlyContinue; W ("  stopped leftover API from a previous run (pid $owner)"); Start-Sleep 2 }
    else { Fail "port $PORT is in use by pid $owner (not ours): $cl" }
  }
}

Section "1. phone"
& $script:ADB start-server 2>&1 | Out-Null
$devs = (& $script:ADB devices 2>&1) | Select-String "\sdevice$" | ForEach-Object { ($_ -split "\s+")[0] }
W ("adb devices: " + ($devs -join ", "))
$script:SERIAL = $devs | Where-Object { $_ -notmatch "^emulator-" } | Select-Object -First 1
if (-not $script:SERIAL) { Fail "no physical device in 'adb devices' (only emulators or none). Is USB debugging authorised?" }
$model = (Adb shell getprop ro.product.model) -join ""; $rel = (Adb shell getprop ro.build.version.release) -join ""; $sdkv = (Adb shell getprop ro.build.version.sdk) -join ""
W ("device $script:SERIAL model=$model android=$rel sdk=$sdkv")
$phoneEpoch = [int64](((Adb shell date +%s) -join "").Trim()); $hostEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$SKEW = $phoneEpoch - $hostEpoch
W ("clock: phone=$phoneEpoch host=$hostEpoch skew=${SKEW}s (server window is +/-300 s)")
if ([math]::Abs($SKEW) -gt 300) { W "  WARNING: skew exceeds the signing window - every signed call would be 401 stale_timestamp" }
$pre = (Adb shell pm list packages) | Select-String familyshield
W ("familyshield packages before: " + (($pre | ForEach-Object { $_.ToString() }) -join ", "))

Section "2. checkout $BRANCH"
if (-not (Test-Path (Join-Path $WORK ".git"))) {
  W "cloning from GitHub..."
  & git clone --quiet --branch $BRANCH https://github.com/handfulofluck-lab/osra.git $WORK 2>&1 | ForEach-Object { W ("  " + $_) }
  if (-not (Test-Path (Join-Path $WORK ".git"))) {
    W "GitHub clone failed; cloning from the local clone and fetching the branch through it"
    & git -C C:\KARIM\familyshield fetch --quiet origin ("+refs/heads/" + $BRANCH + ":refs/remotes/origin/" + $BRANCH) 2>&1 | ForEach-Object { W ("  " + $_) }
    & git clone --quiet --no-checkout C:\KARIM\familyshield $WORK 2>&1 | ForEach-Object { W ("  " + $_) }
    & git -C $WORK fetch --quiet C:\KARIM\familyshield ("refs/remotes/origin/" + $BRANCH + ":refs/heads/" + $BRANCH) 2>&1 | ForEach-Object { W ("  " + $_) }
    & git -C $WORK checkout --quiet $BRANCH 2>&1 | ForEach-Object { W ("  " + $_) }
  }
} else {
  & git -C $WORK fetch --quiet origin $BRANCH 2>&1 | ForEach-Object { W ("  " + $_) }
  & git -C $WORK checkout --quiet $BRANCH 2>&1 | ForEach-Object { W ("  " + $_) }
  & git -C $WORK reset --quiet --hard ("origin/" + $BRANCH) 2>&1 | ForEach-Object { W ("  " + $_) }
}
if (-not (Test-Path (Join-Path $WORK "apps\child-android\gradlew.bat"))) { Fail "checkout incomplete (no apps\child-android\gradlew.bat)" }
$HEAD = (& git -C $WORK rev-parse --short HEAD) -join ""
W ("checkout at $HEAD (" + ((& git -C $WORK log -1 --format=%s) -join "") + ")")

$STAMP = Join-Path $OUT ("built-" + $HEAD + ".txt")
$APK = Join-Path $WORK "apps\child-android\app\build\outputs\apk\debug\app-debug.apk"
$SRV = Join-Path $WORK "services\api\dist\server.js"
if ((Test-Path $STAMP) -and (Test-Path $APK) -and (Test-Path $SRV)) {
  W ("reusing APK and API build from this checkout ($HEAD, stamp " + (Get-Item $STAMP).LastWriteTime + ")")
} else {
Section "3. build child-android (assembleFullDebug - the sideloaded Full build, ADR-0016)"
Push-Location (Join-Path $WORK "apps\child-android")
"sdk.dir=" + ($sdk -replace "\\", "/") | Set-Content local.properties
$gradleLog = Join-Path $OUT "gradle.log"
& .\gradlew.bat :app:assembleFullDebug --console=plain --no-daemon 2>&1 | Tee-Object -FilePath $gradleLog | Select-Object -Last 3 | ForEach-Object { W ("  " + $_) }
Pop-Location
if (-not (Test-Path $APK)) { W "gradle tail:"; Get-Content $gradleLog -Tail 40 | ForEach-Object { W ("  " + $_) }; Fail "APK not produced" }
W ("APK: $APK (" + [math]::Round((Get-Item $APK).Length / 1MB, 1) + " MB)")

Section "4. build + start API from $HEAD"
Push-Location $WORK
& pnpm install --frozen-lockfile 2>&1 | Select-Object -Last 2 | ForEach-Object { W ("  " + $_) }
& pnpm --filter @familyshield/shared-types --filter @familyshield/crypto --filter @familyshield/consent-sdk build 2>&1 | Select-Object -Last 1 | ForEach-Object { W ("  " + $_) }
Pop-Location
Push-Location (Join-Path $WORK "services\api")
$env:DATABASE_URL = "postgres://familyshield@127.0.0.1:5432/familyshield"
$env:REDIS_URL = "redis://127.0.0.1:6379"
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$b = New-Object byte[] 32; $rng.GetBytes($b); $env:JWT_SECRET = ($b | ForEach-Object { $_.ToString("x2") }) -join ""
$rng.GetBytes($b); $env:INTERNAL_HMAC_SECRET = ($b | ForEach-Object { $_.ToString("x2") }) -join ""
$rng.GetBytes($b); $env:VAULT_KEY = [Convert]::ToBase64String($b)
& pnpm exec prisma migrate deploy 2>&1 | Select-Object -Last 2 | ForEach-Object { W ("  " + $_) }
& pnpm exec prisma generate 2>&1 | Select-Object -Last 1 | ForEach-Object { W ("  " + $_) }
& pnpm run build 2>&1 | Select-Object -Last 2 | ForEach-Object { W ("  " + $_) }
Pop-Location
if (-not (Test-Path (Join-Path $WORK "services\api\dist\server.js"))) { Fail "API build produced no dist\server.js" }
"built" | Set-Content $STAMP
}
$env:DATABASE_URL = "postgres://familyshield@127.0.0.1:5432/familyshield"
$env:REDIS_URL = "redis://127.0.0.1:6379"
if (-not $env:JWT_SECRET) {
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create(); $b = New-Object byte[] 32
  $rng.GetBytes($b); $env:JWT_SECRET = ($b | ForEach-Object { $_.ToString("x2") }) -join ""
  $rng.GetBytes($b); $env:INTERNAL_HMAC_SECRET = ($b | ForEach-Object { $_.ToString("x2") }) -join ""
  $rng.GetBytes($b); $env:VAULT_KEY = [Convert]::ToBase64String($b)
}
if (-not (Start-Api 1 "api-v1on.log")) { Fail "API (v1 on) did not start" }

Section "5. pair the phone"
$login = Api POST "/v1/auth/login" @{ email = "demo@familyshield.dev"; password = "CorrectHorseBatteryStaple!" } $null
if (-not $login.token) { Fail "demo parent login failed on the shared DB" }
$TOKEN = $login.token
$me = Api GET "/v1/family/me" $null $TOKEN
$alex = $me.children | Where-Object { $_.displayName -eq "Alex" } | Select-Object -First 1
if (-not $alex) { $alex = $me.children | Select-Object -First 1 }
if (-not $alex) { Fail "no child in the demo family" }
W ("child: " + $alex.displayName + " " + $alex.id)
$devicesBefore = @($alex.devices | ForEach-Object { $_.id })
$code = (Api POST "/v1/devices/pair" @{ childId = $alex.id } $TOKEN).code
if (-not $code) { Fail "no pairing code" }
W ("pairing code issued (6 digits)")
Adb reverse --remove-all | Out-Null
Adb reverse "tcp:$PORT" "tcp:$PORT" | Out-Null
W ("adb reverse tcp:$PORT -> host :$PORT")
$inst = (Adb install -t -r -g $APK) -join " "
W ("adb install: " + $inst)
if ($inst -notmatch "Success") { Fail "install failed" }
foreach ($perm in "android.permission.ACCESS_FINE_LOCATION","android.permission.POST_NOTIFICATIONS") { Adb shell pm grant $PKG $perm 2>&1 | Out-Null }
Adb shell cmd statusbar add-tile "/.sos.SosTileService" | Out-Null; W "  OSRA SOS tile added to quick settings"
Adb shell am start -n "$PKG/.setup.PairingActivity" | Out-Null
Start-Sleep 4
Shot "01-pairing-form"
$ui = UiDump
if (-not $ui) { Start-Sleep 2; $ui = UiDump }
if (-not $ui) { Fail "uiautomator dump failed" }
$edits = @($ui.SelectNodes("//node[@class='android.widget.EditText']"))
$btn = $ui.SelectNodes("//node[@class='android.widget.Button']") | Select-Object -First 1
W ("  pairing form: {0} text fields, pair button={1}" -f $edits.Count, [bool]$btn)
if ($edits.Count -lt 2 -or -not $btn) { Shot "01b-unexpected-screen"; Fail "pairing form not on screen (is the device already paired? see 01-pairing-form.png)" }
$edits = $edits | Sort-Object { [int]([regex]::Match($_.bounds, "\[\d+,(\d+)\]").Groups[1].Value) }
$btnXY = Bounds $btn
W ("  button centre: " + ($btnXY -join ","))
Tap (Bounds $edits[0]); Adb shell input text "http://127.0.0.1:$PORT" | Out-Null; Start-Sleep 1
Tap (Bounds $edits[1]); Adb shell input text "$code" | Out-Null; Start-Sleep 1
Shot "02-form-filled"
Tap $btnXY
W "  Pair tapped; waiting for /v1/devices/pair/claim"
$newDev = $null
for ($i = 0; $i -lt 10 -and -not $newDev; $i++) {
  Start-Sleep 2
  $me = Api GET "/v1/family/me" $null $TOKEN
  $alexNow = $me.children | Where-Object { $_.id -eq $alex.id }
  $newDev = $alexNow.devices | Where-Object { $devicesBefore -notcontains $_.id } | Select-Object -First 1
}
Shot "03-after-pair"
if (-not $newDev) {
  $ui = UiDump
  if ($ui) { $texts = @($ui.SelectNodes("//node[@text!='']") | ForEach-Object { $_.text }); W ("  screen text: " + ($texts -join " | ")) }
  W ("  API log so far: " + ((AlertsLog "api-v1on.log") -join "; "))
  Fail "no new device on the child after pairing (see 03-after-pair.png)"
}
$DEVICE_ID = $newDev.id
W ("paired: device $DEVICE_ID platform=" + $newDev.platform + " model=" + $newDev.model)

function Fire-Sos($label, $logName) {
  Adb shell am force-stop $PKG | Out-Null; Start-Sleep 1
  # SosActivity is not exported (correct), so open it the way a child does: the quick-settings tile.
  Adb shell cmd statusbar collapse | Out-Null; Start-Sleep 1
  Adb shell cmd statusbar expand-settings | Out-Null; Start-Sleep 3
  $qs = UiDump
  $tile = $null
  if ($qs) { $tile = $qs.SelectNodes("//node[@text='OSRA SOS' or @content-desc='OSRA SOS']") | Select-Object -First 1 }
  if (-not $tile) { Adb shell cmd statusbar collapse | Out-Null; Shot ("$label-no-tile"); W "  OSRA SOS tile not found in quick settings"; return $null }
  Tap (Bounds $tile)
  Start-Sleep 3
  $top = (Adb shell dumpsys activity activities | Select-String "topResumedActivity") -join ""
  W ("  after tile tap, foreground: " + $(if ($top -match "familyshield.*SosActivity") { "SosActivity" } else { $top.Trim() }))
  $ui = UiDump
  $sos = $null
  if ($ui) { $sos = $ui.SelectNodes("//node[@text='SOS' and @clickable='true']") | Select-Object -First 1; if (-not $sos) { $sos = $ui.SelectNodes("//node[@text='SOS']") | Select-Object -First 1 } }
  if (-not $sos) { Shot ("$label-no-sos-button"); W "  SOS button not found on screen"; return $null }
  Tap (Bounds $sos)
  W "  SOS pressed; 5 s countdown..."
  Start-Sleep 9
  Shot ("$label-after-sos")
  $hits = AlertsLog $logName
  W ("  API log, /v1/alerts/internal: " + ($(if ($hits.Count) { $hits -join "; " } else { "(no request seen)" })))
  $alerts = Api GET ("/v1/alerts?childId=" + $alex.id + "&category=sos&limit=5") $null $TOKEN
  $mine = @($alerts.items | Where-Object { $_.deviceId -eq $DEVICE_ID })
  W ("  alerts from this device in DB: " + $mine.Count + ($(if ($mine.Count) { " (latest " + $mine[0].createdAt + ": " + $mine[0].title + ")" } else { "" })))
  return @{ hits = $hits; count = $mine.Count; ids = @($mine | ForEach-Object { $_.id }) }
}

Section "6. SOS with INTERNAL_SIGNING_ALLOW_V1=1 (the default)"
$r1 = Fire-Sos "03-v1on" "api-v1on.log"
$pass1 = $r1 -and ($r1.hits -match "-> 201") -and $r1.count -ge 1
W ("RESULT v1=on: " + $(if ($pass1) { "PASS - phone alert accepted (201)" } else { "FAIL" }))

Section "7. SOS with INTERNAL_SIGNING_ALLOW_V1=0"
if (-not (Start-Api 0 "api-v1off.log")) { Fail "API (v1 off) did not start" }
$r2 = Fire-Sos "04-v1off" "api-v1off.log"
$pass2 = $r2 -and ($r2.hits -match "-> 201") -and $r2.count -ge 2
W ("RESULT v1=off: " + $(if ($pass2) { "PASS - phone alert still accepted (201) with legacy v1 refused" } else { "FAIL" }))

Section "8. hygiene (AGENTS.md section 7)"
Adb shell am force-stop $PKG | Out-Null
W ("adb uninstall: " + ((Adb uninstall $PKG) -join " "))
Adb reverse --remove-all | Out-Null
W ("packages after: " + (((Adb shell pm list packages) | Select-String familyshield | ForEach-Object { $_.ToString() }) -join ", ") + " (empty = clean)")
$unpair = Api DELETE ("/v1/devices/" + $DEVICE_ID) $null $TOKEN
W ("unpair test device $DEVICE_ID -> " + $(if ($unpair) { "ok" } else { "see error above" }))
$allIds = @(); if ($r1) { $allIds += $r1.ids }; if ($r2) { $allIds += $r2.ids }; $allIds = $allIds | Select-Object -Unique
$psql = Join-Path $TOOLS "pg\pgsql\bin\psql.exe"
if ($allIds.Count -and (Test-Path $psql)) {
  $list = ($allIds | ForEach-Object { "'" + $_ + "'" }) -join ","
  $sqlFile = Join-Path $OUT "cleanup.sql"
  @(
    ('DELETE FROM "Alert" WHERE id IN (' + $list + ');'),
    ('SELECT count(*) AS left_over FROM "Alert" WHERE id IN (' + $list + ");")
  ) | Set-Content $sqlFile -Encoding ASCII
  $del = & $psql -h 127.0.0.1 -U familyshield -d familyshield -t -A -f $sqlFile 2>&1
  W ("deleted the " + $allIds.Count + " SOS alert row(s) this run created; psql: " + (($del | Where-Object { $_ }) -join " / "))
} elseif ($allIds.Count) { W ("NOTE: psql not found at $psql - alert ids to delete by hand: " + ($allIds -join ", ")) }
Stop-Api
W ("API stopped; test device revoked (revoked:device:$DEVICE_ID key kept on purpose - security state)")

Section "SUMMARY"
W ("branch $BRANCH @ $HEAD . phone $model (Android $rel) . skew ${SKEW}s")
W ("v1 on : " + $(if ($pass1) { "201 PASS" } else { "FAIL" }) + "   v1 off: " + $(if ($pass2) { "201 PASS" } else { "FAIL" }))
W ("evidence: $OUT (report.txt, api-v1on.log, api-v1off.log, *.png, gradle.log)")
W ("=== TR-07 " + $(if ($pass1 -and $pass2) { "PASS" } else { "FAIL" }) + " ===")
