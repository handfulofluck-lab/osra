Describe "Scenario validation suite" {
    BeforeAll {
$script:RunnerPath = Join-Path $PSScriptRoot "../scenario.ps1"
if (-not (Test-Path -LiteralPath $script:RunnerPath)) { throw "runner_not_found: path=[$script:RunnerPath]" }
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

    It "refuses an ApiBase outside the allowlist (#797)" {
        $old = $script:ApiBase
        try {
            $script:ApiBase = "https://example.com"
            { Invoke-ScenarioRun -Manifest (New-Manifest) -Out $TestDrive -DryRun } | Should -Throw
        } finally { $script:ApiBase = $old }
    }
}

Describe "Structural device and data refusals" {
    $cases = @(
        @{ name = "clock date"; command = @("shell", "date") },
        @{ name = "alarm clock"; command = @("shell", "cmd", "alarm", "set-time", "12:00") },
        @{ name = "auto time"; command = @("shell", "settings", "put", "global", "auto_time", "1") },
        @{ name = "auto timezone"; command = @("shell", "settings", "put", "global", "auto_time_zone", "1") },
        @{ name = "explicit timezone"; command = @("shell", "settings", "put", "global", "time_zone", "UTC") },
        @{ name = "airplane setting"; command = @("shell", "settings", "put", "global", "airplane_mode_on", "1") },
        @{ name = "admin removal"; command = @("shell", "dpm", "remove-active-admin", "test/.Admin") },
        @{ name = "admin verb other than list-owners"; command = @("shell", "dpm", "set-active-admin", "test/.Admin") },
        @{ name = "UI dump"; command = @("shell", "uiautomator", "dump") },
        @{ name = "reboot"; command = @("shell", "reboot") },
        @{ name = "reboot bootloader"; command = @("reboot-bootloader") },
        @{ name = "root"; command = @("root") },
        @{ name = "remount"; command = @("remount") },
        @{ name = "install"; command = @("install", "/data/local/tmp/app.apk") },
        @{ name = "top-level uninstall"; command = @("uninstall", "com.osratech.child.full") },
        @{ name = "digit text"; command = @("shell", "input", "text", "1234") },
        @{ name = "embedded digit run"; command = @("shell", "input", "text", "safe1234text") },
        @{ name = "digits split by spaces"; command = @("shell", "input", "text", "1", "2", "3", "4") },
        @{ name = "escape key"; command = @("shell", "input", "keyevent", "111") },
        @{ name = "named escape key"; command = @("shell", "input", "keyevent", "KEYCODE_ESCAPE") },
        @{ name = "numeric key sequence"; command = @("shell", "input", "keyevent", "7", "16") },
        @{ name = "pin then enter"; command = @("shell", "input", "keyevent", "7", "8", "9", "10", "66") },
        @{ name = "named key sequence"; command = @("shell", "input", "keyevent", "KEYCODE_0", "KEYCODE_9") },
        @{ name = "one-element admin removal"; command = @("shell", "dpm remove-active-admin test/.Admin") },
        @{ name = "one-element escape key"; command = @("shell", "input keyevent 111") },
        @{ name = "one-element auto time"; command = @("shell", "settings put global auto_time 0") },
        @{ name = "semicolon chain"; command = @("shell", "echo x;reboot") },
        @{ name = "pipe chain"; command = @("shell", "getprop | reboot") },
        @{ name = "ampersand chain"; command = @("shell", "getprop & reboot") },
        @{ name = "substitution"; command = @("shell", 'echo $(reboot)') },
        @{ name = "backtick substitution"; command = @("shell", 'echo `reboot`') },
        @{ name = "newline inside an element"; command = @("shell", "getprop`nro.product.model") },
        @{ name = "tab inside an element"; command = @("shell", "getprop`tro.product.model") },
        @{ name = "serial override"; command = @("shell", "-s", "another-serial", "getprop") },
        @{ name = "transport flag t"; command = @("-t", "1", "shell", "getprop") },
        @{ name = "transport flag H"; command = @("-H", "127.0.0.1", "shell", "getprop") },
        @{ name = "transport flag P"; command = @("-P", "5037", "shell", "getprop") },
        @{ name = "connect"; command = @("connect", "192.0.2.1:5555") },
        @{ name = "disconnect"; command = @("disconnect") },
        @{ name = "tcpip"; command = @("tcpip", "5555") },
        @{ name = "usb"; command = @("usb") },
        @{ name = "kill server"; command = @("kill-server") },
        @{ name = "reconnect"; command = @("reconnect") },
        @{ name = "wifi service"; command = @("shell", "svc", "wifi", "disable") },
        @{ name = "data service"; command = @("shell", "svc", "data", "disable") },
        @{ name = "bluetooth service"; command = @("shell", "svc", "bluetooth", "disable") },
        @{ name = "cmd wifi"; command = @("shell", "cmd", "wifi", "scan") },
        @{ name = "cmd connectivity"; command = @("shell", "cmd", "connectivity", "check") },
        @{ name = "airplane broadcast"; command = @("shell", "am", "broadcast", "-a", "android.intent.action.AIRPLANE_MODE") },
        @{ name = "unsaved setting"; command = @("shell", "settings", "put", "global", "volume_music", "1") },
        @{ name = "restored key in the wrong table"; command = @("shell", "settings", "put", "global", "screen_off_timeout", "15000") },
        @{ name = "window size"; command = @("shell", "wm", "size", "1080x2400") },
        @{ name = "window density"; command = @("shell", "wm", "density", "440") },
        @{ name = "full-path dpm"; command = @("shell", "/system/bin/dpm", "remove-active-admin", "test/.Admin") },
        @{ name = "full-path input"; command = @("shell", "/system/bin/input", "keyevent", "111") },
        @{ name = "full-path reboot"; command = @("shell", "/system/bin/reboot") },
        @{ name = "quote-split verb"; command = @("shell", "d''pm", "list-owners") },
        @{ name = "quote-split digits"; command = @("shell", "input", "text", "1'2'34") },
        @{ name = "input with a source"; command = @("shell", "input", "keyboard", "keyevent", "111") },
        @{ name = "input with a display"; command = @("shell", "input", "-d", "0", "text", "1234") },
        @{ name = "one digit key"; command = @("shell", "input", "keyevent", "7") },
        @{ name = "numpad keycode"; command = @("shell", "input", "keyevent", "keycode_numpad_1") },
        @{ name = "two digit keys"; command = @("shell", "input", "keyevent", "3", "4") },
        @{ name = "two digit text"; command = @("shell", "input", "text", "12") },
        @{ name = "content insert"; command = @("shell", "content", "insert", "--uri", "content://settings/global") },
        @{ name = "settings delete"; command = @("shell", "settings", "delete", "global", "zen_mode") },
        @{ name = "settings reset"; command = @("shell", "settings", "reset", "global") },
        @{ name = "install multiple"; command = @("install-multiple", "a.apk", "b.apk") },
        @{ name = "transport flag L"; command = @("-L", "5037", "shell", "getprop") },
        @{ name = "backslash in a command"; command = @("shell", 'ro\product.model') }
    )
    It "refuses <name>, wrapped or not" -ForEach $cases {
        param($name, $command)
        { Assert-ScenarioCommand -Command $command } | Should -Throw
        { Assert-ScenarioCommand -Command (@("exec-out") + $command) } | Should -Throw
    }

    It "permits read-only commands, the screenshot flag and every restored key in its own table" {
        foreach ($command in @(
            @("shell", "dpm", "list-owners"),
            @("shell", "settings", "get", "global", "auto_time"),
            @("exec-out", "screencap", "-p"),
            @("shell", "settings", "put", "system", "screen_off_timeout", "15000"),
            @("shell", "settings", "put", "secure", "accessibility_enabled", "1"),
            @("shell", "settings put system screen_off_timeout 15000"),
            @("shell", "input", "text", "hello"),
            @("shell", "input", "keyevent", "4"),
            @("shell", "input", "tap", "540", "1200"),
            @("shell", "input", "swipe", "540", "1600", "540", "400", "300"),
            @("shell", "appops", "get", "com.osratech.child.full", "SYSTEM_ALERT_WINDOW"),
            @("shell", "getprop", "ro.product.model"),
            @("shell", "dumpsys", "package", "com.osratech.child.test"),
            @("shell", "pm", "list", "packages")
        )) { { Assert-ScenarioCommand -Command $command } | Should -Not -Throw }
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

    It "loads with TEMP unset, as on the Linux runner (#667)" {
        $runner = Join-Path $PSScriptRoot "../scenario.ps1"
        $exe = (Get-Process -Id $PID).Path
        $printed = & $exe -NoProfile -Command "`$env:TEMP = `$null; . `"$runner`"; `$script:Out" 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $printed.Trim() | Should -Match "osra-scenarios$"
    }
}
}
