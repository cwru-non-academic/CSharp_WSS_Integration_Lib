# Execute production SDK argument expressions against a capture function, never a product build.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$count=0
$PayloadRoot='verified payload';$state=@{payload_root=$PayloadRoot;project='prepared/SelectedTests.csproj'}
$profile=@{source_root='prepared product'};$proof=@{state=@{source_root=$profile.source_root}}
$project='generated/SelectedTests.csproj';$reloadProject='tests/Wss.Cli.Reload.Tests/Wss.Cli.Reload.Tests.csproj'
$properties=@();$reloadProperties=@();$FixtureRoot='fixture root'
$oldProfile=$env:WSS_PROFILE_PROJECT;$oldArtifact=$env:WSS_ARTIFACT_DIR;$oldBle=$env:WSS_BLE_ARTIFACT_DIR;$oldTemp=$env:RUNNER_TEMP
$env:WSS_PROFILE_PROJECT=$state.project;$env:WSS_ARTIFACT_DIR=$PayloadRoot;$env:WSS_BLE_ARTIFACT_DIR=$PayloadRoot;$env:RUNNER_TEMP='temporary results'
function Capture-Sdk {
 $native=[Collections.Generic.List[string]]::new()
 for($i=0;$i -lt $args.Count;$i++){
  if($args[$i] -ceq '-p:' -and $i+1 -lt $args.Count){$i++;$native.Add('-p:'+[string]$args[$i])}else{$native.Add([string]$args[$i])}
 }
 if($native -cnotcontains '-p:DisablePackageAssetsCache=true'){throw 'SDK invocation omitted the explicit cache-disabled contract'}
 if($native[0] -cin @('build','publish') -and $native -cnotcontains '--no-restore'){throw 'Build/publish can rewrite the captured restore'}
 if($native[0] -ceq 'test'){throw 'Project-based test execution remains; use the captured compiled runner'}
 $script:count++
}
try{
 $files=@(Get-ChildItem -Path (Join-Path $root '.github/scripts'),(Join-Path $root 'tools/CSharpProfiles'),(Join-Path $root 'tools/SelectedRuntimeFixtures') -File -Filter '*.ps1')
 $files+=@(Get-ChildItem (Join-Path $root '.github/workflows') -File -Filter '*.yml')
 foreach($file in $files){
  $lines=Get-Content -LiteralPath $file.FullName
  foreach($line in $lines){
   if($line -match '^\s*\$(properties|reloadProperties)=@'){
    . ([scriptblock]::Create($line.Trim()))
   }
   if($line -match '^\s*&?\s*dotnet\s+@'){throw "Uninspected SDK argument-array invocation remains: $($file.FullName)"}
   if($line -notmatch '^\s*(?:run:\s*)?&?\s*dotnet\s+(restore|build|publish|test)\b'){continue}
   if($line.Contains('workflow-guard/tools/ArtifactBuild/ArtifactBuild.csproj')){continue}
   $command=[regex]::Replace($line,'^\s*run:\s*','')
   $errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($command,[ref]$null,[ref]$errors)
   if($errors.Count){throw "SDK invocation does not parse: $($file.FullName)"}
   $call=$ast.Find({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'dotnet'},$true)
   $target=$call.CommandElements[0]
   $command=$command.Substring(0,$target.Extent.StartOffset)+'Capture-Sdk'+$command.Substring($target.Extent.EndOffset)
   & ([scriptblock]::Create($command))
  }
 }
 if($count -lt 15){throw 'SDK invocation inventory unexpectedly shrank'}
 "SDK caller contracts passed: $count actual invocation captures; cache-disabled restore/build/publish, no implicit restore or project-based test reruns."
}finally{$env:WSS_PROFILE_PROJECT=$oldProfile;$env:WSS_ARTIFACT_DIR=$oldArtifact;$env:WSS_BLE_ARTIFACT_DIR=$oldBle;$env:RUNNER_TEMP=$oldTemp}
