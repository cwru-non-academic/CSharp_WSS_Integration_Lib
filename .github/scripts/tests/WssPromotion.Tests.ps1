param([string] $ArtifactRoot = '')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../WssPromotion.ps1"
$temp = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $temp | Out-Null
$count = 0
function Assert-Rejected([scriptblock] $Action, [string] $Message) {
    $rejected = $false
    try { & $Action } catch { $rejected = $true; if ($_.Exception.Message -notlike $Message) { throw } }
    if (-not $rejected) { throw "Expected rejection: $Message" }
    $script:count++
}
try {
    $approval = Read-WssApproval "$PSScriptRoot/../../universal-bootstrap.json"
    $marker = Get-WssApprovalMarker $approval
    $roundTrip = Read-WssApprovalMarker $marker (Join-Path $temp 'roundtrip.json')
    if ((Get-WssApprovalMarker $roundTrip) -cne $marker) { throw 'Approval marker round trip changed provenance.' }
    $count++
    foreach ($consumer in @('integration', 'cli')) {
        $record = Read-WssBootstrapProof "$PSScriptRoot/../../promotion-evidence" $consumer $approval (Join-Path $temp $consumer)
        Assert-WssCandidateRecord $record $approval
        $count++
    }
    $otherApproval = $approval | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $otherApproval.cli.preflight_run_id = '1'
    Assert-Rejected { Read-WssBootstrapProof "$PSScriptRoot/../../promotion-evidence" 'cli' $otherApproval (Join-Path $temp 'wrong-proof') } 'Archived proof is restricted*'
    Assert-Rejected { Read-WssApprovalMarker "$marker`n$marker" (Join-Path $temp 'duplicate.json') } 'Missing or ambiguous*'
    Assert-Rejected { Assert-WssCandidateRecord ([pscustomobject]@{ repository='other/repo' }) $approval } 'Candidate provenance mismatch*'
    foreach ($field in @('run_id', 'artifact_id', 'commit', 'archive', 'sha256')) {
        $record = $approval.candidate | ConvertTo-Json | ConvertFrom-Json
        $record.$field = 'wrong'
        Assert-Rejected { Assert-WssCandidateRecord $record $approval } 'Candidate provenance mismatch*'
    }
    Assert-WssPaths @('lib/WSS.Transport.Serial.dll', 'lib/wss-candidate.json')
    $count++
    Assert-Rejected { Assert-WssPaths @('lib/a.dll', 'src/StimulationController.cs') } 'Unexpected promotion path*'
    Assert-Rejected { Assert-WssPaths @() } 'Promotion diff is empty*'
    Assert-WssPaths @('lib/a.dll', 'src/Wss.CSharpImplementation.csproj') @('src/Wss.CSharpImplementation.csproj')
    Assert-Rejected { Assert-WssPaths @('lib/a.dll', 'src/StimulationController.cs') @('src/Wss.CSharpImplementation.csproj') } 'Unexpected promotion path*'
    $count++

    $originalProject = 'ac4ca9ca0371f2896f4a29b4f3ec1db55025f363'
    $alignedProject = 'e7bcaa356b22dc7b213c90d8ff2f6c5a8e5d6155'
    $candidateNewtonsoft = '8c1dd5c184b4e2e7ead06971ff3ebcb46783be972292d1deb1061744369b4d80'
    Assert-WssNewtonsoftTestAlignment $originalProject $alignedProject $candidateNewtonsoft
    $count++
    Assert-Rejected { Assert-WssNewtonsoftTestAlignment ('0'*40) $alignedProject $candidateNewtonsoft } 'Test dependency change is not*'
    Assert-Rejected { Assert-WssNewtonsoftTestAlignment $originalProject ('0'*40) $candidateNewtonsoft } 'Test dependency change is not*'
    Assert-Rejected { Assert-WssNewtonsoftTestAlignment $originalProject $alignedProject ('0'*64) } 'Test dependency change is not*'

    # Metadata-only fakes: no candidate binaries, workflow dispatches or PRs are created.
    function Invoke-WssGh([string[]] $Arguments) {
        if ($Arguments[1] -like '*/pulls/*') {
            @{ merged=$script:merged; merge_commit_sha=$script:mergeSha; base=@{ref='dev';repo=@{full_name='cwru-non-academic/CSharp_WSS_Integration_Lib'}};
                head=@{sha='1'*40;ref='automation/wss-test';repo=@{full_name='cwru-non-academic/CSharp_WSS_Integration_Lib'}} } | ConvertTo-Json -Depth 5
        } elseif ($Arguments[1] -like '*/compare/*') {
            @{status=$script:comparison} | ConvertTo-Json
        } elseif ($Arguments[-1] -like '*/workflows/wss-compatibility.yml/runs?*') {
            ConvertTo-Json -InputObject @(@{workflow_runs=$script:normalRuns}) -Depth 8
        } elseif ($Arguments[-1] -like '*/actions/runs/*/jobs?*') {
            ConvertTo-Json -InputObject @(@{jobs=$script:normalJobs}) -Depth 5
        } elseif ($Arguments[1] -like '*/contents/lib/wss-candidate.json?*') {
            @{content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($approval | ConvertTo-Json -Depth 5)))} | ConvertTo-Json
        } else { throw 'Unexpected API call in rejection test.' }
    }
    $script:merged = $false
    $script:mergeSha = '2'*40
    Assert-Rejected { Assert-WssMergedIntegration $script:mergeSha '1' $approval } 'Gitlink must target*'
    $script:merged = $true
    Assert-Rejected { Assert-WssMergedIntegration ('3'*40) '1' $approval } 'Gitlink must target*'
    $script:comparison = 'diverged'
    Assert-Rejected { Assert-WssMergedIntegration $script:mergeSha '1' $approval } 'Integration merge is not contained*'
    # GitHub may omit PR associations after merge; exact run identity remains required.
    $script:comparison = 'identical'
    $normalRun = [pscustomobject]@{
        id=10; repository=@{full_name='cwru-non-academic/CSharp_WSS_Integration_Lib'}
        head_repository=@{full_name='cwru-non-academic/CSharp_WSS_Integration_Lib'}
        path='.github/workflows/wss-compatibility.yml'; event='pull_request'
        head_sha='1'*40; head_branch='automation/wss-test'
        status='completed'; conclusion='success'; pull_requests=@()
    }
    $script:normalRuns = @($normalRun)
    $script:normalJobs = @('Integration behavioral tests', 'Integration compatibility (Windows)',
        'Integration compatibility (Ubuntu)', 'Integration compatibility (macOS)') | ForEach-Object {
        [pscustomobject]@{name=$_;conclusion='success'}
    }
    $validated = Assert-WssMergedIntegration $script:mergeSha '1' $approval
    if ($validated.head.sha -cne ('1'*40)) { throw 'Merged PR final head changed.' }
    $count++
    foreach ($field in @('head_sha', 'head_branch', 'event', 'path', 'repository', 'head_repository', 'pull_requests')) {
        $bad = $normalRun | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        if ($field -in @('repository', 'head_repository')) { $bad.$field.full_name = 'other/repository' }
        elseif ($field -ceq 'pull_requests') { $bad.pull_requests = @(@{number=2}) }
        else { $bad.$field = 'wrong' }
        $script:normalRuns = @($bad)
        Assert-Rejected { Assert-WssMergedIntegration $script:mergeSha '1' $approval } 'Merged Integration PR lacks successful latest*'
    }
    $mixed = $normalRun | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $mixed.pull_requests = @(@{number=1}, @{number=2})
    $script:normalRuns = @($mixed)
    Assert-Rejected { Assert-WssMergedIntegration $script:mergeSha '1' $approval } 'Merged Integration PR lacks successful latest*'
    $normalRun.pull_requests = @(@{number=1})
    $script:normalRuns = @($normalRun)
    $null = Assert-WssMergedIntegration $script:mergeSha '1' $approval
    $count++
    $normalRun.pull_requests = @()
    foreach ($state in @('in_progress', 'completed')) {
        $latest = $normalRun | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $latest.id = 11; $latest.status = $state; $latest.conclusion = 'failure'
        $script:normalRuns = @($normalRun, $latest)
        Assert-Rejected { Assert-WssMergedIntegration $script:mergeSha '1' $approval } 'Merged Integration PR lacks successful latest*'
    }
    $script:normalRuns = @($normalRun)
    $script:normalJobs[0].conclusion = 'failure'
    Assert-Rejected { Assert-WssMergedIntegration $script:mergeSha '1' $approval } 'Required normal Integration CI job did not succeed*'
    Remove-Item Function:Invoke-WssGh
    . "$PSScriptRoot/../WssPromotion.ps1"

    # Automatic handoff contracts: fake only the GitHub transport, never dispatch remotely.
    . "$PSScriptRoot/../WssAutomatic.ps1"
    $producer = [pscustomobject]@{ repository=@{full_name='cwru-non-academic/WSSCore'}; path='.github/workflows/artifacts.yml'; event='push'; head_branch='dev'; head_sha=$approval.candidate.commit }
    Assert-WssAutomaticProducer $producer $approval.candidate.commit
    foreach ($field in @('event', 'head_branch', 'head_sha')) {
        $bad = $producer | ConvertTo-Json | ConvertFrom-Json
        $bad.$field = 'untrusted'
        Assert-Rejected { Assert-WssAutomaticProducer $bad $approval.candidate.commit } 'Automatic promotion requires*'
    }
    $script:runs = @{}
    $script:dispatches = @()
    $script:apiFailure = $false
    $script:dispatchRace = $false
    $script:missingRun = $false
    $script:duplicateRuns = $false
    function Invoke-WssDispatch([string] $Repository, [string] $Body) {
        $request = $Body | ConvertFrom-Json
        $script:dispatches += $request
        if ($script:missingRun) { return }
        $sha = if ($Repository -like '*/CLI_*') { '4'*40 } else { '3'*40 }
        if ($script:dispatchRace) { $sha = '5'*40 }
        $script:runs[$Repository] = [pscustomobject]@{
            id = $(if ($Repository -like '*/CLI_*') { '42' } else { '41' })
            repository = @{full_name=$Repository}; path='.github/workflows/wss-preflight.yml'
            head_sha=$sha; event='workflow_dispatch'; status='completed'; conclusion='success'
            display_title="WSS preflight $($request.inputs.wss_run_id) / $($request.inputs.correlation_id)"
        }
    }
    function Invoke-WssGh([string[]] $Arguments) {
        if ($script:apiFailure) { throw 'Simulated GitHub permission/network failure.' }
        $endpoint = $Arguments[-1]
        foreach ($repo in @('cwru-non-academic/CSharp_WSS_Integration_Lib', 'cwru-non-academic/CLI_CSharp_WSS_Application')) {
            if ($endpoint -like "repos/$repo/*") {
                if ($endpoint -like '*/branches/dev') { return (@{commit=@{sha=$(if ($repo -like '*/CLI_*') { '4'*40 } else { '3'*40 })}} | ConvertTo-Json -Depth 3) }
                if ($endpoint -like '*/workflows/wss-preflight.yml/runs?*') {
                    $found = @($(if ($script:runs.ContainsKey($repo)) { $script:runs[$repo] }))
                    if ($script:duplicateRuns) { $found += $found }
                    return (ConvertTo-Json -InputObject @(@{workflow_runs=$found}) -Depth 6)
                }
                if ($endpoint -like '*/actions/runs/*') { return ($script:runs[$repo] | ConvertTo-Json -Depth 4) }
            }
        }
        throw "Unexpected automatic API call: $endpoint"
    }
    $automatic = New-WssAutomaticApproval $approval.candidate 'wss-test-candidate'
    if ($script:dispatches.Count -ne 2 -or $automatic.integration.source_sha -cne ('3'*40) -or $automatic.cli.source_sha -cne ('4'*40)) { throw 'Automatic source/dispatch binding failed.' }
    foreach ($request in $script:dispatches) {
        if ($request.ref -cne 'dev' -or $request.inputs.wss_run_id -cne $approval.candidate.run_id -or
            $request.inputs.wss_commit -cne $approval.candidate.commit -or $request.inputs.wss_sha256 -cne $approval.candidate.sha256 -or
            $request.inputs.wss_archive -cne $approval.candidate.archive) { throw 'Automatic preflights did not receive the same immutable candidate.' }
    }
    if ($script:dispatches[1].inputs.integration_sha -cne $automatic.integration.source_sha) { throw 'CLI dispatch did not pin Integration source.' }
    $again = New-WssAutomaticApproval $approval.candidate 'wss-test-candidate'
    if ($script:dispatches.Count -ne 2 -or (Get-WssApprovalMarker $again) -cne (Get-WssApprovalMarker $automatic)) { throw 'Replay redispatched or changed approval.' }
    $count++
    $integrationRepo = 'cwru-non-academic/CSharp_WSS_Integration_Lib'
    $script:runs[$integrationRepo].conclusion = 'failure'
    Assert-Rejected { New-WssAutomaticApproval $approval.candidate 'wss-test-candidate' } 'Required run*failed*'
    $script:runs[$integrationRepo].conclusion = 'success'
    $script:runs[$integrationRepo].head_sha = '6'*40
    Assert-Rejected { Wait-WssExactRun $integrationRepo '41' ('3'*40) 'wss-preflight.yml' 'workflow_dispatch' } 'Run identity/source mismatch*'
    $script:runs[$integrationRepo].head_sha = '3'*40
    $script:runs[$integrationRepo].status = 'in_progress'
    Assert-Rejected { Wait-WssExactRun $integrationRepo '41' ('3'*40) 'wss-preflight.yml' 'workflow_dispatch' -TimeoutSeconds 0 } 'Timed out waiting*'
    $script:apiFailure = $true
    $before = $script:dispatches.Count
    Assert-Rejected { Start-WssCorrelatedPreflight $integrationRepo $approval.candidate 'different-candidate' } 'Simulated GitHub permission/network failure*'
    if ($script:dispatches.Count -ne $before) { throw 'API failure was treated as an absent run.' }
    $script:apiFailure = $false
    $script:runs.Clear()
    $script:dispatchRace = $true
    Assert-Rejected { Start-WssCorrelatedPreflight $integrationRepo $approval.candidate 'race-candidate' } 'Downstream dev moved*'
    $script:duplicateRuns = $true
    Assert-Rejected { Get-WssCorrelatedPreflight $integrationRepo "WSS preflight $($approval.candidate.run_id) / race-candidate" } 'Ambiguous correlated preflight*'
    $script:duplicateRuns = $false
    $script:dispatchRace = $false
    $script:missingRun = $true
    $script:runs.Clear()
    $before = $script:dispatches.Count
    Assert-Rejected { Start-WssCorrelatedPreflight $integrationRepo $approval.candidate 'missing-candidate' -DiscoverySeconds 0 } 'Dispatched preflight missing*'
    if ($script:dispatches.Count -ne ($before + 1)) { throw 'Missing run caused redundant dispatches.' }
    $script:missingRun = $false
    $secondCandidate = $approval.candidate | ConvertTo-Json | ConvertFrom-Json
    $secondCandidate.run_id = '99'
    $secondCandidate.artifact_id = '100'
    $secondCandidate.commit = '7'*40
    $secondCandidate.sha256 = '8'*64
    $second = New-WssAutomaticApproval $secondCandidate 'second-candidate'
    foreach ($request in @($script:dispatches[-2], $script:dispatches[-1])) {
        if ($request.inputs.wss_run_id -cne '99' -or $request.inputs.wss_sha256 -cne ('8'*64) -or $request.inputs.wss_commit -cne ('7'*40)) { throw 'Nearby candidates mixed dispatch data.' }
    }
    Assert-WssCandidateRecord $secondCandidate $second
    $count++
    Remove-Item Function:Invoke-WssGh, Function:Invoke-WssDispatch
    . "$PSScriptRoot/../WssAutomatic.ps1"

    # A green but mismatched preflight and expired producer artifact are not authority.
    $script:expiredArtifact = $false
    function Invoke-WssGh([string[]] $Arguments) {
        $c = $approval.candidate
        if ($Arguments[0] -ceq 'run') {
            $destination = $Arguments[-1]
            New-Item -ItemType Directory -Path $destination | Out-Null
            $wrong = $c | ConvertTo-Json | ConvertFrom-Json
            $wrong.sha256 = '0'*64
            $wrong | ConvertTo-Json | Set-Content (Join-Path $destination 'candidate.json')
            return
        }
        if ($Arguments[1] -like '*/actions/artifacts/*') {
            return (@{name='universal-release-assets';expired=$script:expiredArtifact;workflow_run=@{id=$c.run_id;head_sha=$c.commit}} | ConvertTo-Json)
        }
        $repo = if ($Arguments[1] -like '*/WSSCore/*') { $c.repository } else { 'cwru-non-academic/CSharp_WSS_Integration_Lib' }
        $isProducer = $repo -ceq $c.repository
        return (@{repository=@{full_name=$repo};path=$(if ($isProducer) { '.github/workflows/artifacts.yml' } else { '.github/workflows/wss-preflight.yml' });
            head_sha=$(if ($isProducer) { $c.commit } else { $approval.integration.source_sha });status='completed';conclusion='success';
            event=$(if ($isProducer) { 'push' } else { 'workflow_dispatch' })} | ConvertTo-Json)
    }
    Assert-Rejected { Assert-WssApproval $approval (Join-Path $temp 'wrong-preflight-evidence') } 'Candidate provenance mismatch: sha256'
    $script:expiredArtifact = $true
    Assert-Rejected { Assert-WssApproval $approval (Join-Path $temp 'expired-evidence') } 'Artifact ID is not the approved producer artifact*'
    Remove-Item Function:Invoke-WssGh
    . "$PSScriptRoot/../WssAutomatic.ps1"

    # Payload-only no-op detection, independent of promotion metadata. Not runtime DLL fakes.
    . "$PSScriptRoot/../Universal-WssFiles.ps1"
    $payload = Join-Path $temp 'payload'
    $lib = Join-Path $temp 'lib'
    foreach ($root in @($payload, $lib)) {
        foreach ($relative in $WssUniversalFiles) {
            $path = Join-Path $root $relative
            New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
            'test payload bytes' | Set-Content -LiteralPath $path
        }
    }
    Write-WssApproval $approval (Join-Path $lib 'wss-candidate.json')
    if (-not (Test-WssPayloadEqual $lib $payload)) { throw 'Identical payload with old approval did not produce a no-op.' }
    'different payload bytes' | Set-Content (Join-Path $payload 'WSS_Core_Interface.dll')
    if (Test-WssPayloadEqual $lib $payload) { throw 'Different universal candidate was treated as a no-op.' }
    Copy-Item (Join-Path $lib 'WSS_Core_Interface.dll') (Join-Path $payload 'WSS_Core_Interface.dll') -Force
    'stale' | Set-Content (Join-Path $lib 'obsolete.dll')
    if (Test-WssPayloadEqual $lib $payload) { throw 'Incomplete/extra committed dependencies were treated as a no-op.' }
    $count++

    if ($ArtifactRoot) {
        Write-WssApproval $approval (Join-Path $temp 'approval.json')
        & "$PSScriptRoot/../New-WssLib.ps1" -ArtifactRoot $ArtifactRoot -ApprovalFile (Join-Path $temp 'approval.json') -Destination (Join-Path $temp 'first')
        & "$PSScriptRoot/../New-WssLib.ps1" -ArtifactRoot $ArtifactRoot -ApprovalFile (Join-Path $temp 'approval.json') -Destination (Join-Path $temp 'second')
        & git diff --no-index --quiet -- (Join-Path $temp 'first') (Join-Path $temp 'second')
        if ($LASTEXITCODE -ne 0) { throw 'Universal staging is not deterministic.' }
        Assert-Rejected { & "$PSScriptRoot/../New-WssLib.ps1" -ArtifactRoot $ArtifactRoot -ApprovalFile (Join-Path $temp 'approval.json') -Destination (Join-Path $temp 'first') } 'Destination must be new*'
        'wrong' | Set-Content (Join-Path $temp 'first/WSS.Transport.Serial.dll')
        Assert-Rejected { Assert-WssLib (Join-Path $temp 'first') $ArtifactRoot $approval } 'Committed universal bytes differ*'
        $count++
    }
    "PASS: $count focused promotion safety checks (ArtifactRoot supplied: $([bool]$ArtifactRoot))."
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
