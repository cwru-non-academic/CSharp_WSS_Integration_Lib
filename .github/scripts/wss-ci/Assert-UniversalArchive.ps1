# Extracted from Core read-universal-hashes.ps1; inventory stays receiver-owned.
function Get-WssUniversalArchiveHashes {
    param(
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedSha256,
        [Parameter(Mandatory)][string[]]$ExpectedFiles,
        [switch]$AllowDirectoryEntries
    )
    $ErrorActionPreference = 'Stop'
    if ((Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedSha256) { throw 'Candidate ZIP checksum mismatch.' }
$expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$directories = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($relative in $ExpectedFiles) {
    if ($relative -cnotmatch '^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$' -or @($relative.Split('/') | Where-Object { $_ -cin @('.', '..') }).Count) { throw 'Invalid reviewed archive path.' }
    if (!$expected.Add("WSS-Universal/$relative")) { throw 'Duplicate reviewed archive path.' }
    $parts = "WSS-Universal/$relative".Split('/')
    for ($index=1; $index -lt $parts.Count; $index++) { $null=$directories.Add(($parts[0..($index-1)] -join '/')+'/') }
}
$zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Archive).Path)
try {
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $files = [ordered]@{}
    [long]$total=0
    foreach ($entry in $zip.Entries) {
        if (!$seen.Add($entry.FullName)) { throw 'Duplicate/case-colliding ZIP entry.' }
        if ($entry.FullName.EndsWith('/')) {
            if (!$AllowDirectoryEntries) { throw 'Unexpected ZIP directory.' }
            if (!$directories.Contains($entry.FullName) -or $entry.Length -ne 0) { throw 'Unexpected ZIP directory.' }
            continue
        }
        if (!$expected.Contains($entry.FullName) -or $entry.Length -le 0 -or $entry.Length -gt 67108864) { throw 'Unexpected/missing/oversized universal file.' }
        $unixType = (($entry.ExternalAttributes -shr 16) -band 0xf000)
        if ($unixType -ne 0 -and $unixType -ne 0x8000) { throw 'ZIP payload must be regular files.' }
        $stream = $entry.Open()
        $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
        try {
            $buffer = [byte[]]::new(81920)
            [long]$length=0
            while (($count=$stream.Read($buffer,0,$buffer.Length)) -gt 0) {
                $length += $count; $total += $count
                if ($length -gt $entry.Length -or $total -gt 268435456) { throw 'Universal archive exceeds declared size/budget.' }
                $hash.AppendData($buffer,0,$count)
            }
            if ($length -ne $entry.Length) { throw 'Truncated universal file.' }
            $files[$entry.FullName.Substring('WSS-Universal/'.Length)] = [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()
        } finally { $hash.Dispose(); $stream.Dispose() }
    }
    if ($files.Count -ne $expected.Count) { throw 'Universal archive inventory is incomplete.' }
    @{sha256=$ExpectedSha256; files=$files}
} finally { $zip.Dispose() }

}
