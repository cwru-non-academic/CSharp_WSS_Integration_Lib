$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/../WssReleaseReceipt.ps1"
$count = 0
function Reject([scriptblock] $Action) {
    $failed = $false
    try { & $Action } catch { $failed = $true }
    if (-not $failed) { throw 'Expected invalid receipt evidence to be rejected.' }
    $script:count++
}
$repo = 'cwru-non-academic/CSharp_WSS_Integration_Lib'
$sha = '1' * 40
function Pr { [pscustomobject]@{merged=$true;merged_by=@{type='User'};state='closed';merge_commit_sha=$sha;base=@{ref='dev';repo=@{full_name=$repo}};head=@{repo=@{full_name=$repo}};user=@{type='Bot'}} }
$p = Pr
Assert-WssReceiptPr $p $repo $sha
foreach ($mutate in @(
    { param($p) $p.merged=$false }, { param($p) $p.state='open' },
    { param($p) $p.merge_commit_sha='2'*40 }, { param($p) $p.base.ref='main' },
    { param($p) $p.head.repo.full_name='fork/test' }, { param($p) $p.user.type='User' }, { param($p) $p.merged_by.type='Bot' }
)) { $p=Pr; & $mutate $p; Reject { Assert-WssReceiptPr $p $repo $sha } }
$target = @{workflow='.github/workflows/wss-compatibility.yml';jobs=@('Integration behavioral tests','Integration compatibility (macOS)')}
function Run { [pscustomobject]@{status='completed';conclusion='success';head_branch='dev';head_sha=$sha;repository=@{full_name=$repo};head_repository=@{full_name=$repo};path=$target.workflow;event='workflow_dispatch'} }
function Jobs { @($target.jobs | ForEach-Object { [pscustomobject]@{name=$_;status='completed';conclusion='success'} }) }
Assert-WssReceiptNormalRun (Run) $repo $target $sha (Jobs)
foreach ($mutate in @(
    { param($r) $r.event='pull_request' }, { param($r) $r.status='in_progress' },
    { param($r) $r.conclusion='failure' }, { param($r) $r.head_branch='main' },
    { param($r) $r.head_sha='2'*40 }, { param($r) $r.path='.github/workflows/wss-preflight.yml' },
    { param($r) $r.head_repository.full_name='fork/test' }
)) { $r=Run; & $mutate $r; Reject { Assert-WssReceiptNormalRun $r $repo $target $sha (Jobs) } }
Reject { Assert-WssReceiptNormalRun (Run) $repo $target $sha @() }
$j=Jobs; $j[1].conclusion='skipped'; Reject { Assert-WssReceiptNormalRun (Run) $repo $target $sha $j }
$j=Jobs; $j+= $j[1]; Reject { Assert-WssReceiptNormalRun (Run) $repo $target $sha $j }
Assert-WssReceiptChangedFiles csharp-wrapper @(@{filename='lib/backends/macos/libwss_macos_ble.dylib'})
Assert-WssReceiptChangedFiles csharp-cli @(@{filename='SubModules/HFI_WSS_Csharp_Implementation'})
Reject { Assert-WssReceiptChangedFiles csharp-wrapper @() }
Reject { Assert-WssReceiptChangedFiles csharp-wrapper @(@{filename='.github/workflows/unrelated.yml'}) }
Reject { Assert-WssReceiptChangedFiles csharp-cli @(@{filename='SubModules/HFI_WSS_Csharp_Implementation'},@{filename='Program.cs'}) }
Reject { Assert-WssReceiptChangedFiles unknown @(@{filename='lib/test'}) }
$frozenSources = @{target_snapshots=@{'csharp-wrapper'=@{head_sha=('a'*40)};'csharp-cli'=@{head_sha=('b'*40)}}}
$sourceApproval = @{integration=@{source_sha=('a'*40)};cli=@{source_sha=('b'*40)}}
Assert-WssReceiptSources $sourceApproval $frozenSources
$sourceApproval.integration.source_sha='c'*40
Reject { Assert-WssReceiptSources $sourceApproval $frozenSources }
$sourceApproval.integration.source_sha='a'*40
$sourceApproval.cli.source_sha='c'*40
Reject { Assert-WssReceiptSources $sourceApproval $frozenSources }
"Receipt acceptance boundary tests passed ($count rejections; valid merged PR, exact normal CI, frozen preflight sources and allowed dependency scopes)."

# Exercise the production trust boundary without running the networked emitter.
$emitterPath = Join-Path $PSScriptRoot '../Write-ReleaseReceipt.ps1'
$parseErrors = $null
$emitterAst = [System.Management.Automation.Language.Parser]::ParseFile($emitterPath, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Receipt emitter does not parse.' }
$definition = @($emitterAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Assert-WssReceiptTooling'
}, $true))
if ($definition.Count -ne 1) { throw 'Unique production receipt tooling guard required.' }
. ([scriptblock]::Create($definition[0].Extent.Text))
function Git([string] $Root, [string[]] $Arguments) {
    $key = "$Root|$($Arguments[-1])"
    if (-not $script:receiptObjects.ContainsKey($key)) { throw "Unexpected Git object lookup: $key" }
    $script:receiptObjects[$key]
}
function Check-Tooling {
    Assert-WssReceiptTooling $plan $targetId $target '.tools' '.validation-tools' '.accepted' '.integration'
}
function Reject-ToolingMutation([string] $Key, [string] $ExpectedMessage) {
    $before = $script:receiptObjects[$Key]
    $script:receiptObjects[$Key] = 'changed-object'
    $rejected = $false
    try { Check-Tooling } catch {
        if ($_.Exception.Message -cnotlike $ExpectedMessage) { throw }
        $rejected = $true
    } finally { $script:receiptObjects[$Key] = $before }
    if (-not $rejected) { throw "Changed trust object was accepted: $Key" }
    $script:toolingRejections++
}
$toolingRejections = 0
foreach ($targetId in @('csharp-wrapper', 'csharp-cli')) {
    $normal = if ($targetId -ceq 'csharp-wrapper') { '.github/workflows/wss-compatibility.yml' } else { '.github/workflows/cli-ci.yml' }
    $trusted = @('.github/scripts', '.github/workflows/release-receipt.yml', $normal)
    $target = @{ trusted_paths = $trusted }
    $snapshot = @{ '.github/scripts' = 'accepted-scripts'; '.github/workflows/release-receipt.yml' = 'receipt-workflow'; $normal = 'dev-normal-ci' }
    $plan = @{ target_snapshots = @{ 'csharp-wrapper' = @{ trusted = @{ '.github/scripts' = 'wrapper-scripts' } } } }
    $plan.target_snapshots[$targetId] = @{ trusted = $snapshot }
    $wrapperRoot = if ($targetId -ceq 'csharp-wrapper') { '.accepted' } else { '.integration' }
    $script:receiptObjects = @{}
    foreach ($path in $trusted) { $script:receiptObjects[".accepted|HEAD:$path"] = $snapshot[$path] }
    # Branch-specific CI and script trees intentionally differ on main.
    $script:receiptObjects[".tools|HEAD:$normal"] = 'main-normal-ci'
    $script:receiptObjects['.tools|HEAD:.github/scripts'] = 'main-other-scripts'
    $script:receiptObjects['.validation-tools|HEAD:.github/scripts'] = 'main-other-validator-scripts'
    foreach ($path in @('.github/workflows/release-receipt.yml', '.github/scripts/Write-ReleaseReceipt.ps1', '.github/scripts/WssReleaseReceipt.ps1')) {
        $value = if ($path -ceq '.github/workflows/release-receipt.yml') { 'receipt-workflow' } else { "receiver-file:$path" }
        $script:receiptObjects[".accepted|HEAD:$path"] = $value
        $script:receiptObjects[".tools|HEAD:$path"] = $value
    }
    $script:receiptObjects["$wrapperRoot|HEAD:.github/scripts"] = $plan.target_snapshots.'csharp-wrapper'.trusted.'.github/scripts'
    foreach ($path in @('.github/scripts/WssPromotion.ps1', '.github/scripts/Universal-WssFiles.ps1', '.github/scripts/Resolve-WssRelease.ps1')) {
        $script:receiptObjects["$wrapperRoot|HEAD:$path"] = "wrapper-file:$path"
        $script:receiptObjects[".validation-tools|HEAD:$path"] = "wrapper-file:$path"
    }
    Check-Tooling
    foreach ($path in $trusted) {
        Reject-ToolingMutation ".accepted|HEAD:$path" 'Accepted receiver tooling differs:*'
    }
    foreach ($path in @('.github/workflows/release-receipt.yml', '.github/scripts/Write-ReleaseReceipt.ps1', '.github/scripts/WssReleaseReceipt.ps1')) {
        Reject-ToolingMutation ".tools|HEAD:$path" 'Trusted main receipt tooling differs:*'
    }
    foreach ($path in @('.github/scripts/WssPromotion.ps1', '.github/scripts/Universal-WssFiles.ps1', '.github/scripts/Resolve-WssRelease.ps1')) {
        Reject-ToolingMutation ".validation-tools|HEAD:$path" 'Shared C# validator differs from frozen code:*'
    }
    if ($targetId -ceq 'csharp-cli') {
        Reject-ToolingMutation '.integration|HEAD:.github/scripts' 'Accepted wrapper validators differ from frozen code.*'
    }
}
Remove-Item Function:Git
"Branch-aware receipt tooling tests passed (two divergent-CI targets; $toolingRejections exact-object rejections)."

# Receiver-owned policy cannot be weakened by a producer-supplied manifest.
foreach ($policyId in @('csharp-wrapper','csharp-cli')) {
    $isWrapper=$policyId -ceq 'csharp-wrapper'
    $policy=[pscustomobject]@{
        repository=$(if ($isWrapper) { 'cwru-non-academic/CSharp_WSS_Integration_Lib' } else { 'cwru-non-academic/CLI_CSharp_WSS_Application' })
        branch='dev'; kind=$(if ($isWrapper) { 'payload' } else { 'gitlink' })
        workflow=$(if ($isWrapper) { '.github/workflows/wss-compatibility.yml' } else { '.github/workflows/cli-ci.yml' })
        jobs=$(if ($isWrapper) { @('Integration behavioral tests','Integration compatibility (Windows)','Integration compatibility (Ubuntu)','Integration compatibility (macOS)') } else { @('CLI general conformance','CLI platform compatibility (Windows)','CLI platform compatibility (Ubuntu)','CLI platform compatibility (macOS)') })
        parents=$(if ($isWrapper) { [pscustomobject]@{} } else { [pscustomobject]@{'csharp-wrapper'='SubModules/HFI_WSS_Csharp_Implementation'} })
        trusted_paths=@('.github/scripts','.github/workflows/release-receipt.yml',$(if ($isWrapper) { '.github/workflows/wss-compatibility.yml' } else { '.github/workflows/cli-ci.yml' }))
        coverage=@('canonical-conformance','packaged-macos-ble-load')
    }
    Assert-WssReceiptPolicy $policyId $policy
    foreach ($mutation in @(
        {param($p)$p.jobs=@($p.jobs[0])}, {param($p)$p.workflow='.github/workflows/wss-preflight.yml'},
        {param($p)$p.branch='main'}, {param($p)$p.repository='other/repository'},
        {param($p)$p.coverage=@('canonical-conformance')}, {param($p)$p.trusted_paths=@('.github/scripts')},
        {param($p)$p.parents=[pscustomobject]@{'csharp-wrapper'='other/gitlink'}}
    )) {
        $bad=$policy | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        & $mutation $bad
        Reject { Assert-WssReceiptPolicy $policyId $bad }
    }
}
$normalTarget=@{workflow='.github/workflows/cli-ci.yml';jobs=@('CLI general conformance')}
$normalRepo='cwru-non-academic/CLI_CSharp_WSS_Application'
$normalSha='a'*40
$originalNormal=[pscustomobject]@{id=123;run_attempt=1}
$latestNormal=[pscustomobject]@{id=123;run_attempt=1}
$liveNormal=[pscustomobject]@{id=123;run_attempt=1;repository=@{full_name=$normalRepo};head_repository=@{full_name=$normalRepo};head_branch='dev';head_sha=$normalSha;path=$normalTarget.workflow;event='workflow_dispatch';status='completed';conclusion='success'}
$normalJobs=@([pscustomobject]@{name='CLI general conformance';status='completed';conclusion='success'})
Assert-WssReceiptNormalFresh $originalNormal $latestNormal $liveNormal $normalRepo $normalTarget $normalSha $normalJobs
$latestNormal.id=124
Reject { Assert-WssReceiptNormalFresh $originalNormal $latestNormal $liveNormal $normalRepo $normalTarget $normalSha $normalJobs }
$latestNormal.id=123; $latestNormal.run_attempt=2
Reject { Assert-WssReceiptNormalFresh $originalNormal $latestNormal $liveNormal $normalRepo $normalTarget $normalSha $normalJobs }
$latestNormal.run_attempt=1; $liveNormal.run_attempt=2
Reject { Assert-WssReceiptNormalFresh $originalNormal $latestNormal $liveNormal $normalRepo $normalTarget $normalSha $normalJobs }
$liveNormal.run_attempt=1; $liveNormal.conclusion='failure'
Reject { Assert-WssReceiptNormalFresh $originalNormal $latestNormal $liveNormal $normalRepo $normalTarget $normalSha $normalJobs }
"Receiver-owned policy and final CI identity tests passed (18 new rejections)."
