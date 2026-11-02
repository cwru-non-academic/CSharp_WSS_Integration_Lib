param(
    [Parameter(Mandatory)][ValidateSet('csharp','unity')][string]$Receiver,
    [Parameter(Mandatory)][string]$RecordPath,
    [Parameter(Mandatory)][string]$WorkRoot,
    [string]$CoreRoot = '.core-stage'
)
$ErrorActionPreference = 'Stop'
$core = 'cwru-non-academic/WSSCore'
function Read-GitHub([string]$Path) {
    $raw = & gh api $Path
    if ($LASTEXITCODE -ne 0) { throw "Read-only GitHub lookup failed: $Path" }
    return ($raw | ConvertFrom-Json)
}
function Read-RepositoryJson([string]$Repository, [string]$Commit, [string]$Path) {
    $file = Read-GitHub "repos/$Repository/contents/$($Path)?ref=$Commit"
    if ($file.type -cne 'file' -or $file.encoding -cne 'base64') { throw 'Expected immutable JSON file.' }
    return ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($file.content)) | ConvertFrom-Json)
}
function Write-ReadyEvent($PullRequest) {
    if (!$PullRequest.merged -or $PullRequest.state -cne 'closed' -or
        $PullRequest.base.ref -cne 'dev' -or $PullRequest.base.repo.full_name -cne $env:GITHUB_REPOSITORY -or
        $PullRequest.head.repo.full_name -cne $env:GITHUB_REPOSITORY -or $PullRequest.user.type -cne 'Bot') {
        throw 'Expected a merged same-repository bot dependency PR targeting dev.'
    }
    New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
    $path = Join-Path $WorkRoot 'fanout-event.json'
    @{pull_request=$PullRequest;repository=@{full_name=$env:GITHUB_REPOSITORY}} |
        ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path
    "event_path=$path" >> $env:GITHUB_OUTPUT
    "merge_sha=$($PullRequest.merge_commit_sha)" >> $env:GITHUB_OUTPUT
    'dispatch_allowed=true' >> $env:GITHUB_OUTPUT
}
if ($env:GITHUB_ACTIONS -cne 'true') { throw 'GitHub Actions execution required.' }
$cap = Get-Content .github/dev-propagation.json -Raw | ConvertFrom-Json
if ($cap.schema -cne 'wss-dev-stage-receiver/v1' -or !$cap.staged_applications) { throw 'Staged receiver contract required.' }
if ($env:GITHUB_EVENT_NAME -ceq 'workflow_dispatch') {
    if ($env:GITHUB_REF -cne 'refs/heads/main' -or
        $env:PRODUCER_RUN_ID -cnotmatch '^[1-9][0-9]*$' -or
        $env:BARRIER_RUN_ID -cnotmatch '^[1-9][0-9]*$' -or
        $env:BARRIER_ATTEMPT -cnotmatch '^[1-9][0-9]*$') { throw 'Resume requires main and exact positive run identities.' }
    $trusted = Read-GitHub "repos/$core/git/ref/heads/main"
    $checkedOut = & git -C $CoreRoot rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $checkedOut -cne $trusted.object.sha) { throw 'Core verifier checkout is not current trusted main.' }
    $raw = & node (Join-Path $CoreRoot 'tools/ci/dev-propagation.mjs') verify-barrier $env:PRODUCER_RUN_ID $env:BARRIER_RUN_ID $env:BARRIER_ATTEMPT
    if ($LASTEXITCODE -ne 0) { throw 'Trusted Core integration barrier verification failed.' }
    $barrier = $raw | ConvertFrom-Json
    $accepted = $barrier.integrations.$Receiver
    if ($accepted.repository -cne $env:GITHUB_REPOSITORY -or $accepted.pr_number -cnotmatch '^[1-9][0-9]*$') {
        throw 'Barrier does not name this receiver.'
    }
    $pr = Read-GitHub "repos/$($env:GITHUB_REPOSITORY)/pulls/$($accepted.pr_number)"
    if ($pr.merge_commit_sha -cne $accepted.head_sha) { throw 'Barrier merge identity changed.' }
    Write-ReadyEvent $pr
} elseif ($env:GITHUB_EVENT_NAME -ceq 'pull_request_target') {
    $event = Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json
    $pr = $event.pull_request
    if ($pr.merge_commit_sha -cnotmatch '^[0-9a-f]{40}$') { throw 'Invalid integration merge identity.' }
    $record = Read-RepositoryJson $env:GITHUB_REPOSITORY $pr.merge_commit_sha $RecordPath
    $candidate = $record.candidate
    if ($candidate.repository -cne $core -or $candidate.run_id -cnotmatch '^[1-9][0-9]*$' -or
        $candidate.commit -cnotmatch '^[0-9a-f]{40}$') { throw 'Invalid canonical producer identity.' }
    $run = Read-GitHub "repos/$core/actions/runs/$($candidate.run_id)"
    if ($run.repository.full_name -cne $core -or $run.head_repository.full_name -cne $core -or
        $run.head_sha -cne $candidate.commit -or $run.path -cne '.github/workflows/artifacts.yml' -or
        $run.event -cne 'push' -or $run.head_branch -cne 'dev' -or $run.conclusion -cne 'success') {
        throw 'Candidate is not a successful canonical Core dev producer.'
    }
    # A successful immutable tree lookup distinguishes absence from lookup/auth failure.
    $tree = Read-GitHub "repos/$core/git/trees/$($candidate.commit)?recursive=1"
    if ($tree.truncated) { throw 'Cannot establish staging policy absence from a truncated tree.' }
    $policyPath = 'tools/ci/dev-propagation.json'
    $entry = @($tree.tree | Where-Object path -CEQ $policyPath)
    if ($entry.Count -eq 0) {
        Write-ReadyEvent $pr
    } else {
        $policy = Read-RepositoryJson $core $candidate.commit $policyPath
        $target = @($policy.libraries | Where-Object id -CEQ $Receiver)
        if ($entry.Count -ne 1 -or $policy.schema -cne 'wss-dev-stage/v1' -or $policy.channel -cne 'dev' -or
            $target.Count -ne 1 -or $target[0].repository -cne $env:GITHUB_REPOSITORY -or
            $target[0].fanout -cne $cap.fanout_workflow -or
            (@($target[0].applications | Sort-Object) -join ',') -cne (@($cap.applications | Sort-Object) -join ',')) {
            throw 'Producer staging policy does not match this receiver.'
        }
        'dispatch_allowed=false' >> $env:GITHUB_OUTPUT
        "Waiting for Core's complete integration barrier for producer $($candidate.run_id); no application write token requested." >> $env:GITHUB_STEP_SUMMARY
    }
} else { throw 'Unsupported fanout trigger.' }
