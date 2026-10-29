Set-StrictMode -Version Latest

function Assert-WssReceiptPr($Pr,[string] $Repository,[string] $Sha) {
    if (-not $Pr.merged -or $Pr.state -cne 'closed' -or $Pr.merge_commit_sha -cne $Sha -or
        $Pr.base.ref -cne 'dev' -or $Pr.base.repo.full_name -cne $Repository -or
        $Pr.head.repo.full_name -cne $Repository -or $Pr.user.type -cne 'Bot') {
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
