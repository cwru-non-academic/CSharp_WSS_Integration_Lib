Set-StrictMode -Version Latest
. "$PSScriptRoot/WssPromotion.ps1"

function Assert-WssAutomaticProducer($Run, [string] $Commit) {
    if ($Run.repository.full_name -cne 'cwru-non-academic/WSSCore' -or
        $Run.path -cne '.github/workflows/artifacts.yml' -or $Run.event -cne 'push' -or
        $Run.head_branch -cne 'dev' -or $Run.head_sha -cne $Commit) {
        throw 'Automatic promotion requires the exact trusted WSSCore dev push producer.'
    }
}

function Wait-WssExactRun([string] $Repository, [string] $RunId, [string] $SourceSha,
    [string] $Workflow, [string] $Event, [int] $TimeoutSeconds = 2400) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $run = Invoke-WssGh @('api', "repos/$Repository/actions/runs/$RunId") | ConvertFrom-Json
        if ($run.repository.full_name -cne $Repository -or $run.path -cne ".github/workflows/$Workflow" -or
            $run.head_sha -cne $SourceSha -or $run.event -cne $Event) { throw 'Run identity/source mismatch; promotion stopped.' }
        if ($run.status -ceq 'completed') {
            if ($run.conclusion -cne 'success') { throw "Required run $Repository/$RunId failed: $($run.conclusion)." }
            return $run
        }
        if ([DateTime]::UtcNow -ge $deadline) { throw "Timed out waiting for $Repository/$RunId; no promotion authorized." }
        Start-Sleep -Seconds 15
    } while ($true)
}

function Get-WssCorrelatedPreflight([string] $Repository, [string] $Title) {
    $pages = Invoke-WssGh @('api', '--paginate', '--slurp', "repos/$Repository/actions/workflows/wss-preflight.yml/runs?event=workflow_dispatch&per_page=100") | ConvertFrom-Json
    $runs = @($pages | ForEach-Object { $_.workflow_runs } | Where-Object { $_.display_title -ceq $Title })
    if ($runs.Count -gt 1) { throw "Ambiguous correlated preflight in $Repository; refusing to select a green run." }
    if ($runs.Count -eq 1) { return $runs[0] }
    return $null
}

function Invoke-WssDispatch([string] $Repository, [string] $Body) {
    $Body | & gh api --method POST "repos/$Repository/actions/workflows/wss-preflight.yml/dispatches" --input -
    if ($LASTEXITCODE -ne 0) { throw "Preflight dispatch failed in $Repository; check App Actions-write permission. Dispatch is not retried automatically." }
}

function Start-WssCorrelatedPreflight([string] $Repository, $Candidate, [string] $CorrelationId,
    [string] $IntegrationSha = '', [int] $DiscoverySeconds = 180) {
    $title = "WSS preflight $($Candidate.run_id) / $CorrelationId"
    $existing = Get-WssCorrelatedPreflight $Repository $title
    # Replays retain original tested sources even after dev advances. Never redispatch a failed run.
    if ($null -ne $existing) { return $existing }
    $branch = Invoke-WssGh @('api', "repos/$Repository/branches/dev") | ConvertFrom-Json
    $sha = $branch.commit.sha
    if ($sha -cnotmatch '^[0-9a-f]{40}$') { throw 'Cannot resolve exact downstream dev source.' }
    $inputs = @{
        wss_producer_repository = $Candidate.repository; wss_run_id = [string]$Candidate.run_id
        wss_commit = $Candidate.commit; wss_archive = $Candidate.archive; wss_sha256 = $Candidate.sha256
        correlation_id = $CorrelationId
    }
    if ($IntegrationSha) { $inputs.integration_sha = $IntegrationSha }
    $body = @{ ref = 'dev'; inputs = $inputs } | ConvertTo-Json -Depth 4 -Compress
    Invoke-WssDispatch $Repository $body
    $deadline = [DateTime]::UtcNow.AddSeconds($DiscoverySeconds)
    do {
        $run = Get-WssCorrelatedPreflight $Repository $title
        if ($null -ne $run) {
            if ($run.head_sha -cne $sha) { throw 'Downstream dev moved during dispatch; refusing an unpinned source.' }
            return $run
        }
        if ([DateTime]::UtcNow -ge $deadline) { throw "Dispatched preflight missing in $Repository; inspect before replaying. No promotion authorized." }
        Start-Sleep -Seconds 5
    } while ($true)
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
    if (@(Compare-Object (@($WssUniversalFiles) + @('wss-candidate.json')) $actual -CaseSensitive).Count -ne 0) { return $false }
    # Require valid committed provenance; a no-op preserves it instead of manufacturing a metadata-only PR.
    $null = Read-WssApproval (Join-Path $root 'wss-candidate.json')
    foreach ($relative in $WssUniversalFiles) {
        if ((Get-FileHash -LiteralPath (Join-Path $root $relative)).Hash -cne
            (Get-FileHash -LiteralPath (Join-Path $ArtifactRoot $relative)).Hash) { return $false }
    }
    return $true
}
