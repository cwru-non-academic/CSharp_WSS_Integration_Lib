param(
    [string] $ReleaseTag = '',
    [string] $ProducerRepository = 'cwru-non-academic/WSSCore',
    [string] $RunId = '',
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string] $ExpectedCommit,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^WSS-Universal-[A-Za-z0-9._-]+\.zip$')]
    [string] $ArchiveName,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string] $ExpectedSha256,
    [Parameter(Mandatory = $true)]
    [string] $OutputRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/Universal-WssFiles.ps1"

function Invoke-Gh([string[]] $Arguments) {
    $result = & gh @Arguments
    if ($LASTEXITCODE -ne 0) { throw "gh failed ($LASTEXITCODE): $($Arguments -join ' ')" }
    return $result
}

if ($ProducerRepository -cne 'cwru-non-academic/WSSCore') {
    throw 'Only the authoritative cwru-non-academic/WSSCore producer is accepted.'
}
if (([string]::IsNullOrEmpty($RunId)) -eq ([string]::IsNullOrEmpty($ReleaseTag))) {
    throw 'Specify exactly one of RunId or ReleaseTag. No default or older candidate is substituted.'
}
if (Test-Path -LiteralPath $OutputRoot) { throw 'OutputRoot must be a new directory.' }

$artifactId = $null
if ($ReleaseTag) {
    if ($ReleaseTag -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or
        $ArchiveName -cne "WSS-Universal-$ReleaseTag.zip") { throw 'Invalid universal release tag/archive pair.' }
    $commit = Invoke-Gh @('api', "repos/$ProducerRepository/commits/$ReleaseTag") | ConvertFrom-Json
    if ($commit.sha -ine $ExpectedCommit) { throw 'Release tag does not resolve to ExpectedCommit.' }
    $release = Invoke-Gh @('api', "repos/$ProducerRepository/releases/tags/$ReleaseTag") | ConvertFrom-Json
    if ($release.draft -or $release.tag_name -cne $ReleaseTag) { throw 'Release is not published for the requested tag.' }
    $pages = Invoke-Gh @('api', '--paginate', '--slurp', "repos/$ProducerRepository/actions/workflows/artifacts.yml/runs?event=push&head_sha=$ExpectedCommit&per_page=100") | ConvertFrom-Json
    $runs = @($pages | ForEach-Object { $_.workflow_runs } | Where-Object {
        $_.head_branch -ceq $ReleaseTag -and $_.status -ceq 'completed' -and $_.conclusion -ceq 'success'
    })
    if ($runs.Count -ne 1) { throw 'Release must resolve to exactly one successful authoritative tag-push run.' }
    $RunId = [string] $runs[0].id
}

if ($RunId) {
    if ($RunId -notmatch '^[1-9][0-9]*$') { throw 'RunId must be a positive integer.' }
    $run = Invoke-Gh @('api', "repos/$ProducerRepository/actions/runs/$RunId") | ConvertFrom-Json
    if ($run.repository.full_name -cne $ProducerRepository -or
        $run.path -cne '.github/workflows/artifacts.yml' -or
        $run.status -cne 'completed' -or $run.conclusion -cne 'success') {
        throw 'Candidate must come from a successful completed authoritative producer workflow.'
    }
    if ($run.head_sha -ine $ExpectedCommit) { throw "Producer commit mismatch: $($run.head_sha)" }
    # PR runs are merge-ref candidates, not proof of the merged dev revision.
    if ($run.event -notin @('workflow_dispatch', 'push')) { throw 'PR artifacts are not accepted as merged candidates.' }
    $artifacts = Invoke-Gh @('api', '--paginate', '--slurp', "repos/$ProducerRepository/actions/runs/$RunId/artifacts?per_page=100") | ConvertFrom-Json
    $matches = @($artifacts | ForEach-Object { $_.artifacts } | Where-Object { $_.name -ceq 'universal-release-assets' })
    if ($matches.Count -ne 1 -or $matches[0].expired) { throw 'Exactly one unexpired universal-release-assets artifact is required.' }
    $artifactId = $matches[0].id
}

$downloadDir = Join-Path $OutputRoot 'downloads'
New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
# Even tag selection consumes the immutable Actions archive, never manually attached release assets.
Invoke-Gh @('run', 'download', $RunId, '--repo', $ProducerRepository, '--name', 'universal-release-assets', '--dir', $downloadDir)
$files = @(Get-ChildItem -LiteralPath $downloadDir -File -Recurse)
if ($files.Count -ne 2 -or -not (Test-Path -LiteralPath (Join-Path $downloadDir $ArchiveName) -PathType Leaf) -or
    -not (Test-Path -LiteralPath (Join-Path $downloadDir 'SHA256SUMS.txt') -PathType Leaf)) {
    throw 'Candidate artifact must contain exactly the requested universal ZIP and SHA256SUMS.txt.'
}
$checksum = (Get-Content -LiteralPath (Join-Path $downloadDir 'SHA256SUMS.txt') -Raw).Trim()
$match = [Regex]::Match($checksum, "^(?<hash>[0-9a-fA-F]{64})\s+\*?$([Regex]::Escape($ArchiveName))$")
if (-not $match.Success -or $match.Groups['hash'].Value -ine $ExpectedSha256) { throw 'Published checksum does not match the pinned archive SHA-256.' }
$archive = Join-Path $downloadDir $ArchiveName
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $ExpectedSha256) { throw 'Universal archive SHA-256 mismatch.' }

# Validate ZIP paths and inventory before extraction, including case-colliding entries.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    $entries = @($zip.Entries | ForEach-Object { $_.FullName })
    if (@($entries | Where-Object { -not $_.StartsWith('WSS-Universal/', [StringComparison]::Ordinal) }).Count -ne 0) {
        throw 'ZIP entries must remain under WSS-Universal/.'
    }
    $selectedFiles = @(Get-WssUniversalFiles @($entries | ForEach-Object { $_.Substring(14) }))
} finally { $zip.Dispose() }
Expand-Archive -LiteralPath $archive -DestinationPath (Join-Path $OutputRoot 'extracted')
$root = (Resolve-Path -LiteralPath (Join-Path $OutputRoot 'extracted/WSS-Universal')).Path
Assert-WssMacOSPayload $root $selectedFiles
if ($WssMacOSFiles[0] -cin $selectedFiles) {
    $pages = Invoke-Gh @('api', '--paginate', '--slurp', "repos/$ProducerRepository/actions/runs/$RunId/jobs?per_page=100") | ConvertFrom-Json
    $jobs = @($pages | ForEach-Object { $_.jobs })
    Assert-WssMacOSProducerJobs $jobs
}
$provenance = [ordered]@{
    repository = $ProducerRepository; run_id = $RunId; artifact_id = $artifactId
    commit = $ExpectedCommit.ToLowerInvariant(); release_tag = $ReleaseTag
    archive = $ArchiveName; sha256 = $ExpectedSha256.ToLowerInvariant()
}
$provenance | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputRoot 'candidate.json')
if ($env:GITHUB_ENV) {
    "WSS_ARTIFACT_DIR=$root" >> $env:GITHUB_ENV
    "WSS_BLE_ARTIFACT_DIR=$root" >> $env:GITHUB_ENV
}
if ($env:GITHUB_STEP_SUMMARY) {
    '## Verified universal candidate' >> $env:GITHUB_STEP_SUMMARY
    ($provenance | ConvertTo-Json) >> $env:GITHUB_STEP_SUMMARY
}
"Verified universal root: $root"
