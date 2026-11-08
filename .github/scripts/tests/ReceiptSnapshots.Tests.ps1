$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/../WssPromotion.ps1"
$script:mode='valid'
$script:events=[Collections.Generic.List[string]]::new()
$script:approval=[pscustomobject]@{
 candidate=@{repository='cwru-non-academic/WSSCore';commit=('a'*40);run_id='10';artifact_id='20';archive='WSS-Universal-ci.zip';sha256=('b'*64)}
 integration=@{preflight_run_id='11';source_sha=('c'*40)}
 cli=@{preflight_run_id='12';source_sha=('d'*40)}
}
function Get-WssCiChannel { 'dev' }
function New-TestRun([string]$RunId,[string]$Repository,[string]$Sha){
 [pscustomobject]@{id=$RunId;run_attempt=3;repository=@{full_name=$Repository};head_repository=@{full_name=$Repository};head_branch='dev';path='.github/workflows/wss-preflight.yml';event='workflow_dispatch';head_sha=$Sha;status='completed';conclusion='success'}
}
function Invoke-WssGh([string[]]$Arguments){
 if($Arguments.Count -ne 2 -or $Arguments[0] -cne 'api'){throw 'Receipt used legacy artifact/log transport.'}
 $path=$Arguments[1]
 if($path -ceq 'repos/cwru-non-academic/WSSCore/actions/runs/10'){
  $run=New-TestRun '10' $script:approval.candidate.repository $script:approval.candidate.commit
  $run.path='.github/workflows/artifacts.yml';return ($run|ConvertTo-Json -Depth 8)
 }
 if($path -ceq 'repos/cwru-non-academic/WSSCore/actions/artifacts/20'){return (@{name='universal-release-assets';expired=$false;workflow_run=@{id='10';head_sha=$script:approval.candidate.commit}}|ConvertTo-Json -Depth 8)}
 foreach($pair in @(@('11','CSharp_WSS_Integration_Lib','integration'),@('12','CLI_CSharp_WSS_Application','cli'))){
  if($path -ceq "repos/cwru-non-academic/$($pair[1])/actions/runs/$($pair[0])"){return (New-TestRun $pair[0] "cwru-non-academic/$($pair[1])" $script:approval.($pair[2]).source_sha|ConvertTo-Json -Depth 8)}
 }
 throw "Unexpected receipt API request: $path"
}
function Start-WssCiPreflightProof($Repository,$RunId,$SourceSha,$Root,$ExpectedAttempt){
 if($ExpectedAttempt -ne 3 -or !$Root.EndsWith('-proof')){throw 'Observed attempt/proof root changed.'}
 if($script:mode -ceq 'capture-drift'){throw 'capture drift'}
 $script:events.Add("capture:$RunId")
 $names=if($RunId -ceq '11'){@('Resolve preflight inputs','Preflight behavioral tests','Preflight compatibility (Windows)','Preflight compatibility (Ubuntu)','Preflight compatibility (macOS)')}else{@('WSS universal candidate provenance','CLI general conformance','CLI platform compatibility (Windows)','CLI platform compatibility (Ubuntu)','CLI platform compatibility (macOS)')}
 $jobs=@();$id=100;foreach($name in $names){$id++;$jobs+=@{id=[string]$id;name=$name;status='completed';conclusion='success'}}
 if($script:mode -ceq 'required-job-failure'){$jobs[1].conclusion='failure'}
 [pscustomobject]@{Run=(New-TestRun $RunId $Repository $SourceSha);Jobs=$jobs;repository=$Repository;run_id=$RunId;source_sha=$SourceSha}
}
function Read-WssCiPreflightArtifact($Proof,$Name,$Destination){
 if($Name -cne 'wss-candidate-provenance'){throw 'Wrong native artifact name.'}
 if($script:mode -ceq 'artifact-failure'){throw 'artifact failure'}
 $script:events.Add("artifact:$($Proof.run_id)")
 $null=New-Item -ItemType Directory -Path $Destination
 $record=$script:approval.candidate|ConvertTo-Json|ConvertFrom-Json
 if($script:mode -ceq 'candidate-mismatch'){$record.sha256='e'*64}
 $record|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $Destination 'candidate.json')
}
function Read-WssCiPreflightLog($Proof,$JobId){
 if($Proof.run_id -cne '12' -or $JobId -cne '102'){throw 'Log did not use captured CLI job ID.'}
 $script:events.Add('log:12:102')
 if($script:mode -ceq 'log-mismatch'){return ('EXPECTED_INTEGRATION_SHA: '+('e'*40))}
 "EXPECTED_INTEGRATION_SHA: $($script:approval.integration.source_sha)`r`n"
}
function Complete-WssCiPreflightProof($Proof){
 if(!$script:events.Contains('log:12:102')){throw 'Snapshot completed before CLI native log validation.'}
 if($script:mode -ceq 'complete-drift'){throw 'complete drift'}
 $script:events.Add("complete:$($Proof.run_id)")
 [pscustomobject]@{repository=$Proof.repository;run_id=$Proof.run_id;source_sha=$Proof.source_sha;workflow='.github/workflows/wss-preflight.yml';attempt=3;jobs=$Proof.Jobs;artifacts=@(@{id='77';name='wss-candidate-provenance';digest=('sha256:'+('f'*64))});logs=@($(if($Proof.run_id -ceq '12'){@{job_id='102';sha256=('a'*64)}}))}
}
$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$root=Join-Path $tempRoot ('wss receipt snapshots '+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
try {
 $list=[Collections.Generic.List[object]]::new()
 $output=@(Assert-WssApproval $script:approval (Join-Path $root 'valid') -RequireCanonicalDev -ReceiptSnapshots $list)
 if($output.Count -ne 0 -or $list.Count -ne 2 -or $list[0].attempt -ne 3 -or $list[1].logs[0].job_id -cne '102'){throw 'Receipt snapshot propagation or stdout contract changed.'}
 $rejects=0
 foreach($case in @('capture-drift','required-job-failure','artifact-failure','candidate-mismatch','log-mismatch','complete-drift')){
  $script:mode=$case;$script:events.Clear();$list=[Collections.Generic.List[object]]::new();$failed=$false
  try{Assert-WssApproval $script:approval (Join-Path $root $case) -RequireCanonicalDev -ReceiptSnapshots $list}catch{$failed=$true}
  if(!$failed -or $list.Count){throw "Native proof failure produced an accepted descriptor: $case"};$rejects++
 }
 "C# receipt snapshot contracts passed (paired attempt propagation, captured CLI log job, unchanged semantic rejections; $rejects fail-closed cases)."
} finally {
 $resolved=[IO.Path]::GetFullPath($root);$prefix=$tempRoot.TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
 if(!$resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -cnotmatch '^wss receipt snapshots [0-9a-f]{32}$'){throw 'Unsafe fixture cleanup path.'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
$global:LASTEXITCODE=0