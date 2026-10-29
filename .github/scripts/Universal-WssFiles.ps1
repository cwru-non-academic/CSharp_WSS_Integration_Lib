# Final producer contract: tools/ArtifactBuild/manifests/universal.json.
$WssUniversalFiles = @(
    'WSS_Core_Interface.dll', 'WSS.Transport.Serial.dll', 'WSS.Transport.BLE.dll',
    'Newtonsoft.Json.dll', 'System.IO.Ports.dll', 'System.Memory.dll', 'System.Buffers.dll',
    'System.Numerics.Vectors.dll', 'System.Runtime.CompilerServices.Unsafe.dll',
    'System.Security.Permissions.dll', 'System.Security.AccessControl.dll', 'System.Security.Principal.Windows.dll',
    'backends/windows/WSS.Transport.BLE.Windows.dll',
    'backends/windows/WSS.Transport.BLE.Windows.Native.dll', 'backends/windows/WssBleWindows.dll',
    'backends/linux/WSS.Transport.BLE.Linux.dll', 'backends/linux/Linux.Bluetooth.dll', 'backends/linux/Tmds.DBus.dll',
    'backends/linux/Microsoft.Bcl.AsyncInterfaces.dll', 'backends/linux/System.Reflection.Emit.dll',
    'backends/linux/System.Reflection.Emit.ILGeneration.dll', 'backends/linux/System.Threading.Tasks.Extensions.dll',
    'runtimes/win/lib/net8.0/System.IO.Ports.dll', 'runtimes/unix/lib/net8.0/System.IO.Ports.dll',
    'runtimes/linux-x64/native/libSystem.IO.Ports.Native.so'
)

# The sole permitted extension. Keep the legacy list explicit for committed
# legacy inputs and the synthetic fixture; never infer arbitrary extra files.
$WssMacOSFiles = @('backends/macos/WSS.Transport.BLE.MacOS.dll', 'backends/macos/libwss_macos_ble.dylib')

function Get-WssUniversalFiles([string[]] $Paths) {
    if ($null -eq $Paths -or $Paths.Count -eq 0) { throw 'Payload does not match the exact legacy or macOS universal inventory.' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $Paths) {
        if ([string]::IsNullOrEmpty($path) -or -not $seen.Add($path)) { throw 'Duplicate/case-colliding universal path.' }
    }
    foreach ($expected in @(@{files=@($WssUniversalFiles)}, @{files=@($WssUniversalFiles) + @($WssMacOSFiles)})) {
        if ($Paths.Count -eq $expected.files.Count -and @(Compare-Object $expected.files $Paths -CaseSensitive).Count -eq 0) {
            return $expected.files
        }
    }
    throw 'Payload does not match the exact legacy or macOS universal inventory.'
}

function Assert-WssMacOSProducerJobs($Jobs) {
    foreach ($name in @('Build macOS universal BLE bridge','BLE consumer (macOS arm64)','BLE consumer (macOS x86_64)')) {
        $matching = @($Jobs | Where-Object { $_.name -ceq $name })
        if ($matching.Count -ne 1 -or $matching[0].conclusion -cne 'success') {
            throw "Required macOS producer job missing/skipped/failed: $name"
        }
    }
}

function Read-WssUniversalFiles([string] $Root, [switch] $AllowProvenance) {
    $resolved = (Resolve-Path -LiteralPath $Root).Path
    $paths = @(Get-ChildItem -LiteralPath $resolved -File -Recurse | ForEach-Object {
        $_.FullName.Substring($resolved.Length).TrimStart('\', '/').Replace('\', '/')
    })
    if ($AllowProvenance) { $paths = @($paths | Where-Object { $_ -cne 'wss-candidate.json' }) }
    Get-WssUniversalFiles $paths
}

function Get-WssBigUInt32([byte[]] $Bytes, [int] $Offset) {
    $value = [byte[]]@($Bytes[$Offset], $Bytes[$Offset+1], $Bytes[$Offset+2], $Bytes[$Offset+3])
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($value) }
    [BitConverter]::ToUInt32($value, 0)
}

function Assert-WssMacOSPayload([string] $Root, [string[]] $Files) {
    if ('backends/macos/WSS.Transport.BLE.MacOS.dll' -cnotin $Files) { return }
    $managed = Join-Path $Root 'backends/macos/WSS.Transport.BLE.MacOS.dll'
    $identity = [Reflection.AssemblyName]::GetAssemblyName($managed)
    if ($identity.Name -cne 'WSS.Transport.BLE.MacOS' -or $identity.Version.ToString() -cne '1.0.0.0') {
        throw 'macOS managed adapter identity/version mismatch.'
    }
    $bytes = [IO.File]::ReadAllBytes((Join-Path $Root 'backends/macos/libwss_macos_ble.dylib'))
    if ($bytes.Length -lt 48 -or (Get-WssBigUInt32 $bytes 0) -ne 0xcafebabeL -or (Get-WssBigUInt32 $bytes 4) -ne 2) {
        throw 'macOS native payload must be an exact x86_64/arm64 universal Mach-O dylib.'
    }
    $cpus = [Collections.Generic.HashSet[uint32]]::new()
    $ranges = @()
    foreach ($index in 0,1) {
        $entry = 8 + 20*$index
        $cpu = Get-WssBigUInt32 $bytes $entry
        $offset = Get-WssBigUInt32 $bytes ($entry+8)
        $size = Get-WssBigUInt32 $bytes ($entry+12)
        if ($cpu -notin @(0x01000007,0x0100000c) -or -not $cpus.Add($cpu) -or $offset -lt 48 -or $size -lt 32 -or
            ([long]$offset + $size) -gt $bytes.Length -or
            @($ranges | Where-Object { [long]$offset -lt ($_.offset + $_.size) -and $_.offset -lt ([long]$offset + $size) }).Count -ne 0) {
            throw 'Invalid macOS universal architecture or slice range.'
        }
        if (-not [BitConverter]::IsLittleEndian) { throw 'Mach-O validation requires a little-endian host.' }
        if ([BitConverter]::ToUInt32($bytes,[int]$offset) -ne 0xfeedfacfL -or
            [BitConverter]::ToUInt32($bytes,[int]$offset+4) -ne $cpu -or [BitConverter]::ToUInt32($bytes,[int]$offset+12) -ne 6) {
            throw 'macOS native slice must be a matching 64-bit Mach-O dylib.'
        }
        $ranges += @{offset=[long]$offset;size=[long]$size}
    }
    # Actual exports, ABI 0x10000, native load and managed activation are mandatory
    # in the macOS BleBackendLoadingTests preflight, before any promotion approval.
}
