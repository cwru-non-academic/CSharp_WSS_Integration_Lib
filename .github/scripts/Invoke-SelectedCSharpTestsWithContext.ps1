[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('csharp-wrapper','csharp-cli')][string]$TargetId,
    [Parameter(Mandatory)][string]$CoreRoot,[Parameter(Mandatory)][string]$ContextPath,
    [Parameter(Mandatory)][string]$RootsPath,[Parameter(Mandatory)][string]$PayloadRoot,
    [Parameter(Mandatory)][string]$WorkRoot
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/SelectedTestContext.ps1"
$binding=Invoke-ReviewedSelectionCore $CoreRoot inspect $TargetId $ContextPath $RootsPath
$roots=Get-Content -LiteralPath $RootsPath -Raw | ConvertFrom-Json
$product=Get-SelectedProduct $roots $binding.repository
$wrapper=Get-SelectedProduct $roots 'cwru-non-academic/CSharp_WSS_Integration_Lib'
$options=@{Role=$(if($TargetId -ceq 'csharp-wrapper'){'wrapper'}else{'cli'});ProductRoot=$product.path;ProductSha=$product.commit;
    PayloadRoot=$PayloadRoot;WorkRoot=$WorkRoot;TestRoot=$roots.test_root;TestSha=$binding.test_commit;
    TestRepository=$binding.test_repository;TestSelectionId=$binding.selection_id}
if($TargetId -ceq 'csharp-cli'){$options.IntegrationRoot=$wrapper.path;$options.IntegrationSha=$wrapper.commit}
& "$PSScriptRoot/Invoke-SelectedCSharpTests.ps1" @options
# Workflow callers must also preserve all existing native/platform and release gates.
Invoke-ReviewedSelectionCore $CoreRoot evidence $TargetId $ContextPath $RootsPath (Join-Path $WorkRoot 'selection/evidence.json')