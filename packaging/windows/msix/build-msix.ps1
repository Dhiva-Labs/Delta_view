<#
.SYNOPSIS
  Packs the Microsoft Store package (.msix) of DeltaView from a Windows release
  build (flutter build windows --release).

.DESCRIPTION
  The package is not signed: the Store signs it. The identity defaults to
  DeltaView's Partner Center reservation; if Partner Center shows other values
  (Product management > Product identity), change the defaults below. CI passes
  a test identity to install a test-signed copy.

  The Visual C++ runtime DLLs (vcruntime140.dll, msvcp140.dll, ...) go into the
  package next to delta_view.exe, taken from the Visual Studio that compiled it,
  so the package runs on a PC that has no Visual C++ Redistributable.

  Needs the Windows SDK (makeappx, makepri) and Visual Studio with the C++ tools
  of the architecture. The output is dist\DeltaView-<version>-<arch>.msix.

.PARAMETER Arch
  x64 or arm64: the build to package (build\windows\<Arch>\runner\Release).
  Defaults to this machine's, because Flutter builds for the machine it runs on.
  The package is refused when delta_view.exe is built for another architecture.

.PARAMETER CrtDir
  A folder holding the Visual C++ runtime DLLs to put in the package, instead of
  the one found next to the Visual Studio that built the app.
#>
param(
    [ValidatePattern('^[A-Za-z0-9.-]{3,50}$')]
    [string]$Name = 'Dhiva-Labs.DeltaView',
    [ValidatePattern('^CN=')]
    [string]$Publisher = 'CN=0F69015A-AA5B-431D-970A-165099309E53',
    [string]$PublisherDisplayName = 'Dhiva-Labs',
    [ValidateSet('x64', 'arm64')]
    [string]$Arch,
    [string]$Release,
    [string]$Out,
    [string]$CrtDir
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

if (-not $Arch) {
    $Arch = switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { 'x64' }
        'ARM64' { 'arm64' }
        default { throw "unsupported PROCESSOR_ARCHITECTURE '$env:PROCESSOR_ARCHITECTURE' (AMD64 or ARM64)" }
    }
}
$version = Get-AppVersion
if (-not $Release) { $Release = Join-Path $DeltaViewRoot "build\windows\$Arch\runner\Release" }
if (-not $Out) { $Out = Join-Path $DeltaViewRoot "dist\DeltaView-$version-$Arch.msix" }
# makeappx gets an absolute path: it does not know PowerShell's current folder.
$Out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Out)

$exe = Join-Path $Release 'delta_view.exe'
if (-not (Test-Path $exe)) { throw "$exe not found; run 'flutter build windows --release' first" }
$expected = $PeMachines[$Arch]
$machine = Get-PeMachine $exe
if ($machine -ne $expected) {
    throw ('delta_view.exe in {0} is built for machine 0x{1:X4}, not {2} (0x{3:X4})' -f $Release, $machine, $Arch, $expected)
}

# The Visual C++ runtime of the Visual Studio that built the app: CMake records
# that installation in the build's cache. Its default redistributable version is
# the one that goes with its default compiler, which is the one CMake used.
if (-not $CrtDir) {
    $vs = $null
    $cache = Join-Path $DeltaViewRoot "build\windows\$Arch\CMakeCache.txt"
    if (Test-Path $cache) {
        $line = Select-String -Path $cache -Pattern '^CMAKE_GENERATOR_INSTANCE:[A-Z]+=(.+)$' | Select-Object -First 1
        if ($line) { $vs = $line.Matches[0].Groups[1].Value.Trim() -replace '/', '\' }
    }
    if (-not $vs) {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
        $component = @{ x64 = 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'; arm64 = 'Microsoft.VisualStudio.Component.VC.Tools.ARM64' }[$Arch]
        if (Test-Path $vswhere) { $vs = & $vswhere -latest -products * -requires $component -property installationPath }
    }
    if (-not $vs) { throw "no Visual Studio with the $Arch C++ tools found; pass -CrtDir" }
    "Visual Studio: $vs"
    $redistVersionFile = Join-Path $vs 'VC\Auxiliary\Build\Microsoft.VCRedistVersion.default.txt'
    if (-not (Test-Path $redistVersionFile)) { throw "$redistVersionFile not found; pass -CrtDir" }
    $redistVersion = (Get-Content $redistVersionFile -TotalCount 1).Trim()
    $CrtDir = Get-ChildItem (Join-Path $vs "VC\Redist\MSVC\$redistVersion\$Arch") -Directory -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
    if (-not $CrtDir) { throw "no Microsoft.VC*.CRT folder under $vs\VC\Redist\MSVC\$redistVersion\$Arch; pass -CrtDir" }
}
$crt = @(Get-ChildItem $CrtDir -Filter '*.dll')
if (-not ($crt.Name -contains 'vcruntime140.dll')) { throw "$CrtDir has no vcruntime140.dll" }
"Visual C++ runtime: $CrtDir"

$makeappx = Find-SdkTool 'makeappx.exe'
$makepri = Find-SdkTool 'makepri.exe'
"makeappx: $makeappx"

$stage = Join-Path ([IO.Path]::GetTempPath()) "deltaview-msix-$PID"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory $stage | Out-Null
try {
    Copy-Item -Recurse (Join-Path $Release '*') $stage
    foreach ($dll in $crt) {
        # The arm64 runtime folder also holds ARM64X builds (vcruntime140_1.dll)
        # whose header says x64, for apps with ARM64EC code. Native code for
        # $Arch never loads them, so only DLLs built for $Arch are packaged.
        $m = Get-PeMachine $dll.FullName
        if ($m -ne $expected) {
            '  - {0,-28} skipped: machine 0x{1:X4}, not {2}' -f $dll.Name, $m, $Arch
            continue
        }
        Copy-Item $dll.FullName $stage -Force
        '  + {0,-28} {1}' -f $dll.Name, $dll.VersionInfo.FileVersion
    }
    Copy-Item -Recurse (Join-Path $PSScriptRoot 'Assets') $stage

    # Every program file in the package must be for $Arch, the runtime DLLs too.
    foreach ($f in Get-ChildItem $stage -Recurse -File -Include *.exe, *.dll) {
        $m = Get-PeMachine $f.FullName
        if ($m -ne $expected) { throw ('{0} is built for machine 0x{1:X4}, not {2}' -f $f.FullName, $m, $Arch) }
    }

    $values = @{
        '@NAME@'                   = $Name
        '@PUBLISHER@'              = $Publisher
        '@PUBLISHER_DISPLAY_NAME@' = $PublisherDisplayName
        '@VERSION@'                = "$version.0"
        '@ARCH@'                   = $Arch
    }
    $manifest = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'AppxManifest.xml.in'))
    foreach ($key in $values.Keys) {
        $manifest = $manifest.Replace($key, [Security.SecurityElement]::Escape($values[$key]))
    }
    if ($manifest -cmatch '@[A-Z_]+@') { throw "AppxManifest.xml.in has an unfilled placeholder: $($Matches[0])" }
    $null = [xml]$manifest # fails here if the result is not well-formed XML
    [IO.File]::WriteAllText((Join-Path $stage 'AppxManifest.xml'), $manifest)

    # The resource index, from which Windows picks each image's size and variant.
    Push-Location $stage
    try {
        Invoke-Tool 'makepri createconfig' { & $makepri createconfig /cf priconfig.xml /dq en-US /o }
        Invoke-Tool 'makepri new' { & $makepri new /pr . /cf priconfig.xml /mn AppxManifest.xml /of resources.pri /o }
        Remove-Item priconfig.xml
    } finally { Pop-Location }

    New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
    Invoke-Tool 'makeappx pack' { & $makeappx pack /d $stage /p $Out /o }
} finally {
    Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
}
"Package: $Out ($Name $version.0 $Arch)"
