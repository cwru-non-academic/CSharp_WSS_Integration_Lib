# PowerShell adapters use the same Core channel policy as the Node engines.
function Get-WssCiChannelContext([string]$Channel='') {
    if(!$Channel){$Channel=$env:WSS_CI_CHANNEL}
    # Execution may be on trusted main while the authorized target is dev.
    # Never infer an authorization channel from GITHUB_REF or a PR base.
    if(!$Channel -and $env:GITHUB_ACTIONS -cne 'true'){$Channel='dev'}
    if(!$Channel){throw 'An explicit CI channel context is required.'}
    if(!(Get-Variable WssCiChannelContexts -Scope Script -ErrorAction SilentlyContinue)){$script:WssCiChannelContexts=@{}}
    if(!$script:WssCiChannelContexts.ContainsKey($Channel)){
        $module=if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'channels.mjs')){Join-Path $PSScriptRoot 'channels.mjs'}else{Join-Path $PSScriptRoot '../../release/channels.mjs'}
        $raw=& node $module $Channel
        if($LASTEXITCODE -ne 0){throw 'Canonical CI channel policy rejected the context.'}
        $script:WssCiChannelContexts[$Channel]=($raw -join "`n")|ConvertFrom-Json
    }
    $script:WssCiChannelContexts[$Channel]
}
function Get-WssCiChannel([string]$Channel=''){(Get-WssCiChannelContext $Channel).channel}
function Assert-WssCiTargetRef([string]$Channel=''){
    $context=Get-WssCiChannelContext $Channel
    if($env:GITHUB_ACTIONS -cne 'true' -or $env:GITHUB_REF -cne $context.ref){throw 'Target workflow ref differs from the verified CI channel.'}
}
function Assert-WssCiWorkflowAuthorization([string]$ProducerRunId,[string]$SourceRoot=''){
    $context=Get-WssCiChannelContext
    if($context.channel -ceq 'dev'){return}
    if(!$SourceRoot){$SourceRoot=$env:WSS_TARGET_ROOT}
    $core=$env:WSS_CORE_TOOLS_ROOT
    if(!$core -or !$SourceRoot -or $ProducerRunId -cnotmatch '^[1-9][0-9]*$'){throw 'Main authorization requires exact canonical tooling and target roots.'}
    $lock=Get-Content -LiteralPath (Join-Path $SourceRoot '.github/scripts/wss-ci.lock.json') -Raw|ConvertFrom-Json
    if($lock.source_repository -cne 'cwru-non-academic/WSSCore' -or $lock.source_commit -cnotmatch '^[a-f0-9]{40}$'){throw 'Invalid immutable Core tooling lock.'}
    $head=& git -C $core rev-parse HEAD
    if($LASTEXITCODE -ne 0 -or $head -cne $lock.source_commit){throw 'Main workflow guard must execute the locked Core revision.'}
    $status=& git -C $core status --porcelain --untracked-files=no
    if($LASTEXITCODE -ne 0 -or $status){throw 'Core workflow guard checkout must be clean.'}
    $raw=& node (Join-Path $core 'tools/ci/workflow-freeze.mjs') check-receiver $ProducerRunId $env:GITHUB_REPOSITORY
    if($LASTEXITCODE -ne 0 -or !$raw){throw 'Frozen main workflow authorization failed.'}
    $proof=($raw -join "`n")|ConvertFrom-Json
    if($proof.schema -cne 'wss-receiver-workflow-authorization/v1' -or $proof.channel -cne 'main' -or
       $proof.repository -cne $env:GITHUB_REPOSITORY -or [string]$proof.candidate.run_id -cne $ProducerRunId -or
       $proof.plan_id -cnotmatch '^[a-f0-9]{64}$'){throw 'Main workflow guard returned mismatched proof.'}
    $proof
}
