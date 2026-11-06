. "$PSScriptRoot/Channel.ps1"
function Test-WssCiStagingPolicy($Tree,$File,$Receiver,[ValidateSet('csharp','unity','python','matlab')][string]$Family) {
    $path=Join-Path ([IO.Path]::GetTempPath()) ('wss-staging-'+[guid]::NewGuid().ToString('N')+'.json')
    try {
        @{tree=$Tree;file=$File;receiver=$Receiver;family=$Family;channel=(Get-WssCiChannel)}|ConvertTo-Json -Depth 40|Set-Content -LiteralPath $path
        $raw=& node (Join-Path $PSScriptRoot 'staging.mjs') $path
        if($LASTEXITCODE -ne 0){throw 'Shared producer staging validation failed; no application write is authorized.'}
        $raw|ConvertFrom-Json
    } finally {if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}}
}
function Assert-WssCiBarrierExecution($Barrier,[ValidateSet('csharp','unity','python','matlab')][string]$Family,[string]$SourceRoot){
    $channel=Get-WssCiChannel
    if($channel -ceq 'dev'){return}
    $path=Join-Path ([IO.Path]::GetTempPath()) ('wss-execution-'+[guid]::NewGuid().ToString('N')+'.json')
    try{
        $environment=@{};foreach($name in @('GITHUB_ACTIONS','GITHUB_EVENT_NAME','GITHUB_REPOSITORY','GITHUB_REF','GITHUB_SHA','GITHUB_WORKFLOW_SHA','GITHUB_WORKFLOW_REF')){$environment[$name]=[Environment]::GetEnvironmentVariable($name)}
        $context=@{operation='execution';channel=$channel;barrier=$Barrier;family=$Family;source_root=$SourceRoot;env=$environment}
        [IO.File]::WriteAllText($path,($context|ConvertTo-Json -Depth 40 -Compress),[Text.UTF8Encoding]::new($false))
        $raw=& node (Join-Path $PSScriptRoot 'staging.mjs') $path
        if($LASTEXITCODE -ne 0 -or ($raw -join "`n") -cne 'true'){throw 'Actual main execution does not match its frozen accepted-merge authority.'}
    }finally{if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}}
}
