param(
    [Parameter(Mandatory = $true)] [ValidateSet('Integration', 'CLI')] [string] $Repository,
    [Parameter(Mandatory = $true)] [string] $Worktree,
    [Parameter(Mandatory = $true)] [string] $ScratchRoot,
    [string] $IntegrationPr = '',
    [switch] $Stage
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/WssPromotion.ps1"
$approval = Read-WssApproval "$PSScriptRoot/../universal-bootstrap.json"
# This exception cannot be used for later candidates or unrelated source changes.
if ($approval.candidate.run_id -cne '38418794761' -or $approval.candidate.artifact_id -cne '11825915903' -or
    $approval.candidate.commit -cne '378a489423cac6e812327da52e5031922d4ed7e7' -or
    $approval.candidate.archive -cne 'WSS-Universal-ci.zip' -or
    $approval.candidate.sha256 -cne '7571d47a8b687e59f65ddb24bce9b77220095f8cd79ed44056f9f19f465ccb2a' -or
    $approval.integration.source_sha -cne 'cd181c1f2abca8048fc2d1181dbf9beca9050e21' -or $approval.integration.preflight_run_id -cne '38420209110' -or
    $approval.cli.source_sha -cne 'a3b272b23fba4e566d7c1fe3bfafa048cca9806c' -or $approval.cli.preflight_run_id -cne '38420541537') {
    throw 'Bootstrap is restricted to the first verified migration; use routine promotion for future candidates.'
}
$worktree = (Resolve-Path -LiteralPath $Worktree).Path
$worktrees = @(& git -C $worktree worktree list --porcelain)
if ($LASTEXITCODE -ne 0 -or $worktrees.Count -eq 0) { throw 'Cannot verify separate worktree.' }
$primary = $worktrees[0].Substring('worktree '.Length).Replace('/', '\')
if ($worktree.Replace('/', '\') -ieq $primary) { throw 'Bootstrap must use a separate worktree, never the original pinned checkout.' }
$remote = (& git -C $worktree remote get-url origin).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Worktree lacks origin.' }
$repoName = if ($Repository -ceq 'Integration') { 'CSharp_WSS_Integration_Lib' } else { 'CLI_CSharp_WSS_Application' }
$accepted = @("https://github.com/cwru-non-academic/$repoName.git", "https://github.com/cwru-non-academic/$repoName", "git@github.com:cwru-non-academic/$repoName.git")
if ($Repository -ceq 'Integration') { $accepted += 'git@github.com:cwru-non-academic/HFI_WSS_Csharp_Implementation.git' }
if ($remote -cnotin $accepted) { throw 'Wrong bootstrap target repository.' }
$status = @(& git -C $worktree status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $status.Count -ne 0) { throw 'Use a clean separate checkout with the reviewed automation committed. No unrelated changes may be overwritten.' }
$source = if ($Repository -ceq 'Integration') { $approval.integration.source_sha } else { $approval.cli.source_sha }
& git -C $worktree merge-base --is-ancestor $source HEAD
if ($LASTEXITCODE -ne 0) { throw 'Bootstrap branch must include the exact validated source history.' }
Assert-WssSource $worktree $source
if ($Repository -ceq 'Integration') {
    $toolsRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    foreach ($relative in @('.github/scripts/WssPromotion.ps1', '.github/scripts/New-WssLib.ps1',
        '.github/scripts/Prepare-UniversalBootstrap.ps1', '.github/scripts/tests/WssPromotion.Tests.ps1',
        '.github/workflows/promote-wss.yml', '.github/workflows/dispatch-cli-promotion.yml',
        '.github/workflows/wss-compatibility.yml', '.github/universal-bootstrap.json',
        '.github/promotion-evidence/integration.zip.b64', '.github/promotion-evidence/cli.zip.b64')) {
        $file = Join-Path $worktree $relative
        if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or
            (Get-FileHash -LiteralPath $file).Hash -cne (Get-FileHash -LiteralPath (Join-Path $toolsRoot $relative)).Hash) {
            throw "Bootstrap checkout must include the reviewed promotion tooling: $relative"
        }
    }
} else {
    $workflow = Get-Content -LiteralPath (Join-Path $worktree '.github/workflows/promote-integration.yml') -Raw
    $ci = Get-Content -LiteralPath (Join-Path $worktree '.github/workflows/cli-ci.yml') -Raw
    if ($workflow -notmatch 'Validate universal approval and merged Integration state' -or
        $workflow -notmatch 'Check out trusted Integration dev promotion tools' -or
        $ci -notmatch 'Verify committed universal build and publish propagation') {
        throw 'CLI bootstrap checkout lacks the reviewed universal promotion/committed-state CI automation.'
    }
}
& git -C $worktree fetch origin dev
if ($LASTEXITCODE -ne 0) { throw 'Cannot fetch current dev.' }
& git -C $worktree merge-base --is-ancestor origin/dev HEAD
if ($LASTEXITCODE -ne 0) { throw 'Dev advanced outside this bootstrap branch; coordinate/review before preparing a PR.' }
if (Test-Path -LiteralPath $ScratchRoot) { throw 'ScratchRoot must be new.' }
New-Item -ItemType Directory -Path $ScratchRoot | Out-Null
Assert-WssApproval $approval (Join-Path $ScratchRoot 'evidence') "$PSScriptRoot/../promotion-evidence"
$approvalPath = Join-Path $ScratchRoot 'approval.json'
Write-WssApproval $approval $approvalPath
& "$PSScriptRoot/Resolve-WssRelease.ps1" -RunId $approval.candidate.run_id -ExpectedCommit $approval.candidate.commit -ArchiveName $approval.candidate.archive -ExpectedSha256 $approval.candidate.sha256 -OutputRoot (Join-Path $ScratchRoot 'release')
Assert-WssCandidateRecord (Get-Content (Join-Path $ScratchRoot 'release/candidate.json') -Raw | ConvertFrom-Json) $approval
$artifactRoot = Join-Path $ScratchRoot 'release/extracted/WSS-Universal'
$desired = Join-Path $ScratchRoot 'desired-lib'
& "$PSScriptRoot/New-WssLib.ps1" -ArtifactRoot $artifactRoot -ApprovalFile $approvalPath -Destination $desired
$extra = @('README.md', '.github/scripts/New-WssLib.ps1', '.github/scripts/WssPromotion.ps1',
    '.github/scripts/Prepare-UniversalBootstrap.ps1', '.github/scripts/tests/WssPromotion.Tests.ps1',
    '.github/universal-bootstrap.json', '.github/promotion-evidence/integration.zip.b64', '.github/promotion-evidence/cli.zip.b64',
    '.github/workflows/promote-wss.yml', '.github/workflows/dispatch-cli-promotion.yml',
    '.github/workflows/promote-integration.yml', '.github/workflows/cli-ci.yml')
if ($Repository -ceq 'Integration') {
    $extra += @('.github/scripts/Resolve-WssRelease.ps1', '.github/scripts/Universal-WssFiles.ps1', '.github/scripts/Verify-WssOutput.ps1',
        '.github/workflows/wss-preflight.yml', '.github/workflows/wss-compatibility.yml', 'src/Wss.CSharpImplementation.csproj',
        'tests/Wss.CSharpImplementation.Tests/Wss.CSharpImplementation.Tests.csproj',
        'tests/Wss.CSharpImplementation.Tests/BleBackendLoadingTests.cs', 'tests/Wss.CSharpImplementation.Tests/SerialRuntimeSelectionTests.cs')
} else {
    $extra += @('.github/workflows/wss-preflight.yml', 'src/CLI_CSharp_WSS_Application.csproj', 'SubModules/HFI_WSS_Csharp_Implementation')
    if ($IntegrationPr -cnotmatch '^[1-9][0-9]*$') { throw 'CLI bootstrap requires the reviewed, merged Integration PR number.' }
    $pr = Invoke-WssGh @('api', "repos/cwru-non-academic/CSharp_WSS_Integration_Lib/pulls/$IntegrationPr") | ConvertFrom-Json
    $mergeSha = [string]$pr.merge_commit_sha
    $null = Assert-WssMergedIntegration $mergeSha $IntegrationPr $approval
    $merged = Join-Path $ScratchRoot 'merged-integration'
    Invoke-WssGh @('repo', 'clone', 'cwru-non-academic/CSharp_WSS_Integration_Lib', $merged, '--', '--no-checkout')
    & git -C $merged checkout --detach $mergeSha
    if ($LASTEXITCODE -ne 0) { throw 'Cannot check out actual merged Integration SHA.' }
    Assert-WssSource $merged $approval.integration.source_sha
    Assert-WssLib (Join-Path $merged 'lib') $artifactRoot $approval
}
$paths = @(& git -C $worktree diff --name-only origin/dev...HEAD)
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect bootstrap source diff.' }
Assert-WssPaths $paths $extra
if ($Stage) {
    & git -C $worktree switch -c bootstrap/universal-wss-378a489
    if ($LASTEXITCODE -ne 0) { throw 'Bootstrap branch already exists or cannot be created; no overwrite is allowed.' }
    if ($Repository -ceq 'Integration') {
        Remove-Item -LiteralPath (Join-Path $worktree 'lib') -Recurse -Force
        Copy-Item -LiteralPath $desired -Destination (Join-Path $worktree 'lib') -Recurse
        Assert-WssLib (Join-Path $worktree 'lib') $artifactRoot $approval
        & git -C $worktree add -A -- lib
    } else {
        & git -C $worktree update-index --cacheinfo "160000,$mergeSha,SubModules/HFI_WSS_Csharp_Implementation"
    }
    if ($LASTEXITCODE -ne 0) { throw 'Failed to stage bootstrap changes.' }
    $staged = @(& git -C $worktree diff --cached --name-only)
    if ($Repository -ceq 'Integration') { Assert-WssPaths $staged } else {
        if ($staged.Count -ne 1 -or $staged[0] -cne 'SubModules/HFI_WSS_Csharp_Implementation') { throw 'CLI bootstrap staged unexpected paths.' }
        $entry = (& git -C $worktree ls-files --stage -- SubModules/HFI_WSS_Csharp_Implementation) -join ''
        if ($entry -cne "160000 $mergeSha 0`tSubModules/HFI_WSS_Csharp_Implementation") { throw 'Staged CLI gitlink differs from the actual merged commit.' }
    }
    & git -C $worktree diff --cached --check
    if ($LASTEXITCODE -ne 0) { throw 'Bootstrap staged diff failed validation.' }
}
@(
    '<!-- wss-bootstrap:v1 -->'
    (Get-WssApprovalMarker $approval)
    "First universal $Repository migration: validated source plus verified committed dependencies/gitlink."
    "Integration source: $($approval.integration.source_sha); CLI source: $($approval.cli.source_sha)."
    "Producer run: https://github.com/cwru-non-academic/WSSCore/actions/runs/$($approval.candidate.run_id)"
    "SHA-256: $($approval.candidate.sha256)"
    "Integration preflight: https://github.com/cwru-non-academic/CSharp_WSS_Integration_Lib/actions/runs/$($approval.integration.preflight_run_id)"
    "CLI preflight: https://github.com/cwru-non-academic/CLI_CSharp_WSS_Application/actions/runs/$($approval.cli.preflight_run_id)"
    "Integration merged PR (CLI only): $IntegrationPr"
    'Require successful NORMAL committed-state CI and human review before manual merge.'
    'This bootstrap is outside routine bot/lib-only dispatch. No automatic merge or promotion has occurred.'
) | Set-Content -LiteralPath (Join-Path $ScratchRoot 'bootstrap-pr-body.md')
"Bootstrap verified. Stage=$Stage. No commit, push, PR creation, or merge was performed. PR body: $ScratchRoot/bootstrap-pr-body.md"
