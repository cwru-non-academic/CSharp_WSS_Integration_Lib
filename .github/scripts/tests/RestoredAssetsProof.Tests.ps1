$ErrorActionPreference='Stop'
. "$PSScriptRoot/../TrustedBaseline.ps1"
$root=Join-Path ([IO.Path]::GetTempPath()) ('wss-restore-proof-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $root
if(!$IsWindows){Push-Location $root;try{$root=(& /bin/pwd -P).Trim()}finally{Pop-Location}}
try {
 $files=@('project.csproj','project.assets.json','neutral.dll')|ForEach-Object {Join-Path $root $_}
 foreach($file in $files){[IO.File]::WriteAllText($file,'original')}
 $proof=New-TrustedBaselineSnapshot $files;Assert-TrustedBaselineSnapshot $proof;$count=1
 foreach($file in $files){
  [IO.File]::WriteAllText($file,'child-mutated');$caught=$false
  try{Assert-TrustedBaselineSnapshot $proof}catch{if($_.Exception.Message -notlike '*changed trusted baseline*'){throw};$caught=$true}
  if(!$caught){throw 'Child restore input mutation accepted'};$count++
  [IO.File]::WriteAllText($file,'original')
 }
 foreach($relative in @('.github/scripts/Invoke-SelectedCSharpTests.ps1','tools/CSharpProfiles/Invoke-BaselineProfileTests.ps1')){
  $text=Get-Content (Join-Path "$PSScriptRoot/../../.." $relative) -Raw
  $before=$text.IndexOf('& $validator -ArtifactRoot');$capture=$text.IndexOf('$restoredSnapshot=New-TrustedBaselineSnapshot @($project,$restoredAssets,$restoredNeutral)')
  $child=$text.IndexOf('Invoke-Behavior.ps1',$capture);if($child -lt 0){$child=$text.IndexOf('Invoke-WssBehavioralConformance.ps1',$capture)}
  $assert=$text.IndexOf('Assert-TrustedBaselineSnapshot $restoredSnapshot');$after=$text.LastIndexOf('& $validator -ArtifactRoot')
  if($before -lt 0 -or $capture -le $before -or $child -le $capture -or $assert -le $child -or $after -le $assert){throw 'Restore proof no longer encloses child test execution'}
  if(!$text.Contains('[Wss.BuildTools.RestoredPackageAssets]::ResolveProjectAsset(')){throw 'Proof must reuse the canonical resolver'};$count++
 }
 "Restored child-boundary proof contracts passed: $count; actual file mutation negatives, no WSS/native execution."
}finally{
 $resolved=[IO.Path]::GetFullPath($root)
 if([IO.Path]::GetFileName($resolved) -cnotmatch '^wss-restore-proof-[a-f0-9]{32}$' -or !(Split-Path -Parent $resolved)){throw 'Unsafe fixture cleanup path'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
