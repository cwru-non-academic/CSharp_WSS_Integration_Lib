Set-StrictMode -Version Latest
. "$PSScriptRoot/wss-ci/Channel.ps1"

function Assert-WssReceiptPolicy([string] $TargetId, [string] $ContextPath, [string] $ToolsRoot) {
    if ($TargetId -cne 'csharp-wrapper' -and $TargetId -cne 'csharp-cli') { throw 'Unknown C# receipt target policy.' }
    # Import the already-frozen common validator; never execute its receipt CLI.
    # The fixed argv[1] sentinel also prevents the imported module's CLI guard
    # from matching a caller-supplied context filename.
    $assertion = @'
import {readFileSync} from 'node:fs';
import {resolve,join} from 'node:path';
import {pathToFileURL} from 'node:url';
if(process.argv.length!==5 || process.argv[1]!=='wss-receipt-policy-assertion') throw Error('Invalid policy assertion arguments');
const [,,contextPath,toolsRoot,id]=process.argv;
if(!['csharp-wrapper','csharp-cli'].includes(id)) throw Error('Unknown C# receipt target policy');
const context=JSON.parse(readFileSync(contextPath,'utf8').replace(/^\uFEFF/,''));
if(!context || typeof context!=='object' || Array.isArray(context) || !context.paths ||
   typeof context.paths.toolsRoot!=='string' || resolve(context.paths.toolsRoot)!==resolve(toolsRoot)) throw Error('Receipt policy context tooling differs');
const moduleRoot=join(resolve(toolsRoot),'.github/scripts/wss-ci');
const {targetPolicy}=await import(pathToFileURL(join(moduleRoot,'receipt.mjs')).href);
const {canonical,plan}=await import(pathToFileURL(join(moduleRoot,'verify.mjs')).href);
plan(context.plan);
const target=targetPolicy(context.plan,id);
if(canonical(target)!==canonical(context.target)) throw Error('Receipt context target differs from canonical plan policy');
'@
    $arguments = @('--input-type=module','--eval',$assertion,'--','wss-receipt-policy-assertion',
        [IO.Path]::GetFullPath($ContextPath),[IO.Path]::GetFullPath($ToolsRoot),$TargetId)
    & node @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Frozen plan differs from receiver-owned C# acceptance policy.' }
}
function Assert-WssReceiptNormalFresh($Original, $Latest, $Run, [string] $Repository, $Target, [string] $Sha, $Jobs) {
    if ([string]$Latest.id -cne [string]$Original.id -or [int]$Latest.run_attempt -ne [int]$Original.run_attempt -or
        [string]$Run.id -cne [string]$Original.id -or [int]$Run.run_attempt -ne [int]$Original.run_attempt) { throw 'Normal CI run or attempt changed during receipt validation.' }
    Assert-WssReceiptNormalRun $Run $Repository $Target $Sha $Jobs
}


function Assert-WssReceiptSources($Approval, $Plan) {
    if ($Approval.integration.source_sha -cne $Plan.target_snapshots.'csharp-wrapper'.head_sha -or
        $Approval.cli.source_sha -cne $Plan.target_snapshots.'csharp-cli'.head_sha) {
        throw 'Preflight sources differ from the frozen C# target snapshots.'
    }
}

function Assert-WssReceiptPr($Pr,[string] $Repository,[string] $Sha) {
    if (-not $Pr.merged -or $Pr.state -cne 'closed' -or $Pr.merge_commit_sha -cne $Sha -or
        $Pr.base.ref -cne (Get-WssCiChannel) -or $Pr.base.repo.full_name -cne $Repository -or
        $Pr.head.repo.full_name -cne $Repository -or $Pr.user.type -cne 'Bot' -or $Pr.merged_by.type -cne 'User') {
        throw 'Receipt requires an actual same-repository bot dependency PR merged into dev.'
    }
}

function Assert-WssReceiptNormalRun($Run,[string] $Repository,$Target,[string] $Sha,$Jobs) {
    if ($Run.status -cne 'completed' -or $Run.conclusion -cne 'success' -or $Run.head_branch -cne (Get-WssCiChannel) -or
        $Run.head_sha -cne $Sha -or $Run.repository.full_name -cne $Repository -or $Run.head_repository.full_name -cne $Repository -or
        $Run.path -cne $Target.workflow -or $Run.event -cnotin @('push','workflow_dispatch')) {
        throw 'Fresh exact-merge normal CI is not successful.'
    }
    foreach ($name in $Target.jobs) {
        $match = @($Jobs | Where-Object name -CEQ $name)
        if ($match.Count -ne 1 -or $match[0].status -cne 'completed' -or $match[0].conclusion -cne 'success') { throw "Missing unique successful normal job: $name" }
    }
}

function Assert-WssReceiptChangedFiles([string] $TargetId,$Files) {
    if (@($Files).Count -eq 0) { throw 'Dependency PR must change the accepted dependency.' }
    if ($TargetId -ceq 'csharp-wrapper') {
        if (@($Files | Where-Object filename -CNotMatch '^lib/').Count -ne 0) { throw 'Wrapper receipt PR may change only lib/.' }
    } elseif ($TargetId -ceq 'csharp-cli') {
        if (@($Files).Count -ne 1 -or $Files[0].filename -cne 'SubModules/HFI_WSS_Csharp_Implementation') { throw 'CLI receipt PR may change only its wrapper gitlink.' }
    } else { throw 'Unknown C# acceptance target.' }
}
