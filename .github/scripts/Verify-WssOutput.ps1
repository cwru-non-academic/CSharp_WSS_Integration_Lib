# Tooling-owned validator; product/fixture pins do not select executable validation code.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ArtifactRoot,
    [Parameter(Mandatory)][string]$OutputRoot,
    [Parameter(Mandatory)][string]$ProjectAssetsFile,
    [Parameter(Mandatory)][string]$ProjectPath
)
$ErrorActionPreference='Stop'
& "$PSScriptRoot/wss-ci/restored-assets/Verify-WssOutput.ps1" @PSBoundParameters
