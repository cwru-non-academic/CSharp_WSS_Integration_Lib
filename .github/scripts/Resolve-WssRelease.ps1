param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')]
    [string] $ReleaseTag,

    [Parameter(Mandatory = $true)]
    [string] $OutputRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-FileExists([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file is missing: $Path"
    }
}

function Assert-DirectoryHasFiles([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Required directory is missing: $Path"
    }

    if (@(Get-ChildItem -LiteralPath $Path -File -Recurse).Count -eq 0) {
        throw "Required directory contains no files: $Path"
    }
}

$coreArchiveName = "WSS-Core-$ReleaseTag.zip"
$bleArchiveName = "WSS-BLE-Unified-$ReleaseTag.zip"
$downloadDir = Join-Path $OutputRoot 'downloads'
$coreArtifactDir = Join-Path $OutputRoot 'core'
$bleArtifactDir = Join-Path $OutputRoot 'ble-unified'

if (Test-Path -LiteralPath $OutputRoot) {
    Remove-Item -LiteralPath $OutputRoot -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $downloadDir, $coreArtifactDir, $bleArtifactDir | Out-Null

& gh release download $ReleaseTag `
    --repo cwru-non-academic/WSSCore `
    --pattern $coreArchiveName `
    --pattern $bleArchiveName `
    --pattern SHA256SUMS.txt `
    --dir $downloadDir
if ($LASTEXITCODE -ne 0) {
    throw "gh release download failed with exit code $LASTEXITCODE."
}

$checksumsPath = Join-Path $downloadDir 'SHA256SUMS.txt'
Assert-FileExists $checksumsPath
$checksumText = Get-Content -LiteralPath $checksumsPath -Raw

foreach ($archiveName in @($coreArchiveName, $bleArchiveName)) {
    $archivePath = Join-Path $downloadDir $archiveName
    Assert-FileExists $archivePath
    $escapedName = [Regex]::Escape($archiveName)
    $checksumMatch = [Regex]::Match(
        $checksumText,
        "(?m)^(?<hash>[0-9a-fA-F]{64})\s+\*?$escapedName\r?$"
    )
    if (-not $checksumMatch.Success) {
        throw "SHA256SUMS.txt has no checksum entry for $archiveName."
    }

    $expectedSha = $checksumMatch.Groups['hash'].Value
    $actualSha = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
    if (-not $actualSha.Equals($expectedSha, [StringComparison]::OrdinalIgnoreCase)) {
        throw "SHA-256 mismatch for $archiveName. Expected $expectedSha; actual $actualSha."
    }

    Write-Output "Verified $archiveName SHA256: $actualSha"
}

Expand-Archive -LiteralPath (Join-Path $downloadDir $coreArchiveName) -DestinationPath $coreArtifactDir
Expand-Archive -LiteralPath (Join-Path $downloadDir $bleArchiveName) -DestinationPath $bleArtifactDir

foreach ($requiredFile in @(
    'WSS_Core_Interface.dll',
    'Newtonsoft.Json.dll'
)) {
    Assert-FileExists (Join-Path $coreArtifactDir $requiredFile)
}

foreach ($requiredFile in @(
    'WSS_Core_Interface.dll',
    'Newtonsoft.Json.dll',
    'WSS.Transport.BLE.dll',
    'System.IO.Ports.dll',
    'System.Security.Permissions.dll',
    'System.Windows.Extensions.dll',
    'System.Drawing.Common.dll',
    'Microsoft.Win32.SystemEvents.dll',
    'backends/windows/WSS.Transport.BLE.Windows.dll',
    'backends/windows/Microsoft.Windows.SDK.NET.dll',
    'backends/windows/WinRT.Runtime.dll',
    'backends/linux/WSS.Transport.BLE.Linux.dll',
    'backends/linux/Linux.Bluetooth.dll',
    'backends/linux/Tmds.DBus.dll',
    'runtimes/win/lib/net9.0/System.IO.Ports.dll',
    'runtimes/unix/lib/net9.0/System.IO.Ports.dll',
    'runtimes/linux-x64/native/libSystem.IO.Ports.Native.so'
)) {
    Assert-FileExists (Join-Path $bleArtifactDir $requiredFile)
}

foreach ($runtimeTree in @('runtimes/win', 'runtimes/unix', 'runtimes/linux-x64')) {
    Assert-DirectoryHasFiles (Join-Path $bleArtifactDir $runtimeTree)
}

$coreInterfaceHash = (Get-FileHash -LiteralPath (Join-Path $coreArtifactDir 'WSS_Core_Interface.dll') -Algorithm SHA256).Hash
$bleInterfaceHash = (Get-FileHash -LiteralPath (Join-Path $bleArtifactDir 'WSS_Core_Interface.dll') -Algorithm SHA256).Hash
if (-not $coreInterfaceHash.Equals($bleInterfaceHash, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'WSS_Core_Interface.dll differs between the Core and BLE Unified artifacts.'
}

Write-Output "WSS_ARTIFACT_DIR=$coreArtifactDir"
Write-Output "WSS_BLE_ARTIFACT_DIR=$bleArtifactDir"
