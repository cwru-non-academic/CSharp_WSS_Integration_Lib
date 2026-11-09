[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('csharp-wrapper','csharp-cli')][string]$TargetId,
    [Parameter(Mandatory)][string]$CoreRoot,[Parameter(Mandatory)][string]$ContextPath,
    [Parameter(Mandatory)][string]$RootsPath,[Parameter(Mandatory)][string]$PayloadRoot,
    [Parameter(Mandatory)][string]$WorkRoot,
    [string]$ProfileEvidencePath=$env:WSS_PROFILE_EVIDENCE
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/SelectedProcessIsolation.ps1"
. "$PSScriptRoot/SelectedTestContext.ps1"
. "$PSScriptRoot/TrustedBaseline.ps1"
. "$PSScriptRoot/wss-ci/restored-assets/RestoredAssets.ps1"
# Freeze authority bytes before any child; mutable Git metadata alone is not proof.
$authorityRoots=@(Get-ReviewedCoreAuthorityRoots $CoreRoot)+@((Join-Path $PSScriptRoot 'wss-ci.lock.json'),$ContextPath,$RootsPath)
$authoritySnapshot=New-TrustedBaselineSnapshot $authorityRoots
$binding=Invoke-ReviewedSelectionCore $CoreRoot inspect $TargetId $ContextPath $RootsPath
$roots=Get-Content -LiteralPath $RootsPath -Raw | ConvertFrom-Json
$product=Get-SelectedProduct $roots $binding.repository
$wrapper=Get-SelectedProduct $roots 'cwru-non-academic/CSharp_WSS_Integration_Lib'
if(!$ProfileEvidencePath){throw 'Selected suites require a parent-prepared authenticated profile proof.'}
. "$PSScriptRoot/CSharpProfilesBootstrap.ps1"
. "$PSScriptRoot/PreparedProfileProof.ps1"
. "$PSScriptRoot/CSharpTestSource.ps1"
$context=Get-Content -LiteralPath $ContextPath -Raw | ConvertFrom-Json
$proof=New-PreparedProfileProof $ProfileEvidencePath $PayloadRoot $wrapper.path $wrapper.commit ($context.scope -ceq 'campaign')
Assert-CSharpTestWorkRoot $proof.state.output_root @($product.path,$wrapper.path,$roots.test_root,$PayloadRoot)
$baselineResults=$WorkRoot+'-baseline-results'
Invoke-CredentialFreeSelectedPowerShell "$PSScriptRoot/Invoke-ProfileFullTests.ps1" @{EvidencePath=$ProfileEvidencePath;ResultsDirectory=$baselineResults}
Assert-PreparedProfileProof $proof
# Bind trusted baseline output/results before running any separately selected code.
$baselineRoots=@($proof.state.output_root,$baselineResults,(Join-Path $PSScriptRoot 'wss-ci/restored-assets'),(Join-Path $PSScriptRoot 'Verify-WssOutput.ps1'))
$options=@{Role=$(if($TargetId -ceq 'csharp-wrapper'){'wrapper'}else{'cli'});ProductRoot=$product.path;ProductSha=$product.commit;
    PayloadRoot=$PayloadRoot;WorkRoot=$WorkRoot;TestRoot=$roots.test_root;TestSha=$binding.test_commit;
    TestRepository=$binding.test_repository;TestSelectionId=$binding.selection_id;ProfileEvidencePath=$ProfileEvidencePath}
if($TargetId -ceq 'csharp-cli'){$options.IntegrationRoot=$wrapper.path;$options.IntegrationSha=$wrapper.commit}
if($TargetId -ceq 'csharp-cli'){$baselineRoots+=@(Invoke-TrustedCliBaseline $options ($WorkRoot+'-baseline-cli'))}
Assert-PreparedProfileProof $proof
# Immutable baseline builds are complete. Capture parent-owned restore proofs
# before freely selected code can change a package root or restore inputs.
$baselineAssets=Join-Path (Split-Path -Parent $proof.state.project) 'obj/project.assets.json'
$baselineRestoreProof=New-WssRestoredAssetsProof -ProjectAssetsFile $baselineAssets -ProjectPath $proof.state.project
$cliRestoreProof=$null
if($TargetId -ceq 'csharp-cli'){
 $cliBaselineProject=Join-Path ($WorkRoot+'-baseline-cli') 'SelectedTests.csproj'
 $cliBaselineAssets=Join-Path ($WorkRoot+'-baseline-cli') 'obj/project.assets.json'
 $cliRestoreProof=New-WssRestoredAssetsProof -ProjectAssetsFile $cliBaselineAssets -ProjectPath $cliBaselineProject
}
function Assert-BaselineRestoreProofs {
 Assert-WssRestoredAssetsProof -Proof $baselineRestoreProof -ProjectAssetsFile $baselineAssets -ProjectPath $proof.state.project
 & "$PSScriptRoot/Verify-WssOutput.ps1" -ArtifactRoot $PayloadRoot -OutputRoot (Join-Path $proof.state.output_root 'Release/net9.0') -ProjectPath $proof.state.project -ProjectAssetsFile $baselineAssets -RestoreProof $baselineRestoreProof
 if($null -ne $cliRestoreProof){
  Assert-WssRestoredAssetsProof -Proof $cliRestoreProof -ProjectAssetsFile $cliBaselineAssets -ProjectPath $cliBaselineProject
  & "$PSScriptRoot/Verify-WssOutput.ps1" -ArtifactRoot $PayloadRoot -OutputRoot (Join-Path ($WorkRoot+'-baseline-cli') 'bin/Release/net9.0') -ProjectPath $cliBaselineProject -ProjectAssetsFile $cliBaselineAssets -RestoreProof $cliRestoreProof
 }
}
Assert-BaselineRestoreProofs
$baselineSnapshot=New-TrustedBaselineSnapshot $baselineRoots
Invoke-CredentialFreeSelectedPowerShell "$PSScriptRoot/Invoke-SelectedCSharpTests.ps1" $options
Assert-PreparedProfileProof $proof
Assert-TrustedBaselineSnapshot $baselineSnapshot
Assert-BaselineRestoreProofs
Assert-TrustedBaselineSnapshot $authoritySnapshot
# Workflow callers must also preserve all existing native/platform and release gates.
Invoke-ReviewedSelectionCore $CoreRoot evidence $TargetId $ContextPath $RootsPath (Join-Path $WorkRoot 'selection/evidence.json')