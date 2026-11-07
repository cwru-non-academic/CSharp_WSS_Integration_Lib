param([string]$RepositoryRoot = (Join-Path $PSScriptRoot '../../..'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# This is a drift regression, not a replacement source authority. Runtime still
# uses the independent reviewed literals in each workflow. Canonical sync-tooling
# separately verifies the source lock, origins and every managed file hash.
function Assert-ReviewedPackageGuard([string]$Text, $Lock) {
    if ($Lock.source_repository -cne 'cwru-non-academic/WSSCore' -or
        $Lock.source_commit -cnotmatch '^[a-f0-9]{40}$' -or
        $Lock.source_ref -cne "refs/heads/ci/tooling/$($Lock.source_commit)") {
        throw 'Invalid reviewed package source lock.'
    }
    $lines = @($Text -split '\r?\n' | Where-Object { $_.Contains('Unexpected reviewed package verifier lock.') })
    $expected = 'if ($lock.source_repository -cne ''cwru-non-academic/WSSCore'' -or $lock.source_commit -cne ''' + $Lock.source_commit + ''' -or $lock.source_ref -cne "refs/heads/ci/tooling/$($lock.source_commit)") { throw ''Unexpected reviewed package verifier lock.'' }'
    if ($lines.Count -ne 1 -or $lines[0].Trim() -cne $expected) {
        throw 'Reviewed package workflow guard differs from canonical lock or exact fail-closed contract.'
    }
    # Execute only the exact validated guard, without any workflow side effects.
    [scriptblock]::Create($lines[0].Trim())
}
function Invoke-ReviewedGuard([scriptblock]$Guard, $lock) { & $Guard }
function Expect-GuardRejection([scriptblock]$Action, [string]$Name) {
    $rejected = $false
    try { $null = & $Action } catch { $rejected = $true }
    if (!$rejected) { throw "Reviewed package guard accepted: $Name" }
    $script:guardContracts++
}
$sourceLock = Get-Content (Join-Path $RepositoryRoot '.github/scripts/wss-ci.lock.json') -Raw | ConvertFrom-Json
$script:guardContracts = 0
foreach ($workflow in @('wss-compatibility.yml', 'wss-preflight.yml')) {
    $text = Get-Content (Join-Path $RepositoryRoot ".github/workflows/$workflow") -Raw
    $guard = Assert-ReviewedPackageGuard $text $sourceLock
    Invoke-ReviewedGuard $guard $sourceLock
    $script:guardContracts++
    foreach ($mutation in @(
        @{ field = 'source_repository'; value = 'other/WSSCore' },
        @{ field = 'source_repository'; value = 'cwru-non-academic/wsscore' },
        @{ field = 'source_commit'; value = ('f' * 40) },
        @{ field = 'source_commit'; value = $sourceLock.source_commit.ToUpperInvariant() },
        @{ field = 'source_commit'; value = $null },
        @{ field = 'source_ref'; value = 'refs/heads/dev' },
        @{ field = 'source_ref'; value = "refs/tags/ci/tooling/$($sourceLock.source_commit)" }
    )) {
        $changed = $sourceLock | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $changed.($mutation.field) = $mutation.value
        Expect-GuardRejection { Invoke-ReviewedGuard $guard $changed } "$workflow/$($mutation.field)"
    }
    $nextLock = $sourceLock | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $nextLock.source_commit = 'e' * 40
    $nextLock.source_ref = "refs/heads/ci/tooling/$($nextLock.source_commit)"
    Expect-GuardRejection { Assert-ReviewedPackageGuard $text $nextLock } "$workflow/future lock without guard refresh"
    Expect-GuardRejection { Assert-ReviewedPackageGuard ($text.Replace($sourceLock.source_commit, ('d' * 40))) $sourceLock } "$workflow/stale literal"
    Expect-GuardRejection { Assert-ReviewedPackageGuard ($text.Replace('-cne', '-ne')) $sourceLock } "$workflow/relaxed comparisons"
    Expect-GuardRejection { Assert-ReviewedPackageGuard '' $sourceLock } "$workflow/missing guard"
    Expect-GuardRejection { Assert-ReviewedPackageGuard ($text + "`n" + $text) $sourceLock } "$workflow/duplicate guard"
}
"Reviewed package guard contracts passed: $script:guardContracts. Both workflow literals match the canonical lock; source authority remains independent."
