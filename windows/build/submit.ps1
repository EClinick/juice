<#
.SYNOPSIS
    Submits a packaged bundle to the Microsoft Store.

.DESCRIPTION
    Wraps the Microsoft Store Developer CLI, which winapp downloads on first use, so that
    a submission is one command rather than a sequence of portal clicks.

    Credentials are read from environment variables and are never written to this
    repository. They identify a Partner Center account and can publish software under it,
    so they belong in a secret store, in CI secrets, or in a shell session, and nowhere
    else.

        JUICE_STORE_TENANT_ID       Azure AD tenant containing the app registration
        JUICE_STORE_SELLER_ID       Partner Center seller id
        JUICE_STORE_CLIENT_ID       Azure AD application (client) id
        JUICE_STORE_CLIENT_SECRET   Client secret for that application

    One-time setup in Partner Center, under Account settings then User management then
    Azure AD applications: associate or create an Azure AD application, grant it access,
    and note the tenant, client and seller ids. Create a client secret for it.

.PARAMETER Bundle
    Path to the .msixbundle. Defaults to the newest one in windows/artifacts.

.PARAMETER WhatIf
    Validate credentials and the bundle without submitting anything.

.EXAMPLE
    .\submit.ps1 -WhatIf
    Check that everything is in place without touching the Store.

.EXAMPLE
    .\submit.ps1
    Submit the newest bundle.

.NOTES
    The Store rejects a submission whose version is not strictly greater than the last one
    accepted. pack.ps1 bumps the build segment on every pack, so submit whatever it just
    produced rather than repackaging an older version.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Bundle
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$buildRoot = $PSScriptRoot
$windowsRoot = Split-Path -Parent $buildRoot
$artifacts = Join-Path $windowsRoot 'artifacts'

function Get-RequiredSecret {
    param([Parameter(Mandatory)][string] $Name)

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "$Name is not set. See the notes at the top of this script for what it is and where to get it."
    }

    $value
}

if (-not (Get-Command winapp -ErrorAction SilentlyContinue)) {
    throw "winapp is not on PATH. Install the Windows App CLI, then re-run."
}

if (-not $Bundle) {
    $candidate = Get-ChildItem $artifacts -Filter '*.msixbundle' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $candidate) {
        throw "No .msixbundle found in $artifacts. Run pack.ps1 -FrameworkDependent first."
    }

    $Bundle = $candidate.FullName
}

if (-not (Test-Path $Bundle)) { throw "Bundle not found: $Bundle" }

Write-Host "Bundle: $Bundle" -ForegroundColor Cyan
Write-Host ("Size:   {0:N1} MB" -f ((Get-Item $Bundle).Length / 1MB))

$tenantId = Get-RequiredSecret 'JUICE_STORE_TENANT_ID'
$sellerId = Get-RequiredSecret 'JUICE_STORE_SELLER_ID'
$clientId = Get-RequiredSecret 'JUICE_STORE_CLIENT_ID'
$clientSecret = Get-RequiredSecret 'JUICE_STORE_CLIENT_SECRET'

Write-Host "Credentials: present for tenant $tenantId, seller $sellerId" -ForegroundColor DarkGray

if (-not $PSCmdlet.ShouldProcess($Bundle, 'Submit to the Microsoft Store')) {
    Write-Host "`nValidation only. Nothing was submitted." -ForegroundColor Yellow
    return
}

Write-Host "`nConfiguring the Store CLI" -ForegroundColor Cyan

# The secret is passed as an argument rather than piped because the CLI has no stdin
# mode for it. Anything invoking this should avoid transcript logging for that reason.
winapp store -- reconfigure `
    --tenantId $tenantId `
    --sellerId $sellerId `
    --clientId $clientId `
    --clientSecret $clientSecret
if ($LASTEXITCODE -ne 0) { throw "Store CLI configuration failed." }

Write-Host "`nSubmitting" -ForegroundColor Cyan

winapp store -- publish $Bundle
if ($LASTEXITCODE -ne 0) { throw "Submission failed." }

Write-Host "`nSubmitted. Review and complete it in Partner Center." -ForegroundColor Green
