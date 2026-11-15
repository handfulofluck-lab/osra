Describe "Committed scenario manifests and dry-run CLI" {
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
$script:DryRun = $true

    }
    BeforeEach {
        $script:DryRun = $true
        $script:OldPath = $env:PATH
        $bin = Join-Path $script:TestsDir "fixtures/bin"
        $env:PATH = "$bin$([IO.Path]::PathSeparator)$script:OldPath"
        $env:FAKE_ADB_LOG = Join-Path $TestDrive "adb-calls.jsonl"
        $env:FAKE_SCREENSHOT = Join-Path $script:TestsDir "fixtures/rgb.png"
        if (-not (Test-Path -LiteralPath (Join-Path $script:TestsDir "../scenarios/SC-0.1.json"))) { throw "samples_not_implemented" }
    }
    AfterEach {
        $env:PATH = $script:OldPath
        foreach ($name in @("FAKE_ADB_LOG", "FAKE_SCREENSHOT")) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
    }

    It "validates both committed manifests" {
        foreach ($id in @("SC-0.1", "SC-1.1")) {
            $manifest = Read-ScenarioManifest -Path $id -Out $TestDrive
            $manifest.id | Should -Be $id
        }
    }

    It "prints PASS (DRY RUN), writes result files, and exits zero" {
        $out = Join-Path $TestDrive "out"
        $hostExe = (Get-Process -Id $PID).Path
        $output = & $hostExe -NoProfile -ExecutionPolicy Bypass -File $script:RunnerPath -DryRun -Scenario SC-0.1 -Out $out 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $output | Should -Match "PASS \(DRY RUN\)"
        $result = Get-ChildItem -Path $out -Recurse -Filter result.md
        $result.Count | Should -Be 1
        (Get-Content -LiteralPath $result[0].FullName -Raw) | Should -Match "PASS \(DRY RUN\)"
    }
}
