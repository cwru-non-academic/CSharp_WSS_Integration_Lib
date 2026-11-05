$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/../MacOSBleEvidence.ps1"
$count=0
function Record([string]$Arch) {
    [pscustomobject]@{schema='wss-macos-ble-consumer/v1';ci=(New-WssCiEvidenceIdentity $env:GITHUB_REPOSITORY '123' '1' ('a'*40) $Arch);architecture=$Arch;context='fixture';run_id='123';attempt='1';source_sha=('a'*40);integration_sha=('b'*40);passed=$true;job_result='success';coverage='packaged-native-abi-load';test_outcome='Passed';cli_legacy_asserted=$false;hardware_ble='not-executed';synthetic_fixture=$false;reason='metadata-only regression fixture';host=@{architecture=$Arch;runner_arch=$Arch;process_arch=$Arch;os_arch=$Arch;dotnet_host_arch=$Arch;rosetta=$false}}
}
function Reject([scriptblock]$Action,[string]$Expected) {
    $failed=$false
    try { & $Action } catch { if ($_.Exception.Message -cnotlike $Expected) { throw }; $failed=$true }
    if (!$failed) { throw 'Expected incomplete/forged macOS evidence to fail.' }
    $script:count++
}
$valid=@((Record x64),(Record arm64))
Assert-WssMacOSGate $valid 'fixture' 'success' '123' '1' ('a'*40)
foreach ($arch in @('x64','arm64')) {
    $records=@((Record x64),(Record arm64))
    ($records | Where-Object architecture -CEQ $arch).passed=$false
    Reject { Assert-WssMacOSGate $records 'fixture' 'success' '123' '1' ('a'*40) } "*$arch*"
}
Reject { Assert-WssMacOSGate @($valid[0]) 'fixture' 'success' '123' '1' ('a'*40) } '*arm64*'
Reject { Assert-WssMacOSGate @($valid[0],$valid[0]) 'fixture' 'success' '123' '1' ('a'*40) } '*x64*'
foreach ($mutate in @(
    {param($r)$r.context='another-workflow'}, {param($r)$r.run_id='124'}, {param($r)$r.attempt='2'},
    {param($r)$r.source_sha='b'*40}, {param($r)$r.ci.attempt='2'}, {param($r)$r.host.process_arch='x64'}, {param($r)$r.host.dotnet_host_arch='x64'},
    {param($r)$r.host.rosetta=$true}, {param($r)$r.synthetic_fixture=$true}, {param($r)$r.hardware_ble='executed'},
    {param($r)$r.coverage='synthetic-fixture'}, {param($r)$r.test_outcome='NotExecuted'}, {param($r)$r.job_result='cancelled'}
)) {
    $records=@((Record x64),(Record arm64)); & $mutate $records[1]
    Reject { Assert-WssMacOSGate $records 'fixture' 'success' '123' '1' ('a'*40) } '*arm64*'
}
foreach ($result in @('failure','cancelled','skipped')) {
    Reject { Assert-WssMacOSGate $valid 'fixture' $result '123' '1' ('a'*40) } '*worker group result*'
}
$legacy=@((Record x64),(Record arm64))
foreach ($record in $legacy) { $record.coverage='legacy-unsupported-asserted' }
Assert-WssMacOSGate $legacy 'fixture' 'success' '123' '1' ('a'*40)
$legacy[0].test_outcome='NotExecuted'
Reject { Assert-WssMacOSGate $legacy 'fixture' 'success' '123' '1' ('a'*40) } '*x64*'
$legacy[0].cli_legacy_asserted=$true
Assert-WssMacOSGate $legacy 'fixture' 'success' '123' '1' ('a'*40)
$differentSources=@((Record x64),(Record arm64)); $differentSources[1].integration_sha='c'*40
Reject { Assert-WssMacOSGate $differentSources 'fixture' 'success' '123' '1' ('a'*40) } '*same Integration revision*'

# The public gate keeps the existing required check names while its two native
# architecture jobs remain implementation details with clearly labelled evidence.
$workflowRoot=Join-Path $PSScriptRoot '../../workflows'
$normal=if (Test-Path (Join-Path $workflowRoot 'cli-ci.yml')) { 'cli-ci.yml' } else { 'wss-compatibility.yml' }
foreach ($file in @($normal,'wss-preflight.yml')) {
    $workflow=Get-Content (Join-Path $workflowRoot $file) -Raw
    if (!$workflow.Contains('os: macos-15-intel') -or !$workflow.Contains('os: macos-15') -or
        !$workflow.Contains('cpu: Intel x86_64') -or !$workflow.Contains('cpu: Apple Silicon arm64') -or
        !$workflow.Contains('needs: macos_architecture') -or !$workflow.Contains('Complete-WssMacOSGate ') -or
        !$workflow.Contains('RunConfiguration.TargetPlatform=') -or !$workflow.Contains('name: wss-macos-') -or
        !$workflow.Contains('name: Record canonical packaged BLE result before any synthetic fixture')) { throw 'Both native architectures, fixed test-host target and fail-closed aggregate are required.' }
    $gate=[regex]::Match($workflow,'(?ms)^  macos_compatibility:\r?\n(?<body>.*)\z')
    if (!$gate.Success -or !$gate.Groups['body'].Value.Contains('    if: always()') -or
        !$gate.Groups['body'].Value.Contains('continue-on-error: true')) { throw 'Aggregate must report failed/skipped workers and missing artifacts.' }
    $worker=[regex]::Match($workflow,'(?ms)^  macos_architecture:\r?\n(?<body>.*?)(?=^  macos_compatibility:)').Groups['body'].Value
    $recordAt=$worker.IndexOf('name: Record canonical packaged BLE result before any synthetic fixture')
    $fixtureAt=$worker.IndexOf('name: Verify declared macOS native fixture and fail-closed missing payload')
    if ($recordAt -lt 0 -or ($fixtureAt -ge 0 -and $fixtureAt -le $recordAt)) { throw 'Synthetic fixture cannot replace canonical packaged evidence.' }
    if ([regex]::Matches($worker,'(?m)^            arch:').Count -ne 2) { throw 'Exactly two native architecture workers are required.' }
    $expectedGate=if ($normal -ceq 'cli-ci.yml') { 'CLI platform compatibility (macOS)' } elseif ($file -ceq 'wss-preflight.yml') { 'Preflight compatibility (macOS)' } else { 'Integration compatibility (macOS)' }
    if ([regex]::Matches($workflow,('(?m)^    name: '+[regex]::Escape($expectedGate)+'\r?$')).Count -ne 1) { throw 'The existing logical required check name must remain unique and unchanged.' }
}
"PASS: macOS aggregate metadata contracts ($count rejections). No macOS runtime, emulation, engine or physical BLE execution occurs in these metadata fixtures."
