param(
    [Parameter(Mandatory = $true)] [string] $ArtifactRoot,
    [Parameter(Mandatory = $true)] [string] $ApprovalFile,
    [Parameter(Mandatory = $true)] [string] $Destination
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/WssPromotion.ps1"
. "$PSScriptRoot/Universal-WssFiles.ps1"
$approval = Read-WssApproval $ApprovalFile
$root = (Resolve-Path -LiteralPath $ArtifactRoot).Path
$files = @(Get-ChildItem -LiteralPath $root -File -Recurse | ForEach-Object {
    $_.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
})
$selectedFiles = @(Get-WssUniversalFiles $files)
Assert-WssMacOSPayload $root $selectedFiles
if (Test-Path -LiteralPath $Destination) { throw 'Destination must be new; existing dependencies will not be overwritten.' }
New-Item -ItemType Directory -Path $Destination | Out-Null
foreach ($relative in $selectedFiles) {
    $target = Join-Path $Destination $relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item -LiteralPath (Join-Path $root $relative) -Destination $target
}
# Keep the complete original package, including the net462 alternate. Project copy rules
# exclude that alternate from runnable output while retaining BOTH platform runtime trees.
Write-WssApproval $approval (Join-Path $Destination 'wss-candidate.json')
Assert-WssLib $Destination $root $approval
