<#
.SYNOPSIS
Publishes OSRA.Service + OSRA for a target Windows architecture and builds an unsigned per-machine WiX v5 MSI.
#>
[CmdletBinding()]
param(
    [ValidateSet('win-x64', 'win-arm64')]
    [string]$RuntimeIdentifier = 'win-x64',

    [string]$Configuration = 'Release',

    [string]$OsraApiBase = '',

    [string]$Version = '',

    [string]$PublishDir = '',

    [string]$OutputDir = '',

    [string]$WixPath = 'wix',

    [string]$DotnetPath = 'dotnet',

    [switch]$SkipPublish
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$agentDesktopRoot = Split-Path -Parent $PSScriptRoot
$installerDir = $PSScriptRoot
$sharedProject = Join-Path $agentDesktopRoot 'FamilyShield.Agent.csproj'
$serviceProject = Join-Path $agentDesktopRoot 'src/OSRA.Service/OSRA.Service.csproj'
$trayProject = Join-Path $agentDesktopRoot 'src/OSRA/OSRA.csproj'
$wxsPath = Join-Path $installerDir 'OSRA.wxs'

if ([string]::IsNullOrWhiteSpace($Version)) {
    [xml]$csproj = Get-Content -Path $sharedProject -Raw
    $Version = ($csproj.Project.PropertyGroup | ForEach-Object { $_.AssemblyVersion } | Where-Object { $_ } | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($Version)) {
        throw "Could not read AssemblyVersion from $sharedProject"
    }
}

$arch = if ($RuntimeIdentifier -eq 'win-arm64') { 'arm64' } else { 'x64' }
$artifactsRoot = Join-Path $agentDesktopRoot 'artifacts'
if ([string]::IsNullOrWhiteSpace($PublishDir)) {
    $PublishDir = Join-Path $artifactsRoot "publish-$RuntimeIdentifier"
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $artifactsRoot 'msi'
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

if (-not $SkipPublish) {
    if (Test-Path $PublishDir) {
        Remove-Item -Recurse -Force $PublishDir
    }
    New-Item -ItemType Directory -Force -Path $PublishDir | Out-Null

    $commonArgs = @('-c', $Configuration, '-r', $RuntimeIdentifier, '--self-contained', 'true', '-o', $PublishDir, '--nologo')
    if (-not [string]::IsNullOrWhiteSpace($OsraApiBase)) {
        $commonArgs += "-p:OsraApiBase=$OsraApiBase"
    }

    & $DotnetPath publish $serviceProject @commonArgs
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed for OSRA.Service ($LASTEXITCODE)"
    }

    & $DotnetPath publish $trayProject @commonArgs
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed for OSRA ($LASTEXITCODE)"
    }
}

foreach ($required in @('OSRA.Service.exe', 'OSRA.exe', 'OSRA.Agent.dll')) {
    $candidate = Join-Path $PublishDir $required
    if (-not (Test-Path -Path $candidate -PathType Leaf)) {
        throw "Missing required publish payload: $candidate"
    }
}

$msiName = "OSRA-$Version-$RuntimeIdentifier-unsigned.msi"
$msiPath = Join-Path $OutputDir $msiName

$extensions = & $WixPath extension list 2>$null
if (-not ($extensions -match 'WixToolset\.Util\.wixext')) {
    & $WixPath extension add WixToolset.Util.wixext/5.0.2
    if ($LASTEXITCODE -ne 0) {
        throw "wix extension add WixToolset.Util.wixext/5.0.2 failed ($LASTEXITCODE)"
    }
}

& $WixPath build $wxsPath `
    -ext WixToolset.Util.wixext `
    -arch $arch `
    -d "PublishDir=$PublishDir" `
    -d "ProductVersion=$Version" `
    -o $msiPath

if ($LASTEXITCODE -ne 0 -or -not (Test-Path -Path $msiPath -PathType Leaf)) {
    throw "wix build failed for $msiPath ($LASTEXITCODE)"
}

Write-Output $msiPath
