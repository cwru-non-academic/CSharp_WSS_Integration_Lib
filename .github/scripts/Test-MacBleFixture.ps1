param(
    [Parameter(Mandatory)][string] $CoreSourceRoot,
    [Parameter(Mandatory)][string] $WorkRoot
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $false # Expected negative dotnet test below is checked explicitly.
if (-not $IsMacOS) { throw 'The native macOS fixture must execute on macOS.' }
$expectedCore = '0ac18df22a1371e5ff94d5485c6d3fa4b3e6538f'
$actualCore = & git -C $CoreSourceRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $actualCore -cne $expectedCore) { throw 'Unexpected Core source for the reviewed macOS fixture.' }
if (Test-Path -LiteralPath $WorkRoot) { throw 'Fixture WorkRoot must be new.' }
New-Item -ItemType Directory -Path $WorkRoot | Out-Null
$integrationRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Push-Location $CoreSourceRoot
try {
    & dotnet build WSS.Transport.BLE.MacOS/WSS.Transport.BLE.MacOS.csproj -c Release -p:RestoreLockedMode=true --nologo
    if ($LASTEXITCODE -ne 0) { throw 'Reviewed Core managed fixture build failed.' }
    & bash tools/MacBleBridge/build.sh
    if ($LASTEXITCODE -ne 0) { throw 'Reviewed Core universal native fixture build/ABI verification failed.' }
} finally { Pop-Location }

# This is synthetic fixture data, never a release candidate. Keep the committed
# dependency/provenance record intact and do not copy its approval onto new bytes.
. "$PSScriptRoot/Universal-WssFiles.ps1"
$payload = Join-Path $WorkRoot 'payload'
foreach ($relative in $WssUniversalFiles) {
    $destination = Join-Path $payload $relative
    New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $integrationRoot "lib/$relative") -Destination $destination
}
$replacementFiles = @{
    'WSS_Core_Interface.dll' = 'bin/Release/netstandard2.0/WSS_Core_Interface.dll'
    'WSS.Transport.Serial.dll' = 'WSS.Transport.Serial/bin/Release/netstandard2.0/WSS.Transport.Serial.dll'
    'WSS.Transport.BLE.dll' = 'WSS.Transport.BLE/bin/Release/netstandard2.0/WSS.Transport.BLE.dll'
    'backends/macos/WSS.Transport.BLE.MacOS.dll' = 'WSS.Transport.BLE.MacOS/bin/Release/netstandard2.0/WSS.Transport.BLE.MacOS.dll'
    'backends/macos/libwss_macos_ble.dylib' = 'tools/MacBleBridge/out/libwss_macos_ble.dylib'
}
foreach ($relative in $replacementFiles.Keys) {
    $destination = Join-Path $payload $relative
    New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $CoreSourceRoot $replacementFiles[$relative]) -Destination $destination -Force
}
$project = Join-Path $integrationRoot 'tests/Wss.CSharpImplementation.Tests/Wss.CSharpImplementation.Tests.csproj'
$properties = @("-p:WSS_ARTIFACT_DIR=$payload", "-p:WSS_BLE_ARTIFACT_DIR=$payload", '-p:TreatWarningsAsErrors=true')
$results = Join-Path $WorkRoot 'results'
Push-Location $integrationRoot
try {
    & dotnet test $project -c Release @properties --nologo --filter 'FullyQualifiedName~SerialRuntimeSelectionTests|FullyQualifiedName~BleBackendLoadingTests' --logger 'trx;LogFileName=macos-declared.trx' --results-directory $results
    if ($LASTEXITCODE -ne 0) { throw 'Declared macOS fixture did not pass actual native loading/ABI/activation.' }
    $output = Join-Path $integrationRoot 'tests/Wss.CSharpImplementation.Tests/bin/Release/net9.0'
    & "$PSScriptRoot/Verify-WssOutput.ps1" -ArtifactRoot $payload -OutputRoot $output
    $native = Join-Path $output 'backends/macos/libwss_macos_ble.dylib'
    $backup = Join-Path $WorkRoot 'libwss_macos_ble.dylib.saved'
    Move-Item -LiteralPath $native -Destination $backup
    try {
        $failure = & dotnet test $project -c Release @properties --no-build --no-restore --nologo --filter 'FullyQualifiedName~BleBackendLoadingTests' 2>&1
        $status = $LASTEXITCODE
        $failure | Set-Content -LiteralPath (Join-Path $WorkRoot 'missing-native-rejection.log')
        if ($status -eq 0 -or ($failure -join "`n") -notlike '*Declared macOS backend requires exactly*') {
            throw 'A declared macOS payload with a missing native dylib did not fail the compatibility fixture.'
        }
    } finally { Move-Item -LiteralPath $backup -Destination $native }
} finally { Pop-Location }
@{
    schema='wss-macos-ble-fixture/v1'; test_data_only=$true; core_source=$expectedCore
    integration_source=$env:GITHUB_SHA; declared_native_load_abi_activation='passed'
    missing_declared_native_rejected=$true; physical_ble='not executed'
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $WorkRoot 'fixture-evidence.json')
'PASS: reviewed-source macOS fixture; actual ABI/load/activation and missing-native rejection. No canonical candidate or hardware operation created.'
