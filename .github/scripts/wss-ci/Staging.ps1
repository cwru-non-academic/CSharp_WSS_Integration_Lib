function Test-WssCiStagingPolicy($Tree,$File,$Receiver,[ValidateSet('csharp','unity','python','matlab')][string]$Family) {
    $path=Join-Path ([IO.Path]::GetTempPath()) ('wss-staging-'+[guid]::NewGuid().ToString('N')+'.json')
    try {
        @{tree=$Tree;file=$File;receiver=$Receiver;family=$Family}|ConvertTo-Json -Depth 40|Set-Content -LiteralPath $path
        $raw=& node (Join-Path $PSScriptRoot 'staging.mjs') $path
        if($LASTEXITCODE -ne 0){throw 'Shared producer staging validation failed; no application write is authorized.'}
        $raw|ConvertFrom-Json
    } finally {if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}}
}
