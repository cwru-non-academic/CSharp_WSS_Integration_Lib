[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('wrapper','cli')][string]$Role,
    [Parameter(Mandatory)][string]$ProductRoot,
    [Parameter(Mandatory)][string]$ProductSha,
    [Parameter(Mandatory)][string]$PayloadRoot,
    [Parameter(Mandatory)][string]$WorkRoot,
    [Parameter(Mandatory)][string]$TestRoot,
    [Parameter(Mandatory)][string]$TestSha,
    [Parameter(Mandatory)][string]$TestRepository,
    [Parameter(Mandatory)][string]$TestSelectionId,
    [string]$IntegrationRoot='', [string]$IntegrationSha='', [string]$ProfileEvidencePath=''
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/CSharpTestSource.ps1"
$ProductRoot=[IO.Path]::GetFullPath($ProductRoot)
$PayloadRoot=[IO.Path]::GetFullPath($PayloadRoot)
Assert-TestBundleCheckout $ProductRoot $ProductSha @('src','Config','.github')
if ($Role -ceq 'wrapper') { $IntegrationRoot=$ProductRoot; $IntegrationSha=$ProductSha }
else { if (!$IntegrationRoot -or !$IntegrationSha) { throw 'CLI test selection requires its unchanged integration product root and SHA.' }; $IntegrationRoot=[IO.Path]::GetFullPath($IntegrationRoot); Assert-TestBundleCheckout $IntegrationRoot $IntegrationSha @('src','.github') }
$profile=$null
$profileName='layered-v1'
if($ProfileEvidencePath){
 . "$PSScriptRoot/CSharpProfilesBootstrap.ps1"
 . "$PSScriptRoot/PreparedProfileProof.ps1"
 $proof=New-PreparedProfileProof $ProfileEvidencePath $PayloadRoot $IntegrationRoot $IntegrationSha $false
 $profile=$proof.state.profile
 $profileName=$profile.profile
}
$bundle=Resolve-CSharpTestBundle $Role $ProductRoot $TestRoot $TestSha $TestRepository $TestSelectionId $profileName
function Get-SelectedPayloadDigest([string]$Root) {
    $entries=@(Get-ChildItem -LiteralPath $Root -Recurse -File | Sort-Object FullName | ForEach-Object { [IO.Path]::GetRelativePath($Root,$_.FullName).Replace('\','/')+':'+(Get-TestBundleFileHash $_.FullName) })
    if ($entries.Count -eq 0) { throw 'Selected payload is empty.' }
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($entries -join "`n")))).ToLowerInvariant()
}
$payloadDigest=Get-SelectedPayloadDigest $PayloadRoot
Assert-CSharpTestWorkRoot $WorkRoot @($ProductRoot,$IntegrationRoot,$TestRoot,$PayloadRoot)
if (Test-Path -LiteralPath $WorkRoot) { throw 'Selected test work directory must be new.' }
$null=New-Item -ItemType Directory -Path $WorkRoot
$WorkRoot=[IO.Path]::GetFullPath($WorkRoot)
# Export the immutable integration source rather than building inside the product checkout.
# Original roots remain pristine for the Core inspect/evidence bootstrap.
$archive=Join-Path $WorkRoot 'product-source.zip'
$null=Invoke-TestBundleGit $IntegrationRoot @('archive','--format=zip',"--output=$archive",$IntegrationSha)
$buildProduct=Join-Path $WorkRoot 'product'
Expand-Archive -LiteralPath $archive -DestinationPath $buildProduct
$buildSourceFiles=@(Invoke-TestBundleGit $IntegrationRoot @('ls-files','--','src'))
$buildSourceHashes=@($buildSourceFiles | ForEach-Object { @{path=$_;sha256=(Get-TestBundleFileHash (Join-Path $buildProduct $_))} })
function Assert-StagedCSharpProduct {
    foreach ($file in $buildSourceHashes) {
        if ((Get-TestBundleFileHash (Join-Path $buildProduct $file.path)) -cne $file.sha256) { throw 'Staged product source changed during selected tests.' }
    }
}
function Escape-Xml([string]$Text) { [Security.SecurityElement]::Escape($Text) }
$productProject=Escape-Xml (Join-Path $buildProduct 'src/Wss.CSharpImplementation.csproj')
$payload=Escape-Xml $PayloadRoot
$compile=($bundle.sources | ForEach-Object { '    <Compile Include="'+(Escape-Xml $_)+'" />' }) -join "`n"
if ($Role -ceq 'cli') { $compile+="`n    <Compile Include=`"$(Escape-Xml (Join-Path $ProductRoot 'src/Program.cs'))`" Link=`"ProductionProgram.cs`" />" }
$project=Join-Path $WorkRoot 'SelectedTests.csproj'
# This project is bootstrap-owned. Never evaluate selected .csproj, props or targets.
$xml=@"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net9.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable>
    <IsTestProject>true</IsTestProject><IsPackable>false</IsPackable><EnableDefaultCompileItems>false</EnableDefaultCompileItems><EnableDefaultNoneItems>false</EnableDefaultNoneItems>
    <NoWarn>CS8892</NoWarn><AssemblyName>$(if($Role -ceq 'wrapper'){'Wss.CSharpImplementation.Tests'}else{'Wss.Cli.Tests'})</AssemblyName>
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
$properties=@("-p:WSS_ARTIFACT_DIR=$PayloadRoot","-p:WSS_BLE_ARTIFACT_DIR=$PayloadRoot",'-p:TreatWarningsAsErrors=true','-p:ImportDirectoryBuildProps=false','-p:ImportDirectoryBuildTargets=false')
& dotnet build $project -c Release @properties
if ($LASTEXITCODE -ne 0) { throw 'Selected test build failed.' }
$output=Join-Path $WorkRoot 'bin/Release/net9.0'
# Product-owned propagation validator remains independent of the selected checkout.
$validator=if ($Role -ceq 'wrapper') { Join-Path $PSScriptRoot 'Verify-WssOutput.ps1' } else { Join-Path $IntegrationRoot '.github/scripts/Verify-WssOutput.ps1' }
& $validator -ArtifactRoot $PayloadRoot -OutputRoot $output
if ($Role -ceq 'wrapper') {
    if($ProfileEvidencePath){
        & "$PSScriptRoot/../../tools/CSharpProfiles/Invoke-Behavior.ps1" -Profile $profileName -Project $project -IsolatedBuild -ResultsDirectory (Join-Path $WorkRoot 'behavior') -ArtifactDirectory $PayloadRoot -BleArtifactDirectory $PayloadRoot
    }else{
    & "$PSScriptRoot/Invoke-WssBehavioralConformance.ps1" -Project $project -IsolatedBuild -ResultsDirectory (Join-Path $WorkRoot 'behavior') -ArtifactDirectory $PayloadRoot -BleArtifactDirectory $PayloadRoot
    }
    # The ordinary platform/reload/options suites are additive and never replace canonical 16+16.
    & dotnet test $project -c Release --no-build --no-restore @properties --logger 'trx;LogFileName=all.trx' --results-directory (Join-Path $WorkRoot 'all')
    if ($LASTEXITCODE -ne 0) { throw 'Selected full suite failed.' }
    Assert-CSharpFullTestResults (Join-Path $WorkRoot 'all/all.trx')
} else {
    & dotnet test $project -c Release --no-build --no-restore @properties --logger 'trx;LogFileName=commands.trx' --results-directory (Join-Path $WorkRoot 'commands')
    if ($LASTEXITCODE -ne 0) { throw 'Selected production command tests failed.' }
    [xml]$trx=Get-Content (Join-Path $WorkRoot 'commands/commands.trx') -Raw
    $expected=@('analog.multichannel-isolation','analog.multidevice-isolation')
    foreach ($model in @('p','pd')) { foreach ($mode in @('pw','pa')) { foreach ($stage in @('single','multi')) { $expected+="modeled.$model.$mode.$stage" } } }
    $definitions=@($trx.TestRun.TestDefinitions.UnitTest | Where-Object { $_.TestMethod.className -ceq 'Wss.Cli.Tests.ModeledCommandTests' })
    $ids=@($definitions.id)
    $results=@($trx.TestRun.Results.UnitTestResult | Where-Object { $_.testId -cin $ids })
    if ($results.Count -ne 10 -or @(Compare-Object $expected @($results.testName) -CaseSensitive).Count -ne 0 -or @($trx.TestRun.Results.UnitTestResult | Where-Object outcome -cne 'Passed').Count -ne 0) { throw 'Selected CLI suite lost mandatory command coverage.' }
}
if($ProfileEvidencePath){Assert-PreparedProfileProof $proof}
Assert-StagedCSharpProduct
Assert-CSharpTestBundle $bundle
Assert-TestBundleCheckout $ProductRoot $ProductSha @('src','Config','.github')
Assert-TestBundleCheckout $IntegrationRoot $IntegrationSha @('src','.github')
& $validator -ArtifactRoot $PayloadRoot -OutputRoot $output
if ((Get-SelectedPayloadDigest $PayloadRoot) -cne $payloadDigest) { throw 'Selected payload changed during execution.' }
$evidence=@{profile=$profile;build_product_sha=$IntegrationSha;build_product_root=$buildProduct;payload_sha256=$payloadDigest;schema='wss-selected-csharp-tests/v1';role=$Role;product_root=$ProductRoot;product_sha=$ProductSha;integration_root=$IntegrationRoot;integration_sha=$IntegrationSha;payload_root=$PayloadRoot;test_root=$bundle.root;test_sha=$bundle.sha;test_repository=$bundle.repository;test_selection_id=$bundle.selection_id;test_contract_sha256=$bundle.contract_sha256;passed=$true}
$evidence | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $WorkRoot 'test-source-evidence.json')
$evidence