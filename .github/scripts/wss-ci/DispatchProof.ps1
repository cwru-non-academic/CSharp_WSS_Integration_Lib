. "$PSScriptRoot/Channel.ps1"
function Invoke-WssCiDispatchProof($Context) {
    if($Context.operation -ceq 'reuse'){$Context.expected.channel=Get-WssCiChannel}
    $path=Join-Path ([IO.Path]::GetTempPath()) ('wss-dispatch-proof-'+[guid]::NewGuid().ToString('N')+'.json')
    try {
        $Context|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $path
        $raw=& node (Join-Path $PSScriptRoot 'dispatch-proof.mjs') $path
        if($LASTEXITCODE -ne 0){throw 'Common application dispatch proof failed; inspect remote state before any write/retry.'}
        $raw|ConvertFrom-Json
    } finally {if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}}
}
function Test-WssCiApplicationDispatchReuse([string]$Repository,[string]$SourceSha,[string]$Title,$MergedAt,[string]$ReadCommand) {
    if (!$MergedAt) { throw 'Application dispatch discovery requires the integration PR merge time.' }
    $since=([DateTimeOffset]$MergedAt).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ',[Globalization.CultureInfo]::InvariantCulture)
    $created=[Uri]::EscapeDataString(">=$since")
    $pages=& $ReadCommand -Arguments @('api','--paginate','--slurp',"repos/$Repository/actions/workflows/promote-integration.yml/runs?event=workflow_dispatch&created=$created&per_page=100") | ConvertFrom-Json
    $runs=@($pages | ForEach-Object { $_.workflow_runs } | Where-Object display_title -CEQ $Title)
    $run=if($runs.Count -eq 1 -and [string]$runs[0].id -cmatch '^[1-9][0-9]*$'){
        & $ReadCommand -Arguments @('api',"repos/$Repository/actions/runs/$($runs[0].id)") | ConvertFrom-Json
    } else { $null }
    Invoke-WssCiDispatchProof @{operation='reuse';runs=$runs;run=$run;expected=@{repository=$Repository;source_sha=$SourceSha;title=$Title}}
}
function Assert-WssCiDispatchArtifacts([string]$Repository,[string]$Name,[switch]$RequireCurrent) {
    . "$PSScriptRoot/Process.ps1"
    $pages=Invoke-WssCiProcess -Executable gh -Arguments @('api','--paginate','--slurp',"repos/$Repository/actions/artifacts?name=$Name&per_page=100")|ConvertFrom-Json
    $artifacts=@($pages|ForEach-Object {$_.artifacts}|Where-Object name -CEQ $Name)
    $null=Invoke-WssCiDispatchProof @{operation='intent';artifacts=$artifacts;run_id=$env:GITHUB_RUN_ID;attempt=$env:GITHUB_RUN_ATTEMPT;source_sha=$env:GITHUB_SHA;required=[bool]$RequireCurrent}
}
function Send-WssCiApplicationDispatch([string]$Repository,[string]$RequestPath,[string]$ReadToken,[string]$WriteToken,[string]$OwnerRepository,[string]$IntentName,$Sources) {
    if(!$ReadToken -or !$WriteToken){throw 'Separate read and target-only Actions-write tokens required.'}
    . "$PSScriptRoot/Process.ps1"
    $saved=$env:GH_TOKEN
    try {
        $env:GH_TOKEN=$ReadToken
        $channel=Get-WssCiChannel
        $request=Get-Content -LiteralPath $RequestPath -Raw|ConvertFrom-Json
        if($request.ref -cne $channel){throw 'Application dispatch ref differs from the verified target channel.'}
        if($channel -ceq 'main'){$null=Assert-WssCiWorkflowAuthorization $env:PRODUCER_RUN_ID}
        Assert-WssCiDispatchArtifacts $OwnerRepository $IntentName -RequireCurrent
        foreach($repo in $Sources.Keys) {
            $head=Invoke-WssCiProcess -Executable gh -Arguments @('api',"repos/$repo/git/ref/heads/$channel")|ConvertFrom-Json
            if($head.object.sha -cne $Sources[$repo]){throw 'Fanout source moved immediately before application writes.'}
        }
        $env:GH_TOKEN=$WriteToken
        Invoke-WssCiProcess -Executable gh -Arguments @('api','--method','POST',"repos/$Repository/actions/workflows/promote-integration.yml/dispatches",'--input',$RequestPath) -FailureMessage 'Application dispatch failed or uncertain; inspect before replay'
    } finally {$env:GH_TOKEN=$saved}
}
