Describe "OSRA-only evidence and PNG crops" {
    BeforeAll {
$script:TestsDir = $PSScriptRoot
if (-not $script:TestsDir) {
    # Pester 5 does not guarantee $PSScriptRoot or $PWD inside BeforeAll on every platform (the Linux
    # runner leaves both null), so anchor on the directory the suite was invoked from.
    $anchors = @($env:GITHUB_WORKSPACE, (Get-Location).Path, $PWD.Path) | Where-Object { $_ }
    foreach ($anchor in $anchors) {
        $root = $anchor
        while ($root -and -not (Test-Path -LiteralPath (Join-Path $root "scripts/hardware/scenario.ps1"))) {
            $parent = Split-Path -Parent $root
            if (-not $parent -or $parent -eq $root) { $root = $null; break }
            $root = $parent
        }
        if ($root) { $script:TestsDir = Join-Path $root "scripts/hardware/tests"; break }
    }
}
if (-not $script:TestsDir) {
    throw "tests_dir_not_found: root=[$PSScriptRoot] cmd=[$PSCommandPath] pwd=[$($PWD.Path)] loc=[$((Get-Location).Path)] ws=[$env:GITHUB_WORKSPACE]"
}
$script:RunnerPath = Join-Path $script:TestsDir "../scenario.ps1"
if (-not (Test-Path -LiteralPath $script:RunnerPath)) { throw "runner_not_found: dir=[$script:TestsDir] path=[$script:RunnerPath]" }
. $script:RunnerPath
$script:DryRun = $true

    }
    BeforeEach {
        $script:OldPath = $env:PATH
        $bin = Join-Path $script:TestsDir "fixtures/bin"
        $env:PATH = "$bin$([IO.Path]::PathSeparator)$script:OldPath"
        $env:FAKE_ADB_LOG = Join-Path $TestDrive "adb-calls.jsonl"
        $env:FAKE_SCREENSHOT = Join-Path $script:TestsDir "fixtures/rgb.png"
        $env:FAKE_WINDOW_BOUNDS = "valid"
        if (-not (Get-Command Save-ScenarioScreenshot -ErrorAction SilentlyContinue)) { throw "evidence_not_implemented" }
    }
    AfterEach {
        $env:PATH = $script:OldPath
        foreach ($name in @("FAKE_ADB_LOG", "FAKE_SCREENSHOT", "FAKE_WINDOW_BOUNDS")) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
    }

    It "crops RGB and RGBA with exact dimensions and known pixels" {
        foreach ($kind in @("rgb", "rgba")) {
            $bytes = [IO.File]::ReadAllBytes((Join-Path $script:TestsDir "fixtures/$kind.png"))
            $crop = Crop-ScenarioPng -Bytes $bytes -X 1 -Y 1 -Width 2 -Height 2
            $image = [ScenarioPng]::Decode($crop)
            $image.Width | Should -Be 2
            $image.Height | Should -Be 2
            $expected = if ($kind -eq "rgb") {
                [byte[]](0,255,0, 0,255,0, 0,0,255, 0,0,255)
            } else {
                [byte[]](0,255,0,255, 0,255,0,255, 0,0,255,255, 0,0,255,255)
            }
            ($image.Pixels -join ",") | Should -Be ($expected -join ",")
        }
    }

    It "refuses unsafe bounds instead of capturing other windows or a locked phone" {
        $env:FAKE_WINDOW_BOUNDS = "missing"
        { Get-ScenarioSafeBounds } | Should -Throw
        { Save-ScenarioScreenshot -Evidence $TestDrive -Name "safe.png" -LockState $true } | Should -Throw
        if (Test-Path -LiteralPath $env:FAKE_ADB_LOG) {
            (Get-Content -LiteralPath $env:FAKE_ADB_LOG -Raw) | Should -Not -Match "screencap"
        }
    }

    It "captures in memory and leaves only the cropped PNG, never an on-device path" {
        $folder = New-ScenarioEvidence -ScenarioId "SC-0.1" -Out $TestDrive -Before ([pscustomobject]@{ lockState = $false; values = @{} })
        $result = Save-ScenarioScreenshot -Evidence $folder -Name "safe.png" -LockState $false
        $result.status | Should -Be "DONE"
        $result.width | Should -Be 2
        $result.height | Should -Be 2
        Test-Path -LiteralPath (Join-Path $folder "safe.png") | Should -Be $true
        (Get-Content -LiteralPath $env:FAKE_ADB_LOG -Raw) | Should -Match "exec-out"
        (Get-Content -LiteralPath $env:FAKE_ADB_LOG -Raw) | Should -Not -Match "/sdcard"
        $raw = [IO.File]::ReadAllBytes((Join-Path $folder "safe.png"))
        ([ScenarioPng]::Decode($raw).Height) | Should -Be 2
    }

    It "returns NOT RUN for an unsupported image without saving raw bytes" {
        $invalid = Join-Path $TestDrive "invalid.png"
        [IO.File]::WriteAllBytes($invalid, [byte[]](1,2,3,4))
        $env:FAKE_SCREENSHOT = $invalid
        $result = Save-ScenarioScreenshot -Evidence $TestDrive -Name "safe.png" -LockState $false
        $result.status | Should -Be "NOT RUN"
        Test-Path -LiteralPath (Join-Path $TestDrive "safe.png") | Should -Be $false
    }

    It "collects the events buffer separately from the sanitized runner log" {
        $folder = New-ScenarioEvidence -ScenarioId "SC-0.1" -Out $TestDrive -Before ([pscustomobject]@{ lockState = $false; values = @{} })
        $process = Start-ScenarioEventLog -Evidence $folder
        Stop-ScenarioEventLog -Process $process
        Test-Path -LiteralPath (Join-Path $folder "events.log") | Should -Be $true
        Test-Path -LiteralPath (Join-Path $folder "runner.log") | Should -Be $false
    }

    It "does not write raw command output or arbitrary messages to the runner log" {
        $folder = New-ScenarioEvidence -ScenarioId "SC-0.1" -Out $TestDrive -Before ([pscustomobject]@{ lockState = $false; values = @{} })
        Write-ScenarioLog -Evidence $folder -Stage "preflight"
        { Write-ScenarioLog -Evidence $folder -Stage "raw-http-body" } | Should -Throw
        (Get-Content -LiteralPath (Join-Path $folder "runner.log") -Raw) | Should -Be "preflight`n"
    }
}
