<#
.SYNOPSIS
  Combines the x64 and arm64 Store packages made by build-msix.ps1 into one
  .msixbundle, the file to upload to Partner Center.

.DESCRIPTION
  The packages must be of the same version and identity, one per architecture.
  The bundle is not signed: the Store signs it. Needs the Windows SDK (makeappx).
  The output is dist\DeltaView-<version>.msixbundle.

.EXAMPLE
  .\packaging\windows\msix\bundle-msix.ps1 -Packages dist\DeltaView-1.1.0-x64.msix, dist\DeltaView-1.1.0-arm64.msix
#>
param(
    [Parameter(Mandatory)]
    [string[]]$Packages,
    [string]$Out
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$version = Get-AppVersion
if (-not $Out) { $Out = Join-Path $DeltaViewRoot "dist\DeltaView-$version.msixbundle" }
$Out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Out)

# Each package's identity, checked against the others before makeappx sees them.
$identities = @(foreach ($package in $Packages) {
    $path = (Resolve-Path $package).Path
    $id = (Read-PackageXml $path).Package.Identity
    Write-Host ('{0}: {1} {2} {3} {4}' -f (Split-Path -Leaf $path), $id.Name, $id.Version, $id.ProcessorArchitecture, $id.Publisher)
    [pscustomobject]@{ Path = $path; Name = $id.Name; Publisher = $id.Publisher; Version = $id.Version; Arch = $id.ProcessorArchitecture }
})
foreach ($property in 'Name', 'Publisher', 'Version') {
    $distinct = @($identities | Select-Object -ExpandProperty $property -Unique)
    if ($distinct.Count -ne 1) { throw "the packages differ in $property ($($distinct -join ', '))" }
}
if ($identities[0].Version -ne "$version.0") {
    throw "the packages are version $($identities[0].Version), pubspec.yaml says $version"
}
$archs = @($identities.Arch | Sort-Object)
if (@($archs | Select-Object -Unique).Count -ne $archs.Count) { throw "two packages for the same architecture: $($archs -join ', ')" }

$makeappx = Find-SdkTool 'makeappx.exe'
$stage = Join-Path ([IO.Path]::GetTempPath()) "deltaview-bundle-$PID"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory $stage | Out-Null
try {
    foreach ($id in $identities) { Copy-Item $id.Path $stage }
    New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
    Invoke-Tool 'makeappx bundle' { & $makeappx bundle /d $stage /p $Out /bv "$version.0" /o }
} finally {
    Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
}

# What the bundle says it holds.
$bundle = (Read-PackageXml $Out 'AppxMetadata/AppxBundleManifest.xml').Bundle
$apps = @($bundle.Packages.Package | Where-Object { $_.Type -eq 'application' })
$apps | ForEach-Object { '  {0,-6} {1} {2}' -f $_.Architecture, $_.Version, $_.FileName }
$inBundle = @($apps | ForEach-Object { $_.Architecture } | Sort-Object)
if (($inBundle -join ',') -ne ($archs -join ',')) { throw "the bundle holds $($inBundle -join ', '), not $($archs -join ', ')" }
"Bundle: $Out ($($bundle.Identity.Name) $($bundle.Identity.Version))"
