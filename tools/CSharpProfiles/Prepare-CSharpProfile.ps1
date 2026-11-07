[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$IntegrationRoot,
 [Parameter(Mandatory)][string]$WorkRoot,
 [string]$PayloadRoot='',
 [string]$ProducerRecordPath='',
 [string]$VerifiedReleaseRoot='',
 [string]$OutputRoot='',
 [switch]$SelectionEnabledCampaign
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../.github/scripts/CSharpTestSource.ps1"
. "$PSScriptRoot/Profile.ps1"
$IntegrationRoot=[IO.Path]::GetFullPath($IntegrationRoot)
$IntegrationSha=((& git -C $IntegrationRoot rev-parse HEAD) -join '').Trim()
if($LASTEXITCODE -ne 0){throw 'Cannot resolve immutable integration source.'}
$ProductRoot=$IntegrationRoot; $ProductSha=$IntegrationSha
if(!$OutputRoot){$OutputRoot=Join-Path $IntegrationRoot 'tests/Wss.CSharpImplementation.Tests/bin/'}
$OutputRoot=[IO.Path]::GetFullPath($OutputRoot)
if(!$PayloadRoot){$PayloadRoot=Join-Path $IntegrationRoot 'lib'}
$PayloadRoot=[IO.Path]::GetFullPath($PayloadRoot)
if(!$ProducerRecordPath){$ProducerRecordPath=Join-Path $PayloadRoot 'wss-candidate.json'}
$record=Get-Content -LiteralPath $ProducerRecordPath -Raw | ConvertFrom-Json
$producer=if($record.PSObject.Properties.Name -ccontains 'candidate'){$record.candidate}else{$record}
# Authenticate producer/run/archive before classification; tokens are scoped to this
# trusted preparation step and are never required by compilation or test execution.
if(!$VerifiedReleaseRoot){
 $VerifiedReleaseRoot=$WorkRoot+'-verified'
 & "$IntegrationRoot/.github/scripts/Resolve-WssRelease.ps1" -ProducerRepository $producer.repository -RunId $producer.run_id -ExpectedCommit $producer.commit -ArchiveName $producer.archive -ExpectedSha256 $producer.sha256 -OutputRoot $VerifiedReleaseRoot
}
Assert-TestBundleCheckout $IntegrationRoot $IntegrationSha @('src','tests')
$verified=Get-Content -LiteralPath (Join-Path $VerifiedReleaseRoot 'candidate.json') -Raw | ConvertFrom-Json
foreach($key in @('repository','commit','archive','sha256','run_id','artifact_id')) {
 if([string]$producer.$key -cne [string]$verified.$key){throw "Verified producer projection differs: $key"}
}
. "$IntegrationRoot/.github/scripts/Universal-WssFiles.ps1"
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
    <IsTestProject>true</IsTestProject><IsPackable>false</IsPackable><EnableDefaultCompileItems>false</EnableDefaultCompileItems>
    <BaseOutputPath>$(Escape-Xml $OutputRoot)/</BaseOutputPath>
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
$evidence=[ordered]@{schema='wss-csharp-prepared-profile/v1';profile=$profile;project=$project;output_root=$OutputRoot;integration_root=$IntegrationRoot;integration_sha=$IntegrationSha;payload_root=$PayloadRoot;payload_sha256=$payloadDigest;fixture=$fixture;fixture_sha256=(Get-TestBundleFileHash $fixture);sources=$buildSourceHashes;source_root=$buildProduct}
$evidencePath=Join-Path $WorkRoot 'profile.json'
$evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $evidencePath
if($env:GITHUB_ENV){
 foreach($entry in @{WSS_PROFILE_PROJECT=$project;WSS_PROFILE_EVIDENCE=$evidencePath}.GetEnumerator()) {
  if($entry.Value -match '[\r\n]'){throw 'Invalid workflow environment path.'}
  "$($entry.Key)=$($entry.Value)" | Add-Content -LiteralPath $env:GITHUB_ENV
 }
}
$evidence
