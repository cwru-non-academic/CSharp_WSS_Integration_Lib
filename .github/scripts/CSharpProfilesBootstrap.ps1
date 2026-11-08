# Protected by the existing adapter-pins script identity guard. Family-owned
# files outside .github cannot change executable bootstrap behavior independently.
function Assert-CSharpProfileBootstrap {
    $files=@{
        'Profile.ps1'='db6d9d261215903300f3ad397a80cb4b0c1d7f5ab3b62d151f224421396d1ea9'
        'Prepare-CSharpProfile.ps1'='1562b2c9ae4ed219be88bf0dedd30e5788390a3917210ba23cd6d29af2a6ffb8'
        'Invoke-PreparedBehavior.ps1'='43aae358f90562130166509a96846cf13102a7c497596cdb8b8ea8ab79febe08'
        'Invoke-PreparedFullTests.ps1'='e95655cea2284910ef27251c0052a8d66455f558873474231036a9f16dda38a7'
        'Invoke-Behavior.ps1'='36ef5788c2f8874fc7152fe3ba4e1a0ad9229a8788f624bb5519da64d193499a'
        'fixtures/legacy-v1/StimulationControllerConformanceTests.cs'='f6aeced83d35255532b6685d9c870307f856aad140da133695a77e9de6104ee2'
        'fixtures/layered-v1/StimulationControllerConformanceTests.cs'='96812ab33be7ede8840ddb78131a50796fd3f797d9627f958251b3e58796baf8'
    }
    $root=Join-Path $PSScriptRoot '../../tools/CSharpProfiles'
    foreach($path in $files.Keys){
        $full=Join-Path $root $path
        $bytes=[IO.File]::ReadAllBytes($full)
        if(!$path.StartsWith('fixtures/',[StringComparison]::Ordinal)){
            $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes).Replace("`r`n","`n")
            $bytes=[Text.Encoding]::UTF8.GetBytes($text)
        }
        $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        if($hash -cne $files[$path]){throw "Profile bootstrap differs from reviewed script identity: $path"}
    }
}
