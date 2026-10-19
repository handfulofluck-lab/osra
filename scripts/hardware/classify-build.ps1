# OSRA - is the installed build gate-eligible? (issue #178)
#
# The ten-bypass probe (android-bypass-probe.ps1) measures tamper protections. Since #170 every debug
# APK declares android:testOnly="true" and is debuggable. A testOnly APK can be replaced with
# `adb install -r` without a signature match, its device admin can be removed with `dpm`, and its
# process is debuggable - so a PASS on it says nothing about the release artefact. This file is the
# pure decision, kept out of the probe so it can be tested without a phone.
#
# Dot-sourced by the hardware scripts:
#   . (Join-Path $PSScriptRoot "classify-build.ps1")
#   $build = Get-BuildKind -DumpsysText (Sh "dumpsys package $PKG") -Package $PKG
#
# Run it directly to check the fixtures (CI runs this in workflow-lint):
#   pwsh -NoProfile -File scripts/hardware/classify-build.ps1 -SelfTest
#
# Windows PowerShell 5.1, ASCII only.

param([switch]$SelfTest)

# Returns [pscustomobject]@{ Kind; Flags; Detail } with Kind one of:
#   release       - no TEST_ONLY and no DEBUGGABLE flag: the build can be gate evidence
#   test-only     - flags carry TEST_ONLY (takes precedence: it is the property that relaxes the gate)
#   debuggable    - flags carry DEBUGGABLE
#   not-installed - dumpsys answered "Unable to find package: ..."
#   unknown       - the text has no package block or no flags line; callers must refuse, not assume
# Precedence is test-only, then debuggable, then release. Flags of another package in the same dump
# are ignored: only the block for -Package is read.
function Get-BuildKind {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$DumpsysText,
        [string]$Package = ""
    )
    $text = $DumpsysText -replace "`r", ""

    if ($text -match "(?im)^\s*Unable to find package:\s*(\S+)") {
        return [pscustomobject]@{
            Kind   = "not-installed"
            Flags  = @()
            Detail = "dumpsys answered 'Unable to find package: " + $Matches[1] + "'"
        }
    }

    $block = $text
    if ($Package) {
        $escaped = [regex]::Escape($Package)
        $start = [regex]::Match($text, "(?m)^\s*Package \[" + $escaped + "\]")
        if (-not $start.Success) {
            return [pscustomobject]@{
                Kind   = "unknown"
                Flags  = @()
                Detail = "no 'Package [" + $Package + "]' block in the dumpsys text"
            }
        }
        $rest = $text.Substring($start.Index)
        $next = [regex]::Match($rest.Substring($start.Length), "(?m)^\s*(Package \[|Hidden system packages:)")
        if ($next.Success) { $rest = $rest.Substring(0, $start.Length + $next.Index) }
        $block = $rest
    }

    $m = [regex]::Match($block, "(?m)^\s*flags=\[([^\]]*)\]")
    if (-not $m.Success) {
        return [pscustomobject]@{
            Kind   = "unknown"
            Flags  = @()
            Detail = "no 'flags=[ ... ]' line in the package block"
        }
    }

    $flags = @($m.Groups[1].Value.Trim() -split "\s+" | Where-Object { $_ })
    $kind = "release"
    if ($flags -contains "TEST_ONLY") { $kind = "test-only" }
    elseif ($flags -contains "DEBUGGABLE") { $kind = "debuggable" }

    return [pscustomobject]@{
        Kind   = $kind
        Flags  = $flags
        Detail = "flags=[" + ($flags -join " ") + "]"
    }
}

# ---------------------------------------------------------------------------------------------------
# Fixtures. The release block and the not-installed line are verbatim output from the maintainer's
# Galaxy Z Flip4 (SM-F721B, Android 16), captured read-only on 2026-10-19 with nothing of ours
# installed. The testOnly/debuggable blocks use the same field layout; their flags line is what the
# child-android debug variant declares since #170 (DEBUGGABLE + TEST_ONLY), and #174's hardware run
# recorded the matching `testOnlyAdmin=true` in `dumpsys device_policy`. They are marked below
# because that exact line was not captured from the phone in this state.
# ---------------------------------------------------------------------------------------------------

# REAL Flip4 output: `adb shell dumpsys package com.esim.numero` (a release-style install).
$fixtureRelease = @'
Packages:
  Package [com.esim.numero] (2fe558d):
    appId=10399
    pkg=Package{c699342 com.esim.numero}
    codePath=/data/app/~~bf7z3LDWSkQGD_4BL2RUMg==/com.esim.numero-JG469vq1_xF5FYjOrv035A==
    resourcePath=/data/app/~~bf7z3LDWSkQGD_4BL2RUMg==/com.esim.numero-JG469vq1_xF5FYjOrv035A==
    legacyNativeLibraryDir=/data/app/~~bf7z3LDWSkQGD_4BL2RUMg==/com.esim.numero-JG469vq1_xF5FYjOrv035A==/lib
    extractNativeLibs=false
    primaryCpuAbi=arm64-v8a
    secondaryCpuAbi=null
    cpuAbiOverride=null
    versionCode=333 minSdk=28 targetSdk=36
    minExtensionVersions=[]
    versionName=18.73
    hiddenApiEnforcementPolicy=2
    usesNonSdkApi=false
    splits=[base, config.arm64_v8a, config.xxhdpi]
    apkSigningVersion=3
    flags=[ HAS_CODE ALLOW_CLEAR_USER_DATA LARGE_HEAP ]
    privateFlags=[ PRIVATE_FLAG_ACTIVITIES_RESIZE_MODE_RESIZEABLE_VIA_SDK_VERSION ALLOW_AUDIO_PLAYBACK_CAPTURE PRIVATE_FLAG_REQUEST_LEGACY_EXTERNAL_STORAGE HAS_DOMAIN_URLS PARTIALLY_DIRECT_BOOT_AWARE PRIVATE_FLAG_ALLOW_NATIVE_HEAP_POINTER_TAGGING ]
'@

# REAL Flip4 output: `adb shell dumpsys package com.familyshield.agent` with nothing installed.
$fixtureNotInstalled = @'
Unable to find package: com.familyshield.agent
'@

# The agent's debug block: same dump layout, flags line assembled for #170's debug variant.
$fixtureTestOnly = @'
Packages:
  Package [com.familyshield.agent] (8f2a1c3):
    appId=10412
    pkg=Package{5a1f2b7 com.familyshield.agent}
    codePath=/data/app/~~T3gX1s0aQ2m==/com.familyshield.agent-P9o4r2wL==
    resourcePath=/data/app/~~T3gX1s0aQ2m==/com.familyshield.agent-P9o4r2wL==
    legacyNativeLibraryDir=/data/app/~~T3gX1s0aQ2m==/com.familyshield.agent-P9o4r2wL==/lib
    extractNativeLibs=false
    primaryCpuAbi=arm64-v8a
    secondaryCpuAbi=null
    cpuAbiOverride=null
    versionCode=1 minSdk=26 targetSdk=35
    minExtensionVersions=[]
    versionName=1.0
    hiddenApiEnforcementPolicy=2
    usesNonSdkApi=false
    splits=[base]
    apkSigningVersion=3
    flags=[ DEBUGGABLE HAS_CODE ALLOW_CLEAR_USER_DATA TEST_ONLY ]
    privateFlags=[ PRIVATE_FLAG_ACTIVITIES_RESIZE_MODE_RESIZEABLE_VIA_SDK_VERSION PARTIALLY_DIRECT_BOOT_AWARE PRIVATE_FLAG_ALLOW_NATIVE_HEAP_POINTER_TAGGING ]
'@

# A debuggable build that is not testOnly (a pre-#170 debug APK).
$fixtureDebuggable = @'
Packages:
  Package [com.familyshield.agent] (8f2a1c3):
    appId=10412
    codePath=/data/app/~~T3gX1s0aQ2m==/com.familyshield.agent-P9o4r2wL==
    versionCode=1 minSdk=26 targetSdk=35
    versionName=1.0
    flags=[ DEBUGGABLE HAS_CODE ALLOW_CLEAR_USER_DATA ]
    privateFlags=[ PARTIALLY_DIRECT_BOOT_AWARE ]
'@

# Two packages in one dump: the flags of another package must not decide this one's kind.
$fixtureTwoPackages = @'
Packages:
  Package [com.example.other] (1111111):
    codePath=/data/app/~~other==
    flags=[ DEBUGGABLE HAS_CODE ALLOW_CLEAR_USER_DATA TEST_ONLY ]
  Package [com.familyshield.agent] (8f2a1c3):
    codePath=/data/app/~~ours==
    flags=[ HAS_CODE ALLOW_CLEAR_USER_DATA ]
'@

function Invoke-ClassifyBuildSelfTest {
    $cases = @(
        @{ Name = "Flip4 release install (real output)"; Text = $fixtureRelease; Package = "com.esim.numero"; Want = "release" },
        @{ Name = "agent debug build (testOnly + debuggable)"; Text = $fixtureTestOnly; Package = "com.familyshield.agent"; Want = "test-only" },
        @{ Name = "agent debug build (debuggable, pre-#170)"; Text = $fixtureDebuggable; Package = "com.familyshield.agent"; Want = "debuggable" },
        @{ Name = "both flags present -> test-only wins"; Text = $fixtureTestOnly; Package = "com.familyshield.agent"; Want = "test-only" },
        @{ Name = "nothing installed (real output)"; Text = $fixtureNotInstalled; Package = "com.familyshield.agent"; Want = "not-installed" },
        @{ Name = "empty dumpsys -> unknown, never release"; Text = ""; Package = "com.familyshield.agent"; Want = "unknown" },
        @{ Name = "requested package absent from a non-empty dump"; Text = $fixtureRelease; Package = "com.familyshield.agent"; Want = "unknown" },
        @{ Name = "another package is testOnly, ours is release"; Text = $fixtureTwoPackages; Package = "com.familyshield.agent"; Want = "release" }
    )

    $failed = 0
    foreach ($case in $cases) {
        $got = Get-BuildKind -DumpsysText $case.Text -Package $case.Package
        if ($got.Kind -eq $case.Want) {
            Write-Host ("PASS  " + $case.Name + " -> " + $got.Kind + " (" + $got.Detail + ")")
        } else {
            $failed++
            Write-Host ("FAIL  " + $case.Name + " -> want " + $case.Want + ", got " + $got.Kind + " (" + $got.Detail + ")")
        }
    }
    $total = $cases.Count
    Write-Host ("classify-build self-test: " + ($total - $failed) + "/" + $total + " fixtures passed")
    if ($failed -gt 0) {
        Write-Host ("SELFTEST FAILED: " + $failed + " of " + $total + " fixtures")
        exit 1
    }
    exit 0
}

# Dot-sourced by the hardware scripts; executed directly it must be asked for the self-test.
if ($MyInvocation.InvocationName -ne ".") {
    if ($SelfTest) { Invoke-ClassifyBuildSelfTest }
    Write-Host "classify-build.ps1 is a library (Get-BuildKind). Run it with -SelfTest, or dot-source it."
    exit 2
}
