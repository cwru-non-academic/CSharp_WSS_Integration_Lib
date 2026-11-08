[CmdletBinding()]
param([string]$HelperPath=(Join-Path $PSScriptRoot '../wss-ci/compiled-tests/CompiledCSharpTests.ps1'),[switch]$RunManagedFixture)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('wss-compiled-runner-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $scratch
if(!$IsWindows){Push-Location $scratch;try{$scratch=(& /bin/pwd -P).Trim()}finally{Pop-Location}}
$count=0
function Require([bool]$Value,[string]$Message){if(!$Value){throw $Message}}
function Write-Bytes([string]$Path,[string]$Value){$null=New-Item -ItemType Directory (Split-Path -Parent $Path) -Force;[IO.File]::WriteAllText($Path,$Value)}
function Reject([scriptblock]$Action,[string]$Reason){$caught=$false;try{& $Action|Out-Null}catch{$caught=$true};Require $caught "Accepted unsafe compiled input: $Reason";$script:count++}
$tools=Join-Path $scratch 'scripts/wss-ci/compiled-tests'
$null=New-Item -ItemType Directory $tools -Force
Copy-Item -LiteralPath $HelperPath -Destination (Join-Path $tools 'CompiledCSharpTests.ps1')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../TrustedBaseline.ps1') -Destination (Join-Path $scratch 'scripts/TrustedBaseline.ps1')
. (Join-Path $tools 'CompiledCSharpTests.ps1')
$originalHost=(Get-Command Invoke-WssCompiledTestHost).ScriptBlock
$oldStage=$env:WSS_CONFORMANCE_STAGE
try{
 if($RunManagedFixture){
  $project=Join-Path $scratch 'safe managed/SafeTests.csproj'
  Write-Bytes $project '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net9.0</TargetFramework><IsTestProject>true</IsTestProject><EnableDefaultNoneItems>false</EnableDefaultNoneItems></PropertyGroup><ItemGroup><PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.11.1"/><PackageReference Include="NUnit" Version="3.14.0"/><PackageReference Include="NUnit3TestAdapter" Version="4.6.0"/></ItemGroup></Project>'
  Write-Bytes (Join-Path (Split-Path $project) 'SafeFixture.cs') 'using System; using System.IO; using NUnit.Framework; public class SafeFixture { [Test] public void First() { Assert.That(Environment.GetEnvironmentVariable("WSS_CONFORMANCE_STAGE"), Is.AnyOf("single","multi")); Assert.That(typeof(Assert).Assembly.Location, Does.StartWith(AppContext.BaseDirectory)); } [Test] public void Second() { Assert.That(2+2, Is.EqualTo(4)); } }'
  $config=Join-Path $scratch 'NuGet.Config';Write-Bytes $config '<configuration><packageSources><clear/></packageSources></configuration>'
  & dotnet restore $project --configfile $config -p:NuGetAudit=false -p:DisablePackageAssetsCache=true -p:ImportDirectoryBuildProps=false -p:ImportDirectoryBuildTargets=false
  if($LASTEXITCODE -ne 0){throw 'Safe managed fixture restore failed; no WSS/native fixture was attempted.'}
  & dotnet build $project -c Release --no-restore -p:DisablePackageAssetsCache=true -p:ImportDirectoryBuildProps=false -p:ImportDirectoryBuildTargets=false
  if($LASTEXITCODE -ne 0){throw 'Safe managed fixture build failed.'}
  $compiled=New-CompiledCSharpTestProof -OutputRoot (Join-Path (Split-Path $project) 'bin/Release/net9.0') -AssemblyName 'SafeTests.dll'
  $untrustedDirectory=Join-Path $scratch 'changed working directory'
  $null=New-Item -ItemType Directory $untrustedDirectory
  Push-Location $untrustedDirectory
  try{foreach($stage in @('single','multi','all')){
   $env:WSS_CONFORMANCE_STAGE=if($stage -ceq 'all'){'single'}else{$stage}
   $results=Join-Path $scratch "managed-results/$stage"
   $filter=if($stage -ceq 'all'){''}else{'FullyQualifiedName~SafeFixture.First'}
   Invoke-CompiledCSharpTests -Proof $compiled -ResultsDirectory $results -Filter $filter -TrxFileName 'safe.trx' -DetailedConsole
   [xml]$trx=Get-Content (Join-Path $results 'safe.trx') -Raw
   $actual=@($trx.TestRun.Results.UnitTestResult)
   Require ($actual.Count -eq $(if($stage -ceq 'all'){2}else{1}) -and @($actual|Where-Object outcome -cne 'Passed').Count -eq 0) 'Actual safe VSTest filter/stage/TRX coverage failed'
   $count++
   if($stage -ceq 'single'){
    Write-Bytes (Join-Path $untrustedDirectory 'global.json') '{"sdk":{"version":"0.0.0","rollForward":"disable"}}'
    Write-Bytes (Join-Path (Split-Path $project) 'Directory.Build.targets') '<Project><Target Name="RejectReevaluation" BeforeTargets="Build;VSTest"><Error Text="MUTABLE MSBUILD IMPORT WAS REEVALUATED"/></Target></Project>'
   }
  }}finally{Pop-Location}
 }
 # The rest uses fabricated byte files and captures the exact native argument array.
 function Invoke-WssCompiledTestHost([string]$Command,[string[]]$Arguments,[hashtable]$Result){
  $script:calls.Add(@($Arguments))
  Require (!$env:DOTNET_STARTUP_HOOKS -and !$env:DOTNET_ADDITIONAL_DEPS -and !$env:DOTNET_SHARED_STORE -and !$env:VSTEST_TESTADAPTER_PATH) 'External runtime/adapter override leaked'
  if($script:mutate){Write-Bytes $script:mutate 'child mutation'}
  $Result.exit_code=0
 }
 $output=Join-Path $scratch 'captured output'
 foreach($file in @('Tests.dll','Tests.deps.json','testhost.dll','NUnit3.TestAdapter.dll','nunit.framework.dll','nunit.engine.dll','nunit.engine.api.dll','nunit.engine.core.dll','testcentric.engine.metadata.dll')){Write-Bytes (Join-Path $output $file) 'safe synthetic bytes'}
 Write-Bytes (Join-Path $output 'Tests.runtimeconfig.json') '{"runtimeOptions":{"tfm":"net9.0"}}'
 $proof=New-CompiledCSharpTestProof -OutputRoot $output -AssemblyName 'Tests.dll'
 $script:calls=[Collections.Generic.List[object]]::new();$script:mutate=''
 $environment=@{}
 foreach($name in @('DOTNET_STARTUP_HOOKS','DOTNET_ADDITIONAL_DEPS','DOTNET_SHARED_STORE','VSTEST_TESTADAPTER_PATH')){$environment[$name]=[Environment]::GetEnvironmentVariable($name);[Environment]::SetEnvironmentVariable($name,'must-not-reach-child')}
 try{
  Invoke-CompiledCSharpTests -Proof $proof -ResultsDirectory (Join-Path $scratch 'captured results') -Filter 'FullyQualifiedName~Mandatory' -TrxFileName 'behavior.trx' -Platform ARM64 -DetailedConsole
  $expected=@('exec',$proof.vstest,(Join-Path $output 'Tests.dll'),"/TestAdapterPath:$output",'/Logger:trx;LogFileName=behavior.trx',"/ResultsDirectory:$(Join-Path $scratch 'captured results')",'/TestCaseFilter:FullyQualifiedName~Mandatory','/Platform:ARM64','/Logger:console;verbosity=detailed')
  Require (($script:calls[0] -join '|') -ceq ($expected -join '|')) 'Direct compiled runner altered the mandatory argument contract'
  foreach($name in $environment.Keys){Require ([Environment]::GetEnvironmentVariable($name) -ceq 'must-not-reach-child') 'Runtime override not restored in parent'}
  $count++
 }finally{foreach($name in $environment.Keys){[Environment]::SetEnvironmentVariable($name,$environment[$name])}}
 foreach($file in @('Tests.dll','Tests.deps.json','Tests.runtimeconfig.json','NUnit3.TestAdapter.dll','nunit.framework.dll')){
  $path=Join-Path $output $file;$bytes=[IO.File]::ReadAllBytes($path);$before=$script:calls.Count
  Write-Bytes $path 'foreign input'
  Reject {Invoke-CompiledCSharpTests -Proof $proof -ResultsDirectory (Join-Path $scratch 'rejected')} $file
  Require ($script:calls.Count -eq $before) 'Changed compiled input reached the next child'
  [IO.File]::WriteAllBytes($path,$bytes)
 }
 $script:mutate=Join-Path $output 'added dependency.dll'
 Reject {Invoke-CompiledCSharpTests -Proof $proof -ResultsDirectory (Join-Path $scratch 'child-addition')} 'child output addition'
 $before=$script:calls.Count
 Reject {Invoke-CompiledCSharpTests -Proof $proof -ResultsDirectory (Join-Path $scratch 'next-stage')} 'next-stage changed closure'
 Require ($script:calls.Count -eq $before) 'Next stage ran after child input mutation'
 Remove-Item -LiteralPath $script:mutate;$script:mutate=''
 Write-Bytes (Join-Path $output 'Tests.runtimeconfig.dev.json') '{"runtimeOptions":{"additionalProbingPaths":["outside-package-cache"]}}'
 Reject {New-CompiledCSharpTestProof -OutputRoot $output -AssemblyName 'Tests.dll'} 'external NuGet probing'
 Remove-Item -LiteralPath (Join-Path $output 'Tests.runtimeconfig.dev.json')
 Reject {Invoke-CompiledCSharpTests -Proof $proof -ResultsDirectory $output} 'results in immutable compiled input'
 "Compiled CSharp runner contracts passed: $count; managed fixture executed=$RunManagedFixture; no WSS/native/hardware execution."
}finally{
 $env:WSS_CONFORMANCE_STAGE=$oldStage
 $resolved=[IO.Path]::GetFullPath($scratch);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
 if(!$resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -cnotmatch '^wss-compiled-runner-[a-f0-9]{32}$'){throw 'Unsafe compiled fixture cleanup path'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
