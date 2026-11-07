# Trusted caller-side bridge. Selection authentication stays in reviewed Core code.
function Invoke-SelectedContextGit([string]$Root,[string[]]$Arguments) {
    $text=& git -C $Root @Arguments 2>&1
    if($LASTEXITCODE -ne 0){throw "Source identity command failed: $($text -join '`n')"}
    @($text)
}
function Assert-ReviewedSelectionCore([string]$CoreRoot) {
    $lock=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'wss-ci.lock.json') -Raw | ConvertFrom-Json
    if($lock.source_repository -cne 'cwru-non-academic/WSSCore' -or $lock.source_commit -cnotmatch '^[a-f0-9]{40}$'){throw 'Reviewed canonical source lock is required.'}
    if(((Invoke-SelectedContextGit $CoreRoot @('rev-parse','HEAD')) -join '').Trim() -cne $lock.source_commit){throw 'Core bootstrap differs from the reviewed immutable lock.'}
    $remote=((Invoke-SelectedContextGit $CoreRoot @('remote','get-url','origin')) -join '').Trim()
    if($remote -cnotmatch '^(https://github.com/|git@github.com:)cwru-non-academic/WSSCore(\.git)?$'){throw 'Core bootstrap repository differs from its reviewed identity.'}
    if(@(Invoke-SelectedContextGit $CoreRoot @('status','--porcelain','--untracked-files=all','--ignored','--','tools')).Count -or
       @(Invoke-SelectedContextGit $CoreRoot @('ls-files','-v','--','tools') | Where-Object {$_ -cnotmatch '^H '}).Count){throw 'Core bootstrap source is not pristine.'}
    if(!(Test-Path -LiteralPath (Join-Path $CoreRoot 'tools/ci/ci-test-selection.mjs'))){throw 'Reviewed Core lock does not yet support selected-test adoption.'}
}
function Invoke-ReviewedSelectionCore([string]$CoreRoot,[string]$Operation,[string]$TargetId,[string]$ContextPath,[string]$RootsPath,[string]$EvidencePath='') {
    Assert-ReviewedSelectionCore $CoreRoot
    $arguments=@((Join-Path $CoreRoot 'tools/ci/ci-test-selection.mjs'),$Operation,$TargetId,$ContextPath,$RootsPath)
    if($EvidencePath){$arguments+=$EvidencePath}
    $output=& node @arguments
    if($LASTEXITCODE -ne 0){throw "Authenticated Core selection $Operation failed."}
    ($output -join "`n") | ConvertFrom-Json
}
function Get-SelectedProduct($Roots,[string]$Repository) {
    $matches=@($Roots.products | Where-Object repository -ceq $Repository)
    if($matches.Count -ne 1){throw "Expected exactly one immutable product: $Repository"}
    $matches[0]
}