# Synthetic regression inventory from immutable wrapper aafeef78536fe06094c6a694dd64d9a9e1433b21.
# This is fixture evidence, never campaign authentication or a selectable remote commit.
function Assert-LegacyFullInventory([string]$Path,[switch]$SelectedExtra) {
 $prefix='Wss.CSharpImplementation.Tests.'
 $expected=@(
  'StimulationControllerConformanceTests|InitializationThroughCSharpImplementationPassesCoreConformance',
  'StimulationControllerConformanceTests|AnalogStimulationThroughCSharpImplementationPassesCoreConformance',
  'StimulationControllerConformanceTests|normalized.minus-0.2',
  'StimulationControllerConformanceTests|normalized.0.0',
  'StimulationControllerConformanceTests|normalized.0.37',
  'StimulationControllerConformanceTests|normalized.0.5',
  'StimulationControllerConformanceTests|normalized.1.0',
  'StimulationControllerConformanceTests|normalized.1.2',
  'StimulationControllerConformanceTests|RuntimeEventEditThroughCSharpImplementationResumesConformantStreaming',
  'StimulationControllerConformanceTests|StopStimulationThroughCSharpImplementationDoesNotResumeStreaming',
  'StimulationControllerTestModeTests|TestModeInitializesAndShutsDownCleanly',
  'StimulationOptionsTests|DefaultTransportIsSerial',
  'StimulationOptionsTests|NonBleTransportDoesNotRequireBleSelector(Serial)',
  'StimulationOptionsTests|NonBleTransportDoesNotRequireBleSelector(Test)',
  'StimulationOptionsTests|NonBleTransportDoesNotRequireBleSelector(Conformance)',
  'StimulationOptionsTests|BleTransportRequiresDeviceSelection',
  'StimulationOptionsTests|BleTransportAcceptsConfiguredSelector(True,null,null)',
  'StimulationOptionsTests|BleTransportAcceptsConfiguredSelector(False,"WSS",null)',
  'StimulationOptionsTests|BleTransportAcceptsConfiguredSelector(False,null,"device-id")',
  'StimulationOptionsTests|UndefinedTransportIsRejected',
  'BleBackendLoadingTests|FacadeLoadsCurrentPlatformBackendAndDependencies',
  'SerialRuntimeSelectionTests|SerialTransportUsesPlatformRuntimeImplementation'
 ) | ForEach-Object {$prefix+$_}
 if($SelectedExtra){$expected+=$prefix+'HostedSelectedFixtureTests|SelectedOnlyFixtureChecksIsolationAndOptionalMutation'}
 [xml]$trx=Get-Content -LiteralPath $Path -Raw
 $actual=@(foreach($result in $trx.TestRun.Results.UnitTestResult){
  if($result.outcome -cne 'Passed'){throw 'Historical full inventory contains a non-passing case.'}
  $definition=@($trx.TestRun.TestDefinitions.UnitTest | Where-Object id -ceq $result.testId)
  if($definition.Count -ne 1){throw 'Historical full inventory has ambiguous test definitions.'}
  [string]$definition[0].TestMethod.className+'|'+[string]$result.testName
 })
 if($actual.Count -ne $expected.Count -or @(Compare-Object $expected $actual -CaseSensitive).Count){throw "Historical full inventory differs from the exact expected $($expected.Count) cases. Observed: $($actual -join '; ')"}
}
