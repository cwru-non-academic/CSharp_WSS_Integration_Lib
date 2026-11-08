$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/../TrustedBaseline.ps1"
. "$PSScriptRoot/../wss-ci/restored-assets/RestoredAssets.ps1"
. "$PSScriptRoot/../wss-ci/restored-assets/Universal-WssFiles.ps1"
$root=Join-Path ([IO.Path]::GetTempPath()) ('wss-restore-proof-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $root
if(!$IsWindows){Push-Location $root;try{$root=(& /bin/pwd -P).Trim()}finally{Pop-Location}}
$count=0
function Require([bool]$Value,[string]$Message){if(!$Value){throw $Message}}
function Write-Bytes([string]$Path,[string]$Value){$null=New-Item -ItemType Directory (Split-Path -Parent $Path) -Force;[IO.File]::WriteAllText($Path,$Value)}
function Reject([scriptblock]$Action,[string]$Name){
 $caught=$false;try{& $Action | Out-Null}catch{$caught=$true}
 Require $caught "Mutation accepted: $Name";$script:count++
}
function New-Case([string]$Name,[switch]$PrimaryPresent){
 $caseRoot=Join-Path $root $Name
 $project=Join-Path $caseRoot 'actual project/SelectedTests.csproj'
 $assets=Join-Path $caseRoot 'actual project/obj/project.assets.json'
 $primary=Join-Path $caseRoot 'primary cache';$fallback=Join-Path $caseRoot 'fallback cache'
 $package='system.io.ports/8.0.0';$asset='lib/net8.0/System.IO.Ports.dll'
 Write-Bytes $project '<Project />'
 foreach($cache in @($fallback)+$(if($PrimaryPresent){@($primary)}else{@()})){
  Write-Bytes (Join-Path $cache "$package/.nupkg.metadata") '{"version":2,"contentHash":"synthetic","source":"synthetic"}'
  Write-Bytes (Join-Path $cache "$package/$asset") 'original-neutral'
 }
 $data=@{version=3;targets=@{'net9.0'=@{'System.IO.Ports/8.0.0'=@{type='package';runtime=@{$asset=@{}}}}};libraries=@{'System.IO.Ports/8.0.0'=@{type='package';path=$package;files=@($asset)}};packageFolders=[ordered]@{$primary=@{};$fallback=@{}};project=@{restore=@{projectPath=$project}}}
 Write-Bytes $assets (ConvertTo-Json -InputObject $data -Depth 20)
 $payload=Join-Path $caseRoot 'payload';$output=Join-Path $caseRoot 'output'
 foreach($relative in $WssUniversalFiles){Write-Bytes (Join-Path $payload $relative) "verified-$relative";Write-Bytes (Join-Path $output $relative) "verified-$relative"}
 Write-Bytes (Join-Path $output 'System.IO.Ports.dll') 'original-neutral'
 $proof=New-WssRestoredAssetsProof -ProjectAssetsFile $assets -ProjectPath $project
 $options=@{ArtifactRoot=$payload;OutputRoot=$output;ProjectPath=$project;ProjectAssetsFile=$assets;RestoreProof=$proof}
 [pscustomobject]@{project=$project;assets=$assets;primary=$primary;fallback=$fallback;package=$package;asset=$asset;proof=$proof;options=$options;output=$output;payload=$payload}
}
function Assert-Case($Case){Assert-WssRestoredAssetsProof -Proof $Case.proof -ProjectAssetsFile $Case.assets -ProjectPath $Case.project}
function Verify-Case($Case){$options=$Case.options;& "$PSScriptRoot/../Verify-WssOutput.ps1" @options | Out-Null}
try {
 # Exercise the existing snapshot guard on fabricated executable-tool sources.
 # The harmless synthetic verifier records whether execution was reached.
 $toolRoot=Join-Path $root 'reviewed tooling/restored-assets'
 $thinVerifier=Join-Path $root 'reviewed tooling/Verify-WssOutput.ps1'
 $helperFiles=@('RestoredAssets.ps1','RestoredPackageAssets.cs','Verify-WssOutput.ps1')|ForEach-Object {Join-Path $toolRoot $_}
 foreach($file in $helperFiles){Write-Bytes $file 'original trusted source'}
 Write-Bytes $thinVerifier 'param($Invocation) $Invocation.reached=$true'
 $toolSnapshot=New-TrustedBaselineSnapshot @($toolRoot,$thinVerifier)
 $invocation=@{reached=$false}
 Assert-TrustedBaselineSnapshot $toolSnapshot
 & $thinVerifier $invocation
 Require $invocation.reached 'Unchanged synthetic verifier was not reached';$count++
 foreach($file in @($helperFiles)+@($thinVerifier)){
  $original=[IO.File]::ReadAllText($file)
  Write-Bytes $file 'param($Invocation) $Invocation.reached=$true; throw "MUTATED TOOL EXECUTED"'
  $invocation.reached=$false
  Reject {Assert-TrustedBaselineSnapshot $toolSnapshot;& $thinVerifier $invocation} 'trusted helper/verifier source mutation'
  Require (!$invocation.reached) 'Verifier was executed before rejecting changed tool source'
  Write-Bytes $file $original
 }
 $added=Join-Path $toolRoot 'child-added-helper.ps1'
 Write-Bytes $added 'throw "ADDED TOOL EXECUTED"'
 $invocation.reached=$false
 Reject {Assert-TrustedBaselineSnapshot $toolSnapshot;& $thinVerifier $invocation} 'trusted helper directory addition'
 Require (!$invocation.reached) 'Verifier was executed before rejecting added helper source'
 Remove-Item -LiteralPath $added
 Assert-TrustedBaselineSnapshot $toolSnapshot
 $c=New-Case 'unchanged fallback'
 Assert-Case $c;Verify-Case $c;$count++
 Require ($c.proof.NeutralAssetPath -ceq (Join-Path $c.fallback "$($c.package)/$($c.asset)")) 'Proof did not capture fallback selection'
 Require (@($c.proof.GetType().GetProperties() | Where-Object CanWrite).Count -eq 0) 'Restore proof exposes mutable properties'
 $count++
 foreach($kind in @('project','assets','neutral')){
  $c=New-Case "changed $kind"
  $path=switch($kind){'project'{$c.project};'assets'{$c.assets};'neutral'{$c.proof.NeutralAssetPath}}
  [IO.File]::AppendAllText($path,' ')
  Reject {Assert-Case $c} "$kind proof";Reject {Verify-Case $c} "$kind verifier"
 }
 foreach($sameBytes in @($false,$true)){
  $c=New-Case "primary addition $sameBytes"
  $snapshot=New-TrustedBaselineSnapshot @($c.project,$c.assets,$c.proof.NeutralAssetPath)
  $bytes=if($sameBytes){'original-neutral'}else{'foreign-neutral'}
  Write-Bytes (Join-Path $c.primary "$($c.package)/.nupkg.metadata") '{"version":2}'
  Write-Bytes (Join-Path $c.primary "$($c.package)/$($c.asset)") $bytes
  Write-Bytes (Join-Path $c.output 'System.IO.Ports.dll') $bytes
  Assert-TrustedBaselineSnapshot $snapshot
  Reject {Assert-Case $c} "earlier root addition $sameBytes";Reject {Verify-Case $c} "earlier root/output replacement $sameBytes"
 }
 $c=New-Case 'fallback shift' -PrimaryPresent
 Remove-Item -LiteralPath (Join-Path $c.primary "$($c.package)/.nupkg.metadata")
 Reject {Assert-Case $c} 'primary removal selects fallback';Reject {Verify-Case $c} 'same-byte fallback replacement'
 $c=New-Case 'incomplete earlier package'
 Write-Bytes (Join-Path $c.primary "$($c.package)/.nupkg.metadata") '{"version":2}'
 Reject {Verify-Case $c} 'new complete-package marker without requested asset'
 $c=New-Case 'output only'
 Write-Bytes (Join-Path $c.output 'System.IO.Ports.dll') 'foreign-output'
 Assert-Case $c;Reject {Verify-Case $c} 'foreign output with intact restore'
 $platform=if($IsWindows){'win'}else{'unix'}
 Write-Bytes (Join-Path $c.output 'System.IO.Ports.dll') "verified-runtimes/$platform/lib/net8.0/System.IO.Ports.dll"
 Verify-Case $c;$count++
 "Restored child-boundary proof contracts passed: $count. Synthetic files and managed proof only; no WSS/native/hardware execution."
}finally{
 $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
 if(!$resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -cnotmatch '^wss-restore-proof-[a-f0-9]{32}$'){throw 'Unsafe fixture cleanup path'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
