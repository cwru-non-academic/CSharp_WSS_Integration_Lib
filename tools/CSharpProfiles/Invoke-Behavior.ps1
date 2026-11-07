[CmdletBinding()]
param(
    [string]$Project = (Join-Path $PSScriptRoot '../../tests/Wss.CSharpImplementation.Tests/Wss.CSharpImplementation.Tests.csproj'),
    [string]$ResultsDirectory = (Join-Path ([IO.Path]::GetTempPath()) ('wss-behavior-' + [Guid]::NewGuid().ToString('N'))),
    [string]$ArtifactDirectory = $env:WSS_ARTIFACT_DIR,
    [string]$BleArtifactDirectory = $env:WSS_BLE_ARTIFACT_DIR,
    [switch]$IsolatedBuild,
    [Parameter(Mandatory)][ValidateSet('legacy-v1','layered-v1')][string]$Profile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This inventory is independent of the Core catalog: removing a scenario must fail CI.
$baseCases = @(
    'InitializationThroughCSharpImplementationPassesCoreConformance',
    'AnalogStimulationThroughCSharpImplementationPassesCoreConformance',
    'normalized.minus-0.2', 'normalized.0.0', 'normalized.0.37',
    'normalized.0.5', 'normalized.1.0', 'normalized.1.2',
    'RuntimeEventEditThroughCSharpImplementationResumesConformantStreaming',
    'StopStimulationThroughCSharpImplementationDoesNotResumeStreaming'
)
$filter = 'FullyQualifiedName~Wss.CSharpImplementation.Tests.StimulationOptionsTests|FullyQualifiedName~Wss.CSharpImplementation.Tests.StimulationControllerTestModeTests|FullyQualifiedName~Wss.CSharpImplementation.Tests.StimulationControllerConformanceTests'
$previousStage = $env:WSS_CONFORMANCE_STAGE
$summary = @()
try {
    foreach ($stage in $(if($Profile -ceq 'layered-v1'){@('single','multi')}else{@('legacy')})) {
        $env:WSS_CONFORMANCE_STAGE = $stage
        $directory = Join-Path $ResultsDirectory $stage
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
        $arguments = @('test', $Project, '-c', 'Release', '--no-build', '--no-restore',
            '--filter', $filter, '-p:TreatWarningsAsErrors=true',
            '--logger', 'trx;LogFileName=behavior.trx', '--results-directory', $directory)
        if ($IsolatedBuild) { $arguments += @('-p:ImportDirectoryBuildProps=false','-p:ImportDirectoryBuildTargets=false') }
        if ($ArtifactDirectory) { $arguments += "-p:WSS_ARTIFACT_DIR=$ArtifactDirectory" }
        if ($BleArtifactDirectory) { $arguments += "-p:WSS_BLE_ARTIFACT_DIR=$BleArtifactDirectory" }
        & dotnet @arguments
        if ($LASTEXITCODE -ne 0) { throw "Behavioral conformance failed in the $stage stage." }
        [xml]$trx = Get-Content -LiteralPath (Join-Path $directory 'behavior.trx') -Raw
        $definitions = @($trx.TestRun.TestDefinitions.UnitTest | Where-Object {
            $_.TestMethod.className -ceq 'Wss.CSharpImplementation.Tests.StimulationControllerConformanceTests'
        })
        $isolation = if ($stage -ceq 'single') { 'multichannel' } else { 'multidevice' }
        $required = @($baseCases) + @("analog.$isolation-isolation", "normalized.$isolation-isolation",
            "modeled.p.pw.$stage", "modeled.p.pa.$stage", "modeled.pd.pw.$stage", "modeled.pd.pa.$stage")
        if($Profile -ceq 'legacy-v1') { $required=@($baseCases) }
        $expectedCount=if($Profile -ceq 'legacy-v1'){10}else{16}
        $ids = @($definitions | ForEach-Object { [string]$_.id })
        $results = @($trx.TestRun.Results.UnitTestResult | Where-Object { [string]$_.testId -cin $ids })
        $names = @($results | ForEach-Object { [string]$_.testName })
        $wrongNames = @(Compare-Object ($required | Sort-Object) ($names | Sort-Object) -CaseSensitive)
        $nonPassing = @($trx.TestRun.Results.UnitTestResult | Where-Object { $_.outcome -cne 'Passed' })
        if ($definitions.Count -ne $expectedCount -or $results.Count -ne $expectedCount -or $wrongNames.Count -ne 0 -or $nonPassing.Count -ne 0) {
            throw "Incomplete $stage behavior evidence: expected all $expectedCount shared cases exactly once and every selected test passed; observed $($names -join ', ')."
        }
        $summary += [pscustomobject]@{ stage = $stage; cases = $names; passed = $results.Count; result = (Join-Path $directory 'behavior.trx') }
    }
    $summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ResultsDirectory 'conformance-stages.json')
}
finally { $env:WSS_CONFORMANCE_STAGE = $previousStage }
