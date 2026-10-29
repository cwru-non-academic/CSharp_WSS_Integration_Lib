param([string] $ArtifactRoot = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/../WssAutomatic.ps1"
. "$PSScriptRoot/../Universal-WssFiles.ps1"
$count = 0
function Reject([scriptblock] $Action, [string] $Message) {
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -notlike $Message) { throw }
        $script:count++; return
    }
    throw "Expected rejection: $Message"
}
$legacy = @($WssUniversalFiles)
$modern = @($legacy) + @($WssMacOSFiles)
foreach ($expected in @(@{files=$legacy},@{files=$modern})) {
    $selected = @(Get-WssUniversalFiles $expected.files)
    if (@(Compare-Object $selected $expected.files -CaseSensitive).Count -ne 0) { throw 'Inventory selection changed paths.' }
    $count++
}
foreach ($missing in $WssMacOSFiles) {
    Reject { Get-WssUniversalFiles @($modern | Where-Object { $_ -cne $missing }) } '*exact legacy or macOS*'
}
Reject { Get-WssUniversalFiles @() } '*exact legacy or macOS*'
Reject { Get-WssUniversalFiles ($modern + @('extra.dll')) } '*exact legacy or macOS*'
Reject { Get-WssUniversalFiles ($legacy + @('backends/macos/other.dylib')) } '*exact legacy or macOS*'
Reject { Get-WssUniversalFiles ($modern + @($modern[0])) } 'Duplicate/case-colliding*'
Reject { Get-WssUniversalFiles ($modern + @($modern[0].ToLowerInvariant())) } 'Duplicate/case-colliding*'
Reject { Get-WssUniversalFiles (@($modern | Select-Object -Skip 1) + @('../WSS_Core_Interface.dll')) } '*exact legacy or macOS*'
Reject { Get-WssUniversalFiles (@($modern | Select-Object -Skip 1) + @('wss_core_interface.dll')) } '*exact legacy or macOS*'
$jobs = @('Build macOS universal BLE bridge','BLE consumer (macOS arm64)','BLE consumer (macOS x86_64)') | ForEach-Object {
    [pscustomobject]@{name=$_;conclusion='success'}
}
Assert-WssMacOSProducerJobs $jobs
$count++
foreach ($missing in $jobs.name) {
    Reject { Assert-WssMacOSProducerJobs @($jobs | Where-Object name -CNE $missing) } 'Required macOS producer job*'
}
$badJobs = $jobs | ConvertTo-Json | ConvertFrom-Json
$badJobs[1].conclusion = 'skipped'
Reject { Assert-WssMacOSProducerJobs $badJobs } 'Required macOS producer job*'
Reject { Assert-WssMacOSProducerJobs ($jobs + @($jobs[0])) } 'Required macOS producer job*'

if ($ArtifactRoot) {
    $files = @(Read-WssUniversalFiles $ArtifactRoot)
    Assert-WssMacOSPayload $ArtifactRoot $files
    $count++
    if ($WssMacOSFiles[0] -cin $files) {
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $temp = [IO.Path]::GetFullPath((Join-Path $tempBase ('wss-inventory-' + [guid]::NewGuid())))
        if (-not $temp.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe temporary path.' }
        New-Item -ItemType Directory -Path $temp | Out-Null
        try {
            # Test-only metadata copied from the existing safety-test fixture, not
            # authorization for a real producer/dispatch. Temp output is destroyed.
            $approval = Read-WssApproval "$PSScriptRoot/../../universal-bootstrap.json"
            $approvalPath = Join-Path $temp 'approval.json'
            Write-WssApproval $approval $approvalPath
            $staged = Join-Path $temp 'staged'
            & "$PSScriptRoot/../New-WssLib.ps1" -ArtifactRoot $ArtifactRoot -ApprovalFile $approvalPath -Destination $staged
            if (-not (Test-WssPayloadEqual $staged $ArtifactRoot)) { throw 'Exact macOS payload was not a no-op.' }
            $native = Join-Path $staged $WssMacOSFiles[1]
            $bytes = [IO.File]::ReadAllBytes($native)
            $bytes[-1] = $bytes[-1] -bxor 1
            [IO.File]::WriteAllBytes($native,$bytes)
            Reject { Assert-WssLib $staged $ArtifactRoot $approval } 'Committed universal bytes differ: backends/macos/libwss_macos_ble.dylib'
            if (Test-WssPayloadEqual $staged $ArtifactRoot) { throw 'Native byte tampering was accepted as no-op.' }
            Copy-Item -LiteralPath (Join-Path $ArtifactRoot $WssMacOSFiles[1]) -Destination $native -Force
            $bytes = [IO.File]::ReadAllBytes($native)
            $bytes[8] = 0; $bytes[9] = 0; $bytes[10] = 0; $bytes[11] = 7
            [IO.File]::WriteAllBytes($native,$bytes)
            Reject { Assert-WssMacOSPayload $staged $files } 'Invalid macOS universal architecture*'
            Copy-Item -LiteralPath (Join-Path $ArtifactRoot $WssMacOSFiles[1]) -Destination $native -Force
            Copy-Item -LiteralPath (Join-Path $ArtifactRoot 'WSS_Core_Interface.dll') -Destination (Join-Path $staged $WssMacOSFiles[0]) -Force
            Reject { Assert-WssMacOSPayload $staged $files } 'macOS managed adapter identity/version mismatch*'
            $count++
        } finally {
            if (-not ([IO.Path]::GetFullPath($temp)).StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path.' }
            Remove-Item -LiteralPath $temp -Recurse -Force
        }
    }
}
"PASS: $count dual-inventory/macOS receiver contract checks (ArtifactRoot supplied: $([bool]$ArtifactRoot)). No dispatch or real approval created."
