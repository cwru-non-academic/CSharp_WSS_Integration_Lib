param(
    [Parameter(Mandatory)][ValidateSet('csharp-wrapper','csharp-cli')][string] $TargetId,
    [Parameter(Mandatory)][ValidatePattern('^[1-9][0-9]*$')][string] $ProducerRunId,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string] $PlanId,
    [string] $ToolsRoot = '.tools',
    [string] $ValidatorRoot = '.validation-tools',
    [string] $AcceptedRoot = '.accepted',
    [string] $IntegrationRoot = '.integration',
    [string] $OutputRoot = 'receipt-output'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Gh([string[]] $Arguments) {
    $result = & gh @Arguments
    if ($LASTEXITCODE -ne 0) { throw "GitHub evidence request failed: $($Arguments[0])" }
    $result
}
function Api([string] $Path) { Gh @('api',$Path) | ConvertFrom-Json }
function Pages([string] $Path, [string] $Key = '') {
    $pages = Gh @('api','--paginate','--slurp',$Path) | ConvertFrom-Json
    if ($Key) { @($pages | ForEach-Object { $_.$Key }) } else { @($pages | ForEach-Object { $_ }) }
}
function Git([string] $Root,[string[]] $Arguments) {
    $result = & git -C $Root @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'Git evidence request failed.' }
    $result
}
function Download([string] $Repository,[string] $Run,[string] $Name,[string] $Directory,[string] $File) {
    $a = @(Pages "repos/$Repository/actions/runs/$Run/artifacts?per_page=100" 'artifacts' | Where-Object name -CEQ $Name)
    if ($a.Count -ne 1 -or $a[0].expired -or [string]$a[0].workflow_run.id -cne $Run) { throw 'Missing/ambiguous/expired evidence artifact.' }
    $null = Gh @('run','download',$Run,'--repo',$Repository,'--name',$Name,'--dir',$Directory)
    $files = @(Get-ChildItem -LiteralPath $Directory -Force)
    if ($files.Count -ne 1 -or $files[0].PSIsContainer -or $files[0].Name -cne $File) { throw 'Unexpected evidence artifact inventory.' }
    Get-Content -LiteralPath (Join-Path $Directory $File) -Raw | ConvertFrom-Json
}
function MergedPr([string] $Repository,[string] $Sha) {
    $matches = @(Pages "repos/$Repository/commits/$Sha/pulls?per_page=100" | Where-Object {
        $_.merged_at -and $_.merge_commit_sha -ceq $Sha -and $_.base.ref -ceq 'dev' -and
        $_.base.repo.full_name -ceq $Repository -and $_.head.repo.full_name -ceq $Repository
    })
    if ($matches.Count -ne 1) { throw 'Current dev must be the actual unique merged dependency PR.' }
    $pr = Api "repos/$Repository/pulls/$($matches[0].number)"
    Assert-WssReceiptPr $pr $Repository $Sha
    $pr
}

$core = 'cwru-non-academic/WSSCore'
$wrapper = 'cwru-non-academic/CSharp_WSS_Integration_Lib'
$repository = if ($TargetId -ceq 'csharp-wrapper') { $wrapper } else { 'cwru-non-academic/CLI_CSharp_WSS_Application' }
if ($env:GITHUB_REPOSITORY -cne $repository -or $env:GITHUB_EVENT_NAME -cne 'workflow_dispatch' -or $env:GITHUB_REF -cne 'refs/heads/dev') { throw 'Receipt emitter is restricted to its canonical dev dispatch.' }
$work = Join-Path $env:RUNNER_TEMP ('wss-receipt-' + [IO.Path]::GetRandomFileName())
$null = New-Item -ItemType Directory -Path $work
$producer = Api "repos/$core/actions/runs/$ProducerRunId"
if ($producer.repository.full_name -cne $core -or $producer.head_repository.full_name -cne $core -or $producer.path -cne '.github/workflows/artifacts.yml' -or $producer.event -cne 'push' -or $producer.head_branch -cne 'dev' -or $producer.status -cne 'completed' -or $producer.conclusion -cne 'success') { throw 'Plan is not from a successful canonical dev push.' }
$plan = Download $core $ProducerRunId 'wss-propagation-plan' (Join-Path $work 'plan') 'plan.json'
if ($plan.schema -cne 'wss-propagation-plan/v1' -or $plan.channel -cne 'dev' -or $plan.plan_id -cne $PlanId -or $plan.candidate.run_id -cne $ProducerRunId -or $plan.candidate.commit -cne $producer.head_sha) { throw 'Plan/input/producer mismatch.' }
# Canonical JSON hashing is shared with Node's UTF-8 JSON representation, not PS formatting.
$hashCode = 'const fs=require("fs"),c=require("crypto");const sort=x=>Array.isArray(x)?x.map(sort):x&&typeof x==="object"?Object.fromEntries(Object.keys(x).sort().map(k=>[k,sort(x[k])])):x;const p=JSON.parse(fs.readFileSync(process.argv[1]));const hash=x=>c.createHash("sha256").update(JSON.stringify(sort(x))).digest("hex");const id=p.plan_id;delete p.plan_id;if(hash(p)!==id||hash(p.manifest)!==p.manifest_sha256)process.exit(1);'
& node -e $hashCode (Join-Path $work 'plan/plan.json')
if ($LASTEXITCODE -ne 0) { throw 'Frozen plan/manifest digest mismatch.' }
$target = @($plan.manifest.targets | Where-Object id -CEQ $TargetId)
if ($target.Count -ne 1 -or $target[0].repository -cne $repository -or $target[0].branch -cne 'dev') { throw 'Required target policy mismatch.' }
$target = $target[0]
foreach ($path in $target.trusted_paths) {
    if ((Git $ToolsRoot @('rev-parse',"HEAD:$path")) -cne $plan.target_snapshots.$TargetId.trusted.$path) { throw "Trusted receipt tooling differs: $path" }
}
if ((Git $ValidatorRoot @('rev-parse','HEAD:.github/scripts')) -cne $plan.target_snapshots.'csharp-wrapper'.trusted.'.github/scripts') { throw 'Shared C# validator differs from frozen code.' }
. (Join-Path $ValidatorRoot '.github/scripts/WssPromotion.ps1')
. (Join-Path $ToolsRoot '.github/scripts/WssReleaseReceipt.ps1')
$acceptedSha = Git $AcceptedRoot @('rev-parse','HEAD')
$current = Api "repos/$repository/git/ref/heads/dev"
if ($acceptedSha -cne $current.object.sha -or $acceptedSha -cne $env:GITHUB_SHA) { throw 'Accepted checkout/emitter/current dev differ.' }
$pr = MergedPr $repository $acceptedSha
$approval = Read-WssApprovalMarker ([string]$pr.body) (Join-Path $work 'approval.json')
Assert-WssCandidateRecord $plan.candidate $approval
$files = @(Pages "repos/$repository/pulls/$($pr.number)/files?per_page=100")
Assert-WssReceiptChangedFiles $TargetId $files
if ($TargetId -ceq 'csharp-wrapper') {
    if (@($files | Where-Object filename -CNotMatch '^lib/').Count -ne 0 -or $pr.head.ref -cne (Get-WssBranch $approval) -or [Regex]::Matches([string]$pr.body,'<!-- wss-promotion:v2 -->').Count -ne 1) { throw 'Wrapper PR scope/promotion marker mismatch.' }
    $IntegrationRoot = $AcceptedRoot
    $null = Assert-WssMergedIntegration $acceptedSha ([string]$pr.number) $approval
} else {
    if ($files.Count -ne 1 -or $files[0].filename -cne 'SubModules/HFI_WSS_Csharp_Implementation') { throw 'CLI PR must change only the reviewed wrapper gitlink.' }
    $integrationSha = Git $IntegrationRoot @('rev-parse','HEAD')
    $pin = Git $AcceptedRoot @('rev-parse','HEAD:SubModules/HFI_WSS_Csharp_Implementation')
    if ($pin -cne $integrationSha -or $pr.head.ref -cne "automation/integration-$integrationSha") { throw 'CLI pin differs from actual current wrapper.' }
    $integrationPr = MergedPr $wrapper $integrationSha
    $null = Assert-WssMergedIntegration $integrationSha ([string]$integrationPr.number) $approval
    if ([Regex]::Matches([string]$pr.body,"(?m)^- Integration PR: #$($integrationPr.number)\r?$").Count -ne 1) { throw 'CLI metadata differs from actual wrapper merge.' }
    Assert-WssSource $AcceptedRoot $approval.cli.source_sha
}
Assert-WssApproval $approval (Join-Path $work 'preflight-proof')
Assert-WssSource $IntegrationRoot $approval.integration.source_sha
& (Join-Path $ValidatorRoot '.github/scripts/Resolve-WssRelease.ps1') -RunId $approval.candidate.run_id -ProducerRepository $core -ExpectedCommit $approval.candidate.commit -ArchiveName $approval.candidate.archive -ExpectedSha256 $approval.candidate.sha256 -OutputRoot (Join-Path $work 'release')
Assert-WssLib (Join-Path $IntegrationRoot 'lib') (Join-Path $work 'release/extracted/WSS-Universal') $approval
$workflow = Split-Path $target.workflow -Leaf
$runs = @(Pages "repos/$repository/actions/workflows/$workflow/runs?event=workflow_dispatch&head_sha=$acceptedSha&per_page=100" 'workflow_runs' | Sort-Object id -Descending)
if ($runs.Count -eq 0) { throw 'Fresh exact-merge normal CI has not run yet.' }
$normal = $runs[0]
$jobs = @(Pages "repos/$repository/actions/runs/$($normal.id)/attempts/$($normal.run_attempt)/jobs?per_page=100" 'jobs')
Assert-WssReceiptNormalRun $normal $repository $target $acceptedSha $jobs
if ((Api "repos/$repository/git/ref/heads/dev").object.sha -cne $acceptedSha) { throw 'Target moved during validation.' }
$parents = @{}
if ($TargetId -ceq 'csharp-cli') { $parents['csharp-wrapper'] = $integrationSha }
$receipt = [ordered]@{
    schema='wss-acceptance-receipt/v1'; plan_id=$PlanId; channel='dev'; target_id=$TargetId; candidate=$plan.candidate; mode='merged-pr'
    merge=@{pr_number=[string]$pr.number; head_sha=$pr.head.sha; sha=$acceptedSha}
    normal_ci=@{run_id=[string]$normal.id; attempt=[int]$normal.run_attempt}
    preflights=@(
        @{repository=$wrapper; run_id=$approval.integration.preflight_run_id; source_sha=$approval.integration.source_sha; workflow='.github/workflows/wss-preflight.yml'},
        @{repository='cwru-non-academic/CLI_CSharp_WSS_Application'; run_id=$approval.cli.preflight_run_id; source_sha=$approval.cli.source_sha; workflow='.github/workflows/wss-preflight.yml'}
    )
    parents=$parents; emitter=@{run_id=$env:GITHUB_RUN_ID; attempt=[int]$env:GITHUB_RUN_ATTEMPT; source_sha=$acceptedSha; workflow='.github/workflows/release-receipt.yml'}
    coverage=@($target.coverage)
}
$null = New-Item -ItemType Directory -Path $OutputRoot
$receipt | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $OutputRoot 'receipt.json') -Encoding utf8
"artifact_name=wss-acceptance-$TargetId-$PlanId-a$env:GITHUB_RUN_ATTEMPT" >> $env:GITHUB_OUTPUT
