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
"Receipt acceptance boundary tests passed ($count rejections; valid merged PR, exact normal CI and allowed dependency scopes)."
