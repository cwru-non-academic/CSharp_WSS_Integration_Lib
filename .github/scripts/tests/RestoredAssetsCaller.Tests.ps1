$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$cli=Test-Path (Join-Path $root '.github/workflows/cli-ci.yml')
$files=@('.github/scripts/Invoke-SelectedCSharpTests.ps1','tools/CSharpProfiles/Invoke-BaselineProfileTests.ps1','tools/SelectedRuntimeFixtures/Invoke-HostedSelectedRuntime.ps1')
$files+=if($cli){@('.github/workflows/cli-ci.yml','.github/workflows/wss-preflight.yml')}else{@('.github/workflows/wss-compatibility.yml','.github/workflows/wss-preflight.yml')}
$WorkRoot=Join-Path $root 'synthetic work with spaces'
$project=Join-Path $WorkRoot 'SelectedTests.csproj';$PayloadRoot='authenticated payload';$output='generated output'
$profile=@{source_root=(Join-Path $WorkRoot 'profile product')}
$proof=@{state=@{source_root=$profile.source_root;project=$project;output_root='prepared output'}}
$state=@{payload_root=$PayloadRoot};$FixtureRoot='synthetic fixture';$integration='unchanged integration'
$oldProfile=$env:WSS_PROFILE_PROJECT;$oldArtifact=$env:WSS_ARTIFACT_DIR;$oldTemp=$env:RUNNER_TEMP
$env:WSS_PROFILE_PROJECT=$project;$env:WSS_ARTIFACT_DIR=$PayloadRoot;$env:RUNNER_TEMP='runner temporary directory'
$count=0
function Capture-Verifier {
 param([Parameter(Mandatory)][string]$ArtifactRoot,[Parameter(Mandatory)][string]$OutputRoot,[Parameter(Mandatory)][string]$ProjectAssetsFile,[Parameter(Mandatory)][string]$ProjectPath)
 [pscustomobject]@{assets=$ProjectAssetsFile;project=$ProjectPath;artifact=$ArtifactRoot;output=$OutputRoot}
}
try {
 foreach($relative in $files){
  $path=Join-Path $root $relative;$text=Get-Content $path -Raw
  if($relative.EndsWith('.yml')){$lines=@($text -split '\r?\n' | Where-Object {$_.Contains('Verify-WssOutput.ps1')})}
  else{$lines=@($text -split '\r?\n' | Where-Object { $_ -match '^\s*& (\$validator|"\$scripts/Verify-WssOutput.ps1") -ArtifactRoot'})}
  if(!$lines.Count){throw "No verifier invocation found: $relative"}
  foreach($line in $lines){
   $errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($line,[ref]$null,[ref]$errors)
   if($errors.Count){throw "Invalid verifier invocation: $relative"}
   $command=$ast.Find({param($node)$node -is [Management.Automation.Language.CommandAst]},$true)
   $target=$command.CommandElements[0]
   if($target.Extent.Text -match 'IntegrationRoot|integration|SubModules'){throw 'Product gitlink selected executable output tooling'}
   $call=$line.Substring(0,$target.Extent.StartOffset)+'Capture-Verifier'+$line.Substring($target.Extent.EndOffset)
   $captured=& ([scriptblock]::Create($call))
   $expectedProject=if($line.Contains('integration-publish') -or $line.Contains('staged-publish')){Join-Path $profile.source_root 'src/Wss.CSharpImplementation.csproj'}elseif($cli -and $relative.EndsWith('.yml')){'src/CLI_CSharp_WSS_Application.csproj'}else{$project}
   $expectedAssets=Join-Path (Split-Path -Parent $expectedProject) 'obj/project.assets.json'
   if($captured.project -cne $expectedProject -or [IO.Path]::GetFullPath($captured.assets) -cne [IO.Path]::GetFullPath($expectedAssets)){throw "Wrong actual restore inputs: $relative"}
   $count++
  }
 }
 $selected=Get-Content (Join-Path $root '.github/scripts/Invoke-SelectedCSharpTests.ps1') -Raw
 if(!$selected.Contains("`$validator=Join-Path `$PSScriptRoot 'Verify-WssOutput.ps1'")){throw 'Selected caller must use the reviewed bootstrap tooling'}
 foreach($gate in @('Assert-StagedCSharpProduct','Assert-CSharpTestBundle $bundle','Assert-TestBundleCheckout $ProductRoot $ProductSha','Assert-TestBundleCheckout $IntegrationRoot $IntegrationSha','Assert-PreparedProfileProof $proof','Selected payload changed during execution.')){if(!$selected.Contains($gate)){throw "Lost selected authority gate: $gate"}}
 "Restored project caller contracts passed: $count actual argument captures; selected/baseline/hosted/build/publish covered without product execution."
}finally{$env:WSS_PROFILE_PROJECT=$oldProfile;$env:WSS_ARTIFACT_DIR=$oldArtifact;$env:RUNNER_TEMP=$oldTemp}
