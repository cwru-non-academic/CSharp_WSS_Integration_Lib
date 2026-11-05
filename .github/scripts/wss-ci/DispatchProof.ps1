function Invoke-WssCiDispatchProof($Context) {
    $path=Join-Path ([IO.Path]::GetTempPath()) ('wss-dispatch-proof-'+[guid]::NewGuid().ToString('N')+'.json')
    try {
        $Context|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $path
        $raw=& node (Join-Path $PSScriptRoot 'dispatch-proof.mjs') $path
        if($LASTEXITCODE -ne 0){throw 'Common application dispatch proof failed; inspect remote state before any write/retry.'}
        $raw|ConvertFrom-Json
    } finally {if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}}
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
        Assert-WssCiDispatchArtifacts $OwnerRepository $IntentName -RequireCurrent
        foreach($repo in $Sources.Keys) {
            $head=Invoke-WssCiProcess -Executable gh -Arguments @('api',"repos/$repo/git/ref/heads/dev")|ConvertFrom-Json
            if($head.object.sha -cne $Sources[$repo]){throw 'Fanout source moved immediately before application writes.'}
        }
        $env:GH_TOKEN=$WriteToken
        Invoke-WssCiProcess -Executable gh -Arguments @('api','--method','POST',"repos/$Repository/actions/workflows/promote-integration.yml/dispatches",'--input',$RequestPath) -FailureMessage 'Application dispatch failed or uncertain; inspect before replay'
    } finally {$env:GH_TOKEN=$saved}
}
