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


# Exercise the real acquisition, equality and assertion functions with both
# supported directory layouts. Only managed identity metadata is inspected;
# no product assembly or native library is executed.
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$temp=Join-Path $tempBase ('wss-directory-inventory-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $temp
try {
    $approval=Read-WssApproval "$PSScriptRoot/../../universal-bootstrap.json"
    $approvalPath=Join-Path $temp 'approval.json'
    Write-WssApproval $approval $approvalPath
    foreach($variant in @(@{files=$legacy},@{files=$modern})) {
        $source=Join-Path $temp ('candidate long directory '+$variant.files.Count)
        foreach($relative in $variant.files){
            $file=Join-Path $source $relative
            $null=New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force
            if($relative -cin $WssMacOSFiles){
                Copy-Item -LiteralPath (Join-Path "$PSScriptRoot/../../../lib" $relative) -Destination $file
            } else {[IO.File]::WriteAllText($file,"fixture bytes: $relative")}
        }
        $sourceRoots=@($source)
        if($IsWindows){
            $short=(New-Object -ComObject Scripting.FileSystemObject).GetFolder($source).ShortPath
            if($short -cne $source){$sourceRoots+=@($short)}
            else {Write-Output 'SKIP Windows 8.3 candidate alias: short names unavailable on fixture volume.'}
        }
        foreach($candidate in $sourceRoots){
            $staged=Join-Path $temp ('installed long directory '+[guid]::NewGuid().ToString('N'))
            & "$PSScriptRoot/../New-WssLib.ps1" -ArtifactRoot $candidate -ApprovalFile $approvalPath -Destination $staged
            $libRoots=@($staged)
            if($IsWindows){$libRoots+=@((New-Object -ComObject Scripting.FileSystemObject).GetFolder($staged).ShortPath)}
            foreach($lib in $libRoots){
                Assert-WssLib $lib $candidate $approval
                if(-not (Test-WssPayloadEqual $lib $candidate)){throw 'Identical payload through alias was not a no-op.'}
                $count++
                $first=Join-Path $lib $variant.files[0]
                [IO.File]::WriteAllText($first,'tampered fixture bytes')
                Reject {Assert-WssLib $lib $candidate $approval} 'Committed universal bytes differ:*'
                if(Test-WssPayloadEqual $lib $candidate){throw 'Tampered bytes accepted through alias.'}
                Copy-Item -LiteralPath (Join-Path $candidate $variant.files[0]) -Destination $first -Force
                $provenance=Join-Path $lib 'wss-candidate.json'
                Remove-Item -LiteralPath $provenance
                Reject {Assert-WssLib $lib $candidate $approval} 'Committed lib provenance is missing.'
                if(Test-WssPayloadEqual $lib $candidate){throw 'Missing provenance accepted through alias.'}
                Write-WssApproval $approval $provenance
                if($IsWindows){
                    $attributes=[IO.File]::GetAttributes($provenance)
                    try {
                        [IO.File]::SetAttributes($provenance,$attributes -bor [IO.FileAttributes]::Hidden)
                        Reject {Assert-WssLib $lib $candidate $approval} 'Committed lib provenance is missing.'
                        if(Test-WssPayloadEqual $lib $candidate){throw 'Hidden provenance changed the existing enumeration contract.'}
                    } finally {[IO.File]::SetAttributes($provenance,$attributes)}
                }
                $wrong=$approval|ConvertTo-Json -Depth 5|ConvertFrom-Json
                $wrong.cli.preflight_run_id='1'
                Write-WssApproval $wrong $provenance
                Reject {Assert-WssLib $lib $candidate $approval} 'Committed lib approval differs.'
                Write-WssApproval $approval $provenance
                [IO.File]::WriteAllText((Join-Path $lib 'extra.dll'),'extra')
                Reject {Assert-WssLib $lib $candidate $approval} '*exact legacy or macOS*'
                if(Test-WssPayloadEqual $lib $candidate){throw 'Extra file accepted through alias.'}
                Remove-Item -LiteralPath (Join-Path $lib 'extra.dll')
                Remove-Item -LiteralPath $provenance
                Write-WssApproval $approval (Join-Path $lib 'WSS-CANDIDATE.JSON')
                Reject {Assert-WssLib $lib $candidate $approval} '*'
                if(Test-WssPayloadEqual $lib $candidate){throw 'Wrong-case provenance accepted through alias.'}
                Remove-Item -LiteralPath (Join-Path $lib 'WSS-CANDIDATE.JSON')
                Write-WssApproval $approval $provenance
            }
        }
    }
} finally {
    $resolved=[IO.Path]::GetFullPath($temp)
    if(-not $resolved.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -cnotmatch '^wss-directory-inventory-[a-f0-9]{32}$'){throw 'Unsafe inventory fixture cleanup.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

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
