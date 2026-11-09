[CmdletBinding()]
param([string]$HelperPath=(Join-Path $PSScriptRoot 'RestoredPackageAssets.cs'))
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
# Only fabricated byte files and a managed build-time helper are used; no WSS DLL is loaded.
Add-Type -Path $HelperPath
. "$PSScriptRoot/Universal-WssFiles.ps1"
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('wss-restored-assets-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $scratch
if(!$IsWindows){Push-Location $scratch;try{$scratch=(& /bin/pwd -P).Trim()}finally{Pop-Location}}
$count=0
function Require([bool]$Value,[string]$Message){if(!$Value){throw $Message}}
function Reject([scriptblock]$Action,[string]$Reason){
 $message='';try{& $Action | Out-Null}catch{$message=$_.Exception.Message}
 Require ($message -like "*$Reason*") "Expected rejection '$Reason', got '$message'"
 $script:count++
}
function Write-Bytes([string]$Path,[string]$Value){$null=New-Item -ItemType Directory (Split-Path -Parent $Path) -Force;[IO.File]::WriteAllText($Path,$Value)}
$project=Join-Path $scratch 'actual project/SelectedTests.csproj'
$assets=Join-Path $scratch 'isolated artifacts/obj/SelectedTests/project.assets.json'
$root=Join-Path $scratch 'custom cache with spaces'
$fallback=Join-Path $scratch 'NuGet fallback folder'
$asset='lib/net8.0/System.IO.Ports.dll';$package='System.IO.Ports/8.0.0'
Write-Bytes $project '<Project />'
Write-Bytes (Join-Path $root "system.io.ports/8.0.0/.nupkg.metadata") '{}'
Write-Bytes (Join-Path $root "system.io.ports/8.0.0/$asset") 'neutral-net8'
function New-Assets {
 @{version=3;targets=@{'net9.0'=@{'System.IO.Ports/8.0.0'=@{type='package';runtime=@{$asset=@{}}}}};libraries=@{'System.IO.Ports/8.0.0'=@{type='package';path='system.io.ports/8.0.0';files=@($asset)}};packageFolders=@{$root=@{}};project=@{restore=@{projectPath=$project}}}
}
function Save-Assets($Value){Write-Bytes $assets (ConvertTo-Json -InputObject $Value -Depth 20)}
function Resolve-Asset{[Wss.BuildTools.RestoredPackageAssets]::ResolveProjectAsset($assets,$project,$package,$asset,'net9.0')}
try {

 # Real directory inventories must not depend on Windows long/8.3 spelling.
 # Keep fixtures as text: this tests path admission, not native payload loading.
 foreach($variant in @(@{files=@($WssUniversalFiles)},@{files=@($WssUniversalFiles)+@($WssMacOSFiles)})) {
  $inventory=Join-Path $scratch ('universal inventory '+$variant.files.Count)
  foreach($relative in $variant.files){Write-Bytes (Join-Path $inventory $relative) 'inventory fixture'}
  $roots=@($inventory)
  if($IsWindows){
   $short=(New-Object -ComObject Scripting.FileSystemObject).GetFolder($inventory).ShortPath
   if($short -cne $inventory){$roots+=@($short)}
   else {Write-Output 'SKIP Windows 8.3 inventory alias: short names unavailable on fixture volume.'}
  }
  foreach($inventoryRoot in $roots){
   $actual=@(Read-WssUniversalFiles $inventoryRoot)
   Require (@(Compare-Object $actual $variant.files -CaseSensitive).Count -eq 0) 'Directory inventory changed through a path alias';$count++
   Write-Bytes (Join-Path $inventory 'wss-candidate.json') '{}'
   Reject {Read-WssUniversalFiles $inventoryRoot} 'exact legacy or macOS'
   $actual=@(Read-WssUniversalFiles $inventoryRoot -AllowProvenance)
   Require (@(Compare-Object $actual $variant.files -CaseSensitive).Count -eq 0) 'Exact provenance exception changed inventory';$count++
   Remove-Item -LiteralPath (Join-Path $inventory 'wss-candidate.json')
   Write-Bytes (Join-Path $inventory 'extra.dll') 'extra'
   Reject {Read-WssUniversalFiles $inventoryRoot} 'exact legacy or macOS'
   Remove-Item -LiteralPath (Join-Path $inventory 'extra.dll')
   $first=Join-Path $inventory $variant.files[0]
   Remove-Item -LiteralPath $first
   Reject {Read-WssUniversalFiles $inventoryRoot} 'exact legacy or macOS'
   Write-Bytes (Join-Path $inventory $variant.files[0].ToLowerInvariant()) 'wrong case'
   Reject {Read-WssUniversalFiles $inventoryRoot} 'exact legacy or macOS'
   Remove-Item -LiteralPath (Join-Path $inventory $variant.files[0].ToLowerInvariant())
   Write-Bytes $first 'inventory fixture'
  }
 }
 Save-Assets (New-Assets)
 Require ((Resolve-Asset) -ceq (Join-Path $root "system.io.ports/8.0.0/$asset")) 'Custom root/spaces resolution failed';$count++
 # Default-cache layout, custom NuGet.Config roots and fallbacks all use the restored packageFolders map.
 $default=Join-Path $scratch 'default-cache/.nuget/packages';Write-Bytes (Join-Path $default 'system.io.ports/8.0.0/.nupkg.metadata') '{}';Write-Bytes (Join-Path $default "system.io.ports/8.0.0/$asset") 'neutral-net8'
 $v=New-Assets;$v.packageFolders=@{$default=@{}};Save-Assets $v
 Require ((Resolve-Asset) -ceq (Join-Path $default "system.io.ports/8.0.0/$asset")) 'Default-layout root failed';$count++
 Write-Bytes (Join-Path $fallback 'system.io.ports/8.0.0/.nupkg.metadata') '{}'
 Write-Bytes (Join-Path $fallback "system.io.ports/8.0.0/$asset") 'fallback-neutral'
 $v=New-Assets;$v.packageFolders=[ordered]@{(Join-Path $scratch 'empty primary')=@{};$fallback=@{}};Save-Assets $v
 Require ((Resolve-Asset) -ceq (Join-Path $fallback "system.io.ports/8.0.0/$asset")) 'Fallback-folder resolution failed';$count++
 $cases=@(
 @{reason='not a package';edit={param($v)$v.libraries[$package].type='project'}},
 @{reason='package/version';edit={param($v)$v.libraries[$package].path='system.io.ports/9.0.0'}},
 @{reason='require object property';edit={param($v)$v.libraries['System.IO.Ports/9.0.0']=$v.libraries[$package];$v.libraries.Remove($package)}},
 @{reason='not declared';edit={param($v)$v.libraries[$package].files=@('lib/net462/System.IO.Ports.dll')}},
 @{reason='inside its package';edit={param($v)$v.libraries[$package].path='../escape'}},
 @{reason='must be absolute';edit={param($v)$v.packageFolders=@{'relative-cache'=@{}}}},
 @{reason='not found';edit={param($v)$v.packageFolders=@{(Join-Path $scratch 'absent cache')=@{}}}},
 @{reason='different project';edit={param($v)$v.project.restore.projectPath=Join-Path $scratch 'other.csproj'}},
 @{reason='target is missing';edit={param($v)$v.targets=@{'net462'=$v.targets['net9.0']}}},
 @{reason='require object property';edit={param($v)$v.targets['net9.0'].Remove($package)}},
 @{reason='Target library is not';edit={param($v)$v.targets['net9.0'][$package].type='project'}},
 @{reason='require object property';edit={param($v)$v.packageFolders=@()}},
 @{reason='require object property';edit={param($v)$v.libraries=$null}}
 )
 foreach($case in $cases){$v=New-Assets;& $case.edit $v;Save-Assets $v;Reject {Resolve-Asset} $case.reason}
 Write-Bytes $assets '{broken';Reject {Resolve-Asset} 'Malformed or incomplete'
 Write-Bytes $assets '{"libraries":{},"libraries":{}}';Reject {Resolve-Asset} 'Duplicate'
 Save-Assets (New-Assets);[IO.File]::SetLastWriteTimeUtc($assets,[IO.File]::GetLastWriteTimeUtc($project).AddSeconds(-5));Reject {Resolve-Asset} 'stale'
 Reject {[Wss.BuildTools.RestoredPackageAssets]::ResolveProjectAsset((Join-Path $scratch 'missing.json'),$project,$package,$asset,'net9.0')} 'assets.json is missing'
 Reject {[Wss.BuildTools.RestoredPackageAssets]::ResolveProjectAsset($assets,(Join-Path $scratch 'missing.csproj'),$package,$asset,'net9.0')} 'project is missing'
 Save-Assets (New-Assets)
 $payload=Join-Path $scratch 'payload';$output=Join-Path $scratch 'output'
 foreach($relative in $WssUniversalFiles){Write-Bytes (Join-Path $payload $relative) "verified-$relative";Write-Bytes (Join-Path $output $relative) "verified-$relative"}
 $verifierArgs=@{ArtifactRoot=$payload;OutputRoot=$output;ProjectAssetsFile=$assets;ProjectPath=$project}
 Write-Bytes (Join-Path $output 'System.IO.Ports.dll') 'neutral-net8'
 & "$PSScriptRoot/Verify-WssOutput.ps1" @verifierArgs | Out-Null;$count++
 $platform=if($IsWindows){'win'}else{'unix'}
 Write-Bytes (Join-Path $output 'System.IO.Ports.dll') "verified-runtimes/$platform/lib/net8.0/System.IO.Ports.dll"
 & "$PSScriptRoot/Verify-WssOutput.ps1" @verifierArgs | Out-Null;$count++
 foreach($bytes in @('verified-System.IO.Ports.dll','foreign bytes')){Write-Bytes (Join-Path $output 'System.IO.Ports.dll') $bytes;Reject {& "$PSScriptRoot/Verify-WssOutput.ps1" @verifierArgs} 'net462 is forbidden'}
 Write-Bytes (Join-Path $output 'System.IO.Ports.dll') 'neutral-net8'
 Write-Bytes (Join-Path $output 'WSS.Transport.Serial.dll') 'changed';Reject {& "$PSScriptRoot/Verify-WssOutput.ps1" @verifierArgs} 'hash mismatch'
 Write-Bytes (Join-Path $output 'WSS.Transport.Serial.dll') 'verified-WSS.Transport.Serial.dll'
 Write-Bytes (Join-Path $output 'backends/macos/WSS.Transport.BLE.MacOS.dll') 'partial';Reject {& "$PSScriptRoot/Verify-WssOutput.ps1" @verifierArgs} 'no partial or stale'
 Remove-Item -LiteralPath (Join-Path $output 'backends/macos/WSS.Transport.BLE.MacOS.dll')
 Write-Bytes (Join-Path $output 'WinRT.Runtime.dll') 'obsolete';Reject {& "$PSScriptRoot/Verify-WssOutput.ps1" @verifierArgs} 'Obsolete'

 # A parent proof fixes the expected bytes and the selected package identity.
 Remove-Item -LiteralPath (Join-Path $output 'WinRT.Runtime.dll')
 . "$PSScriptRoot/RestoredAssets.ps1"
 $neutral=Join-Path $root "system.io.ports/8.0.0/$asset"
 function New-Proof {
  Save-Assets (New-Assets)
  New-WssRestoredAssetsProof -ProjectAssetsFile $assets -ProjectPath $project
 }
 function Check-Proof($Proof) { Assert-WssRestoredAssetsProof -Proof $Proof -ProjectAssetsFile $assets -ProjectPath $project }
 $proof=New-Proof;Check-Proof $proof;$count++
 Require ($proof.NeutralAssetPath -ceq $neutral -and $proof.PackageDirectory -ceq (Join-Path $root 'system.io.ports/8.0.0')) 'Proof identity incorrect';$count++
 Reject {Assert-WssRestoredAssetsProof -Proof @{} -ProjectAssetsFile $assets -ProjectPath $project} 'parent-captured managed'
 Reject {[Wss.BuildTools.RestoredPackageAssets]::AssertProjectAssetProof($proof,$assets,$project,'Other/8.0.0',$asset,'net9.0')} 'different project'
 $originalProject=[IO.File]::ReadAllText($project)
 Write-Bytes $project '<Project changed="true" />'
 [IO.File]::SetLastWriteTimeUtc($assets,[IO.File]::GetLastWriteTimeUtc($project).AddSeconds(1))
 Reject {Check-Proof $proof} 'project/assets content'
 Write-Bytes $project $originalProject
 $proof=New-Proof;[IO.File]::AppendAllText($assets,' ')
 Reject {Check-Proof $proof} 'project/assets content'
 $proof=New-Proof;Write-Bytes $neutral 'child-neutral';Write-Bytes (Join-Path $output 'System.IO.Ports.dll') 'child-neutral'
 Reject {& "$PSScriptRoot/Verify-WssOutput.ps1" @verifierArgs -RestoreProof $proof} 'neutral asset bytes'
 Write-Bytes $neutral 'neutral-net8';Write-Bytes (Join-Path $output 'System.IO.Ports.dll') 'neutral-net8'
 $proof=New-Proof;Write-Bytes (Join-Path $output 'System.IO.Ports.dll') 'child-output'
 Reject {& "$PSScriptRoot/Verify-WssOutput.ps1" @verifierArgs -RestoreProof $proof} 'net462 is forbidden'
 Write-Bytes (Join-Path $output 'System.IO.Ports.dll') 'neutral-net8'
 # Earlier root can be added without touching any initially captured file.
 $earlier=Join-Path $scratch 'new earlier package cache'
 $v=New-Assets;$v.packageFolders=[ordered]@{$earlier=@{};$root=@{}};Save-Assets $v
 $proof=New-WssRestoredAssetsProof -ProjectAssetsFile $assets -ProjectPath $project
 Write-Bytes (Join-Path $earlier "system.io.ports/8.0.0/$asset") 'child-foreign'
 Write-Bytes (Join-Path $output 'System.IO.Ports.dll') 'child-foreign'
 # An asset alone is incomplete and does not change SDK package selection.
 Reject {& "$PSScriptRoot/Verify-WssOutput.ps1" @verifierArgs -RestoreProof $proof} 'net462 is forbidden'
 Write-Bytes (Join-Path $earlier 'system.io.ports/8.0.0/.nupkg.metadata') '{}'
 Reject {& "$PSScriptRoot/Verify-WssOutput.ps1" @verifierArgs -RestoreProof $proof} 'resolution identity'
 Write-Bytes (Join-Path $earlier "system.io.ports/8.0.0/$asset") 'neutral-net8'
 Write-Bytes (Join-Path $output 'System.IO.Ports.dll') 'neutral-net8'
 Reject {Check-Proof $proof} 'resolution identity'
 # A selected complete package never falls through when one asset disappears.
 $v=New-Assets;$v.packageFolders=[ordered]@{$root=@{};$fallback=@{}};Save-Assets $v
 $proof=New-WssRestoredAssetsProof -ProjectAssetsFile $assets -ProjectPath $project
 Remove-Item -LiteralPath $neutral
 Reject {Resolve-Asset} 'fallback is forbidden'
 Reject {Check-Proof $proof} 'fallback is forbidden'
 Write-Bytes $neutral 'neutral-net8'
 # Root-order edits and removal of the selected package marker are also rejected.
 $v.packageFolders=[ordered]@{$fallback=@{};$root=@{}};Save-Assets $v
 Reject {Check-Proof $proof} 'project/assets content'
 $v.packageFolders=[ordered]@{$root=@{};$fallback=@{}};Save-Assets $v
 $proof=New-WssRestoredAssetsProof -ProjectAssetsFile $assets -ProjectPath $project
 $marker=Join-Path $root 'system.io.ports/8.0.0/.nupkg.metadata'
 if($IsWindows){[IO.File]::SetAttributes($marker,[IO.File]::GetAttributes($marker) -bor [IO.FileAttributes]::Hidden)}
 Remove-Item -LiteralPath $marker -Force
 Require (!(Test-Path -LiteralPath $marker)) 'Synthetic package marker was not removed'
 Reject {Check-Proof $proof} 'resolution identity'
 Write-Bytes (Join-Path $root 'system.io.ports/8.0.0/.nupkg.metadata') '{}'
 # Optional root output does not make mandatory restore authentication optional.
 $proof=New-Proof;Remove-Item -LiteralPath (Join-Path $output 'System.IO.Ports.dll')
 & "$PSScriptRoot/Verify-WssOutput.ps1" @verifierArgs -RestoreProof $proof | Out-Null;$count++
 Write-Bytes $assets '{broken'
 Reject {& "$PSScriptRoot/Verify-WssOutput.ps1" @verifierArgs} 'Malformed or incomplete'
 # RID-specific runtime selection may differ; package-declared neutral is deliberate policy.
 $v=New-Assets;$v.targets['net9.0/rid-fixture']=@{$package=@{type='package';runtime=@{'runtimes/rid/lib/net8.0/System.IO.Ports.dll'=@{}}}};Save-Assets $v
 $proof=New-WssRestoredAssetsProof -ProjectAssetsFile $assets -ProjectPath $project
 Check-Proof $proof;$count++
 Write-Output "Restored assets/output contracts passed: $count. Synthetic byte files only; no WSS/native execution."
} finally {
 $resolved=[IO.Path]::GetFullPath($scratch);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
 if(!$IsWindows){Push-Location $temp;try{$temp=(& /bin/pwd -P).Trim()}finally{Pop-Location}}
 if(!$resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -cnotmatch '^wss-restored-assets-[a-f0-9]{32}$'){throw 'Unsafe fixture cleanup path'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
