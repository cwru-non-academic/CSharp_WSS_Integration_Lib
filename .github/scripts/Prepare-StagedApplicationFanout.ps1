param(
    [Parameter(Mandatory)][ValidateSet('csharp','unity')][string]$Receiver,
    [Parameter(Mandatory)][string]$RecordPath,
    [Parameter(Mandatory)][string]$WorkRoot,
    [string]$CoreRoot='.core-stage',
    [string]$ExpectedMergeSha=''
)
& "$PSScriptRoot/wss-ci/Prepare-StagedApplicationFanout.ps1" @PSBoundParameters
