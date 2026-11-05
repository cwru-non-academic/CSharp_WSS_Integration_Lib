function Assert-WssCiProducerJobs($Jobs,[ValidateSet('legacy-v1','macos-ble-v1')][string]$Contract='macos-ble-v1') {
    $path=Join-Path ([IO.Path]::GetTempPath()) ('wss-producer-jobs-'+[guid]::NewGuid().ToString('N')+'.json')
    try {
        @{jobs=@($Jobs);contract=$Contract}|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $path
        & node (Join-Path $PSScriptRoot 'producer-jobs.mjs') $path
        if($LASTEXITCODE -ne 0){throw 'Common exact producer job validation failed.'}
    } finally {if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}}
}
