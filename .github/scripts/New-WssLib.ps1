param(
    [Parameter(Mandatory = $true)]
    [string] $BleArtifactDir,

    [Parameter(Mandatory = $true)]
    [string] $Destination
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $BleArtifactDir -PathType Container)) {
    throw "BLE Unified artifact directory is missing: $BleArtifactDir"
}

if (Test-Path -LiteralPath $Destination) {
    Remove-Item -LiteralPath $Destination -Recurse -Force
}
New-Item -ItemType Directory -Path $Destination | Out-Null

$sourceRoot = (Resolve-Path -LiteralPath $BleArtifactDir).Path
$destinationRoot = (Resolve-Path -LiteralPath $Destination).Path

foreach ($sourceFile in Get-ChildItem -LiteralPath $sourceRoot -File -Recurse) {
    $relativePath = $sourceFile.FullName.Substring($sourceRoot.Length).TrimStart('\', '/').Replace('\', '/')
    $isExcluded =
        $relativePath.Equals('System.IO.Ports.dll', [StringComparison]::OrdinalIgnoreCase) -or
        ($relativePath.StartsWith('runtimes/', [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($relativePath).Equals('System.IO.Ports.dll', [StringComparison]::OrdinalIgnoreCase)) -or
        ($relativePath.StartsWith('runtimes/', [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($relativePath).StartsWith('libSystem.IO.Ports.Native.', [StringComparison]::OrdinalIgnoreCase))

    if ($isExcluded) {
        continue
    }

    $destinationFile = Join-Path $destinationRoot $relativePath
    $destinationParent = Split-Path -Parent $destinationFile
    New-Item -ItemType Directory -Force -Path $destinationParent | Out-Null
    Copy-Item -LiteralPath $sourceFile.FullName -Destination $destinationFile
}

foreach ($requiredFile in @(
    'WSS_Core_Interface.dll',
    'Newtonsoft.Json.dll',
    'WSS.Transport.BLE.dll',
    'backends/windows/WSS.Transport.BLE.Windows.dll',
    'backends/linux/WSS.Transport.BLE.Linux.dll'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $destinationRoot $requiredFile) -PathType Leaf)) {
        throw "Promoted lib is missing required file: $requiredFile"
    }
}

$forbiddenFiles = @(Get-ChildItem -LiteralPath $destinationRoot -File -Recurse | Where-Object {
    $relativePath = $_.FullName.Substring($destinationRoot.Length).TrimStart('\', '/').Replace('\', '/')
    $relativePath.Equals('System.IO.Ports.dll', [StringComparison]::OrdinalIgnoreCase) -or
    ($relativePath.StartsWith('runtimes/', [StringComparison]::OrdinalIgnoreCase) -and
        $_.Name.Equals('System.IO.Ports.dll', [StringComparison]::OrdinalIgnoreCase)) -or
    ($relativePath.StartsWith('runtimes/', [StringComparison]::OrdinalIgnoreCase) -and
        $_.Name.StartsWith('libSystem.IO.Ports.Native.', [StringComparison]::OrdinalIgnoreCase))
})

if ($forbiddenFiles.Count -ne 0) {
    throw "Promoted lib contains NuGet-owned System.IO.Ports files: $($forbiddenFiles.FullName -join ', ')"
}

if (@(Get-ChildItem -LiteralPath $destinationRoot -File -Recurse).Count -eq 0) {
    throw 'Promoted lib contains no files.'
}
