param(
    [Parameter(Mandatory = $true)] [string] $ArtifactRoot,
    [Parameter(Mandatory = $true)] [string] $OutputRoot
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Universal-WssFiles.ps1"
foreach ($relative in $WssUniversalFiles) {
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
    if ((Get-FileHash -LiteralPath $hostPorts).Hash -cne (Get-FileHash -LiteralPath $runtimePorts).Hash) {
        throw 'Root output Ports must be the host runtime asset, never the net462 alternate.'
    }
}
$obsolete = @('WinRT.Runtime.dll', 'Microsoft.Windows.SDK.NET.dll', 'WSS.Transport.BLE.Windows.NativeBackend.dll',
    'System.Drawing.Common.dll', 'System.Windows.Extensions.dll', 'Microsoft.Win32.SystemEvents.dll')
foreach ($file in Get-ChildItem -LiteralPath $OutputRoot -File -Recurse) {
    if ($file.Name -in $obsolete) { throw "Obsolete WSS dependency in output: $($file.FullName)" }
}
"Universal candidate propagation verified: $OutputRoot"
