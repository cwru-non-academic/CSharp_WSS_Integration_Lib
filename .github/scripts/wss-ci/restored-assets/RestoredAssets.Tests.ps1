[CmdletBinding()]
param([string]$HelperPath=(Join-Path $PSScriptRoot 'RestoredPackageAssets.cs'))
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
# Only fabricated byte files and a managed build-time helper are used; no WSS DLL is loaded.
Add-Type -Path $HelperPath
. "$PSScriptRoot/Universal-WssFiles.ps1"
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('wss-restored-assets-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $scratch
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
Write-Bytes (Join-Path $root "system.io.ports/8.0.0/$asset") 'neutral-net8'
function New-Assets {
 @{version=3;targets=@{'net9.0'=@{'System.IO.Ports/8.0.0'=@{type='package';runtime=@{$asset=@{}}}}};libraries=@{'System.IO.Ports/8.0.0'=@{type='package';path='system.io.ports/8.0.0';files=@($asset)}};packageFolders=@{$root=@{}};project=@{restore=@{projectPath=$project}}}
}
function Save-Assets($Value){Write-Bytes $assets (ConvertTo-Json -InputObject $Value -Depth 20)}
function Resolve-Asset{[Wss.BuildTools.RestoredPackageAssets]::ResolveProjectAsset($assets,$project,$package,$asset,'net9.0')}
try {
 Save-Assets (New-Assets)
 Require ((Resolve-Asset) -ceq (Join-Path $root "system.io.ports/8.0.0/$asset")) 'Custom root/spaces resolution failed';$count++
 # Default-cache layout, custom NuGet.Config roots and fallbacks all use the restored packageFolders map.
 $default=Join-Path $scratch 'default-cache/.nuget/packages';Write-Bytes (Join-Path $default "system.io.ports/8.0.0/$asset") 'neutral-net8'
 $v=New-Assets;$v.packageFolders=@{$default=@{}};Save-Assets $v
 Require ((Resolve-Asset) -ceq (Join-Path $default "system.io.ports/8.0.0/$asset")) 'Default-layout root failed';$count++
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
 Write-Output "Restored assets/output contracts passed: $count. Synthetic byte files only; no WSS/native execution."
} finally {
 $resolved=[IO.Path]::GetFullPath($scratch);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
 if(!$resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -cnotmatch '^wss-restored-assets-[a-f0-9]{32}$'){throw 'Unsafe fixture cleanup path'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
