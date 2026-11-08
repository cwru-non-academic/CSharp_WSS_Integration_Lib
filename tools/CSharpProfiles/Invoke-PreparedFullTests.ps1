param([string]$EvidencePath=$env:WSS_PROFILE_EVIDENCE,[string]$ResultsDirectory=(Join-Path ([IO.Path]::GetTempPath()) ('wss-full-'+[guid]::NewGuid().ToString('N'))))
$ErrorActionPreference='Stop'
$scripts=Join-Path $PSScriptRoot '../../.github/scripts'
. "$scripts/CSharpTestSource.ps1"
. "$scripts/wss-ci/restored-assets/RestoredAssets.ps1"
. "$scripts/wss-ci/compiled-tests/CompiledCSharpTests.ps1"
$state=Get-Content -LiteralPath $EvidencePath -Raw | ConvertFrom-Json
$properties=@('-p:DisablePackageAssetsCache=true','-p:TreatWarningsAsErrors=true','-p:ImportDirectoryBuildProps=false','-p:ImportDirectoryBuildTargets=false',"-p:WSS_ARTIFACT_DIR=$($state.payload_root)","-p:WSS_BLE_ARTIFACT_DIR=$($state.payload_root)")
& dotnet restore $state.project @properties
if($LASTEXITCODE -ne 0){throw 'Prepared full-suite restore failed.'}
$assets=Join-Path (Split-Path $state.project) 'obj/project.assets.json'
$restoreProof=New-WssRestoredAssetsProof -ProjectAssetsFile $assets -ProjectPath $state.project
$restoreSnapshot=New-TrustedBaselineSnapshot @($state.project,$assets,$restoreProof.NeutralAssetPath,(Join-Path $scripts 'wss-ci/restored-assets'),(Join-Path $scripts 'Verify-WssOutput.ps1'))
& dotnet build $state.project -c Release --no-restore @properties
if($LASTEXITCODE -ne 0){throw 'Prepared full-suite build failed.'}
$output=Join-Path $state.output_root 'Release/net9.0'
& "$scripts/Verify-WssOutput.ps1" -ArtifactRoot $state.payload_root -OutputRoot $output -ProjectPath $state.project -ProjectAssetsFile $assets -RestoreProof $restoreProof
$compiledProof=New-CompiledCSharpTestProof -OutputRoot $output -AssemblyName 'Wss.CSharpImplementation.Tests.dll'
& "$PSScriptRoot/Invoke-PreparedBehavior.ps1" -EvidencePath $EvidencePath -ResultsDirectory (Join-Path $ResultsDirectory 'behavior') -CompiledProof $compiledProof
Invoke-CompiledCSharpTests -Proof $compiledProof -ResultsDirectory $ResultsDirectory -TrxFileName 'all.trx'
Assert-CSharpFullTestResults (Join-Path $ResultsDirectory 'all.trx')
Assert-TrustedBaselineSnapshot $restoreSnapshot
Assert-WssRestoredAssetsProof -Proof $restoreProof -ProjectAssetsFile $assets -ProjectPath $state.project
& "$scripts/Verify-WssOutput.ps1" -ArtifactRoot $state.payload_root -OutputRoot $output -ProjectPath $state.project -ProjectAssetsFile $assets -RestoreProof $restoreProof
