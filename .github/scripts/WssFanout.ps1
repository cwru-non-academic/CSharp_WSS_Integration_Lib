Set-StrictMode -Version Latest
. "$PSScriptRoot/WssPromotion.ps1"

function Assert-WssFanoutSources([string] $IntegrationSha, [string] $CliSha) {
    if ($IntegrationSha -cnotmatch '^[0-9a-f]{40}$' -or $CliSha -cnotmatch '^[0-9a-f]{40}$') { throw 'Invalid C# fanout source identity.' }
    foreach ($entry in @(@('cwru-non-academic/CSharp_WSS_Integration_Lib',$IntegrationSha),@('cwru-non-academic/CLI_CSharp_WSS_Application',$CliSha))) {
        $head = Invoke-WssGh -Arguments @('api',"repos/$($entry[0])/git/ref/heads/$(Get-WssCiChannel)") | ConvertFrom-Json
        if ($head.object.sha -cne $entry[1]) { throw "Fanout source moved: $($entry[0]); require fresh reviewed evidence." }
    }
}
function Get-WssCliDispatchReuse($Approval,[string]$IntegrationSha,[string]$CorrelationId) {
    . "$PSScriptRoot/wss-ci/DispatchProof.ps1"
    $title="Promote Integration $IntegrationSha / $CorrelationId"
    $repo='cwru-non-academic/CLI_CSharp_WSS_Application'
    $pages=Invoke-WssGh -Arguments @('api','--paginate','--slurp',"repos/$repo/actions/workflows/promote-integration.yml/runs?event=workflow_dispatch&per_page=100")|ConvertFrom-Json
    $runs=@($pages|ForEach-Object {$_.workflow_runs}|Where-Object display_title -CEQ $title)
    $run=if($runs.Count -eq 1 -and [string]$runs[0].id -cmatch '^[1-9][0-9]*$'){Invoke-WssGh -Arguments @('api',"repos/$repo/actions/runs/$($runs[0].id)")|ConvertFrom-Json}else{$null}
    Invoke-WssCiDispatchProof @{operation='reuse';runs=$runs;run=$run;expected=@{repository=$repo;source_sha=$Approval.cli.source_sha;title=$title}}
}

function Assert-WssCliDispatchIntent([string]$IntegrationSha,[switch]$RequireCurrent) {
    if($env:GITHUB_REPOSITORY -cne 'cwru-non-academic/CSharp_WSS_Integration_Lib'){throw 'Dispatch recovery requires canonical wrapper execution.'}
    . "$PSScriptRoot/wss-ci/DispatchProof.ps1"
    $name="csharp-cli-dispatch-$IntegrationSha"
    $pages=Invoke-WssGh -Arguments @('api','--paginate','--slurp',"repos/cwru-non-academic/CSharp_WSS_Integration_Lib/actions/artifacts?name=$name&per_page=100")|ConvertFrom-Json
    $artifacts=@($pages|ForEach-Object {$_.artifacts}|Where-Object name -CEQ $name)
    $null=Invoke-WssCiDispatchProof @{operation='intent';artifacts=$artifacts;run_id=$env:GITHUB_RUN_ID;attempt=$env:GITHUB_RUN_ATTEMPT;source_sha=$env:GITHUB_SHA;required=[bool]$RequireCurrent}
}

function New-WssCliDispatchRequest([string] $IntegrationSha, [string] $IntegrationPr, [string] $CorrelationId, [string] $ApprovalPath, [string] $RequestPath) {
    if ($IntegrationPr -cnotmatch '^[1-9][0-9]*$' -or $CorrelationId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$') { throw 'Invalid CLI dispatch metadata.' }
    try { Write-WssCiPhaseDiagnostic -Family 'csharp' -Role 'cli' -Operation 'validate-approval' -Status 'started' -ErrorCode 'none' } catch { } # wss-diag
    $approval = Read-WssApproval $ApprovalPath
    try { Write-WssCiPhaseDiagnostic -Family 'csharp' -Role 'cli' -Operation 'validate-approval' -Status 'completed' -ErrorCode 'none' } catch { } # wss-diag
    try { Write-WssCiPhaseDiagnostic -Family 'csharp' -Role 'cli' -Operation 'recheck-source' -Status 'started' -ErrorCode 'none' } catch { } # wss-diag
    Assert-WssFanoutSources $IntegrationSha $approval.cli.source_sha
    try { Write-WssCiPhaseDiagnostic -Family 'csharp' -Role 'cli' -Operation 'recheck-source' -Status 'completed' -ErrorCode 'none' } catch { } # wss-diag
    try { Write-WssCiPhaseDiagnostic -Family 'csharp' -Role 'cli' -Operation 'inspect-reuse' -Status 'started' -ErrorCode 'none' } catch { } # wss-diag
    if (Get-WssCliDispatchReuse $approval $IntegrationSha $CorrelationId) { 'dispatch_needed=false' >> $env:GITHUB_OUTPUT; return }
    try { Write-WssCiPhaseDiagnostic -Family 'csharp' -Role 'cli' -Operation 'inspect-reuse' -Status 'completed' -ErrorCode 'none' } catch { } # wss-diag
    try { Write-WssCiPhaseDiagnostic -Family 'csharp' -Role 'cli' -Operation 'validate-intent' -Status 'started' -ErrorCode 'none' } catch { } # wss-diag
    Assert-WssCliDispatchIntent $IntegrationSha
    try { Write-WssCiPhaseDiagnostic -Family 'csharp' -Role 'cli' -Operation 'validate-intent' -Status 'completed' -ErrorCode 'none' } catch { } # wss-diag
    try { Write-WssCiPhaseDiagnostic -Family 'csharp' -Role 'cli' -Operation 'write-intent' -Status 'started' -ErrorCode 'none' } catch { } # wss-diag
    if (Test-Path -LiteralPath $RequestPath) { throw 'CLI dispatch request must be new.' }
    @{ref=(Get-WssCiChannel);inputs=@{integration_sha=$IntegrationSha;integration_pr=$IntegrationPr;correlation_id=$CorrelationId;approval_json=($approval | ConvertTo-Json -Depth 5 -Compress)}} |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $RequestPath -Encoding utf8
    'dispatch_needed=true' >> $env:GITHUB_OUTPUT
    try { Write-WssCiPhaseDiagnostic -Family 'csharp' -Role 'cli' -Operation 'write-intent' -Status 'completed' -ErrorCode 'none' } catch { } # wss-diag
}
function Send-WssCliDispatch([string]$RequestPath,[string]$ReadToken,[string]$WriteToken) {
    . "$PSScriptRoot/wss-ci/DispatchProof.ps1"
    $request=Get-Content -LiteralPath $RequestPath -Raw|ConvertFrom-Json
    $approval=$request.inputs.approval_json|ConvertFrom-Json
    $owner='cwru-non-academic/CSharp_WSS_Integration_Lib'
    $repository='cwru-non-academic/CLI_CSharp_WSS_Application'
    $sources=@{};$sources[$owner]=$request.inputs.integration_sha;$sources[$repository]=$approval.cli.source_sha
    $authorizeMain={param($request,$approval)
            $source=(& git -C $env:GITHUB_WORKSPACE rev-parse HEAD).Trim()
            if($LASTEXITCODE -ne 0 -or $env:GITHUB_ACTIONS -cne 'true' -or $env:GITHUB_EVENT_NAME -cne 'workflow_dispatch' -or
               $env:GITHUB_REPOSITORY -cne 'cwru-non-academic/CSharp_WSS_Integration_Lib' -or $env:GITHUB_REF -cne 'refs/heads/main' -or
               $env:GITHUB_WORKFLOW_REF -cne "$env:GITHUB_REPOSITORY/.github/workflows/dispatch-cli-promotion.yml@refs/heads/main" -or
               $env:GITHUB_SHA -cne $request.inputs.integration_sha -or $env:GITHUB_WORKFLOW_SHA -cne $env:GITHUB_SHA -or $source -cne $env:GITHUB_SHA){throw 'Main fanout must execute the exact accepted integration workflow source.'}
            $proof=Assert-WssCiWorkflowAuthorization ([string]$approval.candidate.run_id)
            Assert-WssCandidateRecord $proof.candidate $approval
    }
    Send-WssCiApplicationDispatch $repository $RequestPath $ReadToken $WriteToken $owner "csharp-cli-dispatch-$($request.inputs.integration_sha)" $sources -AuthorizeMain $authorizeMain
}
