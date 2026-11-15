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
    $scenarioRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "scenarios"))
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

function Invoke-ScenarioProcess {
    param([Parameter(Mandatory = $true)][string]$Exe, [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Args)
    $name = [IO.Path]::GetFileNameWithoutExtension($Exe).ToLowerInvariant()
    if ($name -notin @("adb")) { throw "process_not_allowed" }
    $candidates = @(Get-Command $Exe -CommandType Application -ErrorAction Stop)
    $resolved = if ($env:OS -eq "Windows_NT") {
        $candidates | Where-Object { $_.Source -match "\.(?:cmd|exe)$" } | Select-Object -First 1 -ExpandProperty Source
    } else { $candidates[0].Source }
    if (-not $resolved) { throw "adb_not_found" }
    $text = & $resolved @Args | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $text }
}
