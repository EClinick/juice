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
    Builds against the installed Windows App SDK runtime instead of carrying it.

    This is the right choice for Store submission. The Windows App SDK ships as a
    framework package that the Store resolves and installs automatically, so depending on
    it costs the user nothing and removes a large payload, including the ONNX and DirectML
    components that a self-contained Windows App SDK drags in whether or not the
    application does any machine learning. Juice does none.

    The .NET runtime is carried regardless. It is not a framework package, the Store will
    not install it, and a framework-dependent .NET build would fail to start on a machine
    without the matching desktop runtime. Use -DotNetFrameworkDependent only for
    sideloading onto machines you control.

.PARAMETER DotNetFrameworkDependent
    Also build against an installed .NET runtime. Produces the smallest package, but the
    target machine must already have the matching .NET desktop runtime. Not suitable for
    Store submission.

.PARAMETER NoBump
    Repackage without incrementing the version.

    By default the build segment is bumped on every pack. The Store rejects a submission
    whose version is not strictly greater than the last one accepted, and remembering to
    edit Directory.Build.props by hand is exactly the step that gets forgotten on the
    second submission. The revision segment is never touched and always stays 0, because
    the Store reserves it.

.EXAMPLE
    .\pack.ps1 -FrameworkDependent
    Store profile. Bumps the build segment, takes the Windows App SDK from its framework
    package, carries .NET.

.EXAMPLE
    .\pack.ps1 -CertPath .\prod.pfx -Timestamp http://timestamp.digicert.com
    Fully self-contained production bundle for sideloading.

.EXAMPLE
    .\pack.ps1 -NoBump
    Rebuild the current version, for iterating locally without burning version numbers.
#>
[CmdletBinding()]
param(
    [string] $Configuration = 'Release',
    [string] $CertPath,
    [string] $CertPassword = 'password',
    [string] $Timestamp,
    [switch] $FrameworkDependent,
    [switch] $DotNetFrameworkDependent,
    [switch] $NoBump,
    [string[]] $Architectures
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$buildRoot = $PSScriptRoot
$windowsRoot = Split-Path -Parent $buildRoot
$appProject = Join-Path $windowsRoot 'src\Juice.App\Juice.App.csproj'
$cliProject = Join-Path $windowsRoot 'src\Juice.Cli\Juice.Cli.csproj'
$manifestSource = Join-Path $windowsRoot 'src\Juice.App\Package.appxmanifest'
$TargetFramework = 'net10.0-windows10.0.26100.0'
$artifacts = Join-Path $windowsRoot 'artifacts'
$packagesDir = Join-Path $artifacts 'packages'

function Get-JuiceVersion {
    # Single source of truth: Directory.Build.props. The revision stays 0 because the
    # Microsoft Store reserves that field and rewrites it on submission.
    #
    # XPath rather than property access: under Set-StrictMode, reaching for a property
    # that a given PropertyGroup does not carry is an error rather than a null, and the
    # file has several groups.
    $props = [xml](Get-Content (Join-Path $windowsRoot 'Directory.Build.props'))

    $major = $props.SelectSingleNode('//JuiceMajor')
    $minor = $props.SelectSingleNode('//JuiceMinor')
    $build = $props.SelectSingleNode('//JuiceBuild')

    if (-not $major -or -not $minor -or -not $build) {
        throw "Could not read JuiceMajor/JuiceMinor/JuiceBuild from Directory.Build.props."
    }

    "{0}.{1}.{2}.0" -f $major.InnerText, $minor.InnerText, $build.InnerText
}

function Add-ToPackageRecipe {
    <#
    .SYNOPSIS
        Adds files to the packaging recipe so they end up in the package.

    .DESCRIPTION
        Packaging reads the .appxrecipe the build emitted, not the contents of the output
        folder, so a file copied in afterwards is silently dropped. That failure is quiet
        and only shows up as a missing binary at runtime, which for the command line means
        an execution alias pointing at nothing.
    #>
    param(
        [Parameter(Mandatory)][string] $Layout,
        [Parameter(Mandatory)][string[]] $Names
    )

    foreach ($recipe in Get-ChildItem $Layout -Filter '*.appxrecipe' -File -ErrorAction SilentlyContinue) {
        $xml = [xml](Get-Content $recipe.FullName)

        $group = $xml.SelectSingleNode('//*[local-name()="ItemGroup"][*[local-name()="AppxPackagedFile"]]')
        if (-not $group) { continue }

        $ns = $xml.DocumentElement.NamespaceURI
        $added = 0

        foreach ($name in $Names) {
            $path = Join-Path $Layout $name
            if (-not (Test-Path $path)) { continue }

            $already = $group.ChildNodes | Where-Object { $_.Include -eq $path }
            if ($already) { continue }

            $node = $xml.CreateElement('AppxPackagedFile', $ns)
            $node.SetAttribute('Include', $path)

            $target = $xml.CreateElement('PackagePath', $ns)
            $target.InnerText = $name
            [void]$node.AppendChild($target)

            [void]$group.AppendChild($node)
            $added++
        }

        if ($added -gt 0) {
            $xml.Save($recipe.FullName)
            Write-Host ("  added {0} command line files to the recipe" -f $added) -ForegroundColor DarkGray
        }
    }
}

function Remove-UnusedRuntimes {
    <#
    .SYNOPSIS
        Removes payload the application never loads from the packaging recipe.

    .DESCRIPTION
        The Windows App SDK meta-package pulls in its machine learning components, which
        carry onnxruntime and DirectML and add roughly 38 MB per architecture. Juice
        performs no inference of any kind.

        Also removes the event log message resources, which arrive transitively through
        System.Diagnostics.PerformanceCounter and exist only to format event log entries.
        Juice reads performance counters but never writes to the event log.

        These files are not in the build output. The build emits a .appxrecipe listing
        every file to package, and that recipe references them by absolute path inside the
        NuGet cache, so deleting them from the output folder achieves nothing: packaging
        reads the recipe, not the folder. Pruning the recipe entries is what actually keeps
        them out.

        Excluding the packages through NuGet is not an option either, because the machine
        learning targets fail the build outright when their assets are excluded.

        This is safe only because nothing in this application references those APIs. If a
        feature ever needs on-device inference, or starts writing to the event log, delete
        the relevant pattern rather than working around it.
    #>
    param([Parameter(Mandatory)][string] $Layout)

    $pattern = 'onnxruntime|DirectML|Microsoft\.ML\.OnnxRuntime|Microsoft\.Windows\.AI\.MachineLearning|System\.Diagnostics\.EventLog\.Messages'
    $freed = 0

    # Prune the recipe first, since it is what packaging actually reads.
    foreach ($recipe in Get-ChildItem $Layout -Filter '*.appxrecipe' -File -ErrorAction SilentlyContinue) {
        $xml = [xml](Get-Content $recipe.FullName)
        $removed = 0

        foreach ($node in @($xml.SelectNodes('//*[@Include]'))) {
            if ($node.Include -notmatch $pattern) { continue }

            if (Test-Path $node.Include) { $freed += (Get-Item $node.Include).Length }
            [void]$node.ParentNode.RemoveChild($node)
            $removed++
        }

        if ($removed -gt 0) { $xml.Save($recipe.FullName) }
    }

    # Then the folder, for anything a previous build left behind.
    foreach ($file in Get-ChildItem $Layout -File -ErrorAction SilentlyContinue) {
        if ($file.Name -notmatch $pattern) { continue }
        Remove-Item $file.FullName -Force
    }

    if ($freed -gt 0) {
        Write-Host ("  pruned unused runtimes: {0:N1} MB" -f ($freed / 1MB)) -ForegroundColor DarkGray
    }
}

function Step-JuiceBuildNumber {
    <#
    .SYNOPSIS
        Increments the build segment in Directory.Build.props.

    .DESCRIPTION
        The Store rejects a submission whose version is not strictly greater than the last
        one accepted, so every packed build gets a new number by default rather than
        relying on someone remembering to edit the file.

        Only the build segment moves. The revision stays 0 because the Store reserves that
        field and rewrites it when it repackages a submission, so shipping a non-zero
        revision makes the submitted and published versions disagree.
    #>
    $propsPath = Join-Path $windowsRoot 'Directory.Build.props'
    $text = [System.IO.File]::ReadAllText($propsPath)

    $pattern = '(<JuiceBuild>)(\d+)(</JuiceBuild>)'
    $match = [regex]::Match($text, $pattern)
    if (-not $match.Success) { throw "Could not find JuiceBuild in $propsPath." }

    $next = [int]$match.Groups[2].Value + 1
    $updated = [regex]::Replace($text, $pattern, "`${1}$next`${3}", 1)

    [System.IO.File]::WriteAllText($propsPath, $updated)
    Write-Host ("Version bumped: build {0} -> {1}" -f $match.Groups[2].Value, $next) -ForegroundColor DarkGray
}

function Assert-Tool {
    if (-not (Get-Command winapp -ErrorAction SilentlyContinue)) {
        throw "winapp is not on PATH. Install the Windows App CLI, then re-run."
    }
}

Assert-Tool

# Build the host architecture first so a compilation failure surfaces on the slice that
# can actually be run and debugged here. Cross-compiled slices still ship, they are just
# not what you verify against: an x64 build executed on an ARM64 machine runs under
# emulation, and since Juice attributes energy by share of processor time, an emulated
# build measures the emulator rather than the app.
if (-not $Architectures) {
    $Architectures = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { @('arm64', 'x64') } else { @('x64', 'arm64') }
}

if (-not $NoBump) { Step-JuiceBuildNumber }

$version = Get-JuiceVersion
Write-Host "Juice $version" -ForegroundColor Cyan
Write-Host ("Architectures: {0} (host {1} first)" -f ($Architectures -join ', '), $env:PROCESSOR_ARCHITECTURE)

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

# Two independent decisions, deliberately kept apart.
#
# The Windows App SDK is a framework package the Store resolves and installs, so depending
# on it costs the user nothing and removes a large payload, including the ONNX and DirectML
# components a self-contained Windows App SDK carries whether or not the application does
# any machine learning. Juice does none.
#
# The .NET runtime is not a framework package. The Store will not install it, so it is
# carried unless the caller explicitly opts out for sideloading onto machines they control.
$sdkSelfContained = -not $FrameworkDependent
$dotnetSelfContained = -not $DotNetFrameworkDependent

$sdkFlag = if ($sdkSelfContained) { 'true' } else { 'false' }
$dotnetFlag = if ($dotnetSelfContained) { 'true' } else { 'false' }

Write-Host ("Windows App SDK: {0}" -f $(if ($sdkSelfContained) { 'carried' } else { 'framework package' }))
Write-Host (".NET runtime   : {0}" -f $(if ($dotnetSelfContained) { 'carried' } else { 'framework dependent' }))

foreach ($arch in $Architectures) {
    Write-Host "`nBuilding $arch" -ForegroundColor Cyan

    $rid = "win-$arch"

    # Build rather than publish, and package the build output directly.
    #
    # This is what the Windows packaging guidance prescribes, and the reason is the
    # manifest. The build emits an AppxManifest.xml with everything the source manifest
    # cannot know injected into it, above all the PackageDependency on the Windows App SDK
    # framework package at the exact version this build resolved. Publishing to a separate
    # folder and supplying a hand-written manifest loses that, and the result installs
    # cleanly and then dies at startup with REGDB_E_CLASSNOTREG.
    dotnet build $appProject `
        -c $Configuration `
        -r $rid `
        --self-contained $dotnetFlag `
        -p:Platform=$arch `
        -p:WindowsAppSDKSelfContained=$sdkFlag
    if ($LASTEXITCODE -ne 0) { throw "build failed for $arch" }

    $layout = Join-Path (Split-Path -Parent $appProject) "bin\$arch\$Configuration\$TargetFramework\$rid"
    if (-not (Test-Path (Join-Path $layout 'AppxManifest.xml'))) {
        throw "No AppxManifest.xml in $layout. Packaging that would produce a package that cannot start."
    }

    # The manifest declares an AppExecutionAlias for juice.exe, so the CLI has to be inside
    # the package or the alias resolves to nothing.
    #
    # Only the command line's own files are copied in. Publishing it into the application
    # folder would drop a second complete copy of the .NET runtime on top of the first,
    # since both are self-contained, which inflates the package for no benefit. Everything
    # the CLI shares with the application, the runtime and the Juice libraries, is already
    # present.
    $cliStage = Join-Path $artifacts "cli\$arch"
    Remove-Item $cliStage -Recurse -Force -ErrorAction SilentlyContinue

    dotnet publish $cliProject `
        -c $Configuration `
        -r $rid `
        --self-contained $dotnetFlag `
        -o $cliStage
    if ($LASTEXITCODE -ne 0) { throw "CLI publish failed for $arch" }

    foreach ($name in 'juice.exe', 'juice.dll', 'juice.deps.json', 'juice.runtimeconfig.json') {
        $src = Join-Path $cliStage $name
        if (-not (Test-Path $src)) { throw "CLI artifact missing: $src" }
        Copy-Item $src -Destination $layout -Force
    }

    # Copying the files into the folder is not enough. Packaging reads the .appxrecipe,
    # which lists every file to include, so anything added to the folder afterwards is
    # silently dropped. The command line has to be added to the recipe as well or the
    # AppExecutionAlias points at a binary that is not in the package.
    Add-ToPackageRecipe -Layout $layout -Names 'juice.exe', 'juice.dll', 'juice.deps.json', 'juice.runtimeconfig.json'

    Remove-UnusedRuntimes -Layout $layout

    # Stamp the manifest per architecture. MSIX requires ProcessorArchitecture to match
    # the payload, and every package in a bundle must share one version.
    #
    # This edits the manifest the build generated, never the source one. The build injects
    # the PackageDependency on the Windows App SDK framework package at the exact version
    # it resolved, and losing that produces a package that installs cleanly and then dies
    # at startup with REGDB_E_CLASSNOTREG.
    $generated = Join-Path $layout 'AppxManifest.xml'
    $manifest = [xml](Get-Content $generated)
    $manifest.Package.Identity.Version = $version
    $manifest.Package.Identity.SetAttribute('ProcessorArchitecture', $arch)

    # Resolve the build-time placeholders. They cannot survive into the packaged manifest
    # because the layout contains two executables, the tray application and the command
    # line, so nothing downstream can infer which one the Application element means.
    $app = $manifest.Package.Applications.Application
    if ($app.Executable -like '*$targetnametoken$*') { $app.Executable = 'Juice.App.exe' }
    if ($app.EntryPoint -like '*$targetentrypoint$*') { $app.EntryPoint = 'Windows.FullTrustApplication' }

    $stamped = Join-Path $layout 'Package.appxmanifest'
    $manifest.Save($stamped)

    Write-Host "Packaging $arch" -ForegroundColor Cyan
    $msix = Join-Path $packagesDir "Juice_${version}_${arch}.msix"

    $packArgs = @(
        'package', $layout,
        '--manifest', $stamped,
        '--output', $msix,
        '--executable', 'Juice.App.exe',
        '--cert', $CertPath,
        '--cert-password', $CertPassword,
        '--quiet'
    )
    if ($sdkSelfContained) { $packArgs += '--self-contained' }

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
