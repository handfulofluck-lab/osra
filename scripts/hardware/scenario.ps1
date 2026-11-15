[CmdletBinding()]
param(
    [string]$Scenario = "SC-0.1",
    [string]$Out = (Join-Path $env:TEMP "osra-scenarios"),
    [string]$Owner = "K31",
    [string]$Serial = "R5CW116Y6GF",
    [string]$Package = "com.osratech.child.full",
    [string]$ApiBase,
    [string]$LeaseStore,
    [switch]$DryRun
)

$script:DryRun = [bool]$DryRun
$script:Scenario = $Scenario
$script:Out = $Out
$script:Owner = $Owner
$script:Serial = $Serial
$script:Package = $Package
$script:ApiBase = $ApiBase
$script:LeaseStore = $LeaseStore
$script:RunnerDir = $PSScriptRoot
if (-not $script:RunnerDir) {
    # Dot-sourced under Pester on the Linux runner, $PSScriptRoot arrives empty, so the files this
    # script loads must be found from the invocation directory instead (#667).
    $anchors = @($env:GITHUB_WORKSPACE, (Get-Location).Path, $PWD.Path) | Where-Object { $_ }
    foreach ($start in $anchors) {
        $dir = $start
        while ($dir -and -not (Test-Path -LiteralPath (Join-Path $dir "scripts/hardware/scenario.ps1"))) {
            $parent = Split-Path -Parent $dir
            if (-not $parent -or $parent -eq $dir) { $dir = $null; break }
            $dir = $parent
        }
        if ($dir) { $script:RunnerDir = Join-Path $dir "scripts/hardware"; break }
    }
}
if (-not $script:RunnerDir) {
    throw "runner_dir_not_found: root=[$PSScriptRoot] loc=[$((Get-Location).Path)] ws=[$env:GITHUB_WORKSPACE]"
}
$script:RestoredSettingsKeys = @(
    "enabled_accessibility_services", "accessibility_enabled", "stay_on_while_plugged_in",
    "accelerometer_rotation", "user_rotation", "screen_off_timeout", "zen_mode"
)
$script:SafeContentColumns = @("_id", "count", "date", "timestamp", "type", "blocked", "category", "duration")

function Assert-ScenarioCommand {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Command, [string]$Package)
    if ($Command.Count -eq 0) { throw "empty_adb_command" }
    $c = @($Command | ForEach-Object { "$_".ToLowerInvariant() })
    if ($c -contains "-s") { throw "manifest_serial_not_allowed" }
    foreach ($verb in @("connect", "disconnect", "tcpip", "usb", "kill-server", "reconnect", "date", "reboot", "svc", "cmd", "uiautomator")) {
        if ($c -contains $verb) { throw "device_connection_or_clock_change_refused" }
    }
    if (($c -contains "sh" -or $c -contains "bash" -or $c -contains "cmd") -and $c -contains "-c") { throw "shell_evaluation_refused" }
    if ($c -contains "dpm" -and $c -notcontains "list-owners") { throw "device_admin_change_refused" }
    if ($c -contains "wm") { throw "unrestored_window_change_refused" }
    if ($c -contains "am" -and $c -contains "broadcast" -and @($c | Where-Object { $_ -like "*airplane_mode*" }).Count) {
        throw "radio_change_refused"
    }
    if ($c -contains "settings") {
        $put = [Array]::IndexOf($c, "put")
        if ($put -ge 0) {
            if ($put + 2 -ge $c.Count) { throw "malformed_settings_change" }
            $key = $c[$put + 2]
            if ($key -in @("auto_time", "auto_time_zone", "time_zone", "airplane_mode_on")) { throw "clock_or_radio_change_refused" }
            if ($key -notin $script:RestoredSettingsKeys) { throw "setting_not_in_restore_set" }
        }
    }
    $input = [Array]::IndexOf($c, "input")
    if ($input -ge 0 -and $input + 2 -lt $c.Count -and $c[$input + 1] -eq "text") {
        if (($Command[($input + 2)..($Command.Count - 1)] -join " ") -match "\d{4,}") { throw "pin_input_refused" }
    }
    if ($input -ge 0 -and $input + 2 -lt $c.Count -and $c[$input + 1] -eq "keyevent") {
        $keys = $c[($input + 2)..($c.Count - 1)]
        if ($keys -contains "111") { throw "escape_key_refused" }
        $digitKeys = @($keys | Where-Object { ($_ -match "^(?:[7-9]|1[0-6])$") -or ($_ -match "^keycode_[0-9]$") })
        if ($keys.Count -gt 0 -and $digitKeys.Count -eq $keys.Count) { throw "pin_key_sequence_refused" }
    }
    $pm = [Array]::IndexOf($c, "pm")
    if ($pm -ge 0 -and $pm + 2 -lt $c.Count -and $c[$pm + 1] -in @("uninstall", "clear")) {
        if ($c.Count -ne $pm + 3 -or -not $Package -or $c[$pm + 2] -ne $Package) { throw "package_removal_outside_scenario" }
    }
}

function Assert-ScenarioStep {
    param([Parameter(Mandatory = $true)]$Step, [string]$Package)
    if (-not $Step.type) { throw "step_type_required" }
    $allowed = switch ($Step.type) {
        "adb" { @("type", "command", "nonPersonal", "projection") }
        "screencap" { @("type", "name") }
        "wait" { @("type", "seconds") }
        "http" { @("type", "method", "path", "body") }
        "manual" { @("type", "instruction") }
        default { throw "unknown_step_type" }
    }
    foreach ($name in $Step.PSObject.Properties.Name) {
        if ($name -notin $allowed) { throw "unknown_step_field" }
    }
    switch ($Step.type) {
        "adb" {
            if ($Step.command -is [string] -or $Step.command -isnot [Array]) { throw "adb_command_must_be_argument_array" }
            Assert-ScenarioCommand -Command ([string[]]$Step.command) -Package $Package
            $c = @($Step.command | ForEach-Object { "$_".ToLowerInvariant() })
            if ($c -contains "content" -and $c -contains "query") {
                if ($Step.nonPersonal -ne $true -or -not $Step.projection) { throw "content_query_not_declared_safe" }
                foreach ($column in @($Step.projection)) {
                    if ("$column".ToLowerInvariant() -notin $script:SafeContentColumns) { throw "personal_content_column_refused" }
                }
            }
        }
        "screencap" {
            if ("$($Step.name)" -notmatch "^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$" -or "$($Step.name)".Contains("..")) { throw "unsafe_evidence_name" }
        }
        "wait" {
            if (($Step.seconds -isnot [int] -and $Step.seconds -isnot [long]) -or $Step.seconds -lt 0 -or $Step.seconds -gt 3600) { throw "invalid_wait" }
        }
        "http" {
            if ($Step.method -notin @("GET", "POST", "PATCH", "DELETE")) { throw "invalid_http_method" }
            if ("$($Step.path)" -notmatch "^/" -or "$($Step.path)".Contains("..") -or "$($Step.path)".Contains("://") -or "$($Step.path)".Contains("\")) { throw "unsafe_http_path" }
        }
        "manual" {
            if ([string]::IsNullOrWhiteSpace([string]$Step.instruction) -or ([string]$Step.instruction).Length -gt 500) { throw "invalid_manual_instruction" }
        }
    }
}

function Assert-HealthUrl {
    param([Parameter(Mandatory = $true)][string]$Url)
    try { $uri = [Uri]$Url } catch { throw "invalid_health_url" }
    if (-not $uri.IsAbsoluteUri -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw "unsafe_health_url" }
    $loopback = $uri.Scheme -eq "http" -and $uri.Host -in @("127.0.0.1", "localhost", "::1")
    $staging = $uri.Scheme -eq "https" -and $uri.Host.EndsWith(".staging.osratech.com", [StringComparison]::OrdinalIgnoreCase)
    if (-not $loopback -and -not $staging) { throw "unsafe_health_url" }
}

function Assert-ManifestShape {
    param([Parameter(Mandatory = $true)]$Manifest, [string]$Package)
    $required = @("id", "title", "pair", "package", "apiHealthUrl", "steps", "measurements")
    foreach ($name in $required) {
        if ($Manifest.PSObject.Properties.Name -notcontains $name) { throw "missing_manifest_field_$name" }
    }
    foreach ($name in $Manifest.PSObject.Properties.Name) {
        if ($name -notin @($required + "timeoutSeconds")) { throw "unknown_manifest_field" }
    }
    if ("$($Manifest.id)" -notmatch "^SC-[A-Za-z0-9.-]{1,60}$" -or "$($Manifest.id)".Contains("..")) { throw "invalid_scenario_id" }
    if ([string]::IsNullOrWhiteSpace([string]$Manifest.title) -or ([string]$Manifest.title).Length -gt 120) { throw "invalid_title" }
    if ([string]::IsNullOrWhiteSpace([string]$Manifest.pair) -or ([string]$Manifest.pair).Length -gt 32) { throw "invalid_pair" }
    if ("$($Manifest.package)" -notmatch "^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$") { throw "invalid_package" }
    Assert-HealthUrl -Url $Manifest.apiHealthUrl
    if ($Manifest.PSObject.Properties.Name -contains "timeoutSeconds") {
        if (($Manifest.timeoutSeconds -isnot [int] -and $Manifest.timeoutSeconds -isnot [long]) -or $Manifest.timeoutSeconds -lt 1 -or $Manifest.timeoutSeconds -gt 3600) { throw "invalid_timeout" }
    }
    if ($Manifest.steps -isnot [Array] -or $Manifest.steps.Count -eq 0) { throw "steps_required" }
    foreach ($step in $Manifest.steps) { Assert-ScenarioStep -Step $step -Package $Manifest.package }
    if ($Manifest.measurements -isnot [Array]) { throw "measurements_must_be_array" }
    foreach ($measurement in $Manifest.measurements) {
        foreach ($name in $measurement.PSObject.Properties.Name) {
            if ($name -notin @("name", "actual", "comparator", "limit")) { throw "unknown_measurement_field" }
        }
        if (-not $measurement.name -or "$($measurement.actual)" -notmatch "^[A-Za-z_][A-Za-z0-9_.-]*$") { throw "invalid_measurement_actual" }
        if ($measurement.comparator -notin @("eq", "lte", "gte", "lt", "gt", "present", "empty")) { throw "invalid_comparator" }
        if ($measurement.comparator -notin @("present", "empty") -and $measurement.limit -isnot [ValueType]) { throw "numeric_limit_required" }
    }
}

function Read-ScenarioManifest {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Out)
    $scenarioRoot = [IO.Path]::GetFullPath((Join-Path $script:RunnerDir "scenarios"))
    $outRoot = [IO.Path]::GetFullPath($Out)
    $candidate = $Path
    if (-not [IO.Path]::IsPathRooted($candidate)) {
        $fromScenarios = Join-Path $scenarioRoot "$candidate.json"
        if (Test-Path -LiteralPath $fromScenarios -PathType Leaf) { $candidate = $fromScenarios }
        else { $candidate = Join-Path (Get-Location) $candidate }
    }
    $full = [IO.Path]::GetFullPath($candidate)
    $comparison = if ($env:OS -eq "Windows_NT") { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $scenarioPrefix = $scenarioRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $outPrefix = $outRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($scenarioPrefix, $comparison) -and -not $full.StartsWith($outPrefix, $comparison)) { throw "scenario_path_outside_allowed_roots" }
    if ([IO.Path]::GetExtension($full) -ne ".json" -or -not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "scenario_not_found" }
    try { $manifest = Get-Content -LiteralPath $full -Raw | ConvertFrom-Json } catch { throw "invalid_scenario_json" }
    Assert-ManifestShape -Manifest $manifest
    return $manifest
}

function Resolve-ScenarioAdb {
    $candidates = @(Get-Command "adb" -CommandType Application -ErrorAction Stop)
    $resolved = if ($env:OS -eq "Windows_NT") {
        $candidates | Where-Object { $_.Source -match "\.(?:cmd|exe)$" } | Select-Object -First 1 -ExpandProperty Source
    } else { $candidates[0].Source }
    if (-not $resolved) { throw "adb_not_found" }
    return $resolved
}

function ConvertTo-ScenarioProcessArgument {
    param([string]$Value)
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Invoke-ScenarioProcess {
    param([Parameter(Mandatory = $true)][string]$Exe, [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Args, [switch]$RawBytes)
    $name = [IO.Path]::GetFileNameWithoutExtension($Exe).ToLowerInvariant()
    if ($name -notin @("adb")) { throw "process_not_allowed" }
    $resolved = Resolve-ScenarioAdb
    if (-not $RawBytes) {
        $text = & $resolved @Args | Out-String
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $text }
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $quoted = @($Args | ForEach-Object { ConvertTo-ScenarioProcessArgument $_ }) -join " "
    if ([IO.Path]::GetExtension($resolved) -eq ".cmd") {
        $psi.FileName = $env:ComSpec
        $psi.Arguments = '/d /s /c ""' + $resolved + '" ' + $quoted + '"'
    } else {
        $psi.FileName = $resolved
        $psi.Arguments = $quoted
    }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    if (-not $process.Start()) { throw "process_start_failed" }
    $memory = New-Object System.IO.MemoryStream
    $process.StandardOutput.BaseStream.CopyTo($memory)
    $process.StandardError.ReadToEnd() | Out-Null
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Bytes = $memory.ToArray() }
}


. (Join-Path $script:RunnerDir "classify-build.ps1")

function Invoke-ScenarioLease {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("Claim", "Release", "Heartbeat")][string]$Action,
        [ValidateSet("Clean", "Locked", "Unknown")][string]$LeftState = "Unknown",
        [string]$Note = ""
    )
    if (-not $script:LeaseCalls) { $script:LeaseCalls = @() }
    if (-not $script:DryRun) {
        $lease = @{
            Action = $Action; Owner = $script:Owner; Serial = $script:Serial; Purpose = "scenario:$script:Scenario"
        }
        if ($script:LeaseStore) { $lease.Store = $script:LeaseStore }
        if ($Action -eq "Release") { $lease.LeftState = $LeftState; $lease.Note = $Note }
        & (Join-Path $script:RunnerDir "phone-claim.ps1") @lease
        if ($LASTEXITCODE -ne 0) { throw "phone_lease_$Action_failed" }
    }
    $record = [pscustomobject]@{ Action = $Action; LeftState = $LeftState; Note = $Note }
    $script:LeaseCalls += $record
    return $record
}

function Invoke-ScenarioHttp {
    param([Parameter(Mandatory = $true)][string]$Url, [string]$Method = "GET")
    if ($script:DryRun) {
        if ($env:FAKE_HTTP_STATUS -and [int]$env:FAKE_HTTP_STATUS -ge 400) { throw "backend_unhealthy" }
        return [pscustomobject]@{ StatusCode = 200 }
    }
    $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -Method $Method -TimeoutSec 20
    if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) { throw "backend_unhealthy" }
    return [pscustomobject]@{ StatusCode = [int]$response.StatusCode }
}

function Test-AdminPackageRemoval {
    param([Parameter(Mandatory = $true)][string]$Package)
    $owners = Invoke-Adb -Command @("shell", "dpm", "list-owners") -SkipAdminCheck
    return $owners.Output -notmatch [regex]::Escape($Package)
}

function Invoke-Adb {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Command,
        [string]$Package,
        [switch]$SkipAdminCheck,
        [switch]$RawBytes
    )
    Assert-ScenarioCommand -Command $Command -Package $Package
    $normalized = @($Command | ForEach-Object { "$_".ToLowerInvariant() })
    $pm = [Array]::IndexOf($normalized, "pm")
    if (-not $SkipAdminCheck -and $pm -ge 0 -and $pm + 1 -lt $normalized.Count -and $normalized[$pm + 1] -in @("uninstall", "clear")) {
        if (-not (Test-AdminPackageRemoval -Package $Package)) { throw "active_device_admin_package" }
    }
    $process = Invoke-ScenarioProcess -Exe "adb" -Args (@("-s", $script:Serial) + $Command) -RawBytes:$RawBytes
    if ($process.ExitCode -ne 0) { throw "adb_command_failed" }
    return $process
}

function Get-ScenarioLockState {
    $window = Invoke-Adb -Command @("shell", "dumpsys", "window")
    if ($window.Output -match "mDreamingLockscreen=(true|false)") { return $Matches[1] -eq "true" }
    if ($window.Output -match "mShowingDream=(true|false)") { return $Matches[1] -eq "true" }
    $trust = Invoke-Adb -Command @("shell", "dumpsys", "trust")
    return $trust.Output -match "device is secure"
}

function Invoke-ScenarioPreflight {
    param([Parameter(Mandatory = $true)]$Manifest)
    Assert-ManifestShape -Manifest $Manifest
    $script:LeaseCalls = @()
    Invoke-ScenarioLease -Action Claim | Out-Null
    $model = Invoke-Adb -Command @("shell", "getprop", "ro.product.model")
    $expectedModel = switch ($script:Serial) {
        "R5CW116Y6GF" { "SM-F711B" }
        default { throw "unknown_device_catalogue_serial" }
    }
    if ($model.Output.Trim() -ne $expectedModel) { throw "device_model_mismatch" }
    $dump = Invoke-Adb -Command @("shell", "dumpsys", "package", $Manifest.package)
    $build = Get-BuildKind -DumpsysText $dump.Output -Package $Manifest.package
    if ($build.Kind -ne "release") { throw "build_not_gate_evidence" }
    $health = Invoke-ScenarioHttp -Url $Manifest.apiHealthUrl
    $lockState = Get-ScenarioLockState
    return [pscustomobject]@{
        buildKind = $build.Kind; lockState = $lockState; health = $health; model = $model.Output.Trim()
    }
}

function Get-ScenarioBeforeState {
    $values = [ordered]@{}
    $values.SYSTEM_ALERT_WINDOW = (Invoke-Adb -Command @("shell", "appops", "get", $script:Package, "SYSTEM_ALERT_WINDOW")).Output.Trim()
    $values.locale = (Invoke-Adb -Command @("shell", "getprop", "persist.sys.locale")).Output.Trim()
    foreach ($key in $script:RestoredSettingsKeys) {
        $values[$key] = (Invoke-Adb -Command @("shell", "settings", "get", "global", $key)).Output.Trim()
    }
    return [pscustomobject]@{ lockState = (Get-ScenarioLockState); values = $values }
}

function New-ScenarioEvidence {
    param([Parameter(Mandatory = $true)][string]$ScenarioId, [Parameter(Mandatory = $true)][string]$Out, [Parameter(Mandatory = $true)]$Before)
    if ($ScenarioId -notmatch "^SC-[A-Za-z0-9.-]{1,60}$" -or $ScenarioId.Contains("..")) { throw "invalid_scenario_id" }
    $root = [IO.Path]::GetFullPath($Out)
    $folder = Join-Path $root ("{0}-{1}" -f [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ"), $ScenarioId)
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $Before | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $folder "before.json") -Encoding UTF8
    return $folder
}

function Invoke-ScenarioManualStep {
    param([Parameter(Mandatory = $true)][bool]$LockState, [string]$Instruction = "Confirm the synthetic screen")
    if ($LockState) { return [pscustomobject]@{ status = "NOT RUN"; reason = "phone locked" } }
    if ($script:DryRun) { return [pscustomobject]@{ status = "NOT RUN"; reason = "manual confirmation required" } }
    [Console]::Out.WriteLine($Instruction)
    Read-Host "Press Enter to continue" | Out-Null
    return [pscustomobject]@{ status = "DONE"; reason = "manual confirmation recorded" }
}


if (-not ("ScenarioPng" -as [type])) {
    Add-Type -Path (Join-Path $script:RunnerDir "scenario-png.cs")
}

function Crop-ScenarioPng {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes, [Parameter(Mandatory = $true)][int]$X, [Parameter(Mandatory = $true)][int]$Y, [Parameter(Mandatory = $true)][int]$Width, [Parameter(Mandatory = $true)][int]$Height)
    try {
        return [ScenarioPng]::Crop($Bytes, $X, $Y, $Width, $Height)
    } catch {
        throw "unsupported_or_corrupt_png"
    }
}

function Get-ScenarioSafeBounds {
    $window = (Invoke-Adb -Command @("shell", "dumpsys", "window")).Output
    if ($window -notmatch [regex]::Escape("com.osratech.child")) { throw "osra_window_not_focused" }
    if ($window -notmatch "mStatusBarHeight=(\d+)") { throw "status_bar_bounds_unknown" }
    $statusHeight = [int]$Matches[1]
    if ($window -notmatch "mFrame=Rect\((\d+), (\d+) - (\d+), (\d+)\)") { throw "osra_window_bounds_unknown" }
    $left = [int]$Matches[1]; $top = [Math]::Max([int]$Matches[2], $statusHeight)
    $right = [int]$Matches[3]; $bottom = [int]$Matches[4]
    if ($right -le $left -or $bottom -le $top) { throw "osra_window_bounds_invalid" }
    return [pscustomobject]@{ X = $left; Y = $top; Width = $right - $left; Height = $bottom - $top }
}

function Save-ScenarioScreenshot {
    param([Parameter(Mandatory = $true)][string]$Evidence, [Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][bool]$LockState)
    if ($LockState) { throw "phone_locked_no_screenshot" }
    if ($Name -notmatch "^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$" -or $Name.Contains("..")) { throw "unsafe_evidence_name" }
    $bounds = Get-ScenarioSafeBounds
    $capture = Invoke-Adb -Command @("exec-out", "screencap", "-p") -RawBytes
    if ($capture.ExitCode -ne 0) { throw "screenshot_capture_failed" }
    try {
        $cropped = Crop-ScenarioPng -Bytes $capture.Bytes -X $bounds.X -Y $bounds.Y -Width $bounds.Width -Height $bounds.Height
    } catch {
        return [pscustomobject]@{ status = "NOT RUN"; reason = "unsupported image" }
    }
    $root = [IO.Path]::GetFullPath($Evidence)
    $path = [IO.Path]::GetFullPath((Join-Path $root $Name))
    if (-not $path.StartsWith($root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "unsafe_evidence_path" }
    [IO.File]::WriteAllBytes($path, $cropped)
    $image = [ScenarioPng]::Decode($cropped)
    return [pscustomobject]@{ status = "DONE"; width = $image.Width; height = $image.Height }
}

$script:AllowedLogStages = @(
    "start", "dry-run", "preflight", "before-values", "step-start", "step-end",
    "screenshot", "restore", "lease-release", "result", "refused"
)

function Write-ScenarioLog {
    param([Parameter(Mandatory = $true)][string]$Evidence, [Parameter(Mandatory = $true)][string]$Stage)
    if ($Stage -notin $script:AllowedLogStages) { throw "unsafe_log_stage" }
    $path = Join-Path ([IO.Path]::GetFullPath($Evidence)) "runner.log"
    [IO.File]::AppendAllText($path, "$Stage`n", (New-Object System.Text.UTF8Encoding($false)))
}

function Start-ScenarioEventLog {
    param([Parameter(Mandatory = $true)][string]$Evidence)
    $resolved = Resolve-ScenarioAdb
    $path = Join-Path ([IO.Path]::GetFullPath($Evidence)) "events.log"
    $argumentLine = @("-s", $script:Serial, "logcat", "-b", "events") | ForEach-Object { ConvertTo-ScenarioProcessArgument $_ }
    return Start-Process -FilePath $resolved -ArgumentList $argumentLine -RedirectStandardOutput $path -RedirectStandardError (Join-Path $Evidence "events.err.log") -NoNewWindow -PassThru
}

function Stop-ScenarioEventLog {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Process)
    if (-not $Process.HasExited) {
        $Process.Kill()
        $Process.WaitForExit()
    }
}


function Invoke-ScenarioSteps {
    param([Parameter(Mandatory = $true)]$Steps, [Parameter(Mandatory = $true)][string]$Evidence, [Parameter(Mandatory = $true)][bool]$LockState)
    $captures = [ordered]@{}
    $records = @()
    for ($i = 0; $i -lt $Steps.Count; $i++) {
        $step = $Steps[$i]
        try {
            Assert-ScenarioStep -Step $step -Package $script:Package
            switch ($step.type) {
                "adb" {
                    $process = Invoke-Adb -Command ([string[]]$step.command) -Package $script:Package
                    $captures["adb.$i.exitCode"] = $process.ExitCode
                }
                "wait" {
                    if ($step.seconds -gt 0) { Start-Sleep -Seconds ([int]$step.seconds) }
                    $captures["wait.$i.seconds"] = [int]$step.seconds
                }
                "http" {
                    $base = if ($script:ApiBase) {
                        $script:ApiBase
                    } elseif ($script:ActiveManifest) {
                        $uri = [Uri]$script:ActiveManifest.apiHealthUrl
                        $uri.GetLeftPart([UriPartial]::Authority)
                    } else { "http://127.0.0.1:3000" }
                    $response = Invoke-ScenarioHttp -Url ($base.TrimEnd("/") + $step.path) -Method $step.method
                    $captures["http.$i.status"] = $response.StatusCode
                }
                "screencap" {
                    $shot = Save-ScenarioScreenshot -Evidence $Evidence -Name $step.name -LockState $LockState
                    if ($shot.status -ne "DONE") {
                        $records += [pscustomobject]@{ index = $i; type = "screencap"; status = "NOT RUN" }
                        return [pscustomobject]@{ completed = $false; captures = $captures; steps = $records; error = $shot.reason }
                    }
                    $captures["screencap.$i.width"] = $shot.width
                    $captures["screencap.$i.height"] = $shot.height
                }
                "manual" {
                    $manual = Invoke-ScenarioManualStep -LockState $LockState -Instruction $step.instruction
                    if ($manual.status -ne "DONE") {
                        $records += [pscustomobject]@{ index = $i; type = "manual"; status = "NOT RUN" }
                        return [pscustomobject]@{ completed = $false; captures = $captures; steps = $records; error = $manual.reason }
                    }
                    $captures["manual.$i.confirmed"] = $true
                }
            }
            $records += [pscustomobject]@{ index = $i; type = $step.type; status = "DONE" }
        } catch {
            $records += [pscustomobject]@{ index = $i; type = $step.type; status = "FAIL" }
            return [pscustomobject]@{ completed = $false; captures = $captures; steps = $records; error = "step_failed" }
        }
    }
    return [pscustomobject]@{ completed = $true; captures = $captures; steps = $records; error = $null }
}

function Get-ScenarioOutcome {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$Measurements,
        [Parameter(Mandatory = $true)]$Captures,
        [Parameter(Mandatory = $true)][bool]$StepsCompleted,
        [Parameter(Mandatory = $true)][bool]$RestoreClean
    )
    $rows = @()
    if (-not $StepsCompleted -or -not $RestoreClean) { return [pscustomobject]@{ status = "FAIL"; measurements = $rows } }
    if ($Measurements.Count -eq 0) { return [pscustomobject]@{ status = "NOT RUN"; measurements = $rows } }
    $status = "PASS"
    foreach ($measurement in $Measurements) {
        $actualName = "$($measurement.actual)"
        if (-not $Captures.Contains($actualName) -or $null -eq $Captures[$actualName]) {
            if ($status -eq "PASS") { $status = "NOT RUN" }
            $rows += [pscustomobject]@{ name = $measurement.name; result = "NOT RUN"; value = $null; comparator = $measurement.comparator; limit = $measurement.limit }
            continue
        }
        $value = $Captures[$actualName]
        $ok = $false
        $numeric = 0.0
        $isNumber = [double]::TryParse([string]$value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$numeric)
        switch ($measurement.comparator) {
            "present" { $ok = $null -ne $value -and "$value" -ne "" -and @($value).Count -gt 0 }
            "empty" { $ok = $null -eq $value -or "$value" -eq "" -or @($value).Count -eq 0 -or ($isNumber -and $numeric -eq 0) }
            default {
                if ($isNumber) {
                    switch ($measurement.comparator) {
                        "eq" { $ok = $numeric -eq [double]$measurement.limit }
                        "lte" { $ok = $numeric -le [double]$measurement.limit }
                        "gte" { $ok = $numeric -ge [double]$measurement.limit }
                        "lt" { $ok = $numeric -lt [double]$measurement.limit }
                        "gt" { $ok = $numeric -gt [double]$measurement.limit }
                    }
                }
            }
        }
        $rowResult = if ($ok) { "PASS" } else { "FAIL" }
        if (-not $ok) { $status = "FAIL" }
        $rows += [pscustomobject]@{ name = $measurement.name; result = $rowResult; value = $value; comparator = $measurement.comparator; limit = $measurement.limit }
    }
    return [pscustomobject]@{ status = $status; measurements = $rows }
}

function Restore-ScenarioState {
    param([Parameter(Mandatory = $true)]$Before)
    $failures = @()
    $values = $Before.values
    if ($values.SYSTEM_ALERT_WINDOW -match "SYSTEM_ALERT_WINDOW:\s*(\S+)") {
        try { Invoke-Adb -Command @("shell", "appops", "set", $script:Package, "SYSTEM_ALERT_WINDOW", $Matches[1]) | Out-Null }
        catch { $failures += "SYSTEM_ALERT_WINDOW" }
    }
    if ($values.locale) {
        try { Invoke-Adb -Command @("shell", "setprop", "persist.sys.locale", $values.locale) | Out-Null }
        catch { $failures += "locale" }
    }
    foreach ($key in $script:RestoredSettingsKeys) {
        try { Invoke-Adb -Command @("shell", "settings", "put", "global", $key, "$($values[$key])") | Out-Null }
        catch { $failures += $key }
    }
    $after = Get-ScenarioBeforeState
    $diff = [ordered]@{}
    foreach ($key in $values.Keys) {
        if ("$($after.values[$key])" -ne "$($values[$key])") { $diff[$key] = $true }
    }
    return [pscustomobject]@{ clean = ($failures.Count -eq 0 -and $diff.Count -eq 0); failures = $failures; diffCount = $diff.Count }
}

function Write-ScenarioResult {
    param([Parameter(Mandatory = $true)][string]$Evidence, [Parameter(Mandatory = $true)]$Result)
    $json = $Result | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText((Join-Path $Evidence "result.json"), $json, (New-Object System.Text.UTF8Encoding($false)))
    $lines = @(
        "# Scenario $($Result.id)",
        "",
        "| Result | Build | Restore | Evidence |",
        "|---|---|---|---|",
        "| $($Result.status) | $($Result.buildKind) | $(if ($Result.restore.clean) { 'clean' } else { 'FAIL' }) | $Evidence |"
    )
    [IO.File]::WriteAllText((Join-Path $Evidence "result.md"), ($lines -join "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-ScenarioRun {
    param([Parameter(Mandatory = $true)]$Manifest, [Parameter(Mandatory = $true)][string]$Out, [switch]$DryRun)
    if ($PSBoundParameters.ContainsKey("DryRun")) { $script:DryRun = [bool]$DryRun }
    $script:ActiveManifest = $Manifest
    $script:Package = $Manifest.package
    $before = $null; $folder = $null; $eventProcess = $null; $restore = $null; $preflight = $null
    $stepResult = [pscustomobject]@{ completed = $false; captures = [ordered]@{}; steps = @(); error = "not_started" }
    try {
        $preflight = Invoke-ScenarioPreflight -Manifest $Manifest
        $before = Get-ScenarioBeforeState
        $folder = New-ScenarioEvidence -ScenarioId $Manifest.id -Out $Out -Before $before
        Write-ScenarioLog -Evidence $folder -Stage "start"
        $eventProcess = Start-ScenarioEventLog -Evidence $folder
        $stepResult = Invoke-ScenarioSteps -Steps $Manifest.steps -Evidence $folder -LockState ([bool]$preflight.lockState)
    } catch {
        $stepResult = [pscustomobject]@{ completed = $false; captures = [ordered]@{}; steps = @(); error = "run_failed" }
    } finally {
        if ($before) {
            try { $restore = Restore-ScenarioState -Before $before }
            catch { $restore = [pscustomobject]@{ clean = $false; failures = @("restore_exception"); diffCount = 1 } }
        }
        if ($eventProcess) { Stop-ScenarioEventLog -Process $eventProcess -ErrorAction SilentlyContinue }
        $claimed = @($script:LeaseCalls | Where-Object { $_.Action -eq "Claim" }).Count -gt 0
        $released = @($script:LeaseCalls | Where-Object { $_.Action -eq "Release" }).Count -gt 0
        if ($claimed -and -not $released) {
            $leftState = if (-not $restore) { "Unknown" } elseif ($restore.clean) { "Clean" } else { "Locked" }
            try { Invoke-ScenarioLease -Action Release -LeftState $leftState -Note "scenario runner cleanup" | Out-Null }
            catch {
                if ($restore) {
                    $restore.failures = @($restore.failures) + "lease_release"
                    $restore.diffCount = [int]$restore.diffCount + 1
                    $restore.clean = $false
                } else {
                    $restore = [pscustomobject]@{ clean = $false; failures = @("lease_release"); diffCount = 1 }
                }
            }
        }
    }
    if (-not $restore) { $restore = [pscustomobject]@{ clean = $false; failures = @("preflight_failed"); diffCount = 1 } }
    $captures = $stepResult.captures
    $captures["restore.diffCount"] = $restore.diffCount
    $outcome = Get-ScenarioOutcome -Measurements @($Manifest.measurements) -Captures $captures -StepsCompleted $stepResult.completed -RestoreClean $restore.clean
    $status = $outcome.status
    if ($script:DryRun -and $status -eq "PASS") { $status = "PASS (DRY RUN)" }
    $result = [pscustomobject]@{
        id = $Manifest.id; status = $status; buildKind = $(if ($preflight) { $preflight.buildKind } else { "unknown" }); restore = $restore
        steps = $stepResult.steps; measurements = $outcome.measurements; dryRun = [bool]$script:DryRun
    }
    if ($folder) { Write-ScenarioResult -Evidence $folder -Result $result }
    return $result
}


if ($MyInvocation.InvocationName -ne ".") {
    try {
        $manifest = Read-ScenarioManifest -Path $script:Scenario -Out $script:Out
        $result = Invoke-ScenarioRun -Manifest $manifest -Out $script:Out -DryRun:$script:DryRun
        $result | Select-Object id, status, buildKind, dryRun | Format-Table -AutoSize | Out-String | Write-Output
        if ($result.status -like "PASS*") { exit 0 }
        exit 1
    } catch {
        $message = [string]$_.Exception.Message
        $safe = if ($message -match "^[a-z0-9_]{1,80}$") { $message } else { "scenario_failed" }
        [Console]::Error.WriteLine($safe)
        exit 2
    }
}
