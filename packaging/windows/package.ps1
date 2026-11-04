<#
.SYNOPSIS
  Build, sign and package GridCraft for Windows.

.DESCRIPTION
  Produces, in $env:DIST (default: dist/release):
    gridcraft-<version>-windows-<arch>.msi            per-machine installer (WiX v5)
    gridcraft-<version>-windows-<arch>-portable.zip   gridcraft.exe + gridcraft-cli.exe

  The binaries link the C runtime statically (+crt-static), so neither the MSI nor the portable
  zip needs the Visual C++ redistributable. Signing is delegated to sign.ps1 (skipped with a
  warning when no signing secrets are set).

  Needs: Rust (MSVC toolchain + the target), the Windows SDK (rc.exe, signtool.exe),
  and WiX v5: dotnet tool install --global wix --version 5.0.2

.EXAMPLE
  pwsh packaging/windows/package.ps1 -Arch x64
  pwsh packaging/windows/package.ps1 -Arch x86 -SkipBuild
  pwsh packaging/windows/package.ps1 -Arch arm64     # cross-compiled; needs the MSVC ARM64 build tools
#>
param(
  [ValidateSet('x64', 'x86', 'arm64')] [string] $Arch = 'x64',
  [switch] $SkipBuild
)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

function Invoke-Native([string] $What, [scriptblock] $Block) {
  Write-Output "==> $What"
  & $Block
  if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE" }
}

# The version lives in one place: [workspace.package] version in the root Cargo.toml.
$Version = $env:GRIDCRAFT_VERSION
if (-not $Version) {
  $inPkg = $false
  foreach ($line in Get-Content (Join-Path $Root 'Cargo.toml')) {
    if ($line -match '^\s*\[') { $inPkg = ($line.Trim() -eq '[workspace.package]'); continue }
    if ($inPkg -and $line -match '^\s*version\s*=\s*"([^"]+)"') { $Version = $Matches[1]; break }
  }
}
if (-not $Version) { throw 'could not read [workspace.package] version from Cargo.toml' }
# MSI ProductVersion is numeric (major.minor.build); pre-release tags are dropped there.
$MsiVersion = ($Version -split '-')[0]

# Build metadata embedded in binaries (Help ▸ About and the crash reporter).
$env:GRIDCRAFT_BUILD_SHA = "0000000000000000000000000000000000000000"
if (Test-Path (Join-Path $Root ".git")) {
  try {
    $sha = git -C $Root rev-parse HEAD 2>$null
    if ($sha) { $env:GRIDCRAFT_BUILD_SHA = $sha }
  } catch {}
}
if (-not $env:GRIDCRAFT_BUILD_DATE) {
  $env:GRIDCRAFT_BUILD_DATE = (Get-Date -Format 'yyyy-MM-dd')
}

$DistDir = if ($env:DIST) { $env:DIST } else { Join-Path $Root 'dist\release' }
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

$Triple = switch ($Arch) {
  'x64'   { 'x86_64-pc-windows-msvc' }
  'x86'   { 'i686-pc-windows-msvc' }
  'arm64' { 'aarch64-pc-windows-msvc' }
}

# Build unless caller passed -SkipBuild (used e.g. when CI builds binaries in an earlier step).
if (-not $SkipBuild) {
  # Statically link CRT so clean Windows installs don't need the VC redist.
  $env:RUSTFLAGS = "$env:RUSTFLAGS -C target-feature=+crt-static"

  Invoke-Native "cargo build ($Triple)" {
    cargo build --release --target $Triple -p gridcraft -p gridcraft-cli
  }
}

$TargetBinDir = Join-Path $Root "target\$Triple\release"
$AppExe = Join-Path $TargetBinDir 'gridcraft.exe'
$CliExe = Join-Path $TargetBinDir 'gridcraft-cli.exe'

if (-not (Test-Path $AppExe)) { throw "missing $AppExe" }
if (-not (Test-Path $CliExe)) { throw "missing $CliExe" }

# Sign the binaries before packaging.
$SignScript = Join-Path $PSScriptRoot 'sign.ps1'
if (Test-Path $SignScript) {
  & $SignScript -Files @($AppExe, $CliExe)
}

# 1. Portable zip: executables + attribution/licenses.
$ZipName = "gridcraft-$Version-windows-$Arch-portable.zip"
$ZipPath = Join-Path $DistDir $ZipName
Write-Output "==> Packaging portable zip: $ZipPath"

$StageDir = Join-Path $DistDir "stage-portable-$Arch"
if (Test-Path $StageDir) { Remove-Item -Recurse -Force $StageDir }
New-Item -ItemType Directory -Force -Path $StageDir | Out-Null

Copy-Item $AppExe $StageDir
Copy-Item $CliExe $StageDir
Copy-Item (Join-Path $Root 'LICENSE-MIT') $StageDir
Copy-Item (Join-Path $Root 'LICENSE-APACHE') $StageDir
Copy-Item (Join-Path $Root 'NOTICE') $StageDir
Copy-Item (Join-Path $Root 'ATTRIBUTION.md') $StageDir

if (Test-Path $ZipPath) { Remove-Item -Force $ZipPath }
Compress-Archive -Path (Join-Path $StageDir '*') -DestinationPath $ZipPath
Remove-Item -Recurse -Force $StageDir

# 2. MSI installer via WiX v5.
$MsiName = "gridcraft-$Version-windows-$Arch.msi"
$MsiPath = Join-Path $DistDir $MsiName
Write-Output "==> Packaging MSI: $MsiPath"

# Wix takes -arch x64/x86/arm64 directly.
$Wxs = Join-Path $PSScriptRoot 'gridcraft.wxs'
$IconPath = Join-Path $Root 'assets\app-icon\gridcraft.ico'
if (-not (Test-Path $IconPath)) { throw "missing $IconPath" }

# Clean previous build artifacts for this MSI to avoid conflicts.
$MsiObjDir = Join-Path $DistDir "wix-obj-$Arch"
if (Test-Path $MsiObjDir) { Remove-Item -Recurse -Force $MsiObjDir }
New-Item -ItemType Directory -Force -Path $MsiObjDir | Out-Null

Invoke-Native "wix build" {
  wix build `
    -arch $Arch `
    -ext WixToolset.UI.wixext `
    -ext WixToolset.Util.wixext `
    -d "Version=$MsiVersion" `
    -d "SourceDir=$TargetBinDir" `
    -d "BinDir=$TargetBinDir" `
    -d "IconPath=$IconPath" `
    -d "Root=$Root" `
    -intermediateFolder $MsiObjDir `
    -o $MsiPath `
    $Wxs
}

Remove-Item -Recurse -Force $MsiObjDir

# Sign the MSI.
if (Test-Path $SignScript) {
  & $SignScript -Files @($MsiPath)
}

Write-Output "==> Packaged successfully:"
Write-Output "    $ZipPath"
Write-Output "    $MsiPath"
