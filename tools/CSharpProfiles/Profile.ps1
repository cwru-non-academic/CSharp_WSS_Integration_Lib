# Profile inputs must come from an authenticated producer/package boundary.
# This module does not authenticate arbitrary caller-supplied provenance by itself.
Set-StrictMode -Version Latest
if (-not ('WssProfileMetadata' -as [type])) {
Add-Type -TypeDefinition @"
using System; using System.IO; using System.Linq; using System.Collections.Generic;
using System.Reflection; using System.Reflection.Metadata; using System.Reflection.PortableExecutable;
public static class WssProfileMetadata {
 public static Dictionary<string,string[]> Read(string path) {
  using var s=File.OpenRead(path); using var pe=new PEReader(s); var r=pe.GetMetadataReader();
  if(r.GetString(r.GetAssemblyDefinition().Name)!="WSS_Core_Interface") throw new InvalidDataException("Wrong Core assembly identity.");
  return r.TypeDefinitions.Select(h=>r.GetTypeDefinition(h)).Where(t=>r.GetString(t.Namespace)=="Wss.Testing" || r.GetString(t.Namespace)=="Wss.CoreModule")
   .ToDictionary(t=>r.GetString(t.Namespace)+"."+r.GetString(t.Name),t=>t.GetMethods().Select(h=>r.GetMethodDefinition(h))
    .Where(m=>(m.Attributes & MethodAttributes.MemberAccessMask)==MethodAttributes.Public)
    .Select(m=>r.GetString(m.Name)).ToArray(),StringComparer.Ordinal);
 }
}
"@
}
function Get-WssCapabilityProfile($Api) {
 $base=@{
  'Wss.Testing.WssBehaviorScenarios'=@('get_StimulationFixture','get_Initialization','get_DirectAnalog','get_NormalizedStimulation','get_RuntimeEventEdit','get_StopStimulation')
  'Wss.Testing.IWssConformance'=@('get_MessageHistory','get_ProtocolErrors','get_StimulationHistory','ValidateInitialization','CaptureStimulationBaseline','ValidateStimulation')
 }
 $modern=@{
  'Wss.Testing.WssStimulationSequence'=@('get_Id','get_DeviceCount','get_Steps','get_ModelMode','get_AmplitudeMode','WriteFixture')
  'Wss.Testing.WssStimulationStep'=@('get_Id','get_GlobalChannel','get_Normalized','get_Modeled','get_ReloadParameters','get_ReloadModel','get_ModelOffset','get_Input','get_Expectation','PrepareReload')
  'Wss.Testing.WssStimulationSequences'=@('get_LayeredSingleDevice','get_LayeredMultipleDevices','get_SingleDevice','get_MultipleDevices')
  'Wss.Testing.WssStimulationWindow'=@('Evaluate')
  'Wss.CoreModule.WssConfigurationSnapshot'=@('get_Generation','get_CorePath','get_ParamsPath','get_ModelPath','get_DefaultCorePath','get_DefaultParamsPath','get_DefaultModelPath','ReadDefaults','ReloadDefaults','Reload','ReloadCore','HasSameCore','CaptureCurrent','BuildAndInitialize','ApplyWithoutRestart')
  'Wss.Testing.WssStimulationWindowResult'=@('get_Settled','get_Passed','get_Failures','get_Diagnostics')
 }
 foreach($name in $base.Keys) {
  if(!$Api.ContainsKey($name)){throw "Missing baseline capability: $name"}
  foreach($member in $base[$name]){if($member -cnotin $Api[$name]){throw "Missing baseline capability: $name.$member"}}
 }
 $present=@($modern.Keys | Where-Object {$Api.ContainsKey($_)})
 if($present.Count -eq 0){return 'legacy-v1'}
 foreach($name in $modern.Keys) {
  if(!$Api.ContainsKey($name)){throw "Partial layered capability: $name"}
  foreach($member in $modern[$name]){if($member -cnotin $Api[$name]){throw "Partial layered capability: $name.$member"}}
 }
 'layered-v1'
}
function Resolve-WssReviewedProfile([string]$PayloadRoot,$Producer,[switch]$SelectionEnabledCampaign) {
 # Bounded initial registry: adding a producer requires review of its immutable DLL identity.
 $registry=@{
  '50afc280a6c591bc0adec8dda5fe5ce72ba8708d'=@{profile='legacy-v1';dll='92545eaa872a3e3d1b4b453acd4ead98f06af6e2bc5f0a016943a5512eab806f';archive='3a6d399c0f4c6c63228133e7d818e997c8c05d584924e4632cd5ccca96e257df';run='42258265327';artifact='13524450471'}
  '76803c03c7aa55b8951499053641ad9ce83504b8'=@{profile='legacy-v1';dll='738691490a76ceb56b38aa580148116db1a46601117246890a129eb0e6bfed20';archive='856566f5710a5662254373cc8c5d3ecf3527b89506f0df140824261ca50d2167';run='42230527501';artifact='13507483694'}

 }
 if($Producer.repository -cne 'cwru-non-academic/WSSCore' -or $Producer.commit -cnotmatch '^[a-f0-9]{40}$' -or $Producer.archive -cne 'WSS-Universal-ci.zip' -or $Producer.sha256 -cnotmatch '^[a-f0-9]{64}$' -or [string]$Producer.run_id -cnotmatch '^[1-9][0-9]*$' -or [string]$Producer.artifact_id -cnotmatch '^[1-9][0-9]*$'){throw 'Malformed authenticated producer identity.'}
 $dll=Join-Path $PayloadRoot 'WSS_Core_Interface.dll'
 $hash=(Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash.ToLowerInvariant()
 $profile=Get-WssCapabilityProfile ([WssProfileMetadata]::Read($dll))
 if($registry.ContainsKey([string]$Producer.commit)) {
  $expected=$registry[[string]$Producer.commit]
  if($profile -cne $expected.profile -or $hash -cne $expected.dll -or $Producer.sha256 -cne $expected.archive -or [string]$Producer.run_id -cne $expected.run -or [string]$Producer.artifact_id -cne $expected.artifact){throw 'Legacy producer/package/profile identity mismatch.'}
 } elseif($profile -ceq 'legacy-v1') {throw 'Legacy profile is not in the reviewed immutable producer allowlist.'}
 if($SelectionEnabledCampaign -and $profile -cne 'layered-v1'){throw 'Selection-enabled campaigns require the complete layered profile.'}
 [pscustomobject]@{schema='wss-csharp-profile/v1';profile=$profile;producer=$Producer;core_dll_sha256=$hash}
}

function Get-WssProfileFixture([string]$Profile) {
 $hashes=@{
  'legacy-v1'='f6aeced83d35255532b6685d9c870307f856aad140da133695a77e9de6104ee2'
  'layered-v1'='96812ab33be7ede8840ddb78131a50796fd3f797d9627f958251b3e58796baf8'
 }
 if(!$hashes.ContainsKey($Profile)){throw 'Unknown bootstrap fixture profile.'}
 $path=Join-Path $PSScriptRoot "fixtures/$Profile/StimulationControllerConformanceTests.cs"
 if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hashes[$Profile]){throw 'Bootstrap fixture bytes differ from the reviewed source.'}
 $path
}
