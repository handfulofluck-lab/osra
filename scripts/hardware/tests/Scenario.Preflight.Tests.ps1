Describe "Scenario preflight through the fake boundary" {
    BeforeAll {
$script:TestsDir = $PSScriptRoot
if (-not $script:TestsDir) {
    # Pester 5 does not guarantee $PSScriptRoot inside BeforeAll on every platform (the Linux runner
    # leaves it null), so fall back to the repository this suite was invoked from.
    $root = $PWD.Path
    while (-not (Test-Path -LiteralPath (Join-Path $root "scripts/hardware/scenario.ps1"))) {
        $parent = Split-Path -Parent $root
        if ($parent -eq $root) { throw "tests_dir_not_found" }
        $root = $parent
    }
    $script:TestsDir = Join-Path $root "scripts/hardware/tests"
}
$script:RunnerPath = Join-Path $script:TestsDir "../scenario.ps1"
. $script:RunnerPath

function New-TestManifest {
    return [pscustomobject]@{
        id = "SC-0.1"; title = "Synthetic preflight"; pair = "A"; package = "com.osratech.child.test"
        apiHealthUrl = "http://127.0.0.1:3000/health"; timeoutSeconds = 60
        steps = @([pscustomobject]@{ type = "screencap"; name = "safe.png" })
        measurements = @()
    }
}
function Initialize-FakeAdb {
    $script:DryRun = $true
    $script:OldPath = $env:PATH
    $bin = Join-Path $script:TestsDir "fixtures/bin"
    $env:PATH = "$bin$([IO.Path]::PathSeparator)$script:OldPath"
    $env:FAKE_ADB_LOG = Join-Path $TestDrive "adb-calls.jsonl"
}
function Get-FakeCalls {
    if (-not (Test-Path -LiteralPath $env:FAKE_ADB_LOG)) { return @() }
    $calls = [System.Collections.Generic.List[object]]::new()
    foreach ($line in Get-Content -LiteralPath $env:FAKE_ADB_LOG) { $calls.Add(($line | ConvertFrom-Json)) }
    return $calls.ToArray()
}

    }
    BeforeEach {
        Initialize-FakeAdb
        if (-not (Get-Command Invoke-ScenarioPreflight -ErrorAction SilentlyContinue)) { throw "preflight_not_implemented" }
    }
    AfterEach {
        $env:PATH = $script:OldPath
        foreach ($name in @("FAKE_ADB_LOG", "FAKE_ADB_EXIT", "FAKE_SCREENSHOT", "FAKE_LOCKED", "FAKE_MODEL", "FAKE_BUILD_KIND", "FAKE_ADMIN_PACKAGE")) {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        }
    }

    It "injects the runner serial, checks build and health, and never emits the health body" {
        $result = Invoke-ScenarioPreflight -Manifest (New-TestManifest)
        $result.buildKind | Should -Be "release"
        $result.lockState | Should -Be $false
        $result.health.StatusCode | Should -Be 200
        ($result.health.PSObject.Properties.Name -contains "Content") | Should -Be $false
        foreach ($call in (Get-FakeCalls)) {
            $call[0] | Should -Be "-s"
            $call[1] | Should -Be "R5CW116Y6GF"
        }
        ($script:LeaseCalls[0].Action) | Should -Be "Claim"
        ($result.health.PSObject.Properties.Name -contains "Body") | Should -Be $false
    }

    It "refuses test-only and debuggable builds as gate evidence" {
        foreach ($kind in @("test-only", "debuggable")) {
            $env:FAKE_BUILD_KIND = $kind
            { Invoke-ScenarioPreflight -Manifest (New-TestManifest) } | Should -Throw
        }
    }

    It "refuses a model mismatch rather than pairing another phone" {
        $env:FAKE_MODEL = "not-the-catalogue-model"
        { Invoke-ScenarioPreflight -Manifest (New-TestManifest) } | Should -Throw
    }

    It "stops a manual step on a locked phone without unlock or image attempts" {
        $env:FAKE_LOCKED = "1"
        $result = Invoke-ScenarioManualStep -LockState $true
        $result.status | Should -Be "NOT RUN"
        $result.reason | Should -Be "phone locked"
        $joined = (Get-FakeCalls | ConvertTo-Json -Compress)
        $joined | Should -Not -Match "input"
        $joined | Should -Not -Match "screencap"
    }

    It "saves all nine values and the lock state in before.json" {
        $before = Get-ScenarioBeforeState
        $before.values.Keys.Count | Should -Be 9
        $before.lockState | Should -Be $false
        $evidence = New-ScenarioEvidence -ScenarioId "SC-0.1" -Out $TestDrive -Before $before
        $saved = Get-Content -LiteralPath (Join-Path $evidence "before.json") -Raw | ConvertFrom-Json
        $saved.lockState | Should -Be $false
        $saved.values.PSObject.Properties.Name.Count | Should -Be 9
        $saved.values.PSObject.Properties.Name -contains "screen_off_timeout" | Should -Be $true
        $saved.values.PSObject.Properties.Name -contains "zen_mode" | Should -Be $true
    }

    It "refuses pm uninstall and pm clear of a current device admin before executing them" {
        $env:FAKE_ADMIN_PACKAGE = "com.osratech.child.test"
        foreach ($operation in @("uninstall", "clear")) {
            { Invoke-Adb -Command @("shell", "pm", $operation, "com.osratech.child.test") -Package "com.osratech.child.test" } | Should -Throw
        }
        ((Get-FakeCalls | ConvertTo-Json -Compress) -match "pm.*(uninstall|clear)") | Should -Be $false
    }

    It "never performs an unrestored settings or window mutation" {
        { Invoke-Adb -Command @("shell", "settings", "put", "global", "volume_music", "1") } | Should -Throw
        { Invoke-Adb -Command @("shell", "wm", "size", "1080x2400") } | Should -Throw
        { Invoke-Adb -Command @("shell", "wm", "density", "440") } | Should -Throw
        ((Get-FakeCalls | ConvertTo-Json -Compress) -match '"put"|"wm"') | Should -Be $false
    }
}
