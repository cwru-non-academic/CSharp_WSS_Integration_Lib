# Core-owned bridge. Compile only the immutable sibling managed helper before child code.
if (-not ('Wss.BuildTools.RestoredPackageAssets' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'RestoredPackageAssets.cs')
}
function New-WssRestoredAssetsProof {
    param([Parameter(Mandatory)][string]$ProjectAssetsFile,[Parameter(Mandatory)][string]$ProjectPath)
    [Wss.BuildTools.RestoredPackageAssets]::CaptureProjectAsset(
        $ProjectAssetsFile,$ProjectPath,'System.IO.Ports/8.0.0','lib/net8.0/System.IO.Ports.dll','net9.0')
}
function Assert-WssRestoredAssetsProof {
    param([Parameter(Mandatory)][object]$Proof,[Parameter(Mandatory)][string]$ProjectAssetsFile,[Parameter(Mandatory)][string]$ProjectPath)
    if ($Proof -isnot [Wss.BuildTools.RestoredAssetProof]) { throw 'Only a parent-captured managed restored asset proof is accepted.' }
    [Wss.BuildTools.RestoredPackageAssets]::AssertProjectAssetProof(
        $Proof,$ProjectAssetsFile,$ProjectPath,'System.IO.Ports/8.0.0','lib/net8.0/System.IO.Ports.dll','net9.0')
}