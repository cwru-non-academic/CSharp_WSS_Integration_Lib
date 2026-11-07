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
$baselineFiles=@(Get-ChildItem $proof.state.output_root,$baselineResults -Recurse -File | ForEach-Object {@{path=$_.FullName;sha256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash}})
$options=@{Role=$(if($TargetId -ceq 'csharp-wrapper'){'wrapper'}else{'cli'});ProductRoot=$product.path;ProductSha=$product.commit;
    PayloadRoot=$PayloadRoot;WorkRoot=$WorkRoot;TestRoot=$roots.test_root;TestSha=$binding.test_commit;
    TestRepository=$binding.test_repository;TestSelectionId=$binding.selection_id;ProfileEvidencePath=$ProfileEvidencePath}
if($TargetId -ceq 'csharp-cli'){$options.IntegrationRoot=$wrapper.path;$options.IntegrationSha=$wrapper.commit}
Invoke-CredentialFreeSelectedPowerShell "$PSScriptRoot/Invoke-SelectedCSharpTests.ps1" $options
Assert-PreparedProfileProof $proof
foreach($file in $baselineFiles){if((Get-FileHash $file.path -Algorithm SHA256).Hash -cne $file.sha256){throw 'Selected suite changed trusted baseline evidence/output.'}}
# Workflow callers must also preserve all existing native/platform and release gates.
Invoke-ReviewedSelectionCore $CoreRoot evidence $TargetId $ContextPath $RootsPath (Join-Path $WorkRoot 'selection/evidence.json')