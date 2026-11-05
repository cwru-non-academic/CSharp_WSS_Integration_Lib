# Shared primitive evidence checks; adapters supply schema-specific required fields.
function New-WssCiEvidenceIdentity([string]$Repository,[string]$RunId,[string]$Attempt,[string]$SourceSha,[string]$Architecture) {
    $architectureKey=$Architecture.ToLowerInvariant()
    if($architectureKey -ceq 'x86_64'){$architectureKey='x64'}
    if($Repository -cnotmatch '^cwru-non-academic/[A-Za-z0-9_]+$' -or $RunId -cnotmatch '^[1-9][0-9]*$' -or
        $Attempt -cnotmatch '^[1-9][0-9]*$' -or $SourceSha -cnotmatch '^[a-f0-9]{40}$' -or $architectureKey -cnotin @('x64','arm64')) {
        throw 'Complete canonical CI evidence identity is required.'
    }
    [ordered]@{schema='wss-ci-evidence-identity/v1';repository=$Repository;run_id=$RunId;attempt=$Attempt;source_sha=$SourceSha;architecture=$architectureKey}
}
function Assert-WssCiEvidenceIdentity($Identity,[string]$Repository,[string]$RunId,[string]$Attempt,[string]$SourceSha,[string]$Architecture) {
    if(!$Identity){throw 'Missing versioned CI evidence identity.'}
    $expected=New-WssCiEvidenceIdentity $Repository $RunId $Attempt $SourceSha $Architecture
    $keys=if($Identity -is [System.Collections.IDictionary]){@($Identity.Keys)}else{@($Identity.PSObject.Properties.Name)}
    if(@(Compare-Object @($expected.Keys) $keys -CaseSensitive).Count){throw 'Unexpected CI evidence identity fields.'}
    Assert-WssCiEvidenceFields $Identity $expected
}
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
