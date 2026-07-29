<#
.SYNOPSIS
    Builds Juice and produces a signed x64 + ARM64 .msixbundle.

.DESCRIPTION
    Packaging goes through the winapp CLI end to end.

    winapp produces one .msix per architecture, so this script publishes and packages
    x64 and ARM64 separately and then combines them with makeappx, which winapp exposes
    through its SDK tool passthrough. ARM64 matters more than usual for Juice: Snapdragon
    X Copilot+ PCs are among the machines most likely to carry the ACPI Energy Meter
    device that the hardware rail power source depends on.

.PARAMETER Configuration
    Build configuration. Defaults to Release.

.PARAMETER CertPath
    Signing certificate. When omitted a development certificate is generated.

.PARAMETER Timestamp
    RFC 3161 timestamp URL. Without one, signatures expire when the certificate does,
    so production builds should always pass this.

.PARAMETER FrameworkDependent
    Produces a smaller package that requires the .NET and Windows App SDK runtimes to
    already be present. The default is self-contained, because Juice is a utility people
    sideload or install from the Store and it should never fail to start because of a
    missing runtime.

.EXAMPLE
    .\pack.ps1
    Self-contained development bundle signed with a generated certificate.

.EXAMPLE
    .\pack.ps1 -CertPath .\prod.pfx -Timestamp http://timestamp.digicert.com
    Production bundle.
#>
[CmdletBinding()]
param(
    [string] $Configuration = 'Release',
    [string] $CertPath,
    [string] $CertPassword = 'password',
    [string] $Timestamp,
    [switch] $FrameworkDependent,
    [string[]] $Architectures = @('x64', 'arm64')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$buildRoot = $PSScriptRoot
$windowsRoot = Split-Path -Parent $buildRoot
$appProject = Join-Path $windowsRoot 'src\Juice.App\Juice.App.csproj'
$manifestSource = Join-Path $windowsRoot 'src\Juice.App\Package.appxmanifest'
$artifacts = Join-Path $windowsRoot 'artifacts'
$packagesDir = Join-Path $artifacts 'packages'

function Get-JuiceVersion {
    # Single source of truth: Directory.Build.props. The revision stays 0 because the
    # Microsoft Store reserves that field and rewrites it on submission.
    $props = [xml](Get-Content (Join-Path $windowsRoot 'Directory.Build.props'))
    $group = $props.Project.PropertyGroup | Where-Object { $null -ne $_.JuiceMajor }
    "{0}.{1}.{2}.0" -f $group.JuiceMajor, $group.JuiceMinor, $group.JuiceBuild
}

function Assert-Tool {
    if (-not (Get-Command winapp -ErrorAction SilentlyContinue)) {
        throw "winapp is not on PATH. Install the Windows App CLI, then re-run."
    }
}

Assert-Tool

$version = Get-JuiceVersion
Write-Host "Juice $version" -ForegroundColor Cyan

if (Test-Path $artifacts) { Remove-Item $artifacts -Recurse -Force }
New-Item -ItemType Directory -Force -Path $packagesDir | Out-Null

# A development certificate is generated once and reused across both architectures so
# that every package in the bundle carries the same publisher.
if (-not $CertPath) {
    $CertPath = Join-Path $artifacts 'devcert.pfx'
    Write-Host "Generating development certificate" -ForegroundColor Yellow
    winapp cert generate --manifest $manifestSource --output $CertPath --password $CertPassword --if-exists overwrite --quiet
    if ($LASTEXITCODE -ne 0) { throw "certificate generation failed" }
}

# Self-contained is the default. Two separate runtimes have to be carried: the .NET
# runtime via dotnet publish, and the Windows App SDK via WindowsAppSDKSelfContained
# and winapp's --self-contained. Setting only one of them still leaves the app unable
# to start on a clean machine.
$selfContained = -not $FrameworkDependent
Write-Host ("Deployment: {0}" -f ($selfContained ? 'self-contained' : 'framework-dependent'))

foreach ($arch in $Architectures) {
    Write-Host "`nPublishing $arch" -ForegroundColor Cyan

    $rid = "win-$arch"
    $layout = Join-Path $artifacts "layout\$arch"

    dotnet publish $appProject `
        -c $Configuration `
        -r $rid `
        --self-contained $selfContained.ToString().ToLowerInvariant() `
        -p:Platform=$arch `
        -p:WindowsAppSDKSelfContained=$($selfContained.ToString().ToLowerInvariant()) `
        -p:PublishReadyToRun=true `
        -o $layout
    if ($LASTEXITCODE -ne 0) { throw "publish failed for $arch" }

    # Stamp the manifest per architecture. MSIX requires ProcessorArchitecture to match
    # the payload, and every package in a bundle must share one version.
    $manifest = [xml](Get-Content $manifestSource)
    $manifest.Package.Identity.Version = $version
    $manifest.Package.Identity.SetAttribute('ProcessorArchitecture', $arch)
    $stamped = Join-Path $layout 'Package.appxmanifest'
    $manifest.Save($stamped)

    Write-Host "Packaging $arch" -ForegroundColor Cyan
    $msix = Join-Path $packagesDir "Juice_${version}_${arch}.msix"

    $packArgs = @(
        'package', $layout,
        '--manifest', $stamped,
        '--output', $msix,
        '--cert', $CertPath,
        '--cert-password', $CertPassword,
        '--quiet'
    )
    if ($selfContained) { $packArgs += '--self-contained' }

    winapp @packArgs
    if ($LASTEXITCODE -ne 0) { throw "winapp package failed for $arch" }
}

Write-Host "`nBundling" -ForegroundColor Cyan
$bundle = Join-Path $artifacts "Juice_$version.msixbundle"

# winapp has no bundle command, so use its SDK tool passthrough. makeappx requires the
# input directory to contain nothing but the packages going into the bundle.
winapp tool makeappx -- bundle /d $packagesDir /p $bundle /bv $version /o
if ($LASTEXITCODE -ne 0) { throw "makeappx bundle failed" }

Write-Host "Signing bundle" -ForegroundColor Cyan
$signArgs = @('sign', $bundle, $CertPath, '--password', $CertPassword)
if ($Timestamp) { $signArgs += @('--timestamp', $Timestamp) }
else { Write-Warning "No -Timestamp given. The signature will expire with the certificate." }

winapp @signArgs
if ($LASTEXITCODE -ne 0) { throw "signing failed" }

Write-Host "`nBundle: $bundle" -ForegroundColor Green
Get-ChildItem $packagesDir | ForEach-Object { Write-Host "  $($_.Name)" }
