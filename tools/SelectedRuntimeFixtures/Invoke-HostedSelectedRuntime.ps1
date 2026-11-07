param([Parameter(Mandatory)][ValidateSet('Prepare','Run')][string]$Stage,[Parameter(Mandatory)][string]$FixtureRoot,[string]$BootstrapRoot=(Join-Path $PSScriptRoot '../..'),[string]$AdapterRoot='',[string]$TestSeedRoot='',[string]$ProductSeedRoot='',[string]$VerifiedInputRoot,[ValidateSet('layered-v1','legacy-v1')][string]$FixtureProfile='layered-v1')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$BootstrapRoot=[IO.Path]::GetFullPath($BootstrapRoot)
if(!$AdapterRoot){$AdapterRoot=$BootstrapRoot}
if(!$TestSeedRoot){$TestSeedRoot=$BootstrapRoot}
if(!$ProductSeedRoot){$ProductSeedRoot=$BootstrapRoot}
$ProductSeedRoot=[IO.Path]::GetFullPath($ProductSeedRoot)
$AdapterRoot=[IO.Path]::GetFullPath($AdapterRoot)
$TestSeedRoot=[IO.Path]::GetFullPath($TestSeedRoot)
function Invoke-FixtureGit([string]$Root,[string[]]$Arguments){$result=& git -C $Root @Arguments;if($LASTEXITCODE -ne 0){throw 'Fixture git operation failed'};@($result)}
function Require([bool]$Condition,[string]$Message){if(!$Condition){throw $Message}}
if($Stage -ceq 'Prepare'){
 Require (!(Test-Path -LiteralPath $FixtureRoot)) 'Fixture directory must be new.'
 $null=New-Item -ItemType Directory -Path $FixtureRoot
 if(!$IsWindows){Push-Location $FixtureRoot;try{$FixtureRoot=(& /bin/pwd -P).Trim()}finally{Pop-Location}}
 $FixtureRoot=[IO.Path]::GetFullPath($FixtureRoot)
 $product=Join-Path $FixtureRoot 'product';$tests=Join-Path $FixtureRoot 'selected-tests'
 $sha=(Invoke-FixtureGit $ProductSeedRoot @('rev-parse','HEAD') -join '').Trim()
 $seedSha=(Invoke-FixtureGit $TestSeedRoot @('rev-parse','HEAD') -join '').Trim()
 foreach($clone in @(@{source=$ProductSeedRoot;target=$product;sha=$sha},@{source=$TestSeedRoot;target=$tests;sha=$seedSha})){
  $null=Invoke-FixtureGit $BootstrapRoot @('clone','--quiet','--no-hardlinks','--no-checkout',$clone.source,$clone.target)
  $null=Invoke-FixtureGit $clone.target @('checkout','--quiet','--detach',$clone.sha)
 }
 if($FixtureProfile -ceq 'legacy-v1'){
  Require ($sha -ceq 'aafeef78536fe06094c6a694dd64d9a9e1433b21' -and $seedSha -ceq $sha) 'Legacy fixture must use exact reviewed historical sources.'
  Require (!(Test-Path (Join-Path $tests 'tests/test-contract.json'))) 'Historical fixture unexpectedly has a manifest.'
  @{schema='wss-csharp-tests/v1';role='wrapper';test_directory='tests/Wss.CSharpImplementation.Tests'} | ConvertTo-Json | Set-Content (Join-Path $tests 'tests/test-contract.json')
 }
 $contract=Get-Content (Join-Path $tests 'tests/test-contract.json') -Raw | ConvertFrom-Json
 Require ($contract.test_directory -cin @('tests/Wss.CSharpImplementation.Tests','tests/SelectedWrapper.Tests')) 'Unexpected fixture source directory.'
 $directory=Join-Path $tests $contract.test_directory
 $extra=@"
using System;
using System.IO;
using NUnit.Framework;
namespace Wss.CSharpImplementation.Tests;
public sealed class HostedSelectedFixtureTests {
 [Test] public void SelectedOnlyFixtureChecksIsolationAndOptionalMutation() {
  foreach(var name in new[]{"GH_TOKEN","GITHUB_TOKEN","WSS_TEST_VARIABLE_READ_TOKEN","WSS_EVIDENCE_READ_TOKEN","GITHUB_ENV","GITHUB_OUTPUT","GITHUB_PATH","GITHUB_STATE"})
   Assert.That(Environment.GetEnvironmentVariable(name), Is.Null.Or.Empty, "Credential/command handle leaked: "+name);
  var target=Environment.GetEnvironmentVariable("WSS_FIXTURE_MUTATION_PATH");
  if(!string.IsNullOrEmpty(target)) File.AppendAllText(target, " ");
 }
}
"@
 [IO.File]::WriteAllText((Join-Path $directory 'HostedSelectedFixtureTests.cs'),$extra)
 [IO.File]::WriteAllText((Join-Path $tests 'src/StimulationController.cs'),'INVALID SELECTED PRODUCT SOURCE MUST NEVER COMPILE')
 [IO.File]::WriteAllText((Join-Path $tests '.github/scripts/Verify-WssOutput.ps1'),"throw 'SELECTED VALIDATOR EXECUTED'")
 $poison='<Project><Target Name="Poison" BeforeTargets="PrepareForBuild;Build;VSTest"><Error Text="UNTRUSTED BUILD INPUT EXECUTED" /></Target></Project>'
 [IO.File]::WriteAllText((Join-Path $directory 'Wss.CSharpImplementation.Tests.csproj'),$poison)
 foreach($base in @($tests,$directory,$FixtureRoot)){foreach($name in @('Directory.Build.props','Directory.Build.targets')){[IO.File]::WriteAllText((Join-Path $base $name),$poison)}}
 $null=Invoke-FixtureGit $tests @('add','--all')
 $null=Invoke-FixtureGit $tests @('-c','user.name=Synthetic Runtime Fixture','-c','user.email=fixture@example.invalid','commit','--quiet','-m','Synthetic runtime fixture, never acceptance evidence')
 $testSha=(Invoke-FixtureGit $tests @('rev-parse','HEAD') -join '').Trim()
 Require ($testSha -cne $sha) 'Selected fixture must differ from product.'
 Require (![string]::IsNullOrWhiteSpace($VerifiedInputRoot)) 'Authenticated payload seed is required.'
 $payload=Join-Path $FixtureRoot 'payload';Copy-Item -LiteralPath (Join-Path $VerifiedInputRoot 'extracted/WSS-Universal') -Destination $payload -Recurse
 @{candidate=(Get-Content (Join-Path $VerifiedInputRoot 'candidate.json') -Raw | ConvertFrom-Json)} | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $payload 'wss-candidate.json')
 if($FixtureProfile -ceq 'layered-v1'){Require ((Get-FileHash (Join-Path $product 'lib/WSS_Core_Interface.dll')).Hash -cne (Get-FileHash (Join-Path $payload 'WSS_Core_Interface.dll')).Hash) 'Modern collision regression requires different archived and authenticated candidate bytes.'}
 @{schema='wss-synthetic-selected-runtime-fixture/v1';acceptance=$false;fixture_profile=$FixtureProfile;product_root=$product;product_sha=$sha;test_root=$tests;test_sha=$testSha;test_seed_sha=$seedSha;payload_root=$payload;selection_id=('a'*64)} | ConvertTo-Json | Set-Content (Join-Path $FixtureRoot 'fixture.json')
 foreach($entry in @{WSS_FIXTURE_ROOT=$FixtureRoot;WSS_FIXTURE_PRODUCT=$product;WSS_FIXTURE_PAYLOAD=$payload}.GetEnumerator()){
  Require ($entry.Value -notmatch '[\r\n]') 'Invalid fixture workflow path.'
  "$($entry.Key)=$($entry.Value)" | Add-Content -LiteralPath $env:GITHUB_ENV
 }
 return
}
$FixtureRoot=[IO.Path]::GetFullPath($FixtureRoot)
$state=Get-Content (Join-Path $FixtureRoot 'fixture.json') -Raw | ConvertFrom-Json
Require ($state.acceptance -eq $false) 'Only explicitly synthetic fixtures may run.'
$scripts=Join-Path $AdapterRoot '.github/scripts'
. "$scripts/SelectedProcessIsolation.ps1"
. "$scripts/CSharpProfilesBootstrap.ps1"
. "$scripts/CSharpTestSource.ps1"
. "$scripts/PreparedProfileProof.ps1"
. "$scripts/TrustedBaseline.ps1"
$profilePath=Join-Path $FixtureRoot 'profile/profile.json'
$legacy=$state.fixture_profile -ceq 'legacy-v1'
$proof=New-PreparedProfileProof $profilePath $state.payload_root $state.product_root $state.product_sha (!$legacy)
if($legacy){
 $rejected=$false;try{$null=New-PreparedProfileProof $profilePath $state.payload_root $state.product_root $state.product_sha $true}catch{if($_.Exception.Message -notlike '*campaigns require*'){throw};$rejected=$true}
 Require $rejected 'Legacy campaign profile was accepted.'
 . "$PSScriptRoot/LegacyInventory.ps1"
}
$baseline=Join-Path $FixtureRoot 'baseline-results'
$names=@('GH_TOKEN','GITHUB_TOKEN','WSS_TEST_VARIABLE_READ_TOKEN','WSS_EVIDENCE_READ_TOKEN','GITHUB_ENV','GITHUB_OUTPUT','GITHUB_PATH','GITHUB_STATE');$prior=@{}
try{
 foreach($name in $names){$prior[$name]=[Environment]::GetEnvironmentVariable($name);[Environment]::SetEnvironmentVariable($name,'synthetic-parent-only')}
 Invoke-CredentialFreeSelectedPowerShell "$scripts/Invoke-ProfileFullTests.ps1" @{EvidencePath=$profilePath;ResultsDirectory=$baseline}
 Assert-PreparedProfileProof $proof
 & "$scripts/Verify-WssOutput.ps1" -ArtifactRoot $state.payload_root -OutputRoot (Join-Path $proof.state.output_root 'Release/net9.0')
 & dotnet publish (Join-Path $proof.state.source_root 'src/Wss.CSharpImplementation.csproj') -c Release --no-restore -p:ImportDirectoryBuildProps=false -p:ImportDirectoryBuildTargets=false -p:TreatWarningsAsErrors=true "-p:WSS_ARTIFACT_DIR=$($state.payload_root)" "-p:WSS_BLE_ARTIFACT_DIR=$($state.payload_root)" -o (Join-Path $FixtureRoot 'staged-publish')
 if($LASTEXITCODE -ne 0){throw 'Restored staged product publish failed.'}
 & "$scripts/Verify-WssOutput.ps1" -ArtifactRoot $state.payload_root -OutputRoot (Join-Path $FixtureRoot 'staged-publish')
 if($legacy){Assert-LegacyFullInventory (Join-Path $baseline 'all.trx');[xml]$missing=Get-Content (Join-Path $baseline 'all.trx') -Raw;$null=$missing.TestRun.Results.RemoveChild($missing.TestRun.Results.UnitTestResult[0]);$negative=Join-Path $FixtureRoot 'missing-baseline.trx';$missing.Save($negative);$rejected=$false;try{Assert-LegacyFullInventory $negative}catch{$rejected=$true};Require $rejected 'Missing historical baseline case was accepted.'}
 $baselineRoots=@($proof.state.output_root,$baseline)
 $baselineSnapshot=New-TrustedBaselineSnapshot $baselineRoots
 function Assert-BaselineFiles {Assert-TrustedBaselineSnapshot $baselineSnapshot}
 function SelectedOptions([string]$Name){@{Role='wrapper';ProductRoot=$state.product_root;ProductSha=$state.product_sha;PayloadRoot=$state.payload_root;WorkRoot=(Join-Path $FixtureRoot $Name);TestRoot=$state.test_root;TestSha=$state.test_sha;TestRepository='cwru-non-academic/CSharp_WSS_Integration_Lib';TestSelectionId=$state.selection_id;ProfileEvidencePath=$profilePath}}
 function Assert-SelectedResults([string]$Name){
  $root=Join-Path $FixtureRoot $Name
  Assert-CSharpFullTestResults (Join-Path $root 'all/all.trx')
  [xml]$trx=Get-Content (Join-Path $root 'all/all.trx') -Raw
  $extra=@($trx.TestRun.Results.UnitTestResult | Where-Object testName -ceq 'SelectedOnlyFixtureChecksIsolationAndOptionalMutation')
  Require ($extra.Count -eq 1 -and $extra[0].outcome -ceq 'Passed') 'Selected-only fixture was not executed exactly once.'
  $stages=@(Get-Content (Join-Path $root 'behavior/conformance-stages.json') -Raw | ConvertFrom-Json)
  if($legacy){Require ($stages.Count -eq 1 -and $stages[0].stage -ceq 'legacy' -and $stages[0].passed -eq 10) 'Mandatory legacy10 missing.';Assert-LegacyFullInventory (Join-Path $root 'all/all.trx') -SelectedExtra}
  else{Require ($stages.Count -eq 2 -and @($stages | Where-Object passed -ne 16).Count -eq 0) 'Mandatory modern16+16 missing.'}
 }
 Invoke-CredentialFreeSelectedPowerShell "$scripts/Invoke-SelectedCSharpTests.ps1" (SelectedOptions 'selected-success')
 Assert-SelectedResults 'selected-success';Assert-PreparedProfileProof $proof;Assert-BaselineFiles
 $success=Get-Content (Join-Path $FixtureRoot 'selected-success/test-source-evidence.json') -Raw | ConvertFrom-Json
 Require ($success.product_sha -ceq $state.product_sha -and $success.test_sha -ceq $state.test_sha -and $success.product_root -cne $success.test_root) 'Product/test identities became coupled.'
 foreach($case in @(@{name='reject-baseline-mutation';path=$proof.state.project;reason='*proof/source changed*'},@{name='reject-payload-mutation';path=(Join-Path $state.payload_root 'wss-candidate.json');reason='*payload changed*'})){
  $original=[IO.File]::ReadAllBytes($case.path)
  try{
   $env:WSS_FIXTURE_MUTATION_PATH=$case.path;$rejected=$false
   try{Invoke-CredentialFreeSelectedPowerShell "$scripts/Invoke-SelectedCSharpTests.ps1" (SelectedOptions $case.name)}catch{$rejected=$true}
   Require $rejected 'Mutating selected suite was accepted.';Assert-SelectedResults $case.name
   Require (!(Test-Path (Join-Path $FixtureRoot "$($case.name)/test-source-evidence.json"))) 'Rejected fixture emitted success evidence.'
   $parentRejected=$false
   try{Assert-PreparedProfileProof $proof}catch{if($_.Exception.Message -notlike $case.reason){throw};$parentRejected=$true}
   Require $parentRejected 'Parent failed to detect selected mutation.'
  }finally{Remove-Item Env:WSS_FIXTURE_MUTATION_PATH -ErrorAction SilentlyContinue;[IO.File]::WriteAllBytes($case.path,$original)}
  Assert-PreparedProfileProof $proof;Assert-BaselineFiles
 }
 # The child can add an evidence file without altering existing hashes. The parent
 # inventory guard must reject it even when the selected test runner succeeds.
 $added=Join-Path $baseline 'selected-added-evidence.json'
 try{
  $env:WSS_FIXTURE_MUTATION_PATH=$added
  Invoke-CredentialFreeSelectedPowerShell "$scripts/Invoke-SelectedCSharpTests.ps1" (SelectedOptions 'reject-baseline-addition')
  Assert-SelectedResults 'reject-baseline-addition'
  $rejected=$false
  try{Assert-BaselineFiles}catch{if($_.Exception.Message -notlike '*baseline inventory/content*'){throw};$rejected=$true}
  Require $rejected 'Parent accepted selected-added baseline evidence.'
 }finally{Remove-Item Env:WSS_FIXTURE_MUTATION_PATH -ErrorAction SilentlyContinue;if(Test-Path -LiteralPath $added){Remove-Item -LiteralPath $added}}
 Assert-BaselineFiles
 foreach($name in $names){Require ([Environment]::GetEnvironmentVariable($name) -ceq 'synthetic-parent-only') 'Child modified parent credential fixture.'}
 Assert-TestBundleCheckout $state.product_root $state.product_sha
 Assert-TestBundleCheckout $state.test_root $state.test_sha
 Require (@(Get-ChildItem $FixtureRoot -Recurse -Filter evidence.json | Where-Object FullName -match '[/\\]selection[/\\]').Count -eq 0) 'Synthetic fixture emitted generic selection evidence.'
 @{schema='wss-synthetic-selected-runtime-result/v1';acceptance=$false;product_sha=$state.product_sha;test_sha=$state.test_sha;test_seed_sha=$state.test_seed_sha;mandatory_stages=$(if($legacy){'legacy10'}else{'16+16'});historical_baseline_full22=$legacy;selected_only_test=$true;baseline_mutation_rejected=$true;baseline_addition_rejected=$true;payload_mutation_rejected=$true;credential_isolation=$true;passed=$true} | ConvertTo-Json | Set-Content (Join-Path $FixtureRoot 'synthetic-result.json')
}finally{foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$prior[$name])}}
