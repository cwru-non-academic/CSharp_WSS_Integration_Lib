param(
    [Parameter(Mandatory)][string] $OutputRoot,
    [Parameter(Mandatory)][string] $WorkRoot,
    [Parameter(Mandatory)][ValidateSet('x64','ARM64')][string] $TestPlatform
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $false
if (-not $IsMacOS) { throw 'The native macOS fixture must execute on macOS.' }
if (Test-Path -LiteralPath $WorkRoot) { throw 'Fixture WorkRoot must be new.' }
$output = (Resolve-Path -LiteralPath $OutputRoot).Path
$nativeRelative = 'backends/macos/libwss_macos_ble.dylib'
if (-not (Test-Path -LiteralPath (Join-Path $output $nativeRelative) -PathType Leaf)) {
    throw 'Selected package must include the native macOS dylib before mutation.'
}
$originalHash = (Get-FileHash -LiteralPath (Join-Path $output $nativeRelative)).Hash
New-Item -ItemType Directory -Path $WorkRoot | Out-Null
$copy = Join-Path $WorkRoot 'output'
Copy-Item -LiteralPath $output -Destination $copy -Recurse
# Only the new isolated copy is mutated. No rebuild or restore may repair it.
Remove-Item -LiteralPath (Join-Path $copy $nativeRelative)
$results = Join-Path $WorkRoot 'results'
$filter = 'FullyQualifiedName=Wss.CSharpImplementation.Tests.BleBackendLoadingTests.FacadeLoadsCurrentPlatformBackendAndDependencies'
& dotnet vstest (Join-Path $copy 'Wss.CSharpImplementation.Tests.dll') "/TestCaseFilter:$filter" "/Platform:$TestPlatform" '/Logger:trx;LogFileName=missing-native.trx' "/ResultsDirectory:$results" 2>&1 | Tee-Object -FilePath (Join-Path $WorkRoot 'missing-native-rejection.log')
$status = $LASTEXITCODE
. "$PSScriptRoot/MissingNativeEvidence.ps1"
Assert-WssMissingNativeEvidence (Join-Path $results 'missing-native.trx') $status
if ((Get-FileHash -LiteralPath (Join-Path $output $nativeRelative)).Hash -cne $originalHash) {
    throw 'Canonical output changed during the isolated negative fixture.'
}
@{
    schema='wss-macos-ble-fixture/v2'; test_data_only=$true
    integration_source=$env:GITHUB_SHA; source_output=$output
    missing_declared_native_rejected=$true; physical_ble='not executed'
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $WorkRoot 'fixture-evidence.json')
'PASS: isolated selected-package output rejects the missing native dylib.'
exit 0 # Consume the explicitly checked, expected native failure for Actions.
