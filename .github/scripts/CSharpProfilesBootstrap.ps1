# Protected by the existing adapter-pins script identity guard. Family-owned
# files outside .github cannot change executable bootstrap behavior independently.
function Assert-CSharpProfileBootstrap {
    $files=@{
        'Profile.ps1'='db6d9d261215903300f3ad397a80cb4b0c1d7f5ab3b62d151f224421396d1ea9'
        'Prepare-CSharpProfile.ps1'='1299cfc0dc51109d9808b568af8fb3455f9122a0d75d9e93e50d44e224753ea5'
        'Invoke-PreparedBehavior.ps1'='a322414d4e70a33078c504baed27d0e1cff9636bcc378ca9ee86c3dd520f3fc7'
        'Invoke-PreparedFullTests.ps1'='ed1b20ab888e8692f469515155f553e07ba82870407b949c932b7384d003afdf'
        'Invoke-Behavior.ps1'='d9419f2f7909a9b579cca546af90f491b5c734f50bc8fd2a68510902d924e9c9'
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
