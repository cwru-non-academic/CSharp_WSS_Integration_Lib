param(
    [Parameter(Mandatory = $true)] [string] $ArtifactRoot,
    [Parameter(Mandatory = $true)] [string] $OutputRoot,
    [Parameter(Mandatory = $true)] [string] $ProjectAssetsFile,
    [Parameter(Mandatory = $true)] [string] $ProjectPath
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Universal-WssFiles.ps1"
$selectedFiles = @(Read-WssUniversalFiles $ArtifactRoot -AllowProvenance)
Assert-WssMacOSPayload $ArtifactRoot $selectedFiles
$macFiles = $WssMacOSFiles
$sourceMacCount = @($macFiles | Where-Object { Test-Path -LiteralPath (Join-Path $ArtifactRoot $_) -PathType Leaf }).Count
$outputMacCount = @($macFiles | Where-Object { Test-Path -LiteralPath (Join-Path $OutputRoot $_) -PathType Leaf }).Count
if ($sourceMacCount -notin @(0,2) -or $sourceMacCount -ne $outputMacCount) {
    throw 'macOS backend propagation requires both managed adapter and native dylib in source/output; no partial or stale backend is allowed.'
}
$filesToVerify = $selectedFiles
foreach ($relative in $filesToVerify) {
    # Root net462 Ports is an alternate, not a runnable .NET host implementation.
    if ($relative -ceq 'System.IO.Ports.dll') { continue }
    $source = Join-Path $ArtifactRoot $relative
    $output = Join-Path $OutputRoot $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or -not (Test-Path -LiteralPath $output -PathType Leaf)) {
        throw "Universal content missing from candidate or output: $relative"
    }
    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash) {
        throw "Candidate/output hash mismatch: $relative"
    }
}
$platform = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'win' } else { 'unix' }
$hostPorts = Join-Path $OutputRoot 'System.IO.Ports.dll'
if (Test-Path -LiteralPath $hostPorts) {
    $runtimePorts = Join-Path $ArtifactRoot "runtimes/$platform/lib/net8.0/System.IO.Ports.dll"
    # Framework-dependent builds retain NuGet's neutral net8 DLL at the root;
    # .deps.json selects the platform runtime tree. RID publishes can flatten it.
    # Only this immutable bootstrap's managed helper is compiled, never project or child-provided source.
    if (-not ('Wss.BuildTools.RestoredPackageAssets' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'RestoredPackageAssets.cs')
    }
    $neutralPorts = [Wss.BuildTools.RestoredPackageAssets]::ResolveProjectAsset(
        $ProjectAssetsFile, $ProjectPath, 'System.IO.Ports/8.0.0', 'lib/net8.0/System.IO.Ports.dll', 'net9.0')
    $allowedHashes = @((Get-FileHash -LiteralPath $runtimePorts).Hash, (Get-FileHash -LiteralPath $neutralPorts).Hash)
    if ((Get-FileHash -LiteralPath $hostPorts).Hash -cnotin $allowedHashes) {
        throw 'Root output Ports is neither the restored neutral net8 asset nor the verified host runtime asset; net462 is forbidden.'
    }
}
$obsolete = @('WinRT.Runtime.dll', 'Microsoft.Windows.SDK.NET.dll', 'WSS.Transport.BLE.Windows.NativeBackend.dll',
    'System.Drawing.Common.dll', 'System.Windows.Extensions.dll', 'Microsoft.Win32.SystemEvents.dll')
foreach ($file in Get-ChildItem -LiteralPath $OutputRoot -File -Recurse) {
    if ($file.Name -in $obsolete) { throw "Obsolete WSS dependency in output: $($file.FullName)" }
}
"Universal candidate propagation verified: $OutputRoot"
