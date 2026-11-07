[CmdletBinding()]
param([string]$EvidencePath=$env:WSS_PROFILE_EVIDENCE,[string]$ResultsDirectory=(Join-Path ([IO.Path]::GetTempPath()) ('wss-behavior-'+[guid]::NewGuid().ToString('N'))))
$ErrorActionPreference='Stop'
. "$PSScriptRoot/Profile.ps1"
if(!$EvidencePath){throw 'Verified profile preparation is required before behavioral conformance.'}
$state=Get-Content -LiteralPath $EvidencePath -Raw | ConvertFrom-Json
if($state.schema -cne 'wss-csharp-prepared-profile/v1'){throw 'Invalid prepared profile evidence.'}
$actual=Resolve-WssReviewedProfile $state.payload_root $state.profile.producer
if($actual.profile -cne $state.profile.profile -or $actual.core_dll_sha256 -cne $state.profile.core_dll_sha256){throw 'Prepared payload profile changed.'}
if((Get-WssProfileFixture $actual.profile) -cne $state.fixture){throw 'Prepared fixture differs from trusted profile.'}
function Assert-PreparedSources {
 foreach($file in $state.sources){if((Get-FileHash (Join-Path $state.source_root $file.path) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file.sha256){throw 'Prepared source changed.'}}
 if((Get-FileHash $state.fixture -Algorithm SHA256).Hash.ToLowerInvariant() -cne $state.fixture_sha256){throw 'Prepared fixture changed.'}
 $output=Join-Path $state.output_root 'Release/net9.0/WSS_Core_Interface.dll'
 if((Get-FileHash $output -Algorithm SHA256).Hash.ToLowerInvariant() -cne $state.profile.core_dll_sha256){throw 'Compiled test output uses a different Core payload.'}
}
Assert-PreparedSources
& "$PSScriptRoot/Invoke-Behavior.ps1" -Profile $actual.profile -Project $state.project -IsolatedBuild -ResultsDirectory $ResultsDirectory -ArtifactDirectory $state.payload_root -BleArtifactDirectory $state.payload_root
Assert-PreparedSources
$state.profile | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $ResultsDirectory 'profile.json')
