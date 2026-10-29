Set-StrictMode -Version Latest

function Invoke-WssGh([string[]] $Arguments) {
    $result = & gh @Arguments
    if ($LASTEXITCODE -ne 0) { throw "GitHub operation failed ($LASTEXITCODE): $($Arguments -join ' ')" }
    $result
}

function Read-WssApproval([string] $Path) {
    $a = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($a.schema -ne 2 -or $a.candidate.repository -cne 'cwru-non-academic/WSSCore') { throw 'Invalid approval schema or producer.' }
    foreach ($value in @($a.candidate.run_id, $a.candidate.artifact_id, $a.integration.preflight_run_id, $a.cli.preflight_run_id)) {
        if ([string]$value -cnotmatch '^[1-9][0-9]*$') { throw 'Approval IDs must be positive integers.' }
    }
    foreach ($value in @($a.candidate.commit, $a.integration.source_sha, $a.cli.source_sha)) {
        if ($value -cnotmatch '^[0-9a-f]{40}$') { throw 'Approval source/producer SHAs must be full lowercase SHAs.' }
    }
    if ($a.candidate.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $a.candidate.archive -cnotmatch '^WSS-Universal-[A-Za-z0-9._-]+\.zip$') {
        throw 'Invalid universal archive/hash approval.'
    }
    # Reconstruct the permitted schema: arbitrary extra fields cannot widen promotion scope.
    [pscustomobject][ordered]@{
        schema = 2
        candidate = [ordered]@{
            repository = $a.candidate.repository; run_id = [string]$a.candidate.run_id
            artifact_id = [string]$a.candidate.artifact_id; commit = $a.candidate.commit
            archive = $a.candidate.archive; sha256 = $a.candidate.sha256
        }
        integration = [ordered]@{ source_sha = $a.integration.source_sha; preflight_run_id = [string]$a.integration.preflight_run_id }
        cli = [ordered]@{ source_sha = $a.cli.source_sha; preflight_run_id = [string]$a.cli.preflight_run_id }
    }
}

function Write-WssApproval($Approval, [string] $Path) {
    $Approval | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path
}

function Get-WssApprovalMarker($Approval) {
    $json = $Approval | ConvertTo-Json -Depth 5 -Compress
    '<!-- wss-approval:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)) + ' -->'
}

function Read-WssApprovalMarker([string] $Body, [string] $Destination) {
    $matches = [Regex]::Matches($Body, '(?m)^<!-- wss-approval:([A-Za-z0-9+/=]+) -->\r?$')
    if ($matches.Count -ne 1 -or [Regex]::Matches($Body, '<!-- wss-approval:').Count -ne 1) { throw 'Missing or ambiguous approval marker.' }
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($matches[0].Groups[1].Value)) | Set-Content -LiteralPath $Destination
    $approval = Read-WssApproval $Destination
    if ($matches[0].Value.TrimEnd("`r") -cne (Get-WssApprovalMarker $approval)) { throw 'Approval marker is not canonical.' }
    $approval
}

function Get-WssBranch($Approval) {
    "automation/wss-$($Approval.candidate.run_id)-$($Approval.candidate.sha256)"
}

function Assert-WssCandidateRecord($Record, $Approval) {
    foreach ($name in @('repository', 'run_id', 'artifact_id', 'commit', 'archive', 'sha256')) {
        if ([string]$Record.$name -cne [string]$Approval.candidate.$name) { throw "Candidate provenance mismatch: $name" }
    }
}

function Read-WssBootstrapProof([string] $Root, [string] $Consumer, $Approval, [string] $Destination) {
    if ($Approval.integration.source_sha -cne 'cd181c1f2abca8048fc2d1181dbf9beca9050e21' -or $Approval.integration.preflight_run_id -cne '38420209110' -or
        $Approval.cli.source_sha -cne 'a3b272b23fba4e566d7c1fe3bfafa048cca9806c' -or $Approval.cli.preflight_run_id -cne '38420541537') { throw 'Archived proof is restricted to the exact first bootstrap preflights.' }
    # Original Actions ZIP bytes downloaded before the one-day artifacts expire.
    # These digests were independently checked against the GitHub artifact API:
    # Integration artifact 11826726567; CLI artifact 11825383860.
    $digest = if ($Consumer -ceq 'integration') { 'ef66a907aabc8772221c5b077c08b082850258d58ba0e140fc06617770a3b28d' } else { '436a79dd899a42dbcc0dac947f65e708e7295f77078573365cbfa1c5f0ef9dd3' }
    $bytes = [Convert]::FromBase64String((Get-Content -LiteralPath (Join-Path $Root "$Consumer.zip.b64") -Raw).Trim())
    $zipPath = "$Destination.zip"
    [IO.File]::WriteAllBytes($zipPath, $bytes)
    if ((Get-FileHash -LiteralPath $zipPath).Hash.ToLowerInvariant() -cne $digest) { throw 'Archived bootstrap proof differs from its official Actions digest.' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        if ($zip.Entries.Count -ne 1 -or $zip.Entries[0].FullName -cne 'candidate.json') { throw 'Unexpected bootstrap proof inventory.' }
        $reader = New-Object IO.StreamReader($zip.Entries[0].Open())
        try { $record = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
        Assert-WssCandidateRecord $record $Approval
        $record
    } finally { $zip.Dispose() }
}

function Assert-WssApproval($Approval, [string] $EvidenceRoot, [string] $BootstrapEvidenceRoot = '') {
    if (Test-Path -LiteralPath $EvidenceRoot) { throw 'EvidenceRoot must be new.' }
    New-Item -ItemType Directory -Path $EvidenceRoot | Out-Null
    $c = $Approval.candidate
    $producer = Invoke-WssGh @('api', "repos/$($c.repository)/actions/runs/$($c.run_id)") | ConvertFrom-Json
    if ($producer.repository.full_name -cne $c.repository -or $producer.path -cne '.github/workflows/artifacts.yml' -or
        $producer.head_sha -cne $c.commit -or $producer.status -cne 'completed' -or $producer.conclusion -cne 'success' -or
        $producer.event -notin @('workflow_dispatch', 'push')) { throw 'Producer approval is not a successful exact-commit authoritative run.' }
    $artifact = Invoke-WssGh @('api', "repos/$($c.repository)/actions/artifacts/$($c.artifact_id)") | ConvertFrom-Json
    if ($artifact.name -cne 'universal-release-assets' -or $artifact.expired -or
        [string]$artifact.workflow_run.id -cne $c.run_id -or $artifact.workflow_run.head_sha -cne $c.commit) { throw 'Artifact ID is not the approved producer artifact.' }
    foreach ($consumer in @('integration', 'cli')) {
        $repo = if ($consumer -ceq 'integration') { 'cwru-non-academic/CSharp_WSS_Integration_Lib' } else { 'cwru-non-academic/CLI_CSharp_WSS_Application' }
        $expected = $Approval.$consumer
        $run = Invoke-WssGh @('api', "repos/$repo/actions/runs/$($expected.preflight_run_id)") | ConvertFrom-Json
        if ($run.repository.full_name -cne $repo -or $run.path -cne '.github/workflows/wss-preflight.yml' -or
            $run.event -cne 'workflow_dispatch' -or $run.head_sha -cne $expected.source_sha -or
            $run.status -cne 'completed' -or $run.conclusion -cne 'success') { throw "Invalid $consumer preflight approval." }
        $destination = Join-Path $EvidenceRoot $consumer
        if ($BootstrapEvidenceRoot) {
            $record = Read-WssBootstrapProof $BootstrapEvidenceRoot $consumer $Approval $destination
        } else {
            Invoke-WssGh @('run', 'download', [string]$expected.preflight_run_id, '--repo', $repo, '--name', 'wss-candidate-provenance', '--dir', $destination)
            $record = Get-Content -LiteralPath (Join-Path $destination 'candidate.json') -Raw | ConvertFrom-Json
        }
        Assert-WssCandidateRecord $record $Approval
    }
    # Existing preflight provenance records contain the candidate, not the selected
    # Integration SHA. Bind it using the successful checkout-verification job's log.
    $pages = Invoke-WssGh @('api', '--paginate', '--slurp', "repos/cwru-non-academic/CLI_CSharp_WSS_Application/actions/runs/$($Approval.cli.preflight_run_id)/jobs?per_page=100") | ConvertFrom-Json
    $jobs = @($pages | ForEach-Object { $_.jobs } | Where-Object { $_.name -ceq 'CLI general conformance' -and $_.conclusion -ceq 'success' })
    if ($jobs.Count -ne 1) { throw 'Missing unique successful CLI source-verification job.' }
    $logs = (Invoke-WssGh @('run', 'view', [string]$Approval.cli.preflight_run_id, '--repo', 'cwru-non-academic/CLI_CSharp_WSS_Application', '--job', [string]$jobs[0].id, '--log')) -join "`n"
    $shas = [Regex]::Matches($logs, 'EXPECTED_INTEGRATION_SHA: ([0-9a-f]{40})')
    if ($shas.Count -eq 0 -or @($shas | Where-Object { $_.Groups[1].Value -cne $Approval.integration.source_sha }).Count -ne 0) {
        throw 'CLI preflight did not verify the approved Integration source SHA.'
    }
}

function Assert-WssLib([string] $Lib, [string] $ArtifactRoot, $Approval) {
    . "$PSScriptRoot/Universal-WssFiles.ps1"
    $root = (Resolve-Path -LiteralPath $Lib).Path
    $actual = @(Get-ChildItem -LiteralPath $root -File -Recurse | ForEach-Object { $_.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/') })
    if ('wss-candidate.json' -cnotin $actual) { throw 'Committed lib provenance is missing.' }
    $selectedFiles = @(Get-WssUniversalFiles @($actual | Where-Object { $_ -cne 'wss-candidate.json' }))
    $sourceFiles = @(Read-WssUniversalFiles $ArtifactRoot)
    if (@(Compare-Object $selectedFiles $sourceFiles -CaseSensitive).Count -ne 0) { throw 'Committed and candidate inventory variants differ.' }
    Assert-WssMacOSPayload $root $selectedFiles
    Assert-WssMacOSPayload $ArtifactRoot $sourceFiles
    $record = Read-WssApproval (Join-Path $root 'wss-candidate.json')
    if ((Get-WssApprovalMarker $record) -cne (Get-WssApprovalMarker $Approval)) { throw 'Committed lib approval differs.' }
    foreach ($relative in $selectedFiles) {
        if ((Get-FileHash -LiteralPath (Join-Path $root $relative)).Hash -cne
            (Get-FileHash -LiteralPath (Join-Path $ArtifactRoot $relative)).Hash) { throw "Committed universal bytes differ: $relative" }
    }
}

function Assert-WssPaths([string[]] $Paths, [string[]] $ExtraAllowed = @()) {
    if ($Paths.Count -eq 0) { throw 'Promotion diff is empty.' }
    foreach ($path in $Paths) {
        if ($path -cnotmatch '^lib/' -and $path -cnotin $ExtraAllowed) { throw "Unexpected promotion path: $path" }
    }
}

function Assert-WssNewtonsoftTestAlignment([string] $BeforeBlob, [string] $AfterBlob, [string] $CandidateNewtonsoftHash) {
    # Authorized first-bootstrap correction only: the original validated test project
    # plus only the Newtonsoft.Json 13.0.3 graph pin (excluding package compile/runtime
    # assets) and a direct copy-local reference to the candidate DLL. Git blob IDs bind
    # the whole file, not a path allowlist; the candidate DLL must also match.
    if ($BeforeBlob -cne 'ac4ca9ca0371f2896f4a29b4f3ec1db55025f363' -or
        $AfterBlob -cne 'e7bcaa356b22dc7b213c90d8ff2f6c5a8e5d6155' -or
        $CandidateNewtonsoftHash -cne '8c1dd5c184b4e2e7ead06971ff3ebcb46783be972292d1deb1061744369b4d80') {
        throw 'Test dependency change is not the exact authorized candidate-matching Newtonsoft alignment.'
    }
}

function Assert-WssSource([string] $Worktree, [string] $SourceSha) {
    # Only packaging/promotion automation and documentation may differ from the
    # tested source. Application, dependency references, preflight and tests must match.
    $allowed = @('README.md', '.github/scripts/New-WssLib.ps1', '.github/scripts/WssPromotion.ps1', '.github/scripts/WssAutomatic.ps1',
        '.github/scripts/Prepare-UniversalBootstrap.ps1', '.github/workflows/promote-wss.yml',
        '.github/workflows/dispatch-cli-promotion.yml', '.github/workflows/promote-integration.yml',
        '.github/workflows/cli-ci.yml', '.github/workflows/wss-compatibility.yml', '.github/scripts/tests/WssPromotion.Tests.ps1',
        '.github/universal-bootstrap.json', '.github/promotion-evidence/integration.zip.b64', '.github/promotion-evidence/cli.zip.b64')
    $paths = @(& git -C $Worktree diff --name-only $SourceSha HEAD)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot compare approved source with promotion source.' }
    $testProject = 'tests/Wss.CSharpImplementation.Tests/Wss.CSharpImplementation.Tests.csproj'
    if ($paths -ccontains $testProject) {
        $before = (& git -C $Worktree rev-parse "${SourceSha}:$testProject").Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect validated test-project blob.' }
        $after = (& git -C $Worktree rev-parse "HEAD:$testProject").Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect corrected test-project blob.' }
        $hash = (Get-FileHash -LiteralPath (Join-Path $Worktree 'lib/Newtonsoft.Json.dll')).Hash.ToLowerInvariant()
        Assert-WssNewtonsoftTestAlignment $before $after $hash
        $paths = @($paths | Where-Object { $_ -cne $testProject })
    }
    if ($paths.Count -gt 0) { Assert-WssPaths $paths $allowed }
}

function Assert-WssMergedIntegration([string] $Sha, [string] $PrNumber, $Approval) {
    if ($Sha -cnotmatch '^[0-9a-f]{40}$' -or $PrNumber -cnotmatch '^[1-9][0-9]*$') { throw 'Invalid Integration merge SHA/PR.' }
    $repo = 'cwru-non-academic/CSharp_WSS_Integration_Lib'
    $pr = Invoke-WssGh @('api', "repos/$repo/pulls/$PrNumber") | ConvertFrom-Json
    if (-not $pr.merged -or $pr.base.ref -cne 'dev' -or $pr.base.repo.full_name -cne $repo -or
        $pr.head.repo.full_name -cne $repo -or $pr.merge_commit_sha -cne $Sha) { throw 'Gitlink must target the actual merged Integration dev PR commit.' }
    $compare = Invoke-WssGh @('api', "repos/$repo/compare/${Sha}...dev") | ConvertFrom-Json
    if ($compare.status -notin @('ahead', 'identical')) { throw 'Integration merge is not contained in dev.' }
    $pages = Invoke-WssGh @('api', '--paginate', '--slurp', "repos/$repo/actions/workflows/wss-compatibility.yml/runs?event=pull_request&head_sha=$($pr.head.sha)&per_page=100") | ConvertFrom-Json
    # GitHub can return empty pull_requests after merge. Bind evidence to the exact
    # canonical PR head, branch, event and workflow; reject conflicting associations.
    $allRuns = @($pages | ForEach-Object { $_.workflow_runs } | Where-Object {
        $_.repository.full_name -ceq $repo -and $_.head_repository.full_name -ceq $repo -and
        $_.path -ceq '.github/workflows/wss-compatibility.yml' -and $_.event -ceq 'pull_request' -and
        $_.head_sha -ceq $pr.head.sha -and $_.head_branch -ceq $pr.head.ref -and
        (@($_.pull_requests).Count -eq 0 -or
            (@($_.pull_requests).Count -eq 1 -and
                [string]$_.pull_requests[0].number -ceq $PrNumber))
    } | Sort-Object -Property id -Descending)
    if ($allRuns.Count -eq 0 -or $allRuns[0].status -cne 'completed' -or $allRuns[0].conclusion -cne 'success') {
        throw 'Merged Integration PR lacks successful latest normal committed-state CI at its final head.'
    }
    $jobPages = Invoke-WssGh @('api', '--paginate', '--slurp', "repos/$repo/actions/runs/$($allRuns[0].id)/jobs?per_page=100") | ConvertFrom-Json
    $jobs = @($jobPages | ForEach-Object { $_.jobs })
    foreach ($name in @('Integration behavioral tests', 'Integration compatibility (Windows)', 'Integration compatibility (Ubuntu)', 'Integration compatibility (macOS)')) {
        $found = @($jobs | Where-Object { $_.name -ceq $name -and $_.conclusion -ceq 'success' })
        if ($found.Count -ne 1) { throw "Required normal Integration CI job did not succeed: $name" }
    }
    $content = Invoke-WssGh @('api', "repos/$repo/contents/lib/wss-candidate.json?ref=$Sha") | ConvertFrom-Json
    $recordPath = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
    try {
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($content.content)) | Set-Content -LiteralPath $recordPath
        if ((Get-WssApprovalMarker (Read-WssApproval $recordPath)) -cne (Get-WssApprovalMarker $Approval)) { throw 'Merged Integration candidate approval differs.' }
    } finally { Remove-Item -LiteralPath $recordPath -ErrorAction SilentlyContinue }
    $pr
}
