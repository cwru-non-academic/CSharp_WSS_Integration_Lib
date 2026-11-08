$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$cli=Test-Path (Join-Path $root '.github/workflows/cli-ci.yml')
$files=@('.github/scripts/Invoke-SelectedCSharpTests.ps1','tools/CSharpProfiles/Invoke-BaselineProfileTests.ps1','.github/scripts/Invoke-SelectedCSharpTestsWithContext.ps1','tools/SelectedRuntimeFixtures/Invoke-HostedSelectedRuntime.ps1')
$files+=if($cli){@('.github/workflows/cli-ci.yml','.github/workflows/wss-preflight.yml')}else{@('.github/workflows/wss-compatibility.yml','.github/workflows/wss-preflight.yml')}
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('wss-caller-capture-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $scratch
$oldProfile=$env:WSS_PROFILE_PROJECT;$oldArtifact=$env:WSS_ARTIFACT_DIR;$oldTemp=$env:RUNNER_TEMP
$count=0;$script:ordered=$false
function Require([bool]$Value,[string]$Message){if(!$Value){throw $Message}}
function Capture-Verifier {
 param([Parameter(Mandatory)][string]$ArtifactRoot,[Parameter(Mandatory)][string]$OutputRoot,[Parameter(Mandatory)][string]$ProjectAssetsFile,[Parameter(Mandatory)][string]$ProjectPath,[object]$RestoreProof)
 $expected=Join-Path (Split-Path -Parent $ProjectPath) 'obj/project.assets.json'
 Require ([IO.Path]::GetFullPath($ProjectAssetsFile) -ceq [IO.Path]::GetFullPath($expected)) 'Verifier received a different project restore file'
 if($script:ordered){
  Require ($null -ne $RestoreProof) 'Ordered child-boundary verifier omitted captured proof'
  Require ([object]::ReferenceEquals($RestoreProof,$script:proofs[$RestoreProof.id])) 'Verifier reconstructed proof instead of carrying original object'
  Require ($RestoreProof.project -ceq $ProjectPath -and $RestoreProof.assets -ceq $ProjectAssetsFile) 'Verifier changed proof inputs'
  $script:events.Add([pscustomobject]@{kind='verify';id=$RestoreProof.id})
 }else{[pscustomobject]@{assets=$ProjectAssetsFile;project=$ProjectPath;proof=$RestoreProof}}
}
function New-WssRestoredAssetsProof {
 param([string]$ProjectAssetsFile,[string]$ProjectPath)
 $id=$script:proofs.Count
 $value=[pscustomobject]@{id=$id;assets=$ProjectAssetsFile;project=$ProjectPath;NeutralAssetPath='synthetic neutral'}
 $script:proofs.Add($value);$script:events.Add([pscustomobject]@{kind='capture';id=$id});$value
}
function Assert-WssRestoredAssetsProof {
 param([object]$Proof,[string]$ProjectAssetsFile,[string]$ProjectPath)
 Require ([object]::ReferenceEquals($Proof,$script:proofs[$Proof.id])) 'Assertion did not retain original proof'
 Require ($Proof.project -ceq $ProjectPath -and $Proof.assets -ceq $ProjectAssetsFile) 'Assertion changed proof inputs'
 $script:events.Add([pscustomobject]@{kind='assert';id=$Proof.id})
}
function Capture-Child {$script:events.Add([pscustomobject]@{kind='child';id=-1});$global:LASTEXITCODE=0}
function Capture-TrustedPublish {$global:LASTEXITCODE=0}
function Capture-TrustedCliBaseline {@('synthetic CLI baseline')}
function New-TrustedBaselineSnapshot([string[]]$Roots) {
 $paths=@($Roots|ForEach-Object {[IO.Path]::GetFullPath($_)})
 Require ($paths -ccontains $script:expectedHelperRoot -and $paths -ccontains $script:expectedVerifierPath) 'Caller snapshot omitted trusted helper directory or thin verifier'
 $script:events.Add([pscustomobject]@{kind='tool-capture';id=-1})
 @{roots=$Roots;protected=$true}
}
function Assert-TrustedBaselineSnapshot($Snapshot) {
 if($Snapshot.ContainsKey('protected') -and $Snapshot.protected){$script:events.Add([pscustomobject]@{kind='tool-assert';id=-1})}
}
function Assert-PreparedProfileProof {}
function Assert-StagedCSharpProduct {}
function Assert-CSharpTestBundle {}
function Assert-TestBundleCheckout {}
function Assert-CSharpFullTestResults {}
function Get-SelectedPayloadDigest {'unchanged'}
function Get-WssProfileFixture {'fixture'}
function New-Projection([string]$Text,[string]$Start,[string]$Stop){
 $first=$Text.IndexOf($Start);$last=$Text.IndexOf($Stop,$first)
 Require ($first -ge 0 -and $last -gt $first) "Missing caller execution boundaries: $Start"
 $slice=$Text.Substring($first,$last-$first)
 # Remove imports only. All caller proof expressions, control flow and arguments execute.
 $slice=[regex]::Replace($slice,'(?m)^\s*\. "[^"]+"\r?\n','')
 $errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($slice,[ref]$null,[ref]$errors)
 Require ($errors.Count -eq 0) 'Caller projection parse failed'
 $resultFunction=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Assert-SelectedResults'},$true)
 if($null -ne $resultFunction){$slice=$slice.Remove($resultFunction.Extent.StartOffset,$resultFunction.Extent.EndOffset-$resultFunction.Extent.StartOffset).Insert($resultFunction.Extent.StartOffset,'function Assert-SelectedResults {}')}
 $ast=[Management.Automation.Language.Parser]::ParseInput($slice,[ref]$null,[ref]$errors)
 $edits=@()
 foreach($command in $ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true)){
  $target=$command.CommandElements[0];$name=$target.Extent.Text
  $replacement=if($name.Contains('Verify-WssOutput.ps1') -or $name -ceq '$validator'){'Capture-Verifier'}
   elseif($name.Contains('Invoke-Behavior.ps1') -or $name.Contains('Invoke-WssBehavioralConformance.ps1') -or $name -ceq 'Invoke-CredentialFreeSelectedPowerShell'){'Capture-Child'}
   elseif($name -ceq 'Invoke-TrustedCliBaseline'){'Capture-TrustedCliBaseline'}
   elseif($name -ceq 'dotnet'){if($command.Extent.Text -match 'dotnet publish'){'Capture-TrustedPublish'}else{'Capture-Child'}}
   else{$null}
  if($replacement){$edits+=@{start=$target.Extent.StartOffset;end=$target.Extent.EndOffset;text=$replacement}}
 }
 foreach($edit in $edits|Sort-Object start -Descending){$slice=$slice.Remove($edit.start,$edit.end-$edit.start).Insert($edit.start,$edit.text)}
 $slice.Replace('$PSScriptRoot','$CallerScriptRoot')
}
function Test-OrderedCaller([string]$Relative,[string]$Variant){
 $text=Get-Content (Join-Path $root $Relative) -Raw
 $CallerScriptRoot=Split-Path -Parent (Join-Path $root $Relative)
 $script:expectedHelperRoot=[IO.Path]::GetFullPath((Join-Path $root '.github/scripts/wss-ci/restored-assets'))
 $script:expectedVerifierPath=[IO.Path]::GetFullPath((Join-Path $root '.github/scripts/Verify-WssOutput.ps1'))
 $script:ordered=$true;$script:events=[Collections.Generic.List[object]]::new();$script:proofs=[Collections.Generic.List[object]]::new()
 $WorkRoot=Join-Path $scratch ($Variant+'-'+[IO.Path]::GetFileNameWithoutExtension($Relative))
 $project=Join-Path $WorkRoot 'SelectedTests.csproj';$PayloadRoot='authenticated payload';$output='generated output'
 $ProductRoot='product';$ProductSha='product-sha';$IntegrationRoot='integration';$IntegrationSha='integration-sha';$bundle=@{}
 $ProfileEvidencePath=if($Variant -ceq 'profile'){'profile.json'}else{''};$profileName='layered-v1';$profile=@{profile='layered-v1'};$fixture='fixture';$payloadDigest='unchanged';$properties=@()
 $Role=if($Variant -ceq 'cli'){'cli'}else{'wrapper'};$TargetId=if($Variant -ceq 'cli'){'csharp-cli'}else{'csharp-wrapper'}
 $FixtureRoot=$WorkRoot;$scripts=Join-Path $root '.github/scripts';$legacy=$false;$baseline=Join-Path $WorkRoot 'baseline-results'
 $proof=@{state=@{project=$project;output_root=(Join-Path $WorkRoot 'prepared output');source_root=(Join-Path $WorkRoot 'product')}}
 $state=@{payload_root=$PayloadRoot;product_root=$ProductRoot;product_sha=$ProductSha;test_root='selected source';test_sha='selected-sha';selection_id='selection';integration_root=$IntegrationRoot;integration_sha=$IntegrationSha}
 $profilePath='profile.json';$baselineRoots=@('output','results');$options=@{};$authoritySnapshot=@{}
 # Fabricated TRX permits the existing ten-case CLI coverage assertions to execute.
 $names=@('analog.multichannel-isolation','analog.multidevice-isolation')
 foreach($model in @('p','pd')){foreach($mode in @('pw','pa')){foreach($stage in @('single','multi')){$names+="modeled.$model.$mode.$stage"}}}
 $definitions='';$results='';$i=0
 foreach($name in $names){$definitions+='<UnitTest id="'+$i+'"><TestMethod className="Wss.Cli.Tests.ModeledCommandTests" /></UnitTest>';$results+='<UnitTestResult testId="'+$i+'" testName="'+$name+'" outcome="Passed" />';$i++}
 $null=New-Item -ItemType Directory (Join-Path $WorkRoot 'commands') -Force
 [IO.File]::WriteAllText((Join-Path $WorkRoot 'commands/commands.trx'),'<TestRun><TestDefinitions>'+$definitions+'</TestDefinitions><Results>'+$results+'</Results></TestRun>')
 if($Relative.EndsWith('WithContext.ps1')){
  $baselineResults=$baseline
  $baselineDeclaration=($text -split '\r?\n'|Where-Object {$_.StartsWith('$baselineRoots=@(')})
  Require (@($baselineDeclaration).Count -eq 1) 'Missing actual baseline source snapshot roots'
  Invoke-Expression ($baselineDeclaration.Replace('$PSScriptRoot','$CallerScriptRoot'))
  $slice=New-Projection $text '# Immutable baseline builds' '# Workflow callers'
 }
 elseif($Relative.Contains('HostedSelectedRuntime')){$slice=New-Projection $text ' # The immutable baseline' ' $success='}
 else{$slice=New-Projection $text '# Freeze restore identity' '$evidence='}
 & ([scriptblock]::Create($slice))
 $events=@($script:events);$children=@(0..($events.Count-1)|Where-Object {$events[$_].kind -ceq 'child'})
 Require ($children.Count -gt 0) "No executable child capture: $Relative/$Variant"
 foreach($p in $script:proofs){
  $capture=@(0..($events.Count-1)|Where-Object {$events[$_].kind -ceq 'capture' -and $events[$_].id -eq $p.id})
  $verified=@(0..($events.Count-1)|Where-Object {$events[$_].kind -ceq 'verify' -and $events[$_].id -eq $p.id})
  $asserted=@(0..($events.Count-1)|Where-Object {$events[$_].kind -ceq 'assert' -and $events[$_].id -eq $p.id})
  Require ($capture.Count -eq 1 -and $capture[0] -lt $children[0]) "Proof captured after child: $Relative/$Variant"
  Require ($verified.Count -ge 2 -and $verified[0] -lt $children[0] -and $verified[-1] -gt $children[-1]) "Proof verification did not enclose child: $Relative/$Variant"
  Require ($asserted.Count -gt 0 -and $asserted[-1] -gt $children[-1]) "No final retained proof assertion: $Relative/$Variant"
 }
 foreach($index in 0..($events.Count-1)){
  if($events[$index].kind -cne 'verify'){continue}
  $previousChildren=@($children|Where-Object {$_ -lt $index})
  if(!$previousChildren.Count){continue}
  $toolAssertions=@(0..($index-1)|Where-Object {$events[$_].kind -ceq 'tool-assert'})
  Require ($toolAssertions.Count -gt 0 -and $toolAssertions[-1] -gt $previousChildren[-1]) "Verifier source reloaded before trusted tool snapshot assertion: $Relative/$Variant"
 }
 $toolCaptures=@(0..($events.Count-1)|Where-Object {$events[$_].kind -ceq 'tool-capture'})
 Require ($toolCaptures.Count -gt 0 -and $toolCaptures[0] -lt $children[0]) "Trusted tools were not snapshotted before selectable child: $Relative/$Variant"
 Require ($script:proofs.Count -gt 0) 'No executable proof capture'
 $script:count++;$script:ordered=$false
}
try{
 # Bind every actual verifier invocation, including unchanged trusted workflow publish calls.
 $WorkRoot=Join-Path $scratch 'synthetic work with spaces';$project=Join-Path $WorkRoot 'SelectedTests.csproj';$PayloadRoot='authenticated payload';$output='generated output'
 $profile=@{source_root=(Join-Path $WorkRoot 'profile product')};$proof=@{state=@{source_root=$profile.source_root;project=$project;output_root='prepared output'}}
 $state=@{payload_root=$PayloadRoot};$FixtureRoot='synthetic fixture';$integration='unchanged integration'
 $restoredAssets=Join-Path $WorkRoot 'obj/project.assets.json';$baselineAssets=$restoredAssets
 $publishProject=Join-Path $profile.source_root 'src/Wss.CSharpImplementation.csproj';$publishAssets=Join-Path $profile.source_root 'src/obj/project.assets.json'
 $cliBaselineProject=Join-Path ($WorkRoot+'-baseline-cli') 'SelectedTests.csproj';$cliBaselineAssets=Join-Path ($WorkRoot+'-baseline-cli') 'obj/project.assets.json'
 $restoreProof=$baselineRestoreProof=$publishRestoreProof=$cliRestoreProof=[pscustomobject]@{sentinel='captured parent proof'}
 $env:WSS_PROFILE_PROJECT=$project;$env:WSS_ARTIFACT_DIR=$PayloadRoot;$env:RUNNER_TEMP='runner temporary directory'
 foreach($relative in $files){
  $text=Get-Content (Join-Path $root $relative) -Raw
  $lines=@($text -split '\r?\n'|Where-Object {($_.Contains('Verify-WssOutput.ps1') -or $_ -match '^\s*& \$validator -ArtifactRoot') -and $_.Contains('-ArtifactRoot')})
  Require ($lines.Count -gt 0) "No verifier invocation: $relative"
  foreach($line in $lines){
   $errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($line,[ref]$null,[ref]$errors);Require ($errors.Count -eq 0) 'Invalid verifier invocation'
   $command=$ast.Find({param($n)$n -is [Management.Automation.Language.CommandAst]},$true);$target=$command.CommandElements[0]
   Require ($target.Extent.Text -notmatch 'IntegrationRoot|integration|SubModules') 'Product gitlink selected executable tooling'
   $call=$line.Substring(0,$target.Extent.StartOffset)+'Capture-Verifier'+$line.Substring($target.Extent.EndOffset)
   $captured=& ([scriptblock]::Create($call))
   if(!$relative.EndsWith('.yml')){Require ($null -ne $captured.proof) "Caller omitted restore proof: $relative"}
   $count++
  }
 }
 foreach($variant in @('wrapper','profile','cli')){Test-OrderedCaller '.github/scripts/Invoke-SelectedCSharpTests.ps1' $variant}
 Test-OrderedCaller 'tools/CSharpProfiles/Invoke-BaselineProfileTests.ps1' 'baseline'
 foreach($variant in @('wrapper','cli')){Test-OrderedCaller '.github/scripts/Invoke-SelectedCSharpTestsWithContext.ps1' $variant}
 Test-OrderedCaller 'tools/SelectedRuntimeFixtures/Invoke-HostedSelectedRuntime.ps1' $(if($cli){'cli'}else{'wrapper'})
 $selected=Get-Content (Join-Path $root '.github/scripts/Invoke-SelectedCSharpTests.ps1') -Raw
 foreach($gate in @('Assert-StagedCSharpProduct','Assert-CSharpTestBundle $bundle','Assert-TestBundleCheckout $ProductRoot $ProductSha','Assert-TestBundleCheckout $IntegrationRoot $IntegrationSha','Assert-PreparedProfileProof $proof','Selected payload changed during execution.')){Require ($selected.Contains($gate)) "Lost selected authority gate: $gate"}
 "Restored caller contracts passed: $count. Actual verifier argument binding and seven ordered executable caller projections; child processes are captures only."
}finally{
 $env:WSS_PROFILE_PROJECT=$oldProfile;$env:WSS_ARTIFACT_DIR=$oldArtifact;$env:RUNNER_TEMP=$oldTemp
 $resolved=[IO.Path]::GetFullPath($scratch);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
 if(!$resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -cnotmatch '^wss-caller-capture-[a-f0-9]{32}$'){throw 'Unsafe fixture cleanup path'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
