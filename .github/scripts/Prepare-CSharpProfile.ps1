# Keep forwarding arguments unevaluated; the reviewed target validates its schema.
$ErrorActionPreference='Stop'
. "$PSScriptRoot/CSharpProfilesBootstrap.ps1"
Assert-CSharpProfileBootstrap
& "$PSScriptRoot/../../tools/CSharpProfiles/Prepare-CSharpProfile.ps1" @args
