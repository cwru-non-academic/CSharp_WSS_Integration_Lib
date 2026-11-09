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
function Assert-WssCiDispatchArtifacts([string]$Repository,[string]$Name,[switch]$RequireCurrent) {
    . "$PSScriptRoot/Process.ps1"
    $pages=Invoke-WssCiProcess -Executable gh -Arguments @('api','--paginate','--slurp',"repos/$Repository/actions/artifacts?name=$Name&per_page=100")|ConvertFrom-Json
    $artifacts=@($pages|ForEach-Object {$_.artifacts}|Where-Object name -CEQ $Name)
    $null=Invoke-WssCiDispatchProof @{operation='intent';artifacts=$artifacts;run_id=$env:GITHUB_RUN_ID;attempt=$env:GITHUB_RUN_ATTEMPT;source_sha=$env:GITHUB_SHA;required=[bool]$RequireCurrent}
}
function Get-WssCiApplicationDispatchMapping([string]$Repository,[string]$OwnerRepository,$Request,$Sources,[string]$IntentName) {
    $mappings=@{
        'cwru-non-academic/CLI_CSharp_WSS_Application'=@('CSharp','csharp','cli','integration_sha')
        'cwru-non-academic/GUI_Unity_WSS_Application'=@('Unity','unity','gui','wrapper_sha')
        'cwru-non-academic/CLI_Python_WSS_Application'=@('Python','python','cli','wrapper_sha')
        'cwru-non-academic/ROS_Python_WSS_Application'=@('Python','python','ros','wrapper_sha')
        'cwru-non-academic/CLI_Matlab_WSS_Application'=@('Matlab','matlab','cli','wrapper_sha')
    }
    if(!$mappings.ContainsKey($Repository)){throw 'Unregistered application dispatch destination.'}
    $family,$name,$role,$sourceField=$mappings[$Repository]
    if($OwnerRepository -cne "cwru-non-academic/${family}_WSS_Integration_Lib" -or $env:GITHUB_REPOSITORY -cne $OwnerRepository){throw 'Application dispatch requires canonical wrapper execution.'}
    $approval=$Request.inputs.approval_json|ConvertFrom-Json
    $wrapper=[string]$Request.inputs.$sourceField
    $target=[string]$approval.$role.source_sha
    if($wrapper -cnotmatch '^[a-f0-9]{40}$' -or $target -cnotmatch '^[a-f0-9]{40}$' -or
       $Sources -isnot [System.Collections.IDictionary] -or $Sources.Count -ne 2 -or
       $Sources[$OwnerRepository] -cne $wrapper -or $Sources[$Repository] -cne $target){throw 'Application dispatch source mapping differs from the approved request.'}
    if($IntentName -cne "$name-$role-dispatch-$wrapper"){throw 'Application dispatch intent name differs from the approved request.'}
    if($family -ceq 'CSharp'){
        $correlation=[string]$Request.inputs.correlation_id
        if($correlation -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'){throw 'Invalid application dispatch correlation.'}
    }else{
        if([string]$approval.candidate.run_id -cnotmatch '^[1-9][0-9]*$' -or [string]$approval.candidate.artifact_id -cnotmatch '^[1-9][0-9]*$'){throw 'Invalid application dispatch candidate identity.'}
        $correlation="wss-$($approval.candidate.run_id)-$($approval.candidate.artifact_id)"
    }
    @{family=$family;approval=$approval;source_sha=$target;title="Promote Integration $wrapper / $correlation"}
}
function Assert-WssCiApplicationDispatchSources($Sources,[string]$Channel) {
    foreach($repo in $Sources.Keys) {
        $head=Invoke-WssCiProcess -Executable gh -Arguments @('api',"repos/$repo/git/ref/heads/$Channel")|ConvertFrom-Json
        if($head.object.sha -cne $Sources[$repo]){throw 'Fanout source moved immediately before application writes.'}
    }
}
function Get-WssCiApplicationDispatchReuse([string]$Repository,$Mapping) {
    $pages=Invoke-WssCiProcess -Executable gh -Arguments @('api','--paginate','--slurp',"repos/$Repository/actions/workflows/promote-integration.yml/runs?event=workflow_dispatch&per_page=100")|ConvertFrom-Json
    $runs=@($pages|ForEach-Object {$_.workflow_runs}|Where-Object display_title -CEQ $Mapping.title)
    $run=if($runs.Count -eq 1 -and [string]$runs[0].id -cmatch '^[1-9][0-9]*$'){
        Invoke-WssCiProcess -Executable gh -Arguments @('api',"repos/$Repository/actions/runs/$($runs[0].id)")|ConvertFrom-Json
    }else{$null}
    Invoke-WssCiDispatchProof @{operation='reuse';runs=$runs;run=$run;expected=@{repository=$Repository;source_sha=$Mapping.source_sha;title=$Mapping.title}}
}
function Send-WssCiApplicationDispatch([string]$Repository,[string]$RequestPath,[string]$ReadToken,[string]$WriteToken,[string]$OwnerRepository,[string]$IntentName,$Sources,[scriptblock]$AuthorizeMain) {
    if(!$ReadToken -or !$WriteToken){throw 'Separate read and target-only Actions-write tokens required.'}
    . "$PSScriptRoot/Process.ps1"
    $saved=$env:GH_TOKEN
    try {
        $env:GH_TOKEN=$ReadToken
        $channel=Get-WssCiChannel
        $request=Get-Content -LiteralPath $RequestPath -Raw|ConvertFrom-Json
        if($request.ref -cne $channel){throw 'Application dispatch ref differs from the verified target channel.'}
        $mapping=Get-WssCiApplicationDispatchMapping $Repository $OwnerRepository $request $Sources $IntentName
        # Observational helper loading must preserve native status, including absence.
        $diagnosticExit = Get-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
        $diagnosticExitValue = if ($null -ne $diagnosticExit) { $diagnosticExit.Value } else { $null }
        try { $null = . "$PSScriptRoot/PhaseDiagnostics.ps1" } catch { }
        finally {
            if ($null -ne $diagnosticExit) { $global:LASTEXITCODE = $diagnosticExitValue }
            else { Remove-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
        }
        $diagnosticFamily = $mapping.family.ToLowerInvariant()
        $diagnosticRole = if ($Repository -ceq 'cwru-non-academic/ROS_Python_WSS_Application') { 'ros' } elseif ($mapping.family -ceq 'Unity') { 'gui' } else { 'cli' }
        if($AuthorizeMain -and $mapping.family -cnotin @('CSharp','Unity')){throw 'Only peer adapters supply family main authorization.'}
        if($channel -ceq 'main'){
            if($mapping.family -cin @('CSharp','Unity') -and !$AuthorizeMain){throw 'Peer family main authorization callback required.'}
            if($AuthorizeMain){$null=& $AuthorizeMain $request $mapping.approval}
            else{$null=Assert-WssCiWorkflowAuthorization $env:PRODUCER_RUN_ID}
        }
        try { Write-WssCiPhaseDiagnostic -Family $diagnosticFamily -Role $diagnosticRole -Operation 'recheck-source' -Status 'started' -ErrorCode none } catch { }
        Assert-WssCiApplicationDispatchSources $Sources $channel
        try { Write-WssCiPhaseDiagnostic -Family $diagnosticFamily -Role $diagnosticRole -Operation 'recheck-source' -Status 'completed' -ErrorCode none } catch { }
        # An exact successful concurrent run is a no-op, never a replay permission.
        try { Write-WssCiPhaseDiagnostic -Family $diagnosticFamily -Role $diagnosticRole -Operation 'recheck-reuse' -Status 'started' -ErrorCode none } catch { }
        if(Get-WssCiApplicationDispatchReuse $Repository $mapping){
            try { Write-WssCiPhaseDiagnostic -Family $diagnosticFamily -Role $diagnosticRole -Operation 'recheck-reuse' -Status 'completed' -ErrorCode none } catch { }
            return 'reused'
        }
        try { Write-WssCiPhaseDiagnostic -Family $diagnosticFamily -Role $diagnosticRole -Operation 'recheck-reuse' -Status 'completed' -ErrorCode none } catch { }
        try { Write-WssCiPhaseDiagnostic -Family $diagnosticFamily -Role $diagnosticRole -Operation 'recheck-intent' -Status 'started' -ErrorCode none } catch { }
        Assert-WssCiDispatchArtifacts $OwnerRepository $IntentName -RequireCurrent
        try { Write-WssCiPhaseDiagnostic -Family $diagnosticFamily -Role $diagnosticRole -Operation 'recheck-intent' -Status 'completed' -ErrorCode none } catch { }
        # Keep source checks after both reuse and durable-intent reads on both channels.
        try { Write-WssCiPhaseDiagnostic -Family $diagnosticFamily -Role $diagnosticRole -Operation 'recheck-source' -Status 'started' -ErrorCode none } catch { }
        Assert-WssCiApplicationDispatchSources $Sources $channel
        try { Write-WssCiPhaseDiagnostic -Family $diagnosticFamily -Role $diagnosticRole -Operation 'recheck-source' -Status 'completed' -ErrorCode none } catch { }
        $env:GH_TOKEN=$WriteToken
        $null=Invoke-WssCiProcess -Executable gh -Arguments @('api','--method','POST',"repos/$Repository/actions/workflows/promote-integration.yml/dispatches",'--input',$RequestPath) -FailureMessage 'Application dispatch failed or uncertain; inspect before replay'
        return 'dispatched'
    } finally {$env:GH_TOKEN=$saved}
}
