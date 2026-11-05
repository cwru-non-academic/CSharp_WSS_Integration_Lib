. "$PSScriptRoot/wss-ci/Evidence.ps1"
Set-StrictMode -Version Latest
function Initialize-WssMacOSEvidence([string]$Architecture,[string]$Context,[string]$Directory) {
    if ($Architecture -cnotin @('arm64','x64') -or !$IsMacOS) { throw 'Native macOS Intel/Apple Silicon execution required.' }
    if (Test-Path -LiteralPath $Directory) { throw 'macOS evidence directory must be new.' }
    $null=New-Item -ItemType Directory -Path $Directory
    $process=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
    $os=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    $runner=$env:RUNNER_ARCH.ToLowerInvariant()
    $info=(& dotnet --info) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'Cannot identify the selected dotnet host.' }
    $hostMatches=[regex]::Matches($info,'(?m)^\s*Architecture:\s*(?<arch>arm64|x64)\s*\r?$')
    if ($hostMatches.Count -ne 1) { throw 'Cannot establish unique dotnet host architecture.' }
    $hostArch=$hostMatches[0].Groups['arch'].Value
    $nativeErrorPreference=$PSNativeCommandUseErrorActionPreference
    try { $PSNativeCommandUseErrorActionPreference=$false; $translated=& sysctl -in sysctl.proc_translated 2>$null; $translationStatus=$LASTEXITCODE }
    finally { $PSNativeCommandUseErrorActionPreference=$nativeErrorPreference }
    $rosetta=$translationStatus -eq 0 -and [string]$translated -ceq '1'
    if ($translationStatus -notin @(0,1)) { throw 'Cannot establish native/Rosetta execution state.' }
    $hostRecord=[ordered]@{schema='wss-macos-host/v1';architecture=$Architecture;context=$Context;runner_arch=$runner;process_arch=$process;os_arch=$os;dotnet_host_arch=$hostArch;rosetta=$rosetta}
    $hostRecord | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Directory 'host.json') -Encoding utf8
    if ($process -cne $Architecture -or $os -cne $Architecture -or $runner -cne $Architecture -or $hostArch -cne $Architecture -or $rosetta) { throw "Expected native $Architecture; runner/process/OS/dotnet architecture or Rosetta disagrees." }
    $global:LASTEXITCODE=0 # sysctl.proc_translated is normally absent on Intel.
}
function Write-WssMacOSEvidence([string]$Architecture,[string]$Context,[string]$Directory,[string]$Trx,[string]$ConsoleLog,[string]$PayloadRoot,[string]$CliLog='',[string]$IntegrationSha=$env:GITHUB_SHA) {
    $record=[ordered]@{schema='wss-macos-ble-consumer/v1';architecture=$Architecture;context=$Context;run_id=$env:GITHUB_RUN_ID;attempt=$env:GITHUB_RUN_ATTEMPT;source_sha=$env:GITHUB_SHA;passed=$false;coverage='not-executed';test_outcome='missing';cli_legacy_asserted=$false;hardware_ble='not-executed';synthetic_fixture=$false;reason='Canonical BLE result missing.';host=$null;job_result='pending'}
    try {
        if ($IntegrationSha -cnotmatch '^[0-9a-f]{40}$') { throw 'Exact tested Integration revision is missing.' }
        $record['integration_sha']=$IntegrationSha
        $record.host=Get-Content -LiteralPath (Join-Path $Directory 'host.json') -Raw | ConvertFrom-Json
        if ($record.host.architecture -cne $Architecture -or $record.host.context -cne $Context -or $record.host.rosetta -or
            $record.host.runner_arch -cne $Architecture -or $record.host.process_arch -cne $Architecture -or $record.host.os_arch -cne $Architecture -or $record.host.dotnet_host_arch -cne $Architecture) { throw 'Native architecture attestation is invalid.' }
        [xml]$results=Get-Content -LiteralPath $Trx -Raw
        $ble=@($results.SelectNodes("//*[local-name()='UnitTestResult']") | Where-Object { $_.GetAttribute('testName') -cmatch '(^|\.)FacadeLoadsCurrentPlatformBackendAndDependencies$' })
        if ($ble.Count -ne 1) { throw 'Require the unique canonical BLE backend-loading test result.' }
        $record.test_outcome=$ble[0].GetAttribute('outcome')
        $output=$results.InnerText
        if (Test-Path -LiteralPath $ConsoleLog) { $output+=[IO.File]::ReadAllText($ConsoleLog) }
        $macRoot=Join-Path $PayloadRoot 'backends/macos'
        $macFiles=@(if (Test-Path -LiteralPath $macRoot) { Get-ChildItem -LiteralPath $macRoot -File -Recurse })
        $nativeFiles=@('WSS.Transport.BLE.MacOS.dll','libwss_macos_ble.dylib')
        $inventory=@($macFiles | ForEach-Object { [IO.Path]::GetRelativePath($macRoot,$_.FullName) })
        if ($record.test_outcome -ceq 'Passed' -and $output.Contains('macOS BLE declared backend/native ABI/load/activation: PASS.') -and
            $inventory.Count -eq 2 -and !(Compare-Object $nativeFiles $inventory -CaseSensitive)) {
            $record.coverage='packaged-native-abi-load'; $record.reason='Canonical packaged managed/native ABI/load/activation passed; no Bluetooth operations.'
        } elseif ($record.test_outcome -ceq 'Passed' -and !$macFiles.Count -and $output.Contains('Legacy payload: macOS BLE explicitly unsupported (asserted)')) {
            $record.coverage='legacy-unsupported-asserted'; $record.reason='Legacy facade explicitly rejected macOS BLE; native BLE support was not executed.'
        } elseif ($CliLog -and (Test-Path -LiteralPath $CliLog) -and !$macFiles.Count -and
            [IO.File]::ReadAllText($CliLog).Contains('PASS: legacy macOS BLE explicitly unsupported; native BLE operation NOT EXECUTED.')) {
            $record.coverage='legacy-unsupported-asserted'; $record.reason='Actual CLI smoke explicitly rejected unsupported BLE; the pinned Integration test did not prove native support.'
            $record.cli_legacy_asserted=$true
        } else { throw 'BLE was skipped, failed, lacked canonical evidence, or did not match its declared payload. Synthetic fixtures cannot substitute.' }
        $record.passed=$true
    } catch { $record.reason=$_.Exception.Message }
    $null=New-Item -ItemType Directory -Path $Directory -Force
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Directory 'evidence.json') -Encoding utf8
    if (!$record.passed) { throw "$Architecture canonical macOS BLE evidence failed: $($record.reason)" }
}
function Finalize-WssMacOSEvidence([string]$Architecture,[string]$Context,[string]$Directory,[string]$JobResult) {
    $path=Join-Path $Directory 'evidence.json'
    if (!(Test-Path -LiteralPath $path)) {
        $null=New-Item -ItemType Directory -Path $Directory -Force
        @{schema='wss-macos-ble-consumer/v1';architecture=$Architecture;context=$Context;run_id=$env:GITHUB_RUN_ID;attempt=$env:GITHUB_RUN_ATTEMPT;source_sha=$env:GITHUB_SHA;passed=$false;coverage='not-executed';test_outcome='missing';cli_legacy_asserted=$false;hardware_ble='not-executed';synthetic_fixture=$false;reason='Canonical worker did not produce evidence.';host=$null;job_result=$JobResult} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding utf8
    }
    $record=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $record.job_result=$JobResult
    if ($JobResult -cne 'success') { $record.passed=$false; $record.reason="Worker $JobResult. $($record.reason)" }
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding utf8
    "### macOS BLE - $Architecture" >> $env:GITHUB_STEP_SUMMARY
    "- Coverage: $($record.coverage); result: $($record.passed); $($record.reason)" >> $env:GITHUB_STEP_SUMMARY
    '- Physical Bluetooth authorization, adapter, peripheral I/O and writes: NOT EXECUTED.' >> $env:GITHUB_STEP_SUMMARY
    if (!$record.passed) { throw "macOS $Architecture worker did not pass canonical BLE verification." }
}
function Assert-WssMacOSGate($Records,[string]$Context,[string]$WorkerResult,[string]$RunId,[string]$Attempt,[string]$SourceSha) {
    $problems=[Collections.Generic.List[string]]::new()
    Assert-WssCiArchitecturePair $Records @('x64','arm64')
    foreach ($arch in @('x64','arm64')) {
        $matching=@($Records | Where-Object architecture -CEQ $arch)
        if ($matching.Count -ne 1) { $problems.Add("$arch : missing or duplicate architecture evidence"); continue }
        $r=$matching[0]
        try { Assert-WssCiEvidenceFields $r @{schema='wss-macos-ble-consumer/v1';context=$Context;run_id=$RunId;attempt=$Attempt;source_sha=$SourceSha} }
        catch { throw "$arch : $($_.Exception.Message)" }
        if (
            !$r.passed -or $r.job_result -cne 'success' -or $r.hardware_ble -cne 'not-executed' -or $r.synthetic_fixture -or
            $r.coverage -cnotin @('packaged-native-abi-load','legacy-unsupported-asserted') -or !$r.host -or $r.host.rosetta -or
            $r.integration_sha -cnotmatch '^[0-9a-f]{40}$' -or
            ($r.coverage -ceq 'packaged-native-abi-load' -and $r.test_outcome -cne 'Passed') -or
            ($r.coverage -ceq 'legacy-unsupported-asserted' -and $r.test_outcome -cne 'Passed' -and !$r.cli_legacy_asserted) -or
            $r.host.architecture -cne $arch -or $r.host.runner_arch -cne $arch -or $r.host.process_arch -cne $arch -or $r.host.os_arch -cne $arch -or $r.host.dotnet_host_arch -cne $arch) { $problems.Add("$arch : $($r.reason)") }
    }

    $testedSources=@($Records | Where-Object passed | ForEach-Object integration_sha | Select-Object -Unique)
    if ($testedSources.Count -ne 1) { $problems.Add('Architectures did not verify the same Integration revision.') }
    if ($WorkerResult -cne 'success') { $problems.Add("Architecture worker group result: $WorkerResult") }
    if ($problems.Count) { throw ($problems -join '; ') }
}
function Complete-WssMacOSGate([string]$Directory,[string]$Context,[string]$WorkerResult) {
    $records=@(if (Test-Path -LiteralPath $Directory) { Get-ChildItem -LiteralPath $Directory -Filter evidence.json -File -Recurse | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } })
    "## macOS BLE consumer - Intel and Apple Silicon (worker group: $WorkerResult)" >> $env:GITHUB_STEP_SUMMARY
    '| Architecture | Result | Coverage | Detail |' >> $env:GITHUB_STEP_SUMMARY
    '|---|---|---|---|' >> $env:GITHUB_STEP_SUMMARY
    foreach ($arch in @('x64','arm64')) {
        $matching=@($records | Where-Object architecture -CEQ $arch)
        if ($matching.Count -eq 1) { $r=$matching[0]; "| $arch | $($r.passed) | $($r.coverage) | $($r.reason.Replace('|','/')) |" >> $env:GITHUB_STEP_SUMMARY }
        else { "| $arch | FAILED | not-executed | Missing/duplicate evidence |" >> $env:GITHUB_STEP_SUMMARY }
    }
    'Native packaged ABI/load checks and explicitly verified legacy rejection are reported separately. Synthetic fixture evidence is separate; physical BLE I/O was NOT EXECUTED.' >> $env:GITHUB_STEP_SUMMARY
    Assert-WssMacOSGate $records $Context $WorkerResult $env:GITHUB_RUN_ID $env:GITHUB_RUN_ATTEMPT $env:GITHUB_SHA
}
