Describe "Scenario validation suite" {
    BeforeAll {
$script:RunnerPath = Join-Path $PSScriptRoot "../scenario.ps1"
. $script:RunnerPath

function New-Manifest {
    return [pscustomobject]@{
        id = "SC-0.1"
        title = "Synthetic preflight"
        pair = "A"
        package = "com.osratech.child.test"
        apiHealthUrl = "http://127.0.0.1:3000/health"
        timeoutSeconds = 60
        steps = @([pscustomobject]@{ type = "adb"; command = @("shell", "getprop", "ro.product.model") })
        measurements = @()
    }
}

    }

Describe "Scenario manifest shape and URL validation" {
    It "accepts a minimal valid manifest" {
        $path = Join-Path $TestDrive "SC-0.1.json"
        New-Manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
        (Read-ScenarioManifest -Path $path -Out $TestDrive).id | Should -Be "SC-0.1"
    }

    It "rejects unknown fields" {
        $manifest = New-Manifest
        $manifest | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
        $path = Join-Path $TestDrive "SC-0.1.json"
        $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
        { Read-ScenarioManifest -Path $path -Out $TestDrive } | Should -Throw
    }

    It "rejects a path outside the scenario or output roots" {
        { Read-ScenarioManifest -Path (Join-Path $PSScriptRoot "../scenarios/../outside.json") -Out $TestDrive } | Should -Throw
    }

    It "rejects a non-loopback, non-staging health URL" {
        $manifest = New-Manifest
        $manifest.apiHealthUrl = "https://example.com/health"
        $path = Join-Path $TestDrive "SC-0.1.json"
        $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
        { Read-ScenarioManifest -Path $path -Out $TestDrive } | Should -Throw
    }

    It "accepts every step shape without arbitrary shell strings" {
        $shapes = @(
            [pscustomobject]@{ type = "screencap"; name = "before.png" },
            [pscustomobject]@{ type = "wait"; seconds = 1 },
            [pscustomobject]@{ type = "http"; method = "GET"; path = "/health" },
            [pscustomobject]@{ type = "manual"; instruction = "Observe the synthetic screen and press Enter" }
        )
        foreach ($step in $shapes) { { Assert-ScenarioStep -Step $step } | Should -Not -Throw }
        { Assert-ScenarioStep -Step ([pscustomobject]@{ type = "adb"; command = "shell getprop" }) } | Should -Throw
        { Assert-ScenarioStep -Step ([pscustomobject]@{ type = "screencap"; name = "../other.png" }) } | Should -Throw
    }
}

Describe "Structural device and data refusals" {
    $cases = @(
        @{ name = "clock date"; args = @("shell", "date") },
        @{ name = "alarm clock"; args = @("shell", "cmd", "alarm", "set-time", "12:00") },
        @{ name = "auto time"; args = @("shell", "settings", "put", "global", "auto_time", "1") },
        @{ name = "auto timezone"; args = @("shell", "settings", "put", "global", "auto_time_zone", "1") },
        @{ name = "explicit timezone"; args = @("shell", "settings", "put", "global", "time_zone", "UTC") },
        @{ name = "airplane setting"; args = @("shell", "settings", "put", "global", "airplane_mode_on", "1") },
        @{ name = "admin removal"; args = @("shell", "dpm", "remove-active-admin", "test/.Admin") },
        @{ name = "UI dump"; args = @("shell", "uiautomator", "dump") },
        @{ name = "reboot"; args = @("shell", "reboot") },
        @{ name = "digit text"; args = @("shell", "input", "text", "1234") },
        @{ name = "embedded digit run"; args = @("shell", "input", "text", "safe1234text") },
        @{ name = "escape key"; args = @("shell", "input", "keyevent", "111") },
        @{ name = "numeric key sequence"; args = @("shell", "input", "keyevent", "7", "16") },
        @{ name = "named key sequence"; args = @("shell", "input", "keyevent", "KEYCODE_0", "KEYCODE_9") },
        @{ name = "serial override"; args = @("shell", "-s", "another-serial", "getprop") },
        @{ name = "connect"; args = @("connect", "192.0.2.1:5555") },
        @{ name = "disconnect"; args = @("disconnect") },
        @{ name = "tcpip"; args = @("tcpip", "5555") },
        @{ name = "usb"; args = @("usb") },
        @{ name = "kill server"; args = @("kill-server") },
        @{ name = "reconnect"; args = @("reconnect") },
        @{ name = "wifi service"; args = @("shell", "svc", "wifi", "disable") },
        @{ name = "data service"; args = @("shell", "svc", "data", "disable") },
        @{ name = "bluetooth service"; args = @("shell", "svc", "bluetooth", "disable") },
        @{ name = "cmd wifi"; args = @("shell", "cmd", "wifi", "scan") },
        @{ name = "cmd connectivity"; args = @("shell", "cmd", "connectivity", "check") },
        @{ name = "airplane broadcast"; args = @("shell", "am", "broadcast", "-a", "android.intent.action.AIRPLANE_MODE") },
        @{ name = "unsaved setting"; args = @("shell", "settings", "put", "global", "volume_music", "1") },
        @{ name = "window size"; args = @("shell", "wm", "size", "1080x2400") },
        @{ name = "window density"; args = @("shell", "wm", "density", "440") }
    )
    foreach ($case in $cases) {
        It "refuses $($case.name), including a nested wrapper" {
            { Assert-ScenarioCommand -Command $case.args } | Should -Throw
            { Assert-ScenarioCommand -Command (@("exec-out") + $case.args) } | Should -Throw
        }
    }

    It "permits a read-only settings get" {
        { Assert-ScenarioCommand -Command @("shell", "settings", "get", "global", "auto_time") } | Should -Not -Throw
    }

    It "requires nonpersonal content and a safe projection" {
        $query = @("shell", "content", "query", "--uri", "content://synthetic")
        { Assert-ScenarioStep -Step ([pscustomobject]@{ type = "adb"; command = $query }) } | Should -Throw
        { Assert-ScenarioStep -Step ([pscustomobject]@{ type = "adb"; command = $query; nonPersonal = $true; projection = @("phone", "body") }) } | Should -Throw
        { Assert-ScenarioStep -Step ([pscustomobject]@{ type = "adb"; command = $query; nonPersonal = $true; projection = @("count") }) } | Should -Not -Throw
    }
}

Describe "Fake adb argument-array boundary" {
    It "records literal arguments without executing a command string" {
        $bin = Join-Path $PSScriptRoot "fixtures/bin"
        $env:FAKE_ADB_LOG = Join-Path $TestDrive "adb-calls.jsonl"
        $oldPath = $env:PATH
        try {
            $env:PATH = "$bin$([IO.Path]::PathSeparator)$oldPath"
            $result = Invoke-ScenarioProcess -Exe "adb" -Args @("shell", "getprop", "literal;not-a-command")
            $result.ExitCode | Should -Be 0
            $logged = Get-Content -LiteralPath $env:FAKE_ADB_LOG -Raw | ConvertFrom-Json
            $logged[2] | Should -Be "literal;not-a-command"
        } finally {
            $env:PATH = $oldPath
            Remove-Item Env:FAKE_ADB_LOG -ErrorAction SilentlyContinue
        }
    }
}
}
