Describe "Scenario steps, measurements and restore" {
    BeforeAll {
$script:RunnerPath = Join-Path $PSScriptRoot "../scenario.ps1"
if (-not (Test-Path -LiteralPath $script:RunnerPath)) { throw "runner_not_found: path=[$script:RunnerPath]" }
. $script:RunnerPath -Serial "R5CW116Y6GF"
$script:DryRun = $true

function New-RunManifest($steps, $measurements = @()) {
    return [pscustomobject]@{
        id = "SC-0.1"; title = "Synthetic run"; pair = "A"; package = "com.osratech.child.full"
        apiHealthUrl = "http://127.0.0.1:3000/health"; timeoutSeconds = 3600
        steps = $steps; measurements = $measurements
    }
}
function Initialize-RunFake {
    $script:DryRun = $true
    $script:OldPath = $env:PATH
    $bin = Join-Path $PSScriptRoot "fixtures/bin"
    $env:PATH = "$bin$([IO.Path]::PathSeparator)$script:OldPath"
    $env:FAKE_ADB_LOG = Join-Path $TestDrive "adb-calls.jsonl"
    Remove-Item -LiteralPath $env:FAKE_ADB_LOG -ErrorAction SilentlyContinue
    $env:FAKE_SCREENSHOT = Join-Path $PSScriptRoot "fixtures/rgb.png"
}

    }
    BeforeEach {
        Initialize-RunFake
        if (-not (Get-Command Invoke-ScenarioRun -ErrorAction SilentlyContinue)) { throw "run_not_implemented" }
    }
    AfterEach {
        $env:PATH = $script:OldPath
        foreach ($name in @("FAKE_ADB_LOG", "FAKE_SCREENSHOT", "FAKE_HTTP_STATUS", "FAKE_ADB_FAIL_MATCH", "FAKE_ADB_FAIL_ONCE", "FAKE_ADB_FAILED_MARKER", "FAKE_WINDOW_BOUNDS")) {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        }
    }

    It "executes adb, wait, http and cropped screencap steps and captures values" {
        $folder = Join-Path $TestDrive "evidence"
        New-Item -ItemType Directory -Path $folder | Out-Null
        $steps = @(
            [pscustomobject]@{ type = "adb"; command = @("shell", "getprop", "ro.product.model") },
            [pscustomobject]@{ type = "wait"; seconds = 0 },
            [pscustomobject]@{ type = "http"; method = "GET"; path = "/health" },
            [pscustomobject]@{ type = "screencap"; name = "shot.png" }
        )
        $result = Invoke-ScenarioSteps -Steps $steps -Evidence $folder -LockState $false
        $result.completed | Should -Be $true
        $result.captures["adb.0.exitCode"] | Should -Be 0
        $result.captures["http.2.status"] | Should -Be 200
        $result.captures["screencap.3.height"] | Should -Be 2
    }

    It "never turns missing data or an empty diff alone into PASS" {
        $missing = Get-ScenarioOutcome -Measurements @([pscustomobject]@{ name = "missing"; actual = "no.such.value"; comparator = "eq"; limit = 1 }) -Captures @{} -StepsCompleted $true -RestoreClean $true
        $missing.status | Should -Be "NOT RUN"
        $empty = Get-ScenarioOutcome -Measurements @() -Captures @{} -StepsCompleted $true -RestoreClean $true
        $empty.status | Should -Be "NOT RUN"
        $pass = Get-ScenarioOutcome -Measurements @(
            [pscustomobject]@{ name = "status"; actual = "http.0.status"; comparator = "eq"; limit = 200 },
            [pscustomobject]@{ name = "diff"; actual = "restore.diffCount"; comparator = "empty" }
        ) -Captures @{ "http.0.status" = 200; "restore.diffCount" = 0 } -StepsCompleted $true -RestoreClean $true
        $pass.status | Should -Be "PASS"
        $failed = Get-ScenarioOutcome -Measurements @([pscustomobject]@{ name = "status"; actual = "http.0.status"; comparator = "eq"; limit = 201 }) -Captures @{ "http.0.status" = 200 } -StepsCompleted $true -RestoreClean $true
        $failed.status | Should -Be "FAIL"
        $unclean = Get-ScenarioOutcome -Measurements @([pscustomobject]@{ name = "diff"; actual = "restore.diffCount"; comparator = "empty" }) -Captures @{ "restore.diffCount" = 0 } -StepsCompleted $true -RestoreClean $false
        $unclean.status | Should -Be "FAIL"
    }

    It "refuses a manifest package outside the allowlist before adb or a lease (#797 item 4)" {
        $script:LeaseCalls = @()
        $manifest = New-RunManifest @([pscustomobject]@{ type = "adb"; command = @("shell", "getprop", "ro.product.model") })
        $manifest.package = "com.whatsapp"
        $thrown = $null
        try { Invoke-ScenarioRun -Manifest $manifest -Out $TestDrive | Out-Null } catch { $thrown = [string]$_.Exception.Message }
        $thrown | Should -Be "package_not_in_allowlist"
        (Test-Path -LiteralPath $env:FAKE_ADB_LOG) | Should -Be $false
        @($script:LeaseCalls).Count | Should -Be 0
    }

    It "attempts every restore after one fails and reports the diff" {
        $before = Get-ScenarioBeforeState
        $env:FAKE_ADB_FAIL_ONCE = "settings put global zen_mode"
        $env:FAKE_ADB_FAILED_MARKER = Join-Path $TestDrive "once.marker"
        $restore = Restore-ScenarioState -Before $before
        $restore.clean | Should -Be $false
        $restore.failures.Count | Should -Be 1
        $logged = Get-Content -LiteralPath $env:FAKE_ADB_LOG -Raw
        $logged | Should -Match "screen_off_timeout"
        $logged | Should -Match "zen_mode"
    }

    It "restores and releases in finally when a step throws, preserving FAIL" {
        $env:FAKE_ADB_FAIL_ONCE = "settings put global zen_mode"
        $env:FAKE_ADB_FAILED_MARKER = Join-Path $TestDrive "full-run.marker"
        Remove-Item -LiteralPath $env:FAKE_ADB_FAILED_MARKER -ErrorAction SilentlyContinue
        $manifest = New-RunManifest @([pscustomobject]@{ type = "adb"; command = @("shell", "settings", "put", "global", "zen_mode", "0") })
        $result = Invoke-ScenarioRun -Manifest $manifest -Out $TestDrive
        $result.status | Should -Be "FAIL"
        $result.restore.clean | Should -Be $true
        ($script:LeaseCalls[-1].Action) | Should -Be "Release"
        $log = Get-Content -LiteralPath $env:FAKE_ADB_LOG
        ($log | Select-String -SimpleMatch '"settings","put","global","zen_mode","0"').Count | Should -Be 1
        ($log | Select-String -SimpleMatch '"settings","put","global","zen_mode"').Count | Should -Be 2
    }

    It "heartbeats the lease before a step (#797)" {
        $script:LeaseCalls = @()
        $script:Deadline = $null
        $result = Invoke-ScenarioSteps -Steps @([pscustomobject]@{ type = "wait"; seconds = 0 }) -Evidence $TestDrive -LockState $false
        $result.completed | Should -Be $true
        @($script:LeaseCalls | Where-Object { $_.Action -eq "Heartbeat" }).Count | Should -Be 1
    }

    It "stops at the manifest timeout instead of outlasting the lease (#797)" {
        $script:LeaseCalls = @()
        $script:Deadline = [DateTime]::UtcNow.AddSeconds(-1)
        try {
            $result = Invoke-ScenarioSteps -Steps @([pscustomobject]@{ type = "wait"; seconds = 0 }) -Evidence $TestDrive -LockState $false
        } finally { $script:Deadline = $null }
        $result.completed | Should -Be $false
        $result.error | Should -Be "scenario_timeout"
    }

    It "refuses a wait that would run past the deadline (#797)" {
        $script:LeaseCalls = @()
        $script:Deadline = [DateTime]::UtcNow.AddSeconds(3)
        try {
            $result = Invoke-ScenarioSteps -Steps @([pscustomobject]@{ type = "wait"; seconds = 30 }) -Evidence $TestDrive -LockState $false
        } finally { $script:Deadline = $null }
        $result.completed | Should -Be $false
        $result.error | Should -Be "scenario_timeout"
    }
}
