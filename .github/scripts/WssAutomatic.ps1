Set-StrictMode -Version Latest
. "$PSScriptRoot/wss-ci/Preflight.ps1"
. "$PSScriptRoot/WssPromotion.ps1"

function Assert-WssCandidateNotOlder($Candidate, [string] $ExpectedReceiverSha) {
    $repo='cwru-non-academic/CSharp_WSS_Integration_Lib'
    $head=Invoke-WssGh -Arguments @('api',"repos/$repo/git/ref/heads/$(Get-WssCiChannel)") | ConvertFrom-Json
    if ($ExpectedReceiverSha -cnotmatch '^[0-9a-f]{40}$' -or $head.object.sha -cne $ExpectedReceiverSha) { throw 'Integration dev moved since candidate validation; require fresh evidence.' }
    $file=Invoke-WssGh -Arguments @('api',"repos/$repo/contents/lib/wss-candidate.json?ref=$ExpectedReceiverSha") | ConvertFrom-Json
    if ($file.type -cne 'file' -or $file.encoding -cne 'base64') { throw 'Installed candidate provenance is unreadable.' }
    $record=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($file.content)) | ConvertFrom-Json
    $installed=$record.candidate
    if ($record.schema -ne 2 -or $installed.repository -cne 'cwru-non-academic/WSSCore' -or $Candidate.repository -cne $installed.repository -or
        $installed.commit -cnotmatch '^[0-9a-f]{40}$' -or $Candidate.commit -cnotmatch '^[0-9a-f]{40}$' -or
        [string]$installed.run_id -cnotmatch '^[1-9][0-9]*$' -or [string]$Candidate.run_id -cnotmatch '^[1-9][0-9]*$') { throw 'Installed/candidate producer identities are invalid.' }
    if ($Candidate.run_id -ceq $installed.run_id) {
        Assert-WssCandidateRecord $installed ([pscustomobject]@{candidate=$Candidate})
        return
    }
    if ($Candidate.commit -ceq $installed.commit) {
        if ([bigint]$Candidate.run_id -lt [bigint]$installed.run_id) { throw 'Candidate would roll back the installed producer run.' }
        return
    }
    $comparison=Invoke-WssGh -Arguments @('api',"repos/cwru-non-academic/WSSCore/compare/$($installed.commit)...$($Candidate.commit)") | ConvertFrom-Json
    if ($comparison.status -cne 'ahead' -or $comparison.base_commit.sha -cne $installed.commit -or $comparison.merge_base_commit.sha -cne $installed.commit) { throw 'Candidate would roll back or diverge from the installed Core source.' }
}

function Assert-WssAutomaticProducer($Run, [string] $Commit) {
    if ($Run.repository.full_name -cne 'cwru-non-academic/WSSCore' -or
        $Run.head_repository.full_name -cne 'cwru-non-academic/WSSCore' -or
        $Run.path -cne '.github/workflows/artifacts.yml' -or $Run.event -cne 'push' -or
        $Run.head_branch -cne (Get-WssCiChannel) -or $Run.head_sha -cne $Commit) {
        throw 'Automatic promotion requires the exact trusted WSSCore dev push producer.'
    }
}

function Wait-WssExactRun([string]$Repository,[string]$RunId,[string]$SourceSha,[string]$Workflow,[string]$Event,[int]$TimeoutSeconds=2400) {
    Wait-WssCiRun $Repository $RunId $SourceSha $Workflow $Event $TimeoutSeconds
}





function Start-WssCorrelatedPreflight([string]$Repository,$Candidate,[string]$CorrelationId,[string]$IntegrationSha='',[int]$DiscoverySeconds=180) {
    if($Repository -cnotin @('cwru-non-academic/CSharp_WSS_Integration_Lib','cwru-non-academic/CLI_CSharp_WSS_Application')){throw 'Unknown C# preflight repository.'}
    Start-WssCiPreflight -Repository $Repository -Candidate $Candidate -WrapperSha $IntegrationSha -CorrelationId $CorrelationId -DiscoverySeconds $DiscoverySeconds -DispatchToken $env:GH_TOKEN
}

function New-WssAutomaticApproval($Candidate, [string] $CorrelationId) {
    $integrationRepo = 'cwru-non-academic/CSharp_WSS_Integration_Lib'
    $cliRepo = 'cwru-non-academic/CLI_CSharp_WSS_Application'
    $integration = Start-WssCorrelatedPreflight $integrationRepo $Candidate $CorrelationId
    $cli = Start-WssCorrelatedPreflight $cliRepo $Candidate $CorrelationId $integration.head_sha
    $integration = Wait-WssExactRun $integrationRepo ([string]$integration.id) $integration.head_sha 'wss-preflight.yml' 'workflow_dispatch'
    $cli = Wait-WssExactRun $cliRepo ([string]$cli.id) $cli.head_sha 'wss-preflight.yml' 'workflow_dispatch'
    [pscustomobject][ordered]@{
        schema = 2
        candidate = $Candidate
        integration = @{ source_sha = $integration.head_sha; preflight_run_id = [string]$integration.id }
        cli = @{ source_sha = $cli.head_sha; preflight_run_id = [string]$cli.id }
    }
}

function Test-WssPayloadEqual([string] $Lib, [string] $ArtifactRoot) {
    . "$PSScriptRoot/Universal-WssFiles.ps1"
    $root = (Resolve-Path -LiteralPath $Lib).Path
    $actual = @(Get-ChildItem -LiteralPath $root -File -Recurse | ForEach-Object { $_.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/') })
    if ('wss-candidate.json' -cnotin $actual) { return $false }
    try {
        $selectedFiles = @(Get-WssUniversalFiles @($actual | Where-Object { $_ -cne 'wss-candidate.json' }))
        $sourceFiles = @(Read-WssUniversalFiles $ArtifactRoot)
    } catch { return $false }
    if (@(Compare-Object $selectedFiles $sourceFiles -CaseSensitive).Count -ne 0) { return $false }
    Assert-WssMacOSPayload $ArtifactRoot $sourceFiles
    # Require valid committed provenance; a no-op preserves it instead of manufacturing a metadata-only PR.
    $null = Read-WssApproval (Join-Path $root 'wss-candidate.json')
    foreach ($relative in $selectedFiles) {
        if ((Get-FileHash -LiteralPath (Join-Path $root $relative)).Hash -cne
            (Get-FileHash -LiteralPath (Join-Path $ArtifactRoot $relative)).Hash) { return $false }
    }
    return $true
}
