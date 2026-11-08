[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$ProductRoot,
 [Parameter(Mandatory)][string]$ProductSha,
 [Parameter(Mandatory)][string]$WorkRoot,
 [Parameter(Mandatory)][string]$VerifiedReleaseRoot,
 [switch]$SelectionEnabledCampaign
)
# Local smoke harness. Not a replacement for canonical producer/package authentication.
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../.github/scripts/CSharpTestSource.ps1"
. "$PSScriptRoot/Profile.ps1"
$ProductRoot=[IO.Path]::GetFullPath($ProductRoot)
$PayloadRoot=Join-Path $ProductRoot 'lib'
Assert-TestBundleCheckout $ProductRoot $ProductSha @('src','lib','tests','.github')
$IntegrationRoot=$ProductRoot; $IntegrationSha=$ProductSha
$producer=(Get-Content -LiteralPath (Join-Path $PayloadRoot 'wss-candidate.json') -Raw | ConvertFrom-Json).candidate
# The supplied directory must be the output of the unchanged Resolve-WssRelease gate.
# A local path or candidate JSON is not itself authentication; deployment must keep
# this boundary in the trusted job, inaccessible to selected test code.
$verified=Get-Content -LiteralPath (Join-Path $VerifiedReleaseRoot 'candidate.json') -Raw | ConvertFrom-Json
foreach($key in @('repository','commit','archive','sha256','run_id','artifact_id')) {
 if([string]$producer.$key -cne [string]$verified.$key){throw "Verified producer projection differs: $key"}
}
. "$PSScriptRoot/../../.github/scripts/Universal-WssFiles.ps1"
$verifiedPayload=Join-Path $VerifiedReleaseRoot 'extracted/WSS-Universal'
$files=@(Read-WssUniversalFiles $PayloadRoot -AllowProvenance)
$verifiedFiles=@(Read-WssUniversalFiles $verifiedPayload)
if(@(Compare-Object $files $verifiedFiles -CaseSensitive).Count){throw 'Verified payload inventory mismatch.'}
foreach($file in $files){if((Get-TestBundleFileHash (Join-Path $PayloadRoot $file)) -cne (Get-TestBundleFileHash (Join-Path $verifiedPayload $file))){throw "Verified payload projection differs: $file"}}
$profile=Resolve-WssReviewedProfile $PayloadRoot $producer -SelectionEnabledCampaign:$SelectionEnabledCampaign
$fixture=Get-WssProfileFixture $profile.profile
function Get-SelectedPayloadDigest([string]$Root) {
    $entries=@(Get-ChildItem -LiteralPath $Root -Recurse -File | Sort-Object FullName | ForEach-Object { [IO.Path]::GetRelativePath($Root,$_.FullName).Replace('\','/')+':'+(Get-TestBundleFileHash $_.FullName) })
    if ($entries.Count -eq 0) { throw 'Selected payload is empty.' }
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($entries -join "`n")))).ToLowerInvariant()
}
$payloadDigest=Get-SelectedPayloadDigest $PayloadRoot
Assert-CSharpTestWorkRoot $WorkRoot @($ProductRoot,$IntegrationRoot,$PayloadRoot)
if (Test-Path -LiteralPath $WorkRoot) { throw 'Selected test work directory must be new.' }
$null=New-Item -ItemType Directory -Path $WorkRoot
$WorkRoot=[IO.Path]::GetFullPath($WorkRoot)
# Export the immutable integration source rather than building inside the product checkout.
# Original roots remain pristine for the Core inspect/evidence bootstrap.
$archive=Join-Path $WorkRoot 'product-source.zip'
$null=Invoke-TestBundleGit $IntegrationRoot @('archive','--format=zip',"--output=$archive",$IntegrationSha)
$buildProduct=Join-Path $WorkRoot 'product'
Expand-Archive -LiteralPath $archive -DestinationPath $buildProduct
$buildSourceFiles=@(Invoke-TestBundleGit $IntegrationRoot @('ls-files','--','src','tests'))
$buildSourceHashes=@($buildSourceFiles | ForEach-Object { @{path=$_;sha256=(Get-TestBundleFileHash (Join-Path $buildProduct $_))} })
function Assert-StagedCSharpProduct {
    foreach ($file in $buildSourceHashes) {
        if ((Get-TestBundleFileHash (Join-Path $buildProduct $file.path)) -cne $file.sha256) { throw 'Staged product source changed during selected tests.' }
    }
}
function Escape-Xml([string]$Text) { [Security.SecurityElement]::Escape($Text) }
$productProject=Escape-Xml (Join-Path $buildProduct 'src/Wss.CSharpImplementation.csproj')
$payload=Escape-Xml $PayloadRoot
$sources=@(Get-ChildItem -LiteralPath (Join-Path $buildProduct 'tests/Wss.CSharpImplementation.Tests') -Filter '*.cs' -File | Where-Object Name -cne 'StimulationControllerConformanceTests.cs' | ForEach-Object FullName) + @($fixture)
$compile=($sources | ForEach-Object { '    <Compile Include="'+(Escape-Xml $_)+'" />' }) -join "`n"
$project=Join-Path $WorkRoot 'SelectedTests.csproj'
# This project is bootstrap-owned. Never evaluate selected .csproj, props or targets.
$xml=@"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net9.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable>
    <IsTestProject>true</IsTestProject><IsPackable>false</IsPackable><EnableDefaultCompileItems>false</EnableDefaultCompileItems><EnableDefaultNoneItems>false</EnableDefaultNoneItems>
    <NoWarn>CS8892</NoWarn><AssemblyName>Wss.CSharpImplementation.Tests</AssemblyName>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.11.1" />
    <PackageReference Include="Newtonsoft.Json" Version="13.0.3" ExcludeAssets="compile;runtime" />
    <PackageReference Include="NUnit" Version="3.14.0" /><PackageReference Include="NUnit3TestAdapter" Version="4.6.0" />
    <ProjectReference Include="$productProject" />
    <Reference Include="WSS_Core_Interface"><HintPath>$payload/WSS_Core_Interface.dll</HintPath></Reference>
    <Reference Include="WSS.Transport.Serial"><HintPath>$payload/WSS.Transport.Serial.dll</HintPath></Reference>
    <Reference Include="WSS.Transport.BLE"><HintPath>$payload/WSS.Transport.BLE.dll</HintPath><Private>false</Private></Reference>
    <Reference Include="Newtonsoft.Json"><HintPath>$payload/Newtonsoft.Json.dll</HintPath></Reference>
$compile
  </ItemGroup>
</Project>
"@
[IO.File]::WriteAllText($project,$xml,[Text.UTF8Encoding]::new($false))
$properties=@("-p:WSS_ARTIFACT_DIR=$PayloadRoot","-p:WSS_BLE_ARTIFACT_DIR=$PayloadRoot",'-p:TreatWarningsAsErrors=true','-p:ImportDirectoryBuildProps=false','-p:ImportDirectoryBuildTargets=false','-p:DisablePackageAssetsCache=true')
& dotnet restore $project @properties
if ($LASTEXITCODE -ne 0) { throw 'Explicit test restore failed.' }
$output=Join-Path $WorkRoot 'bin/Release/net9.0'
# Reviewed bootstrap-owned propagation validator remains independent of selected and product checkouts.
$validator=Join-Path $PSScriptRoot '../../.github/scripts/Verify-WssOutput.ps1'
# Freeze explicit restore identity before a cache-disabled build and any test child.
. "$PSScriptRoot/../../.github/scripts/TrustedBaseline.ps1"
$restoredAssets=Join-Path $WorkRoot 'obj/project.assets.json'
. "$PSScriptRoot/../../.github/scripts/wss-ci/restored-assets/RestoredAssets.ps1"
$restoreProof=New-WssRestoredAssetsProof -ProjectAssetsFile $restoredAssets -ProjectPath $project
$restoredNeutral=$restoreProof.NeutralAssetPath
. "$PSScriptRoot/../../.github/scripts/wss-ci/compiled-tests/CompiledCSharpTests.ps1"
$restoredSnapshot=New-TrustedBaselineSnapshot @($project,$restoredAssets,$restoredNeutral,(Join-Path "$PSScriptRoot/../../.github/scripts" 'wss-ci/restored-assets'),(Join-Path "$PSScriptRoot/../../.github/scripts" 'Verify-WssOutput.ps1'))
& dotnet build $project -c Release --no-restore @properties
if ($LASTEXITCODE -ne 0) { throw 'Profile test build failed.' }
Assert-WssRestoredAssetsProof -Proof $restoreProof -ProjectAssetsFile $restoredAssets -ProjectPath $project
& $validator -ArtifactRoot $PayloadRoot -OutputRoot $output -ProjectPath $project -ProjectAssetsFile (Join-Path $WorkRoot 'obj/project.assets.json') -RestoreProof $restoreProof
$compiledProof=New-CompiledCSharpTestProof -OutputRoot $output -AssemblyName 'Wss.CSharpImplementation.Tests.dll'

    & "$PSScriptRoot/Invoke-Behavior.ps1" -Profile $profile.profile -Project $project -CompiledProof $compiledProof -IsolatedBuild -ResultsDirectory (Join-Path $WorkRoot 'behavior') -ArtifactDirectory $PayloadRoot -BleArtifactDirectory $PayloadRoot
    # Platform/reload/options suites are additive and never replace the mandatory profile catalog.
    Invoke-CompiledCSharpTests -Proof $compiledProof -ResultsDirectory (Join-Path $WorkRoot 'all') -TrxFileName 'all.trx'
    if ($LASTEXITCODE -ne 0) { throw 'Additional full suite failed.' }
    Assert-CSharpFullTestResults (Join-Path $WorkRoot 'all/all.trx')
Assert-StagedCSharpProduct
if((Get-WssProfileFixture $profile.profile) -cne $fixture){throw 'Fixture changed during execution.'}
Assert-TestBundleCheckout $ProductRoot $ProductSha @('src','lib','tests','.github')
Assert-TestBundleCheckout $IntegrationRoot $IntegrationSha @('src','lib','tests','.github')
Assert-TrustedBaselineSnapshot $restoredSnapshot
Assert-WssRestoredAssetsProof -Proof $restoreProof -ProjectAssetsFile $restoredAssets -ProjectPath $project
& $validator -ArtifactRoot $PayloadRoot -OutputRoot $output -ProjectPath $project -ProjectAssetsFile (Join-Path $WorkRoot 'obj/project.assets.json') -RestoreProof $restoreProof
if ((Get-SelectedPayloadDigest $PayloadRoot) -cne $payloadDigest) { throw 'Selected payload changed during execution.' }
$evidence=@{schema='wss-csharp-profile-runtime/v1';profile=$profile;product_sha=$ProductSha;build_product_sha=$IntegrationSha;payload_sha256=$payloadDigest;fixture_sha256=(Get-TestBundleFileHash $fixture);passed=$true}
$evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $WorkRoot 'profile-evidence.json')
$evidence
