# Shared primitive evidence checks; adapters supply schema-specific required fields.
function Assert-WssCiEvidenceFields($Record,[System.Collections.IDictionary]$Expected) {
    foreach($key in $Expected.Keys) {
        $property=$Record.PSObject.Properties[[string]$key]
        if($Record -is [System.Collections.IDictionary]) {
            if(!$Record.Contains($key)){throw "Missing evidence field: $key"}
            $value=$Record[$key]
        } else {
            if(!$property){throw "Missing evidence field: $key"}
            $value=$property.Value
        }
        if((ConvertTo-Json -InputObject $value -Compress -Depth 8) -cne (ConvertTo-Json -InputObject $Expected[$key] -Compress -Depth 8)) {throw "Evidence identity/value mismatch: $key"}
    }
}
function Assert-WssCiEvidenceFiles([string]$Root,[System.Collections.IDictionary]$Hashes) {
    foreach($name in $Hashes.Keys) {
        if($name -cnotmatch '^[A-Za-z0-9_.-]+$' -or $Hashes[$name] -cnotmatch '^[a-f0-9]{64}$'){throw 'Invalid evidence file/hash descriptor.'}
        $path=Join-Path $Root $name
        if(!(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Hashes[$name]) {throw "Evidence content hash mismatch: $name"}
    }
}
function Assert-WssCiArchitecturePair($Records,[string[]]$Architectures) {
    foreach($architecture in $Architectures) {
        if(@($Records|Where-Object architecture -CEQ $architecture).Count -ne 1){throw "Missing/duplicate architecture evidence: $architecture"}
    }
    if(@($Records).Count -ne $Architectures.Count){throw 'Missing/extra architecture evidence.'}
}
