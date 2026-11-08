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

# Receipt-only observed proof transport. Existing rich validators retain policy.
function Invoke-WssCiNativeProofRequest($Request,[string]$Root) {
    $requestPath=Join-Path $Root (([guid]::NewGuid().ToString('N'))+'.request.json')
    $responsePath=Join-Path $Root (([guid]::NewGuid().ToString('N'))+'.response.json')
    [IO.File]::WriteAllText($requestPath,(ConvertTo-Json -InputObject $Request -Depth 100 -Compress),[Text.UTF8Encoding]::new($false))
    try {
        & node (Join-Path $PSScriptRoot 'receipt-proof-cli.mjs') $requestPath $responsePath
        if($LASTEXITCODE -ne 0){throw 'Authenticated native proof transport failed.'}
        Get-Content -LiteralPath $responsePath -Raw | ConvertFrom-Json -Depth 100
    } finally {
        Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue
        if(Test-Path -LiteralPath $responsePath){Remove-Item -LiteralPath $responsePath -Force}
    }
}
function Start-WssCiPreflightProof([string]$Repository,[string]$RunId,[string]$SourceSha,[string]$Root,[int]$ExpectedAttempt) {
    if($ExpectedAttempt -lt 1 -or (Test-Path -LiteralPath $Root)){throw 'Observed attempt and new proof root required.'}
    $null=New-Item -ItemType Directory -Path $Root
    $state=Invoke-WssCiNativeProofRequest @{operation='start';identity=@{repository=$Repository;run_id=$RunId;source_sha=$SourceSha;attempt=$ExpectedAttempt}} $Root
    [pscustomobject]@{Root=$Root;State=$state;Run=$state.run;Jobs=@($state.jobs)}
}
function Read-WssCiPreflightArtifact($Proof,[string]$Name,[string]$Destination) {
    $Proof.State=Invoke-WssCiNativeProofRequest @{operation='artifact';state=$Proof.State;name=$Name;destination=$Destination} $Proof.Root
}
function Read-WssCiPreflightLog($Proof,[string]$JobId) {
    $path=Join-Path $Proof.Root (([guid]::NewGuid().ToString('N'))+'.job.log')
    try {
        $Proof.State=Invoke-WssCiNativeProofRequest @{operation='log';state=$Proof.State;job_id=$JobId;destination=$path} $Proof.Root
        [IO.File]::ReadAllText($path,[Text.UTF8Encoding]::new($false,$true))
    } finally {if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force}}
}
function Complete-WssCiPreflightProof($Proof) {
    Invoke-WssCiNativeProofRequest @{operation='complete';state=$Proof.State} $Proof.Root
}
