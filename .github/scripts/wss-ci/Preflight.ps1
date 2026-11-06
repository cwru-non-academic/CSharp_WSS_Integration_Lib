# Shared process bridge; adapters retain language-specific approval/evidence checks.
. "$PSScriptRoot/Channel.ps1"
function Invoke-WssCiPreflightContext($Context,[string]$DispatchToken='') {
    $Context.channel=Get-WssCiChannel
    $path=Join-Path ([IO.Path]::GetTempPath()) ('wss-preflight-'+[guid]::NewGuid().ToString('N')+'.json')
    $previous=$env:WSS_PREFLIGHT_TOKEN
    try {
        [IO.File]::WriteAllText($path,($Context|ConvertTo-Json -Depth 12 -Compress),[Text.UTF8Encoding]::new($false))
        $env:WSS_PREFLIGHT_TOKEN=$DispatchToken
        $output=& node (Join-Path $PSScriptRoot 'preflight.mjs') $path
        if($LASTEXITCODE -ne 0){throw 'Shared exact preflight operation failed; inspect before any retry.'}
        $output|ConvertFrom-Json
    } finally {
        $env:WSS_PREFLIGHT_TOKEN=$previous
        if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}
    }
}
function Start-WssCiPreflight([string]$Repository,$Candidate,[string]$WrapperSha='',[string]$ApplicationSha='',[string]$SourceSha='',[string]$CorrelationId='',[string]$DispatchToken='',[int]$DiscoverySeconds=180) {
    Invoke-WssCiPreflightContext @{operation='start';repository=$Repository;candidate=$Candidate;wrapper_sha=$WrapperSha;application_sha=$ApplicationSha;source_sha=$SourceSha;correlation_id=$CorrelationId;discovery_seconds=$DiscoverySeconds} $DispatchToken
}
function Wait-WssCiRun([string]$Repository,[string]$RunId,[string]$SourceSha,[string]$Workflow,[string]$Event,[int]$TimeoutSeconds=2400) {
    Invoke-WssCiPreflightContext @{operation='wait';repository=$Repository;run_id=$RunId;source_sha=$SourceSha;workflow=$Workflow;event=$Event;timeout_seconds=$TimeoutSeconds}
}
