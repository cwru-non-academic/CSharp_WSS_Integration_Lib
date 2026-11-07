# Parent-only proof capture. Do not reconstruct these expected hashes from child
# output or from a rewritten profile.json after executing selectable code.
function Get-PreparedPayloadDigest([string]$Root) {
 $entries=@(Get-ChildItem -LiteralPath $Root -File -Recurse | Sort-Object FullName | ForEach-Object {
  [IO.Path]::GetRelativePath($Root,$_.FullName).Replace('\','/')+':'+(Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
 })
 [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($entries -join "`n")))).ToLowerInvariant()
}
function New-PreparedProfileProof([string]$Path,[string]$PayloadRoot,[string]$IntegrationRoot,[string]$IntegrationSha,[bool]$Campaign) {
 Assert-CSharpProfileBootstrap
 $state=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
 if($state.schema -cne 'wss-csharp-prepared-profile/v1' -or [IO.Path]::GetFullPath($state.integration_root) -cne [IO.Path]::GetFullPath($IntegrationRoot) -or $state.integration_sha -cne $IntegrationSha -or [IO.Path]::GetFullPath($state.payload_root) -cne [IO.Path]::GetFullPath($PayloadRoot)){throw 'Prepared profile is not bound to the authenticated product/payload.'}
 . "$PSScriptRoot/../../tools/CSharpProfiles/Profile.ps1"
 $profile=Resolve-WssReviewedProfile $PayloadRoot $state.profile.producer -SelectionEnabledCampaign:$Campaign
 if($profile.profile -cne $state.profile.profile -or $profile.core_dll_sha256 -cne $state.profile.core_dll_sha256){throw 'Prepared profile identity changed.'}
 $digest=Get-PreparedPayloadDigest $PayloadRoot
 if($digest -cne $state.payload_sha256){throw 'Prepared payload projection changed.'}
 $paths=@($Path,$state.project,(Get-WssProfileFixture $profile.profile))
 foreach($source in $state.sources){$paths+=Join-Path $state.source_root $source.path}
 $files=@($paths | ForEach-Object {@{path=$_;sha256=(Get-FileHash $_ -Algorithm SHA256).Hash}})
 [pscustomobject]@{state=$state;files=$files;payload_root=$PayloadRoot;payload_sha256=$digest}
}
function Assert-PreparedProfileProof($Proof) {
 Assert-CSharpProfileBootstrap
 foreach($file in $Proof.files){if((Get-FileHash $file.path -Algorithm SHA256).Hash -cne $file.sha256){throw 'Trusted prepared profile proof/source changed during child execution.'}}
 if((Get-PreparedPayloadDigest $Proof.payload_root) -cne $Proof.payload_sha256){throw 'Trusted prepared payload changed during child execution.'}
}
