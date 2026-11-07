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
# Freeze authority bytes before any child; mutable Git metadata alone is not proof.
$authoritySnapshot=New-TrustedBaselineSnapshot @((Join-Path $CoreRoot 'tools'),(Join-Path $PSScriptRoot 'wss-ci.lock.json'),$ContextPath,$RootsPath)
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
$baselineRoots=@($proof.state.output_root,$baselineResults)
$options=@{Role=$(if($TargetId -ceq 'csharp-wrapper'){'wrapper'}else{'cli'});ProductRoot=$product.path;ProductSha=$product.commit;
    PayloadRoot=$PayloadRoot;WorkRoot=$WorkRoot;TestRoot=$roots.test_root;TestSha=$binding.test_commit;
    TestRepository=$binding.test_repository;TestSelectionId=$binding.selection_id;ProfileEvidencePath=$ProfileEvidencePath}
if($TargetId -ceq 'csharp-cli'){$options.IntegrationRoot=$wrapper.path;$options.IntegrationSha=$wrapper.commit}
if($TargetId -ceq 'csharp-cli'){$baselineRoots+=@(Invoke-TrustedCliBaseline $options ($WorkRoot+'-baseline-cli'))}
Assert-PreparedProfileProof $proof
$baselineSnapshot=New-TrustedBaselineSnapshot $baselineRoots
Invoke-CredentialFreeSelectedPowerShell "$PSScriptRoot/Invoke-SelectedCSharpTests.ps1" $options
Assert-PreparedProfileProof $proof
Assert-TrustedBaselineSnapshot $baselineSnapshot
Assert-TrustedBaselineSnapshot $authoritySnapshot
# Workflow callers must also preserve all existing native/platform and release gates.
Invoke-ReviewedSelectionCore $CoreRoot evidence $TargetId $ContextPath $RootsPath (Join-Path $WorkRoot 'selection/evidence.json')