# Core-owned direct compiled-test execution. The installed SDK/framework is trusted;
# these inventory checks are not an operating-system sandbox.
$script:WssCompiledBaselinePath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../TrustedBaseline.ps1'))
. $script:WssCompiledBaselinePath
$script:WssCompiledToolsRoot=$PSScriptRoot
function New-CompiledCSharpTestProof {
 [CmdletBinding()]
 param([Parameter(Mandatory)][string]$OutputRoot,[Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.-]+\.dll$')][string]$AssemblyName)
 $output=[IO.Path]::GetFullPath($OutputRoot)
 $assembly=Join-Path $output $AssemblyName
 $stem=[IO.Path]::GetFileNameWithoutExtension($AssemblyName)
 foreach($file in @($AssemblyName,"$stem.deps.json","$stem.runtimeconfig.json",'testhost.dll','NUnit3.TestAdapter.dll','nunit.framework.dll','nunit.engine.dll','nunit.engine.api.dll','nunit.engine.core.dll','testcentric.engine.metadata.dll')){
  if(!(Test-Path -LiteralPath (Join-Path $output $file) -PathType Leaf)){throw "Compiled test input missing: $file"}
 }
 # Direct VSTest uses copy-local dependencies/adapters, never external NuGet probes.
 foreach($file in Get-ChildItem -LiteralPath $output -Filter '*.runtimeconfig*.json' -File){
  $runtime=Get-Content -LiteralPath $file.FullName -Raw|ConvertFrom-Json -AsHashtable
  if($runtime.ContainsKey('runtimeOptions') -and $runtime.runtimeOptions.ContainsKey('additionalProbingPaths') -and @($runtime.runtimeOptions.additionalProbingPaths).Count){
   throw 'Compiled test runtime configuration contains external additional probing paths.'
  }
 }
 $dotnet=(Get-Command dotnet -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
 # Bind the chosen installed VSTest console once. Later stages must not rerun
 # SDK selection against a global.json changed by a preceding test child.
 $version=(& $dotnet --version|Out-String).Trim()
 if($LASTEXITCODE -ne 0){throw 'Cannot identify the trusted installed SDK.'}
 $sdks=@(& $dotnet --list-sdks)
 if($LASTEXITCODE -ne 0){throw 'Cannot locate the trusted installed SDK.'}
 $sdkMatches=@($sdks|Where-Object {$_ -match ('^'+[regex]::Escape($version)+' \[(.+)\]$')})
 if($sdkMatches.Count -ne 1){throw 'Installed SDK binding is ambiguous.'}
 $match=[regex]::Match($sdkMatches[0],'^.+ \[(.+)\]$')
 $vstest=Join-Path (Join-Path $match.Groups[1].Value $version) 'vstest.console.dll'
 if(!(Test-Path -LiteralPath $vstest -PathType Leaf)){throw 'The selected installed SDK has no VSTest console.'}
 $snapshot=New-TrustedBaselineSnapshot @($output,$script:WssCompiledToolsRoot,$script:WssCompiledBaselinePath,$vstest)
 [pscustomobject]@{output_root=$output;assembly=$assembly;dotnet=$dotnet;vstest=$vstest;snapshot=$snapshot}
}
function Invoke-WssCompiledTestHost([string]$Command,[string[]]$Arguments,[hashtable]$Result) {
 & $Command @Arguments
 $Result.exit_code=$LASTEXITCODE
}
function Invoke-CompiledCSharpTests {
 [CmdletBinding()]
 param(
  [Parameter(Mandatory)]$Proof,
  [Parameter(Mandatory)][string]$ResultsDirectory,
  [string]$Filter='',
  [ValidatePattern('^[A-Za-z0-9_.-]+\.trx$')][string]$TrxFileName='results.trx',
  [ValidateSet('','x64','ARM64','x86')][string]$Platform='',
  [switch]$DetailedConsole
 )
 Assert-TrustedBaselineSnapshot $Proof.snapshot
 $results=[IO.Path]::GetFullPath($ResultsDirectory)
 $relative=[IO.Path]::GetRelativePath($Proof.output_root,$results)
 if($relative -ceq '.' -or ($relative -cne '..' -and !$relative.StartsWith('..'+[IO.Path]::DirectorySeparatorChar) -and ![IO.Path]::IsPathRooted($relative))){throw 'Compiled test results must be outside immutable output.'}
 if(Test-Path -LiteralPath $results){Assert-BaselineRegularPath $results}
 $arguments=@('exec',$Proof.vstest,$Proof.assembly,"/TestAdapterPath:$($Proof.output_root)","/Logger:trx;LogFileName=$TrxFileName","/ResultsDirectory:$results")
 if($Filter){$arguments+="/TestCaseFilter:$Filter"}
 if($Platform){$arguments+="/Platform:$Platform"}
 if($DetailedConsole){$arguments+='/Logger:console;verbosity=detailed'}
 $prior=@{}
 $names=@('DOTNET_STARTUP_HOOKS','DOTNET_ADDITIONAL_DEPS','DOTNET_SHARED_STORE')
 $names+=@('VSTEST_TESTADAPTER_PATH','VSTEST_ADDITIONAL_EXTENSIONS','VSTEST_TESTHOST_PATH')
 $result=@{exit_code=-1}
 try {
  foreach($name in $names){$prior[$name]=[Environment]::GetEnvironmentVariable($name);[Environment]::SetEnvironmentVariable($name,$null)}
  Invoke-WssCompiledTestHost $Proof.dotnet $arguments $result
  Assert-TrustedBaselineSnapshot $Proof.snapshot
  if($result.exit_code -ne 0){throw "Compiled CSharp tests failed ($($result.exit_code))."}
 }finally{foreach($name in $prior.Keys){[Environment]::SetEnvironmentVariable($name,$prior[$name])}}
}
