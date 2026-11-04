Set-StrictMode -Version Latest

function Assert-WssReceiptPolicy([string] $TargetId, $Target) {
    $wrapper = $TargetId -ceq 'csharp-wrapper'
    if (!$wrapper -and $TargetId -cne 'csharp-cli') { throw 'Unknown C# receipt target policy.' }
    $repo = if ($wrapper) { 'cwru-non-academic/CSharp_WSS_Integration_Lib' } else { 'cwru-non-academic/CLI_CSharp_WSS_Application' }
    $workflow = if ($wrapper) { '.github/workflows/wss-compatibility.yml' } else { '.github/workflows/cli-ci.yml' }
    $kind = if ($wrapper) { 'payload' } else { 'gitlink' }
    $required = if ($wrapper) { @('Integration behavioral tests','Integration compatibility (Windows)','Integration compatibility (Ubuntu)','Integration compatibility (macOS)') } else { @('CLI general conformance','CLI platform compatibility (Windows)','CLI platform compatibility (Ubuntu)','CLI platform compatibility (macOS)') }
    $trusted = @('.github/scripts','.github/workflows/release-receipt.yml',$workflow)
    $coverage = @('canonical-conformance','packaged-macos-ble-load')
    $parents = if ($wrapper) { '{}' } else { '{"csharp-wrapper":"SubModules/HFI_WSS_Csharp_Implementation"}' }
    if ($Target.repository -cne $repo -or $Target.branch -cne 'dev' -or $Target.kind -cne $kind -or $Target.workflow -cne $workflow -or
        @($Target.jobs).Count -ne $required.Count -or @(Compare-Object $required @($Target.jobs) -CaseSensitive).Count -or
        @($Target.trusted_paths).Count -ne $trusted.Count -or @(Compare-Object $trusted @($Target.trusted_paths) -CaseSensitive).Count -or
        @($Target.coverage).Count -ne $coverage.Count -or @(Compare-Object $coverage @($Target.coverage) -CaseSensitive).Count -or
        ($Target.parents | ConvertTo-Json -Compress) -cne $parents) { throw 'Frozen plan differs from receiver-owned C# acceptance policy.' }
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
        $Pr.base.ref -cne 'dev' -or $Pr.base.repo.full_name -cne $Repository -or
        $Pr.head.repo.full_name -cne $Repository -or $Pr.user.type -cne 'Bot' -or $Pr.merged_by.type -cne 'User') {
        throw 'Receipt requires an actual same-repository bot dependency PR merged into dev.'
    }
}

function Assert-WssReceiptNormalRun($Run,[string] $Repository,$Target,[string] $Sha,$Jobs) {
    if ($Run.status -cne 'completed' -or $Run.conclusion -cne 'success' -or $Run.head_branch -cne 'dev' -or
        $Run.head_sha -cne $Sha -or $Run.repository.full_name -cne $Repository -or $Run.head_repository.full_name -cne $Repository -or
        $Run.path -cne $Target.workflow -or $Run.event -cne 'workflow_dispatch') {
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
