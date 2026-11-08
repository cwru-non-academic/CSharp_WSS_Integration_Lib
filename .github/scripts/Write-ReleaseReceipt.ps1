param(
    [Parameter(Mandatory)][ValidateSet('csharp-wrapper','csharp-cli')][string] $TargetId,
    [Parameter(Mandatory)][ValidatePattern('^[1-9][0-9]*$')][string] $ProducerRunId,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string] $PlanId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $ContextPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $WorkRoot,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $OutputPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/wss-ci/Channel.ps1"
function Invoke-ReceiptGh([string[]] $Arguments) {
    $result = & gh @Arguments
    if ($LASTEXITCODE -ne 0) { throw "GitHub evidence request failed: $($Arguments[0])" }
    $result
}
function Api([string] $Path) { Invoke-ReceiptGh -Arguments @('api',$Path) | ConvertFrom-Json }
function Pages([string] $Path, [string] $Key = '') {
    $pages = Invoke-ReceiptGh -Arguments @('api','--paginate','--slurp',$Path) | ConvertFrom-Json
    if ($Key) { @($pages | ForEach-Object { $_.$Key }) } else { @($pages | ForEach-Object { $_ }) }
}
function Invoke-ReceiptGit([string] $Root,[string[]] $Arguments) {
    $result = & git -C $Root @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'Git evidence request failed.' }
    $result
}
function Assert-WssReceiptTooling($Plan, [string] $TargetId, $Target, [string] $ToolsRoot, [string] $ValidatorRoot, [string] $AcceptedRoot, [string] $IntegrationRoot) {
    # The frozen target describes the accepted channel and its branch-specific CI.
    foreach ($path in $Target.trusted_paths) {
        if ((Invoke-ReceiptGit $AcceptedRoot -Arguments @('rev-parse',"HEAD:$path")) -cne $Plan.target_snapshots.$TargetId.trusted.$path) { throw "Accepted receiver tooling differs: $path" }
    }
    # Check the admitted adapter files against the accepted receiver as defense in depth.
    # Generic source admission belongs to the common engine.
    foreach ($path in @('.github/workflows/release-receipt.yml', '.github/scripts/Write-ReleaseReceipt.ps1', '.github/scripts/WssReleaseReceipt.ps1', '.github/scripts/wss-ci')) {
        if ((Invoke-ReceiptGit $ToolsRoot -Arguments @('rev-parse',"HEAD:$path")) -cne (Invoke-ReceiptGit $AcceptedRoot -Arguments @('rev-parse',"HEAD:$path"))) { throw "Admitted receipt tooling differs: $path" }
    }
    $wrapperRoot = if ($TargetId -ceq 'csharp-wrapper') { $AcceptedRoot } else { $IntegrationRoot }
    if ((Invoke-ReceiptGit $wrapperRoot -Arguments @('rev-parse','HEAD:.github/scripts')) -cne $Plan.target_snapshots.'csharp-wrapper'.trusted.'.github/scripts') { throw 'Accepted wrapper validators differ from frozen code.' }
    foreach ($path in @('.github/scripts/WssPromotion.ps1', '.github/scripts/Universal-WssFiles.ps1', '.github/scripts/Resolve-WssRelease.ps1', '.github/scripts/wss-ci')) {
        if ((Invoke-ReceiptGit $ValidatorRoot -Arguments @('rev-parse',"HEAD:$path")) -cne (Invoke-ReceiptGit $wrapperRoot -Arguments @('rev-parse',"HEAD:$path"))) { throw "Shared C# validator differs from frozen code: $path" }
    }
}
function Download([string] $Repository,[string] $Run,[string] $Name,[string] $Directory,[string] $File) {
    $a = @(Pages "repos/$Repository/actions/runs/$Run/artifacts?per_page=100" 'artifacts' | Where-Object name -CEQ $Name)
    if ($a.Count -ne 1 -or $a[0].expired -or [string]$a[0].workflow_run.id -cne $Run) { throw 'Missing/ambiguous/expired evidence artifact.' }
    $null = Invoke-ReceiptGh -Arguments @('run','download',$Run,'--repo',$Repository,'--name',$Name,'--dir',$Directory)
    $files = @(Get-ChildItem -LiteralPath $Directory -Force)
    if ($files.Count -ne 1 -or $files[0].PSIsContainer -or $files[0].Name -cne $File) { throw 'Unexpected evidence artifact inventory.' }
    Get-Content -LiteralPath (Join-Path $Directory $File) -Raw | ConvertFrom-Json
}
function MergedPr([string] $Repository,[string] $Sha) {
    $matches = @(Pages "repos/$Repository/commits/$Sha/pulls?per_page=100" | Where-Object {
        $_.merged_at -and $_.merge_commit_sha -ceq $Sha -and $_.base.ref -ceq (Get-WssCiChannel) -and
        $_.base.repo.full_name -ceq $Repository -and $_.head.repo.full_name -ceq $Repository
    })
    if ($matches.Count -ne 1) { throw 'Current dev must be the actual unique merged dependency PR.' }
    $pr = Api "repos/$Repository/pulls/$($matches[0].number)"
    Assert-WssReceiptPr $pr $Repository $Sha
    $pr
}


# The admitted common engine invokes this native-proof adapter exactly once.
# Root identities and generic policy are admitted before this boundary.
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:GITHUB_EVENT_NAME -cne 'workflow_dispatch' -or $env:GITHUB_REF -cne (Get-WssCiChannelContext).ref) { throw 'Adapter is restricted to actual dev receipt execution.' }
$ctx=Get-Content -LiteralPath $ContextPath -Raw | ConvertFrom-Json
if($ctx.plan.channel -cne (Get-WssCiChannel) -or $ctx.target.branch -cne (Get-WssCiChannel)){throw 'Receipt adapter context differs from explicit channel.'}
if((Get-WssCiChannel) -ceq 'main' -and ($env:GITHUB_WORKFLOW_SHA -cne $env:GITHUB_SHA -or $env:GITHUB_WORKFLOW_REF -cne "$env:GITHUB_REPOSITORY/.github/workflows/release-receipt.yml@refs/heads/main")){throw 'Main receipt must execute its exact registered receiver source.'}
if ($ctx.target.id -cne $TargetId -or $ctx.head -cne $env:GITHUB_SHA -or $ctx.target.repository -cne $env:GITHUB_REPOSITORY) { throw 'Adapter source/role differs from receipt context.' }
$plan=$ctx.plan; $target=$ctx.target; $acceptedSha=$ctx.head; $pr=$ctx.pr
$AcceptedRoot=$ctx.paths.sourceRoot; $ToolsRoot=$ctx.paths.toolsRoot; $ValidatorRoot=$ctx.paths.validatorRoot; $IntegrationRoot=$ctx.paths.integrationRoot
$core='cwru-non-academic/WSSCore'; $wrapper='cwru-non-academic/CSharp_WSS_Integration_Lib'; $gui='cwru-non-academic/GUI_Unity_WSS_Application'; $repository=$target.repository
if (Test-Path -LiteralPath $WorkRoot) { throw 'Rich proof validation workspace must be new.' }
$null=New-Item -ItemType Directory -Path $WorkRoot
$work=$WorkRoot
Assert-WssReceiptTooling $plan $TargetId $target $ToolsRoot $ValidatorRoot $AcceptedRoot $IntegrationRoot
. (Join-Path $ValidatorRoot '.github/scripts/WssPromotion.ps1')
. (Join-Path $ToolsRoot '.github/scripts/WssReleaseReceipt.ps1')
Assert-WssReceiptPolicy $TargetId $ContextPath $ctx.paths.engineRoot
$approval = Read-WssApprovalMarker ([string]$pr.body) (Join-Path $work 'approval.json')
Assert-WssReceiptSources $approval $plan
Assert-WssCandidateRecord $plan.candidate $approval
$files = @(Pages "repos/$repository/pulls/$($pr.number)/files?per_page=100")
Assert-WssReceiptChangedFiles $TargetId $files
if ($TargetId -ceq 'csharp-wrapper') {
    if (@($files | Where-Object filename -CNotMatch '^lib/').Count -ne 0 -or $pr.head.ref -cne (Get-WssBranch $approval) -or [Regex]::Matches([string]$pr.body,'<!-- wss-promotion:v2 -->').Count -ne 1) { throw 'Wrapper PR scope/promotion marker mismatch.' }
    $IntegrationRoot = $AcceptedRoot
    $null = Assert-WssMergedIntegration $acceptedSha ([string]$pr.number) $approval
} else {
    if ($files.Count -ne 1 -or $files[0].filename -cne 'SubModules/HFI_WSS_Csharp_Implementation') { throw 'CLI PR must change only the reviewed wrapper gitlink.' }
    $integrationSha = Invoke-ReceiptGit $IntegrationRoot -Arguments @('rev-parse','HEAD')
    $pin = Invoke-ReceiptGit $AcceptedRoot -Arguments @('rev-parse','HEAD:SubModules/HFI_WSS_Csharp_Implementation')
    if ($pin -cne $integrationSha -or $pr.head.ref -cne "automation/integration-$integrationSha") { throw 'CLI pin differs from actual current wrapper.' }
    $integrationPr = MergedPr $wrapper $integrationSha
    $null = Assert-WssMergedIntegration $integrationSha ([string]$integrationPr.number) $approval
    if ([Regex]::Matches([string]$pr.body,"(?m)^- Integration PR: #$($integrationPr.number)\r?$").Count -ne 1) { throw 'CLI metadata differs from actual wrapper merge.' }
    Assert-WssSource $AcceptedRoot $approval.cli.source_sha -Consumer cli
}
Assert-WssApproval $approval (Join-Path $work 'preflight-proof') -RequireCanonicalDev
Assert-WssSource $IntegrationRoot $approval.integration.source_sha
& (Join-Path $ValidatorRoot '.github/scripts/Resolve-WssRelease.ps1') -RunId $approval.candidate.run_id -ProducerRepository $core -ExpectedCommit $approval.candidate.commit -ArchiveName $approval.candidate.archive -ExpectedSha256 $approval.candidate.sha256 -OutputRoot (Join-Path $work 'release')
Assert-WssLib (Join-Path $IntegrationRoot 'lib') (Join-Path $work 'release/extracted/WSS-Universal') $approval

$preflights=@(
    @{repository=$wrapper; run_id=$approval.integration.preflight_run_id; source_sha=$approval.integration.source_sha; workflow='.github/workflows/wss-preflight.yml'},
    @{repository='cwru-non-academic/CLI_CSharp_WSS_Application'; run_id=$approval.cli.preflight_run_id; source_sha=$approval.cli.source_sha; workflow='.github/workflows/wss-preflight.yml'}
)

ConvertTo-Json -InputObject @($preflights) -Depth 8 | Set-Content -LiteralPath $OutputPath
