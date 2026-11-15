Describe "Committed scenario manifests and dry-run CLI" {
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
