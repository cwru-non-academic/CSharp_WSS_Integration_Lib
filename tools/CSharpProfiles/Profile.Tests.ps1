param([Parameter(Mandatory)][string]$MainRoot,[Parameter(Mandatory)][string]$DevRoot)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/Profile.ps1"
$count=0
function Reject([scriptblock]$Action,[string]$Name){try{& $Action | Out-Null}catch{$script:count++;return};throw "Unexpected acceptance: $Name"}
$legacy=[WssProfileMetadata]::Read((Join-Path $MainRoot 'lib/WSS_Core_Interface.dll'))
$modern=[WssProfileMetadata]::Read((Join-Path $DevRoot 'lib/WSS_Core_Interface.dll'))
if((Get-WssCapabilityProfile $legacy) -cne 'legacy-v1' -or (Get-WssCapabilityProfile $modern) -cne 'layered-v1'){throw 'Actual baseline profile mismatch.'};$count+=2
foreach($type in @('Wss.Testing.WssStimulationSequence','Wss.Testing.WssStimulationStep','Wss.Testing.WssStimulationSequences','Wss.Testing.WssStimulationWindow','Wss.Testing.WssStimulationWindowResult','Wss.CoreModule.WssConfigurationSnapshot')){
 $broken=[Collections.Generic.Dictionary[string,string[]]]::new($modern,[StringComparer]::Ordinal)
 $null=$broken.Remove($type)
 Reject {Get-WssCapabilityProfile $broken} "missing $type"
 foreach($member in $modern[$type] | Where-Object {$_ -ne '.ctor'}) {
  $broken=[Collections.Generic.Dictionary[string,string[]]]::new($modern,[StringComparer]::Ordinal)
  $broken[$type]=@($modern[$type] | Where-Object {$_ -cne $member})
  Reject {Get-WssCapabilityProfile $broken} "missing $type.$member"
 }
 $partial=[Collections.Generic.Dictionary[string,string[]]]::new($legacy,[StringComparer]::Ordinal)
 $partial.Add($type,$modern[$type]);Reject {Get-WssCapabilityProfile $partial} "legacy plus $type"
}
foreach($type in @('Wss.Testing.WssBehaviorScenarios','Wss.Testing.IWssConformance')){
 foreach($member in $legacy[$type]){
  $broken=[Collections.Generic.Dictionary[string,string[]]]::new($legacy,[StringComparer]::Ordinal)
  $broken[$type]=@($legacy[$type] | Where-Object {$_ -cne $member})
  Reject {Get-WssCapabilityProfile $broken} "missing baseline $type.$member"
 }
}
$old=(Get-Content (Join-Path $MainRoot 'lib/wss-candidate.json') -Raw | ConvertFrom-Json).candidate
$new=(Get-Content (Join-Path $DevRoot 'lib/wss-candidate.json') -Raw | ConvertFrom-Json).candidate
$null=Resolve-WssReviewedProfile (Join-Path $MainRoot 'lib') $old
$null=Resolve-WssReviewedProfile (Join-Path $DevRoot 'lib') $new -SelectionEnabledCampaign
$count+=2
Reject {Resolve-WssReviewedProfile (Join-Path $MainRoot 'lib') $old -SelectionEnabledCampaign} 'campaign cannot downgrade to legacy'
Reject {Resolve-WssReviewedProfile (Join-Path $MainRoot 'lib') $new} 'legacy DLL modern producer'
Reject {Resolve-WssReviewedProfile (Join-Path $DevRoot 'lib') $old} 'modern DLL legacy producer'
foreach($key in @('repository','commit','archive','sha256','run_id','artifact_id')){
 $changed=$old | ConvertTo-Json | ConvertFrom-Json
 $changed.$key=if($key -ceq 'commit'){'f'*40}else{'wrong'}
 Reject {Resolve-WssReviewedProfile (Join-Path $MainRoot 'lib') $changed} "wrong producer $key"
}
foreach($profile in 'legacy-v1','layered-v1'){$null=Get-WssProfileFixture $profile;$count++}
"$count profile checks passed."
