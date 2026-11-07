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

# Generated project roots contain archived product/lib assemblies. Default None
# discovery would put those assemblies ahead of explicit candidate HintPaths.
foreach($relative in @('tools/CSharpProfiles/Prepare-CSharpProfile.ps1','tools/CSharpProfiles/Invoke-BaselineProfileTests.ps1','.github/scripts/Invoke-SelectedCSharpTests.ps1')){
 $template=Get-Content (Join-Path "$PSScriptRoot/../../.." $relative) -Raw
 if(([regex]::Matches($template,'<EnableDefaultNoneItems>false</EnableDefaultNoneItems>')).Count -ne 1){throw "Generated project permits unintended None discovery: $relative"}
 if($template -notmatch '<HintPath>\$payload/WSS_Core_Interface.dll</HintPath>'){throw "Candidate reference lost explicit payload binding: $relative"}
}
'All three generated project templates exclude default None discovery and retain explicit candidate references.'
