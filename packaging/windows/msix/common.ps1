# Helpers shared by build-msix.ps1, bundle-msix.ps1 and the CI workflow.
# Dot-source it:  . .\packaging\windows\msix\common.ps1
# Works in Windows PowerShell 5.1 and PowerShell 7.

# The repository root.
$DeltaViewRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path

# DeltaView's version from pubspec.yaml without the build number: '1.1.0' for
# 'version: 1.1.0+3'. Packages use it with a fourth field of 0 ('1.1.0.0'),
# because the Store keeps the fourth field for itself.
function Get-AppVersion {
    $line = Select-String -Path (Join-Path $DeltaViewRoot 'pubspec.yaml') -Pattern '^version:\s*(\S+)' |
        Select-Object -First 1
    if (-not $line) { throw 'pubspec.yaml has no version: line' }
    $version = ($line.Matches[0].Groups[1].Value -split '\+')[0]
    if ($version -notmatch '^\d+\.\d+\.\d+$') {
        throw "pubspec.yaml version '$version' is not MAJOR.MINOR.PATCH"
    }
    foreach ($field in $version.Split('.')) {
        if ([long]$field -gt 65535) { throw "pubspec.yaml version '$version' has a field over 65535" }
    }
    return $version
}

# The COFF machine type of a PE file: 0x8664 for x64, 0xAA64 for arm64.
function Get-PeMachine([string]$Path) {
    $fs = [IO.File]::OpenRead($Path)
    try {
        $br = New-Object IO.BinaryReader($fs)
        $fs.Position = 0x3C
        $fs.Position = $br.ReadInt32()
        if ($br.ReadUInt32() -ne 0x4550) { throw "$Path is not a PE file" }
        return $br.ReadUInt16()
    } finally { $fs.Dispose() }
}

$PeMachines = @{ x64 = 0x8664; arm64 = 0xAA64 }

# A tool of the newest Windows 10/11 SDK (makeappx.exe, makepri.exe, signtool.exe):
# the build for this machine's architecture, else the x64 one, which Windows on
# ARM runs emulated.
function Find-SdkTool([string]$Name) {
    $hostDirs = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64', 'x64' } else { 'x64' }
    $bin = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    $tool = Get-ChildItem $bin -Directory -ErrorAction SilentlyContinue |
        Where-Object Name -match '^10\.\d+\.\d+\.\d+$' |
        Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object { $sdk = $_.FullName; $hostDirs | ForEach-Object { Join-Path $sdk "$_\$Name" } } |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1
    if (-not $tool) { throw "$Name not found under $bin (install the Windows SDK)" }
    return $tool
}

# Runs a program and fails when it exits with an error. Windows PowerShell 5.1
# turns a program's stderr output into error records, which would stop a script
# running with $ErrorActionPreference = 'Stop', so only the exit code decides.
function Invoke-Tool([string]$What, [scriptblock]$Command) {
    $ErrorActionPreference = 'Continue'
    & $Command 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE) { throw "$What failed with exit code $LASTEXITCODE" }
}

# An XML file inside an .msix or .msixbundle (both are zip files): by default
# the package's AppxManifest.xml.
function Read-PackageXml([string]$Package, [string]$Entry = 'AppxManifest.xml') {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Package)
    try {
        $file = $zip.GetEntry($Entry)
        if (-not $file) { throw "$Package has no $Entry" }
        $reader = New-Object IO.StreamReader($file.Open())
        # The comma returns the document itself, never its child nodes one by one.
        try { return , ([xml]$reader.ReadToEnd()) } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
}
