Set-StrictMode -Version Latest
. "$PSScriptRoot/WssPromotion.ps1"

function Assert-WssFanoutSources([string] $IntegrationSha, [string] $CliSha) {
    if ($IntegrationSha -cnotmatch '^[0-9a-f]{40}$' -or $CliSha -cnotmatch '^[0-9a-f]{40}$') { throw 'Invalid C# fanout source identity.' }
    foreach ($entry in @(@('cwru-non-academic/CSharp_WSS_Integration_Lib',$IntegrationSha),@('cwru-non-academic/CLI_CSharp_WSS_Application',$CliSha))) {
        $head = Invoke-WssGh @('api',"repos/$($entry[0])/git/ref/heads/dev") | ConvertFrom-Json
        if ($head.object.sha -cne $entry[1]) { throw "Fanout source moved: $($entry[0]); require fresh reviewed evidence." }
    }
}
function Get-WssCliDispatchReuse($Approval, [string] $IntegrationSha, [string] $CorrelationId) {
    $repo = 'cwru-non-academic/CLI_CSharp_WSS_Application'
    $title = "Promote Integration $IntegrationSha / $CorrelationId"
    $pages = Invoke-WssGh @('api','--paginate','--slurp',"repos/$repo/actions/workflows/promote-integration.yml/runs?event=workflow_dispatch&per_page=100") | ConvertFrom-Json
    $existingRuns = @($pages | ForEach-Object { $_.workflow_runs } | Where-Object display_title -CEQ $title)
    if ($existingRuns.Count -gt 1) { throw 'Ambiguous prior CLI dispatch; inspect manually.' }
    if ($existingRuns.Count -eq 0) { return $false }
    if ([string]$existingRuns[0].id -cnotmatch '^[1-9][0-9]*$') { throw 'Invalid prior CLI run identity.' }
    $run = Invoke-WssGh @('api',"repos/$repo/actions/runs/$($existingRuns[0].id)") | ConvertFrom-Json
    if ($run.id -ne $existingRuns[0].id -or $run.repository.full_name -cne $repo -or $run.head_repository.full_name -cne $repo -or
        $run.path -cne '.github/workflows/promote-integration.yml' -or $run.event -cne 'workflow_dispatch' -or
        $run.head_branch -cne 'dev' -or $run.head_sha -cne $Approval.cli.source_sha -or $run.display_title -cne $title) { throw 'Prior CLI dispatch identity mismatch; inspect before any write.' }
    if ($run.status -cne 'completed' -or $run.conclusion -cne 'success') { throw 'Prior CLI dispatch failed or remains uncertain; inspect before any retry.' }
    return $true
}
function Assert-WssCliDispatchIntent([string] $IntegrationSha, [switch] $RequireCurrent) {
    if ($env:GITHUB_REPOSITORY -cne 'cwru-non-academic/CSharp_WSS_Integration_Lib' -or
        $env:GITHUB_RUN_ID -cnotmatch '^[1-9][0-9]*$' -or $env:GITHUB_RUN_ATTEMPT -cne '1') { throw 'Dispatch recovery requires inspection; automatic attempt replay is forbidden.' }
    $name = "csharp-cli-dispatch-$IntegrationSha"
    $pages = Invoke-WssGh @('api','--paginate','--slurp',"repos/cwru-non-academic/CSharp_WSS_Integration_Lib/actions/artifacts?name=$name&per_page=100") | ConvertFrom-Json
    $artifacts = @($pages | ForEach-Object { $_.artifacts } | Where-Object name -CEQ $name)
    if ($artifacts.Count -gt 1 -or @($artifacts | Where-Object { [string]$_.workflow_run.id -cne $env:GITHUB_RUN_ID -or $_.expired -or $_.workflow_run.head_sha -cne $env:GITHUB_SHA }).Count) { throw 'Prior or uncertain CLI dispatch intent exists; inspect before any replay.' }
    if ($RequireCurrent -and $artifacts.Count -ne 1) { throw 'Durable current CLI dispatch intent required before application writes.' }
}
function New-WssCliDispatchRequest([string] $IntegrationSha, [string] $IntegrationPr, [string] $CorrelationId, [string] $ApprovalPath, [string] $RequestPath) {
    if ($IntegrationPr -cnotmatch '^[1-9][0-9]*$' -or $CorrelationId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$') { throw 'Invalid CLI dispatch metadata.' }
    $approval = Read-WssApproval $ApprovalPath
    Assert-WssFanoutSources $IntegrationSha $approval.cli.source_sha
    if (Get-WssCliDispatchReuse $approval $IntegrationSha $CorrelationId) { 'dispatch_needed=false' >> $env:GITHUB_OUTPUT; return }
    Assert-WssCliDispatchIntent $IntegrationSha
    if (Test-Path -LiteralPath $RequestPath) { throw 'CLI dispatch request must be new.' }
    @{ref='dev';inputs=@{integration_sha=$IntegrationSha;integration_pr=$IntegrationPr;correlation_id=$CorrelationId;approval_json=($approval | ConvertTo-Json -Depth 5 -Compress)}} |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $RequestPath -Encoding utf8
    'dispatch_needed=true' >> $env:GITHUB_OUTPUT
}
function Send-WssCliDispatch([string] $RequestPath, [string] $ReadToken, [string] $WriteToken) {
    if (!$ReadToken -or !$WriteToken) { throw 'Separate read and scoped CLI Actions-write tokens required.' }
    $request = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json
    if ($request.ref -cne 'dev') { throw 'CLI dispatch must target dev.' }
    $approval = $request.inputs.approval_json | ConvertFrom-Json
    $original = $env:GH_TOKEN
    try {
        $env:GH_TOKEN = $ReadToken
        Assert-WssFanoutSources $request.inputs.integration_sha $approval.cli.source_sha
        if (Get-WssCliDispatchReuse $approval $request.inputs.integration_sha $request.inputs.correlation_id) { return }
        Assert-WssCliDispatchIntent $request.inputs.integration_sha -RequireCurrent
        # These are the final reads before the one POST, after journal/reuse reads.
        Assert-WssFanoutSources $request.inputs.integration_sha $approval.cli.source_sha
        $env:GH_TOKEN = $WriteToken
        try { $null = Invoke-WssGh @('api','--method','POST','repos/cwru-non-academic/CLI_CSharp_WSS_Application/actions/workflows/promote-integration.yml/dispatches','--input',$RequestPath) }
        catch { throw 'CLI dispatch failed or uncertain; inspect remote state before any replay.' }
    } finally { $env:GH_TOKEN = $original }
}
