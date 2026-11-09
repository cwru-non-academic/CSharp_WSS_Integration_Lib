param([string]$CommonRoot=(Join-Path $PSScriptRoot '../wss-ci'))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. "$PSScriptRoot/../WssPromotion.ps1"
. (Join-Path $CommonRoot 'Evidence.ps1')
$preload=Join-Path $CommonRoot 'tests/receipt-gh-preload.mjs'
if(!(Test-Path $preload)){throw 'Real receipt bridge transport fixture is required.'}
$oldOptions=$env:NODE_OPTIONS;$oldResponses=$env:WSS_TEST_GH_RESPONSES;$oldChannel=$env:WSS_CI_CHANNEL
$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath());$root=Join-Path $tempRoot ('wss csharp composition '+[guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $root
$script:approval=[pscustomobject]@{candidate=@{repository='cwru-non-academic/WSSCore';commit=('a'*40);run_id='10';artifact_id='20';archive='WSS-Universal-ci.zip';sha256=('b'*64)};integration=@{preflight_run_id='11';source_sha=('c'*40)};cli=@{preflight_run_id='12';source_sha=('d'*40)}}
function Add-Route($Arguments,$Value){$script:routes.Add(@{args=@($Arguments);json=$Value})}
function Save-Routes { @{routes=$script:routes.ToArray();calls_file=$script:callsFile}|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $script:responseFile }
function Invoke-WssGh([string[]]$Arguments){
 $key=ConvertTo-Json -InputObject $Arguments -Compress
 $matches=@($script:routes|Where-Object {(ConvertTo-Json -InputObject $_.args -Compress) -ceq $key})
 if($matches.Count -ne 1 -or !$matches[0].ContainsKey('json')){$script:unexpectedCalls++;throw "Unexpected native GitHub fixture request: $key"}
 $result=$matches[0].json|ConvertTo-Json -Depth 30
 if($script:case -ceq 'later-attempt' -and $Arguments[-1] -ceq 'repos/cwru-non-academic/CLI_CSharp_WSS_Application/actions/runs/12'){
  $script:cliReads++
  if($script:cliReads -eq 2){$matches[0].json.run_attempt=4;Save-Routes}
 }
 $result
}
try {
 $env:WSS_CI_CHANNEL='dev';$env:NODE_OPTIONS=($oldOptions+' --import="'+([Uri]::new([IO.Path]::GetFullPath($preload))).AbsoluteUri+'"').Trim()
 $payload=Join-Path $root 'candidate';$null=New-Item -ItemType Directory -Path $payload
 $script:approval.candidate|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $payload 'candidate.json')
 $zip=Join-Path $root 'candidate.zip';[IO.Compression.ZipFile]::CreateFromDirectory($payload,$zip)
 $digest='sha256:'+(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
 $wrong=Join-Path $root 'wrong.zip';[IO.File]::WriteAllText($wrong,'not the captured ZIP bytes')
 $passed=0;$rejected=0
 foreach($case in @('valid','wrong-zip','required-job-failure','wrong-log','later-attempt')){
  $script:unexpectedCalls=0
  $script:case=$case;$script:cliReads=0;$script:routes=[Collections.Generic.List[object]]::new()
  $script:responseFile=Join-Path $root "$case-routes.json";$script:callsFile=Join-Path $root "$case-calls.jsonl";$env:WSS_TEST_GH_RESPONSES=$script:responseFile
  $producer=@{id=10;run_attempt=3;repository=@{full_name=$script:approval.candidate.repository};head_repository=@{full_name=$script:approval.candidate.repository};head_branch='dev';head_sha=$script:approval.candidate.commit;path='.github/workflows/artifacts.yml';event='push';status='completed';conclusion='success'}
  Add-Route @('api','repos/cwru-non-academic/WSSCore/actions/runs/10') $producer
  Add-Route @('api','repos/cwru-non-academic/WSSCore/actions/artifacts/20') @{name='universal-release-assets';expired=$false;workflow_run=@{id=10;head_sha=$script:approval.candidate.commit}}
  foreach($role in @('integration','cli')){
   $repo=if($role -ceq 'integration'){'cwru-non-academic/CSharp_WSS_Integration_Lib'}else{'cwru-non-academic/CLI_CSharp_WSS_Application'}
   $id=$script:approval.$role.preflight_run_id;$sha=$script:approval.$role.source_sha
   $run=@{id=[int]$id;run_attempt=3;repository=@{full_name=$repo};head_repository=@{full_name=$repo};head_branch='dev';head_sha=$sha;path='.github/workflows/wss-preflight.yml';event='workflow_dispatch';status='completed';conclusion='success'}
   Add-Route @('api',"repos/$repo/actions/runs/$id") $run
   $names=if($role -ceq 'integration'){@('Resolve preflight inputs','Preflight behavioral tests','Preflight compatibility (Windows)','Preflight compatibility (Ubuntu)','Preflight compatibility (macOS)')}else{@('WSS universal candidate provenance','CLI general conformance','CLI platform compatibility (Windows)','CLI platform compatibility (Ubuntu)','CLI platform compatibility (macOS)')}
   $jobs=@();$job=100;foreach($name in $names){$job++;$jobs+=@{id=$job;name=$name;status='completed';conclusion='success'}}
   if($case -ceq 'required-job-failure'){$jobs[1].conclusion='skipped'}
   Add-Route @('api',"repos/$repo/actions/runs/$id/attempts/3/jobs?per_page=100&page=1") @{jobs=$jobs;total_count=$jobs.Count}
   $artifact=@{id=([int]$id+1000);name='wss-candidate-provenance';expired=$false;digest=$digest;workflow_run=@{id=[int]$id;head_sha=$sha}}
   Add-Route @('api',"repos/$repo/actions/runs/$id/artifacts?per_page=100&page=1") @{artifacts=@($artifact);total_count=1}
   Add-Route @('api',"repos/$repo/actions/artifacts/$($artifact.id)") $artifact
   $script:routes.Add(@{args=@('api',"repos/$repo/actions/artifacts/$($artifact.id)/zip");file=$(if($case -ceq 'wrong-zip'){$wrong}else{$zip})})
  }
  $text='EXPECTED_INTEGRATION_SHA: '+$(if($case -ceq 'wrong-log'){'e'*40}else{$script:approval.integration.source_sha})+"`r`n"
  $script:routes.Add(@{args=@('api','repos/cwru-non-academic/CLI_CSharp_WSS_Application/actions/jobs/102/logs');text=$text})
  Save-Routes
  $list=[Collections.Generic.List[object]]::new();$failure=$null
  $output=[Collections.Generic.List[object]]::new();$stderrFile=Join-Path $root "$case-stderr.txt"
  $callsFile=Join-Path $root "$case-calls.jsonl"
  if(Test-Path -LiteralPath $callsFile){throw 'Transport call log must be new.'}
  try{Assert-WssApproval $script:approval (Join-Path $root "$case-proof") -RequireCanonicalDev -ReceiptSnapshots $list 2>$stderrFile|ForEach-Object {$output.Add($_)}}catch{$failure=$_}
  # Check transport attempts independently of the expected rejection catch. The
  # shared preload records every request before matching, including forbidden ones.
  if($script:unexpectedCalls){throw "Unexpected native transport operation: $case"}
  if(!(Test-Path -LiteralPath $callsFile)){throw "Missing transport call evidence: $case"}
  $calls=@(Get-Content -LiteralPath $callsFile|ForEach-Object {ConvertFrom-Json -InputObject $_ -NoEnumerate})
  foreach($call in $calls){
   $key=ConvertTo-Json -InputObject $call -Compress
   if(@($script:routes|Where-Object {(ConvertTo-Json -InputObject $_.args -Compress) -ceq $key}).Count -ne 1){throw "Unexpected Node transport operation: $key"}
  }
  $zipCalls=@($calls|Where-Object {$_[-1] -cmatch '/artifacts/[0-9]+/zip$'}|ForEach-Object {($_[-1] -split '/')[-2]})
  $logCalls=@($calls|Where-Object {$_[-1] -cmatch '/jobs/[0-9]+/logs$'})
  $diagnostics=if(Test-Path -LiteralPath $stderrFile){[IO.File]::ReadAllText($stderrFile)}else{''}
  $expectedZips=switch -CaseSensitive ($case){'valid' {'1011|1012|1011|1012'};'later-attempt' {'1011|1012|1011'};'wrong-log' {'1011|1012'};default {'1011'}}
  $expectedLogs=if($case -ceq 'valid'){2}elseif($case -cin @('wrong-log','later-attempt')){1}else{0}
  if(($zipCalls -join '|') -cne $expectedZips -or $logCalls.Count -ne $expectedLogs){throw "Receipt transport rejection phase changed: $case (ZIPs=$($zipCalls -join '|'); logs=$($logCalls.Count); error=$failure)"}
  if($expectedLogs -and $logCalls[0][-1] -cne 'repos/cwru-non-academic/CLI_CSharp_WSS_Application/actions/jobs/102/logs'){throw 'Receipt log lost captured job identity.'}
  if($case -ceq 'later-attempt' -and $script:cliReads -ne 2){throw 'Later-attempt fixture was not activated.'}
  if($case -ceq 'valid'){
   if($diagnostics){throw "Positive receipt emitted unexpected diagnostics: $diagnostics"}
   if($failure){throw $failure}
   if($output.Count -or $list.Count -ne 2 -or $list[0].attempt -ne 3 -or $list[1].logs.Count -ne 1 -or $list[1].artifacts[0].digest -cne $digest){throw 'Real bridge descriptors lost paired/native bindings.'}
   $logHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))).ToLowerInvariant()
   if($list[1].logs[0].sha256 -cne $logHash -or $list[1].logs[0].job_id -cne '102'){throw 'Real bridge changed validated log bytes/job identity.'}
   $passed++
  }else{
   $expected=switch -CaseSensitive ($case){
    'wrong-zip' {'Authenticated native proof transport failed.'}
    'required-job-failure' {'Required canonical C# preflight job missing/skipped/failed: Preflight behavioral tests'}
    'wrong-log' {'CLI preflight did not verify the approved Integration source SHA.'}
    'later-attempt' {'Authenticated native proof transport failed.'}
   }
   $nodeError=switch -CaseSensitive ($case){'wrong-zip' {'Artifact ZIP digest mismatch'};'later-attempt' {'Preflight proved run/attempt changed'};default {''}}
   $expectedSnapshots=if($case -ceq 'later-attempt'){1}else{0}
   if($expectedSnapshots -and ($list.Count -ne 1 -or $list[0].run_id -cne '11' -or $list[0].attempt -ne 3)){throw 'Later attempt changed the already completed integration snapshot.'}
   if($null -eq $failure -or $list.Count -ne $expectedSnapshots -or $output.Count){throw "Real bridge accepted descriptor/output for $case"}
   if($failure.Exception.Message -cne $expected){throw $failure}
   if($nodeError){
    $errors=@($diagnostics -split '\r?\n'|Where-Object {$_ -cmatch '^Error: '})
    if($errors.Count -ne 1 -or $errors[0] -cne "Error: $nodeError"){throw "Wrong underlying Node rejection for ${case}: $diagnostics"}
   }elseif($diagnostics){throw "Unexpected native rejection diagnostics for ${case}: $diagnostics"}
   $rejected++
  }
 }
 "C# real receipt bridge composition passed ($passed paired proof positive, $rejected semantic/ZIP/attempt negatives; actual native checks, Node capture and ZIP extraction; only GitHub transport stubbed)."
}finally{
 $env:NODE_OPTIONS=$oldOptions;$env:WSS_TEST_GH_RESPONSES=$oldResponses;$env:WSS_CI_CHANNEL=$oldChannel
 $resolved=[IO.Path]::GetFullPath($root);$prefix=$tempRoot.TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
 if(!$resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -cnotmatch '^wss csharp composition [0-9a-f]{32}$'){throw 'Unsafe composition fixture cleanup path.'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
$global:LASTEXITCODE=0