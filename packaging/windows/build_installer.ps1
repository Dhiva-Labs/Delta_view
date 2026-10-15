<#
.SYNOPSIS
  Builds the Inno Setup installer from the Windows release build
  (flutter build windows --release) into
  dist\DeltaView-<version>-windows-<arch>-setup.exe.

.DESCRIPTION
  The architecture comes from the machine this runs on (x64 or arm64), because
  Flutter builds for the host; pass -Arch to override it. The version comes from
  pubspec.yaml. Needs Inno Setup 6.3 or newer (ISCC.exe).
#>
param(
    [ValidateSet('x64', 'arm64')]
    [string]$Arch
)
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..\..')

if (-not $Arch) {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { $Arch = 'x64' }
        'ARM64' { $Arch = 'arm64' }
        default { throw "unsupported PROCESSOR_ARCHITECTURE '$env:PROCESSOR_ARCHITECTURE' (AMD64 or ARM64)" }
    }
}

if (-not (Test-Path "build\windows\$Arch\runner\Release\delta_view.exe")) {
    throw "build\windows\$Arch\runner\Release\delta_view.exe not found; run 'flutter build windows --release' first"
}

$versionLine = Select-String -Path pubspec.yaml -Pattern '^version:\s*(\S+)' | Select-Object -First 1
$version = ($versionLine.Matches[0].Groups[1].Value -split '\+')[0]

$iscc = @(
    (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source,
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 (ISCC.exe) not found' }

& $iscc "/DArch=$Arch" "/DAppVersion=$version" packaging\windows\DeltaView.iss
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }
Write-Host "Built: dist\DeltaView-$version-windows-$Arch-setup.exe"
