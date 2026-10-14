param([string] $ArtifactRoot = '')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../WssPromotion.ps1"
$temp = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $temp | Out-Null
$count = 0
function Assert-Rejected([scriptblock] $Action, [string] $Message) {
    $rejected = $false
    try { & $Action } catch { $rejected = $true; if ($_.Exception.Message -notlike $Message) { throw } }
    if (-not $rejected) { throw "Expected rejection: $Message" }
    $script:count++
}
try {
    $approval = Read-WssApproval "$PSScriptRoot/../../universal-bootstrap.json"
    $marker = Get-WssApprovalMarker $approval
    $roundTrip = Read-WssApprovalMarker $marker (Join-Path $temp 'roundtrip.json')
    if ((Get-WssApprovalMarker $roundTrip) -cne $marker) { throw 'Approval marker round trip changed provenance.' }
    $count++
    foreach ($consumer in @('integration', 'cli')) {
        $record = Read-WssBootstrapProof "$PSScriptRoot/../../promotion-evidence" $consumer $approval (Join-Path $temp $consumer)
        Assert-WssCandidateRecord $record $approval
        $count++
    }
    $otherApproval = $approval | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $otherApproval.cli.preflight_run_id = '1'
    Assert-Rejected { Read-WssBootstrapProof "$PSScriptRoot/../../promotion-evidence" 'cli' $otherApproval (Join-Path $temp 'wrong-proof') } 'Archived proof is restricted*'
    Assert-Rejected { Read-WssApprovalMarker "$marker`n$marker" (Join-Path $temp 'duplicate.json') } 'Missing or ambiguous*'
    Assert-Rejected { Assert-WssCandidateRecord ([pscustomobject]@{ repository='other/repo' }) $approval } 'Candidate provenance mismatch*'
    foreach ($field in @('run_id', 'artifact_id', 'commit', 'archive', 'sha256')) {
        $record = $approval.candidate | ConvertTo-Json | ConvertFrom-Json
        $record.$field = 'wrong'
        Assert-Rejected { Assert-WssCandidateRecord $record $approval } 'Candidate provenance mismatch*'
    }
    Assert-WssPaths @('lib/WSS.Transport.Serial.dll', 'lib/wss-candidate.json')
    $count++
    Assert-Rejected { Assert-WssPaths @('lib/a.dll', 'src/StimulationController.cs') } 'Unexpected promotion path*'
    Assert-Rejected { Assert-WssPaths @() } 'Promotion diff is empty*'
    Assert-WssPaths @('lib/a.dll', 'src/Wss.CSharpImplementation.csproj') @('src/Wss.CSharpImplementation.csproj')
    Assert-Rejected { Assert-WssPaths @('lib/a.dll', 'src/StimulationController.cs') @('src/Wss.CSharpImplementation.csproj') } 'Unexpected promotion path*'
    $count++

    $originalProject = 'ac4ca9ca0371f2896f4a29b4f3ec1db55025f363'
    $alignedProject = 'e7bcaa356b22dc7b213c90d8ff2f6c5a8e5d6155'
    $candidateNewtonsoft = '8c1dd5c184b4e2e7ead06971ff3ebcb46783be972292d1deb1061744369b4d80'
    Assert-WssNewtonsoftTestAlignment $originalProject $alignedProject $candidateNewtonsoft
    $count++
    Assert-Rejected { Assert-WssNewtonsoftTestAlignment ('0'*40) $alignedProject $candidateNewtonsoft } 'Test dependency change is not*'
    Assert-Rejected { Assert-WssNewtonsoftTestAlignment $originalProject ('0'*40) $candidateNewtonsoft } 'Test dependency change is not*'
    Assert-Rejected { Assert-WssNewtonsoftTestAlignment $originalProject $alignedProject ('0'*64) } 'Test dependency change is not*'

    # Metadata-only fakes: no candidate binaries, workflow dispatches or PRs are created.
    function Invoke-WssGh([string[]] $Arguments) {
        if ($Arguments[1] -like '*/pulls/*') {
            @{ merged=$script:merged; merge_commit_sha=$script:mergeSha; base=@{ref='dev';repo=@{full_name='cwru-non-academic/CSharp_WSS_Integration_Lib'}};
                head=@{sha='1'*40;repo=@{full_name='cwru-non-academic/CSharp_WSS_Integration_Lib'}} } | ConvertTo-Json -Depth 5
        } elseif ($Arguments[1] -like '*/compare/*') {
            @{status=$script:comparison} | ConvertTo-Json
        } else { throw 'Unexpected API call in rejection test.' }
    }
    $script:merged = $false
    $script:mergeSha = '2'*40
    Assert-Rejected { Assert-WssMergedIntegration $script:mergeSha '1' $approval } 'Gitlink must target*'
    $script:merged = $true
    Assert-Rejected { Assert-WssMergedIntegration ('3'*40) '1' $approval } 'Gitlink must target*'
    $script:comparison = 'diverged'
    Assert-Rejected { Assert-WssMergedIntegration $script:mergeSha '1' $approval } 'Integration merge is not contained*'
    Remove-Item Function:Invoke-WssGh
    . "$PSScriptRoot/../WssPromotion.ps1"

    if ($ArtifactRoot) {
        Write-WssApproval $approval (Join-Path $temp 'approval.json')
        & "$PSScriptRoot/../New-WssLib.ps1" -ArtifactRoot $ArtifactRoot -ApprovalFile (Join-Path $temp 'approval.json') -Destination (Join-Path $temp 'first')
        & "$PSScriptRoot/../New-WssLib.ps1" -ArtifactRoot $ArtifactRoot -ApprovalFile (Join-Path $temp 'approval.json') -Destination (Join-Path $temp 'second')
        & git diff --no-index --quiet -- (Join-Path $temp 'first') (Join-Path $temp 'second')
        if ($LASTEXITCODE -ne 0) { throw 'Universal staging is not deterministic.' }
        Assert-Rejected { & "$PSScriptRoot/../New-WssLib.ps1" -ArtifactRoot $ArtifactRoot -ApprovalFile (Join-Path $temp 'approval.json') -Destination (Join-Path $temp 'first') } 'Destination must be new*'
        'wrong' | Set-Content (Join-Path $temp 'first/WSS.Transport.Serial.dll')
        Assert-Rejected { Assert-WssLib (Join-Path $temp 'first') $ArtifactRoot $approval } 'Committed universal bytes differ*'
        $count++
    }
    "PASS: $count focused promotion safety checks (ArtifactRoot supplied: $([bool]$ArtifactRoot))."
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
