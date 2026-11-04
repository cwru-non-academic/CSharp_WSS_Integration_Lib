$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/../WssFanout.ps1"
$temp = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
$null = New-Item -ItemType Directory -Path $temp
$saved = @{}
foreach ($key in @('GH_TOKEN','GITHUB_REPOSITORY','GITHUB_RUN_ID','GITHUB_RUN_ATTEMPT','GITHUB_SHA','GITHUB_OUTPUT')) { $saved[$key]=[Environment]::GetEnvironmentVariable($key) }
$count=0
function Reject([scriptblock]$Action,[string]$Message) {
    $failed=$false
    try { & $Action } catch { if ($_.Exception.Message -cnotlike $Message) { throw }; $failed=$true }
    if (!$failed) { throw "Expected fanout rejection: $Message" }
    $script:count++
}
try {
    $approval=Read-WssApproval "$PSScriptRoot/../../universal-bootstrap.json"
    $sha='a'*40; $correlation='wss-fanout-fixture'
    $approvalPath=Join-Path $temp 'approval.json'; Write-WssApproval $approval $approvalPath
    $requestPath=Join-Path $temp 'request.json'
    $env:GH_TOKEN='original-fixture'; $env:GITHUB_REPOSITORY='cwru-non-academic/CSharp_WSS_Integration_Lib'
    $env:GITHUB_RUN_ID='99'; $env:GITHUB_RUN_ATTEMPT='1'; $env:GITHUB_SHA='d'*40; $env:GITHUB_OUTPUT=Join-Path $temp 'outputs'
    $script:cliHead=$approval.cli.source_sha; $script:wrapperHead=$sha
    $script:runs=@(); $script:intents=@(); $script:posts=0; $script:failPost=$false; $script:moveOnIntent=$false
    $currentIntent=@{name="csharp-cli-dispatch-$sha";expired=$false;workflow_run=@{id=99;head_sha=$env:GITHUB_SHA}}
    $script:priorRun=@{id=7;repository=@{full_name='cwru-non-academic/CLI_CSharp_WSS_Application'};head_repository=@{full_name='cwru-non-academic/CLI_CSharp_WSS_Application'};path='.github/workflows/promote-integration.yml';event='workflow_dispatch';head_branch='dev';head_sha=$approval.cli.source_sha;display_title="Promote Integration $sha / $correlation";status='completed';conclusion='success'}
    function Invoke-WssGh([string[]]$Arguments) {
        if ('POST' -cin $Arguments) {
            if ($env:GH_TOKEN -cne 'write-fixture') { throw 'POST did not use scoped write token.' }
            $script:posts++
            if ($script:failPost) { throw 'Simulated uncertain POST.' }
            return
        }
        switch -Wildcard ($Arguments[-1]) {
            '*/CSharp_WSS_Integration_Lib/git/ref/heads/dev' { @{object=@{sha=$script:wrapperHead}} | ConvertTo-Json -Depth 4 }
            '*/CLI_CSharp_WSS_Application/git/ref/heads/dev' { @{object=@{sha=$script:cliHead}} | ConvertTo-Json -Depth 4 }
            '*/workflows/promote-integration.yml/runs?*' { ConvertTo-Json -InputObject @(@{workflow_runs=$script:runs}) -Depth 8 }
            '*/CLI_CSharp_WSS_Application/actions/runs/7' { $script:priorRun | ConvertTo-Json -Depth 8 }
            '*/CSharp_WSS_Integration_Lib/actions/artifacts?*' {
                if ($script:moveOnIntent) { $script:cliHead='f'*40 }
                ConvertTo-Json -InputObject @(@{artifacts=$script:intents}) -Depth 8
            }
            default { throw "Unexpected fixture API read: $($Arguments[-1])" }
        }
    }
    New-WssCliDispatchRequest $sha '40' $correlation $approvalPath $requestPath
    $request=Get-Content $requestPath -Raw | ConvertFrom-Json
    if ($request.ref -cne 'dev' -or $request.inputs.integration_sha -cne $sha -or $script:posts -ne 0) { throw 'Read-only preparation changed the dispatch target or wrote remotely.' }
    Reject { Send-WssCliDispatch $requestPath '' 'write-fixture' } 'Separate read*'
    Reject { Send-WssCliDispatch $requestPath 'read-fixture' '' } 'Separate read*'
    Reject { Send-WssCliDispatch $requestPath 'read-fixture' 'write-fixture' } 'Durable current CLI dispatch intent required*'
    $script:intents=@($currentIntent)
    Send-WssCliDispatch $requestPath 'read-fixture' 'write-fixture'
    if ($script:posts -ne 1 -or $env:GH_TOKEN -cne 'original-fixture') { throw 'Expected exactly one POST and restored read environment.' }

    $script:runs=@(@{id=7;display_title=$script:priorRun.display_title})
    Send-WssCliDispatch $requestPath 'read-fixture' 'write-fixture'
    if ($script:posts -ne 1) { throw 'Exact successful reuse redispatched.' }
    foreach ($field in @('head_sha','head_branch','path','event','display_title','repository','head_repository')) {
        $before=$script:priorRun[$field]
        $script:priorRun[$field]=if ($field -cin @('repository','head_repository')) { @{full_name='other/repo'} } else { 'wrong' }
        Reject { Get-WssCliDispatchReuse $approval $sha $correlation } 'Prior CLI dispatch identity mismatch*'
        $script:priorRun[$field]=$before
    }
    $script:priorRun.conclusion='failure'
    Reject { Send-WssCliDispatch $requestPath 'read-fixture' 'write-fixture' } 'Prior CLI dispatch failed or remains uncertain*'
    $script:priorRun.conclusion='success'; $script:priorRun.status='in_progress'
    Reject { Get-WssCliDispatchReuse $approval $sha $correlation } 'Prior CLI dispatch failed or remains uncertain*'
    $script:priorRun.status='completed'; $script:runs+= $script:runs[0]
    Reject { Get-WssCliDispatchReuse $approval $sha $correlation } 'Ambiguous prior CLI dispatch*'
    $script:runs=@()

    $env:GITHUB_RUN_ATTEMPT='2'
    Reject { Send-WssCliDispatch $requestPath 'read-fixture' 'write-fixture' } 'Dispatch recovery requires inspection*'
    $env:GITHUB_RUN_ATTEMPT='1'
    foreach ($mutation in @({param($a)$a.workflow_run.id=98},{param($a)$a.expired=$true},{param($a)$a.workflow_run.head_sha='e'*40})) {
        $bad=$currentIntent | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        & $mutation $bad; $script:intents=@($bad)
        Reject { Send-WssCliDispatch $requestPath 'read-fixture' 'write-fixture' } 'Prior or uncertain CLI dispatch intent exists*'
    }
    $script:intents=@($currentIntent,$currentIntent)
    Reject { Send-WssCliDispatch $requestPath 'read-fixture' 'write-fixture' } 'Prior or uncertain CLI dispatch intent exists*'
    $script:intents=@($currentIntent); $script:wrapperHead='e'*40
    Reject { Send-WssCliDispatch $requestPath 'read-fixture' 'write-fixture' } 'Fanout source moved:*'
    $script:wrapperHead=$sha; $script:moveOnIntent=$true
    Reject { Send-WssCliDispatch $requestPath 'read-fixture' 'write-fixture' } 'Fanout source moved:*'
    $script:moveOnIntent=$false; $script:cliHead=$approval.cli.source_sha
    if ($script:posts -ne 1) { throw 'A rejected request attempted a POST.' }
    $script:failPost=$true
    Reject { Send-WssCliDispatch $requestPath 'read-fixture' 'write-fixture' } 'CLI dispatch failed or uncertain*'
    if ($script:posts -ne 2 -or $env:GH_TOKEN -cne 'original-fixture') { throw 'Uncertain POST was retried or token environment was not restored.' }
    $workflow=Get-Content "$PSScriptRoot/../../workflows/dispatch-cli-promotion.yml" -Raw
    $intentAt=$workflow.IndexOf('name: Record CLI dispatch intent before write credentials')
    $barrierAt=$workflow.IndexOf('name: Recheck integration barrier immediately before CLI writes')
    $tokenAt=$workflow.IndexOf('name: Create CLI Actions token')
    $postAt=$workflow.IndexOf('name: Dispatch CLI promotion workflow')
    if ($intentAt -lt 0 -or $barrierAt -le $intentAt -or $tokenAt -le $barrierAt -or $postAt -le $tokenAt -or !$workflow.Contains('group: csharp-cli-fanout') -or !$workflow.Contains('Send-WssCliDispatch ')) { throw 'Workflow must serialize fanout and journal/recheck before requesting write credentials.' }
    "PASS: C# CLI fanout contracts ($count rejections; exact reuse, durable intent, final receiver heads and no uncertain retry)."
} finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key]) }
    Remove-Item -LiteralPath $temp -Recurse -Force
}
