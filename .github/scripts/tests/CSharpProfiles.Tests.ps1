$ErrorActionPreference='Stop'
. "$PSScriptRoot/../CSharpProfilesBootstrap.ps1"
Assert-CSharpProfileBootstrap
. "$PSScriptRoot/../../../tools/CSharpProfiles/Profile.ps1"
foreach($profile in 'legacy-v1','layered-v1'){$null=Get-WssProfileFixture $profile}
# Baseline APIs alone must classify legacy. Any modern sentinel makes a partial
# profile fail closed instead of silently falling back to the legacy suite.
$api=[Collections.Generic.Dictionary[string,string[]]]::new([StringComparer]::Ordinal)
$api.Add('Wss.Testing.WssBehaviorScenarios',@('get_StimulationFixture','get_Initialization','get_DirectAnalog','get_NormalizedStimulation','get_RuntimeEventEdit','get_StopStimulation'))
$api.Add('Wss.Testing.IWssConformance',@('get_MessageHistory','get_ProtocolErrors','get_StimulationHistory','ValidateInitialization','CaptureStimulationBaseline','ValidateStimulation'))
if((Get-WssCapabilityProfile $api) -cne 'legacy-v1'){throw 'Complete baseline rejected.'}
foreach($type in @('Wss.Testing.WssStimulationSequence','Wss.Testing.WssStimulationStep','Wss.Testing.WssStimulationSequences','Wss.Testing.WssStimulationWindow','Wss.Testing.WssStimulationWindowResult','Wss.CoreModule.WssConfigurationSnapshot')){
 $broken=[Collections.Generic.Dictionary[string,string[]]]::new($api,[StringComparer]::Ordinal)
 $broken.Add($type,@())
 $rejected=$false
 try{$null=Get-WssCapabilityProfile $broken}catch{$rejected=$true}
 if(!$rejected){throw "Partial modern profile accepted: $type"}
}
foreach($type in @($api.Keys)){
 foreach($method in $api[$type]){
  $broken=[Collections.Generic.Dictionary[string,string[]]]::new($api,[StringComparer]::Ordinal)
  $broken[$type]=@($api[$type] | Where-Object {$_ -cne $method})
  $rejected=$false
  try{$null=Get-WssCapabilityProfile $broken}catch{$rejected=$true}
  if(!$rejected){throw "Incomplete baseline accepted: $type.$method"}
 }
}
'Profile helper identities, fixed fixtures and 18 partial capability rejections passed.'
