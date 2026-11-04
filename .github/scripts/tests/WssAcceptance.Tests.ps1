$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/../WssPromotion.ps1"
$count=0
function Reject([scriptblock]$Action,[string]$Message) {
    $failed=$false
    try { & $Action } catch { if ($_.Exception.Message -cnotlike $Message) { throw }; $failed=$true }
    if (!$failed) { throw "Expected rejection: $Message" }
    $script:count++
}
foreach ($consumer in @('integration','cli')) {
    $repo=if ($consumer -ceq 'integration') { 'cwru-non-academic/CSharp_WSS_Integration_Lib' } else { 'cwru-non-academic/CLI_CSharp_WSS_Application' }
    $names=if ($consumer -ceq 'integration') { @('Resolve preflight inputs','Preflight behavioral tests','Preflight compatibility (Windows)','Preflight compatibility (Ubuntu)','Preflight compatibility (macOS)') } else { @('WSS universal candidate provenance','CLI general conformance','CLI platform compatibility (Windows)','CLI platform compatibility (Ubuntu)','CLI platform compatibility (macOS)') }
    $sha='a'*40
    $run=[pscustomobject]@{repository=@{full_name=$repo};head_repository=@{full_name=$repo};head_branch='dev';head_sha=$sha;path='.github/workflows/wss-preflight.yml';event='workflow_dispatch';status='completed';conclusion='success'}
    $jobs=@($names | ForEach-Object { [pscustomobject]@{name=$_;status='completed';conclusion='success'} })
    Assert-WssCanonicalPreflight $run $consumer $sha $jobs
    foreach ($mutation in @(
        {param($r)$r.head_branch='main'}, {param($r)$r.head_repository.full_name='fork/repo'},
        {param($r)$r.repository.full_name='other/repo'}, {param($r)$r.event='pull_request'},
        {param($r)$r.head_sha='b'*40}, {param($r)$r.path='.github/workflows/normal.yml'}
    )) {
        $bad=$run | ConvertTo-Json -Depth 5 | ConvertFrom-Json; & $mutation $bad
        Reject { Assert-WssCanonicalPreflight $bad $consumer $sha $jobs } 'Canonical C# dev preflight identity is invalid*'
    }
    $jobs[-1].conclusion='skipped'
    Reject { Assert-WssCanonicalPreflight $run $consumer $sha $jobs } 'Required canonical C# preflight job missing/skipped/failed:*'
    $jobs[-1].conclusion='success'
    Reject { Assert-WssCanonicalPreflight $run $consumer $sha @($jobs[0]) } 'Required canonical C# preflight job missing/skipped/failed:*'
    Reject { Assert-WssCanonicalPreflight $run $consumer $sha @($jobs + $jobs[-1]) } 'Required canonical C# preflight job missing/skipped/failed:*'
}
"PASS: canonical dev preflight contracts ($count rejections, both receiver job sets)."

. "$PSScriptRoot/../WssAutomatic.ps1"
$approval=Read-WssApproval "$PSScriptRoot/../../universal-bootstrap.json"
$candidate=$approval.candidate | ConvertTo-Json | ConvertFrom-Json
$candidate.commit='b'*40; $candidate.run_id='21'
$script:installed=$candidate | ConvertTo-Json | ConvertFrom-Json
$script:installed.commit='a'*40; $script:installed.run_id='20'
$script:receiverHead='c'*40; $script:comparison='ahead'; $script:badMergeBase=$false
function Invoke-WssGh([string[]]$Arguments) {
    switch -Wildcard ($Arguments[-1]) {
        '*/git/ref/heads/dev' { @{object=@{sha=$script:receiverHead}} | ConvertTo-Json -Depth 4 }
        '*/contents/lib/wss-candidate.json?*' {
            $bytes=[Text.Encoding]::UTF8.GetBytes((@{schema=2;candidate=$script:installed} | ConvertTo-Json -Depth 5))
            @{type='file';encoding='base64';content=[Convert]::ToBase64String($bytes)} | ConvertTo-Json
        }
        '*/WSSCore/compare/*' { @{status=$script:comparison;base_commit=@{sha=$script:installed.commit};merge_base_commit=@{sha=$(if ($script:badMergeBase) { 'f'*40 } else { $script:installed.commit })}} | ConvertTo-Json -Depth 5 }
        default { throw 'Unexpected anti-rollback fixture read.' }
    }
}
Assert-WssCandidateNotOlder $candidate ('c'*40)
foreach ($status in @('behind','diverged','identical')) {
    $script:comparison=$status
    Reject { Assert-WssCandidateNotOlder $candidate ('c'*40) } 'Candidate would roll back or diverge*'
}
$script:comparison='ahead'; $script:badMergeBase=$true
Reject { Assert-WssCandidateNotOlder $candidate ('c'*40) } 'Candidate would roll back or diverge*'
$script:badMergeBase=$false; $script:receiverHead='d'*40
Reject { Assert-WssCandidateNotOlder $candidate ('c'*40) } 'Integration dev moved*'
$script:receiverHead='c'*40; $candidate.commit=$script:installed.commit; $candidate.run_id='19'
Reject { Assert-WssCandidateNotOlder $candidate ('c'*40) } 'Candidate would roll back the installed producer run*'
$candidate.run_id='21'
Assert-WssCandidateNotOlder $candidate ('c'*40)
$candidate.run_id='20'
Assert-WssCandidateNotOlder $candidate ('c'*40)
$candidate.sha256='f'*64
Reject { Assert-WssCandidateNotOlder $candidate ('c'*40) } 'Candidate provenance mismatch:*'
$workflow=Get-Content "$PSScriptRoot/../../workflows/promote-wss.yml" -Raw
if ([regex]::Matches($workflow,'Assert-WssCandidateNotOlder').Count -ne 3 -or
    $workflow.IndexOf('Assert-WssCandidateNotOlder') -ge $workflow.IndexOf('name: Create Integration write token')) { throw 'Installed-candidate guard must run before write credentials and again before push/PR creation.' }
"PASS: C# acceptance contracts ($count total rejections, canonical preflights and installed-candidate rollback guards)."
